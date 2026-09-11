import XCTest
@preconcurrency import AVFoundation
import ListenUpExport
import ListenUpDomain

final class ResultBundleExporterTests: XCTestCase {
    func testBundleContainsOnlyM4AAndCombinedHTML() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionDirectory = root.appendingPathComponent("session", isDirectory: true)
        let audioDirectory = sessionDirectory.appendingPathComponent("audio/microphone", isDirectory: true)
        let source = audioDirectory.appendingPathComponent("000001.caf")
        let archive = root.appendingPathComponent("result.zip")
        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try Self.writeSilentCAF(to: source, durationSeconds: 0.25)
        try "internal".write(
            to: sessionDirectory.appendingPathComponent("session.json"),
            atomically: true,
            encoding: .utf8
        )

        let transcript = TranscriptRevision(
            id: "transcript-internal-id",
            segments: [TranscriptSegment(text: "테스트 전사 <script>", startMs: 0, endMs: 250, requestID: "request-internal-id")],
            coverage: Coverage(startMs: 0, endMs: 250),
            modelID: "fixture",
            configurationHash: "fixture"
        )
        let summary = SummaryRevision(
            id: "summary-internal-id",
            purpose: .meeting,
            sourceTranscriptRevisionID: transcript.id,
            annotationRevisionID: "annotation-internal-id",
            promptVersion: "test",
            modelID: "fixture",
            sections: SummarySections(overview: [SummaryItem(text: "테스트 요약 <b>")]),
            inputHash: "fixture"
        )
        let session = Session(
            title: "테스트 회의",
            purpose: .meeting,
            inputSource: .microphone,
            tracks: [AudioSpan(
                trackID: "microphone",
                relativePath: "audio/microphone/000001.caf",
                durationMs: 250,
                sessionStartMs: 0,
                sampleRate: 48_000,
                frameCount: 12_000,
                checksum: "fixture"
            )]
        )

        try await ResultBundleExporter().export(
            session: session,
            transcript: transcript,
            summary: summary,
            sessionDirectory: sessionDirectory,
            destination: archive
        )

        let entries = try Self.run("/usr/bin/unzip", ["-Z1", archive.path])
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(Set(entries), Set(["recording.m4a", "transcript-summary.html"]))

        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        _ = try Self.run("/usr/bin/unzip", ["-q", archive.path, "-d", extracted.path])
        let exportedAudio = extracted.appendingPathComponent("recording.m4a")
        let asset = AVURLAsset(url: exportedAudio)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty)
        let resultHTML = try String(
            contentsOf: extracted.appendingPathComponent("transcript-summary.html"),
            encoding: .utf8
        )
        XCTAssertTrue(resultHTML.contains("테스트 전사"))
        XCTAssertTrue(resultHTML.contains("테스트 요약"))
        XCTAssertTrue(resultHTML.contains("&lt;script&gt;"))
        XCTAssertTrue(resultHTML.contains("&lt;b&gt;"))
        XCTAssertFalse(resultHTML.contains("<script>"))
        XCTAssertTrue(resultHTML.contains("src=\"recording.m4a\""))
        XCTAssertFalse(resultHTML.contains("transcript-internal-id"))
        XCTAssertFalse(resultHTML.contains("request-internal-id"))
        XCTAssertFalse(resultHTML.contains("session.json"))
    }

    private static func writeSilentCAF(to url: URL, durationSeconds: Double) throws {
        let sampleRate = 48_000.0
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw ListenUpError.writeFailed("test audio format") }
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ListenUpError.writeFailed("test audio buffer")
        }
        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData?.pointee {
            channel.initialize(repeating: 0, count: Int(frameCount))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ListenUpError.writeFailed(message)
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
