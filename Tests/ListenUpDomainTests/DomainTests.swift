import Foundation
import Testing
@testable import ListenUpDomain

@Test func sessionRoundTripAndValidation() throws {
    let session = Session(title: "분산 시스템 강의", purpose: .lecture, inputSource: .systemAudio)
    try DomainValidator.validate(session)
    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(Session.self, from: data)
    #expect(decoded == session)
    #expect(decoded.providerConfiguration.sttLocation == .cloud)
    #expect(decoded.providerConfiguration.summaryLocation == .cloud)
}

@Test func rejectsPathTraversal() {
    let span = AudioSpan(trackID: "system", relativePath: "../escape.caf", durationMs: 1_000, sessionStartMs: 0, sampleRate: 48_000, frameCount: 48_000, checksum: "abc")
    let session = Session(title: "test", purpose: .meeting, inputSource: .systemAudio, tracks: [span])
    #expect(throws: ListenUpError.invalidRelativePath("../escape.caf")) { try DomainValidator.validate(session) }
}

@Test func acceptsMacFilenameCharactersAndRedundantSeparators() throws {
    try DomainValidator.validateRelativePath("audio/meeting\\notes.caf")
    try DomainValidator.validateRelativePath("audio//system/000001.m4a")
}

@Test func summaryMustReferenceExistingSegment() throws {
    let transcript = TranscriptRevision(id: "t1", segments: [TranscriptSegment(id: "s1", text: "결정되지 않았다.", startMs: 0, endMs: 1_000, requestID: "r1")], coverage: Coverage(startMs: 0, endMs: 1_000), modelID: "mock", configurationHash: "hash")
    let summary = SummaryRevision(id: "sum1", purpose: .meeting, sourceTranscriptRevisionID: "t1", annotationRevisionID: "a1", promptVersion: "1", modelID: "mock", sections: SummarySections(decisions: [SummaryItem(text: "잘못된 근거", evidenceSegmentIDs: ["missing"])]), inputHash: "hash")
    #expect(throws: ListenUpError.missingReference("summary evidence")) { try DomainValidator.validate(summary, transcript: transcript) }
}

@Test func oldSummarySectionsDecodeWithoutLectureNotes() throws {
    let json = #"{"overview":[],"topics":[],"concepts":[],"examples":[],"emphasizedPoints":[],"reviewQuestions":[],"agendaItems":[],"decisions":[],"actionItems":[],"openIssues":[],"disagreements":[],"uncertainties":[]}"#
    let decoded = try JSONDecoder().decode(SummarySections.self, from: Data(json.utf8))
    #expect(decoded.lectureNotes == nil)
}

@Test func nestedStudyNoteEvidenceMustReferenceExistingSegment() throws {
    let transcript = TranscriptRevision(id: "t", segments: [TranscriptSegment(id: "s1", text: "근거", startMs: 0, endMs: 1, requestID: "r")], coverage: Coverage(startMs: 0, endMs: 1), modelID: "m", configurationHash: "h")
    let sections = SummarySections(lectureNotes: [
        StudyNoteSection(title: "주제", items: [
            StudyNoteItem(text: "상위", children: [
                StudyNoteItem(text: "잘못된 하위 근거", evidenceSegmentIDs: ["missing"])
            ], evidenceSegmentIDs: ["s1"])
        ])
    ])
    let summary = SummaryRevision(id: "sum", purpose: .lecture, sourceTranscriptRevisionID: "t", annotationRevisionID: "a", promptVersion: "v5", modelID: "m", sections: sections, inputHash: "h")

    #expect(throws: ListenUpError.missingReference("summary evidence")) {
        try DomainValidator.validate(summary, transcript: transcript)
    }
}
