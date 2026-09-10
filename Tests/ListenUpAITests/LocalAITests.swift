import Testing
import Foundation
@testable import ListenUpAI
import ListenUpDomain

@Test func catalogPinsVerifiedAssets() {
    #expect(ModelCatalog.qwen.revision == "4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25")
    #expect(ModelCatalog.qwen.files.count == 9)
    #expect(ModelCatalog.qwen.files.first(where: { $0.path == "model.safetensors" })?.sha256 == "e240c0bdc0ebb0681bf0da0f98d9719fd6ebe269a3633f81542c13e81345651d")
    #expect(ModelCatalog.whisper.revision == "0f63a7800b00dd0226abd051b906c246e1907482")
    #expect(ModelCatalog.whisper.totalBytes == 626_718_238)
}

@Test func whisperAdapterMapsTimestampsAndKoreanHint() async throws {
    let engine = FakeWhisperEngine()
    let adapter = WhisperKitAdapter(engine: engine)
    let result = try await adapter.transcribe(LocalAudioInput(samples: [0], startMs: 100, requestID: "r"), languageHint: "ko")
    #expect(engine.lastLanguage == "ko")
    #expect(result.segments[0].startMs == 600)
    #expect(result.segments[0].endMs == 1_600)
}

@Test func summaryRejectsUnknownEvidence() async throws {
    let transcript = TranscriptRevision(id: "t", segments: [TranscriptSegment(id: "known", text: "text", startMs: 0, endMs: 1, requestID: "r")], coverage: Coverage(startMs: 0, endMs: 1), modelID: "m", configurationHash: "c")
    let sections = SummarySections(overview: [SummaryItem(text: "bad", evidenceSegmentIDs: ["missing"])])
    let summary = SummaryRevision(id: "s", purpose: .lecture, sourceTranscriptRevisionID: "t", annotationRevisionID: "a", promptVersion: "p", modelID: "m", sections: sections, inputHash: "h")
    let provider = MockSummaryProvider(result: summary)
    do { _ = try await provider.summarize(SummaryInput(purpose: .lecture, transcript: transcript, inputHash: "h")); Issue.record("expected invalid evidence") } catch { #expect(error as? ListenUpError == .missingReference("summary evidence")) }
}

@Test func meetingSummaryAllowsSynthesizedOverview() throws {
    let sections = SummarySections(overview: [SummaryItem(text: "회의 목적과 핵심 흐름", evidenceSegmentIDs: ["s"])])
    try SummaryPrompt.validate(sections, schema: .meeting, allowedSegmentIDs: ["s"])
}

private final class FakeWhisperEngine: WhisperKitEngine, @unchecked Sendable {
    var lastLanguage: String?
    func transcribe(samples: [Float], language: String?) async throws -> [WhisperSegment] { lastLanguage = language; return [WhisperSegment(text: "안녕", startSeconds: 0.5, endSeconds: 1.5)] }
}

@Test func whisperAdapterPropagatesEngineFailure() async {
    let adapter = WhisperKitAdapter(engine: FailingWhisperEngine())
    do {
        _ = try await adapter.transcribe(LocalAudioInput(samples: [0]), languageHint: "ko")
        Issue.record("expected transcription failure")
    } catch {
        #expect(error as? ListenUpError == .modelUnavailable("decoder failed"))
    }
}

private struct FailingWhisperEngine: WhisperKitEngine {
    func transcribe(samples: [Float], language: String?) async throws -> [WhisperSegment] {
        throw ListenUpError.modelUnavailable("decoder failed")
    }
}

@Test func contentRangeRequiresExactResumeOffsetAndTotal() {
    #expect(ModelManager.validContentRange("bytes 10-99/100", expectedStart: 10, expectedTotal: 100))
    #expect(!ModelManager.validContentRange("bytes 0-99/100", expectedStart: 10, expectedTotal: 100))
    #expect(!ModelManager.validContentRange("bytes 10-99/101", expectedStart: 10, expectedTotal: 100))
    #expect(!ModelManager.validContentRange("bytes 10-98/100", expectedStart: 10, expectedTotal: 100))
    #expect(!ModelManager.validContentRange("bytes */100", expectedStart: 10, expectedTotal: 100))
}

@Test func rangeRequestReceivingFullResponseRestartsPartialSafely() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("listenup-range-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = ModelManifest(
        id: "test/model", revision: "r1",
        files: [ModelFile(path: "payload", byteCount: 5, sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")],
        totalBytes: 5, downloadBaseURL: URL(string: "https://example.invalid")!
    )
    let staging = root.appendingPathComponent("test_model/staging-r1")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try Data("he".utf8).write(to: staging.appendingPathComponent("payload.partial"))
    try "\"v1\"".write(to: staging.appendingPathComponent("payload.etag"), atomically: true, encoding: .utf8)

    MockModelURLProtocol.handler = { request in
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=2-")
        #expect(request.value(forHTTPHeaderField: "If-Range") == "\"v1\"")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "5", "ETag": "\"v2\""])!
        return (response, Data("hello".utf8))
    }
    defer { MockModelURLProtocol.handler = nil }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockModelURLProtocol.self]
    let manager = ModelManager(root: root, session: URLSession(configuration: configuration), runtimeValidator: { _, _, _ in })
    try await manager.install(manifest)
    let installed = try Data(contentsOf: await manager.activeURL(for: manifest).appendingPathComponent("payload"))
    #expect(String(decoding: installed, as: UTF8.self) == "hello")
}

private final class MockModelURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw ListenUpError.writeFailed("missing mock handler") }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@Test func failedRuntimeValidationRetainsPreviousActiveInstall() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("listenup-model-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = ModelManifest(
        id: "test/model", revision: "r1",
        files: [ModelFile(path: "payload", byteCount: 0, sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")],
        totalBytes: 0, downloadBaseURL: URL(string: "https://example.invalid")!
    )
    let manager = ModelManager(root: root, runtimeValidator: { _, _, _ in
        throw ListenUpError.modelUnavailable("runtime parse")
    })
    let active = await manager.activeURL(for: manifest)
    let staging = root.appendingPathComponent("staged")
    try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
    try Data("working".utf8).write(to: active.appendingPathComponent("old"))
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: staging.appendingPathComponent("payload").path, contents: Data())

    await #expect(throws: ListenUpError.modelUnavailable("runtime parse")) {
        try await manager.activate(manifest: manifest, staging: staging)
    }
    #expect(FileManager.default.fileExists(atPath: active.appendingPathComponent("old").path))
    #expect(FileManager.default.fileExists(atPath: staging.path))
}

@Test func summaryRejectsExcludedEvidenceAndPurposeMismatch() async throws {
    let segment = TranscriptSegment(id: "excluded", text: "secret", startMs: 100, endMs: 200, requestID: "r")
    let transcript = TranscriptRevision(id: "t", segments: [segment], coverage: Coverage(startMs: 0, endMs: 200), modelID: "m", configurationHash: "c")
    let annotations = AnnotationRevision(id: "a", annotations: [
        Annotation(kind: .textExclusion, startMs: 0, textSelection: TextSelection(segmentID: "excluded", range: 0..<3), excludedFromSummary: true)
    ])
    let input = SummaryInput(purpose: .lecture, transcript: transcript, annotations: annotations, inputHash: "h")
    #expect(SummaryPrompt.segmentChunks(input: input) == [[]])

    let sections = SummarySections(
        overview: [SummaryItem(text: "leak", evidenceSegmentIDs: ["excluded"])],
        decisions: [SummaryItem(text: "wrong schema", evidenceSegmentIDs: ["excluded"])]
    )
    #expect(throws: ListenUpError.missingReference("summary evidence")) {
        try SummaryPrompt.validate(sections, schema: .lecture, allowedSegmentIDs: [])
    }
}

@Test func summaryRequiresEvidenceAndGeneratedReviewQuestionFlag() {
    let missingEvidence = SummarySections(overview: [SummaryItem(text: "unsupported")])
    #expect(throws: ListenUpError.missingReference("summary evidence")) {
        try SummaryPrompt.validate(missingEvidence, schema: .lecture, allowedSegmentIDs: ["s"])
    }
    let wrongGeneratedFlag = SummarySections(reviewQuestions: [SummaryItem(text: "question", evidenceSegmentIDs: ["s"], generated: false)])
    #expect(throws: ListenUpError.invalidModelResponse("lecture summary schema")) {
        try SummaryPrompt.validate(wrongGeneratedFlag, schema: .lecture, allowedSegmentIDs: ["s"])
    }
}

@Test func summaryDecoderSkipsReasoningObjectsBeforeFinalJSON() throws {
    let json = #"{"overview":[{"id":"UUID1","text":"answer","evidenceSegmentIDs":["s"],"generated":false}]}"#
    let output = "<think>{\"draft\":true}</think>\n```json\n\(json)\n```"
    let decoded = SummaryPrompt.decodeSections(from: output)
    #expect(decoded?.overview.first?.text == "answer")
    #expect(decoded?.overview.first?.evidenceSegmentIDs == ["s"])
    #expect(decoded?.topics.isEmpty == true)
}

@Test func heldoutMeetingRejectsFabricatedActionsAndKeepsConciseGroundedTask() throws {
    let segments = [
        TranscriptSegment(id: "h0", text: "수연이 다음 주 화요일까지 견적서를 보내기로 했다.", startMs: 0, endMs: 1, requestID: "r"),
        TranscriptSegment(id: "h1", text: "예산 증액은 제안만 나왔고 결정하지 않았다.", startMs: 1, endMs: 2, requestID: "r"),
        TranscriptSegment(id: "h2", text: "보안 점검은 아직 하지 않았다.", startMs: 2, endMs: 3, requestID: "r"),
        TranscriptSegment(id: "h3", text: "다음 회의 날짜와 담당자는 정하지 않았다.", startMs: 3, endMs: 4, requestID: "r")
    ]
    let raw = #"{"actionItems":[{"task":"견적서 작성","owner":"수연","dueOriginal":"다음 주 화요일","dueNormalized":"2023-10-12","evidenceSegmentIDs":["h0"]},{"task":"예산 증액 검토","owner":null,"dueOriginal":null,"dueNormalized":null,"evidenceSegmentIDs":["h1"]},{"task":"보안 점검","owner":null,"dueOriginal":null,"dueNormalized":null,"evidenceSegmentIDs":["h2"]},{"task":"다음 회의 날짜와 담당자 결정","owner":null,"dueOriginal":null,"dueNormalized":null,"evidenceSegmentIDs":["h3"]}]}"#
    let decoded = try SummaryPrompt.decodeAndValidate(from: raw, schema: .meeting, segments: segments)
    #expect(decoded.actionItems.count == 1)
    #expect(decoded.actionItems[0].task == "견적서 작성")
    #expect(decoded.actionItems[0].owner == "수연")
    #expect(decoded.actionItems[0].dueOriginal == "다음 주 화요일")
    #expect(decoded.actionItems[0].dueNormalized == nil)
    #expect(decoded.actionItems[0].evidenceSegmentIDs == ["h0"])
    #expect(decoded.uncertainties.isEmpty)
}

@Test func commitmentGrammarRejectsNegationsAndAcceptsExplicitAgreement() throws {
    let segments = [
        TranscriptSegment(id: "n0", text: "보안 점검을 하기로 하지는 않았다.", startMs: 0, endMs: 1, requestID: "r"),
        TranscriptSegment(id: "n1", text: "검토해 보자는 제안만 있었고 정하지 않았다.", startMs: 1, endMs: 2, requestID: "r"),
        TranscriptSegment(id: "n2", text: "자료 정리는 아직 하지 않았다.", startMs: 2, endMs: 3, requestID: "r"),
        TranscriptSegment(id: "n3", text: "민수가 맡기로 했다는 말은 사실이 아니다.", startMs: 3, endMs: 4, requestID: "r"),
        TranscriptSegment(id: "n4", text: "Nobody agreed to send it.", startMs: 4, endMs: 5, requestID: "r"),
        TranscriptSegment(id: "p0", text: "배포 전에 보안 설정을 검토하기로 했다.", startMs: 5, endMs: 6, requestID: "r")
    ]
    let decoded = try SummaryPrompt.decodeAndValidate(from: #"{"actionItems":[]}"#, schema: .meeting, segments: segments)
    #expect(decoded.actionItems.isEmpty)
}
