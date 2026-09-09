import XCTest
import ListenUpExport
import ListenUpDomain

final class MarkdownExporterTests: XCTestCase {
    func testTranscriptAndSummaryContainEvidenceAndTimestamps() throws {
        let transcript = TranscriptRevision(id: "transcript-r001", segments: [TranscriptSegment(id: "s1", text: "Hello <world>", startMs: 12_000, endMs: 15_000, requestID: "r")], coverage: Coverage(startMs: 0, endMs: 15_000), modelID: "fixture", configurationHash: "fixture")
        let summary = SummaryRevision(id: "summary-r001", purpose: .meeting, sourceTranscriptRevisionID: transcript.id, annotationRevisionID: "annotations-r001", promptVersion: "1", modelID: "fixture", sections: SummarySections(decisions: [SummaryItem(text: "Decide rollout", evidenceSegmentIDs: ["s1"]) ]), inputHash: "hash")
        let exporter = MarkdownExporter()
        let text = try exporter.transcript(transcript)
        XCTAssertTrue(text.contains("[00:00:12–00:00:15]")); XCTAssertTrue(text.contains("Hello <world>"))
        let sum = exporter.summary(summary); XCTAssertTrue(sum.contains("Decide rollout")); XCTAssertTrue(sum.contains("s1"))
    }

    func testWriteUsesSafeNameAndPreservesModifiedExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = MarkdownExporter(); let first = try exporter.write("one", to: directory, filename: "../meeting:notes")
        XCTAssertTrue(first.lastPathComponent.contains("meeting_notes")); let second = try exporter.write("two", to: directory, filename: "../meeting:notes")
        XCTAssertNotEqual(first, second); XCTAssertEqual(try String(contentsOf: first), "one")
        XCTAssertTrue(second.lastPathComponent.contains("conflict"))
        let third = try exporter.write("three", to: directory, filename: "../meeting:notes")
        XCTAssertNotEqual(second, third)
    }

    func testIncompleteCoverageAndActionUncertaintyAreVisible() throws {
        let gap = Gap(startMs: 1_000, endMs: 2_000, reason: .device)
        let transcript = TranscriptRevision(id: "t", segments: [], coverage: Coverage(startMs: 0, endMs: 2_000, failedRanges: [gap]), modelID: "fixture", configurationHash: "fixture")
        let action = ActionItem(task: "Follow up", evidenceSegmentIDs: ["s1"])
        let summary = SummaryRevision(id: "s", purpose: .meeting, sourceTranscriptRevisionID: "t", annotationRevisionID: "a", promptVersion: "1", modelID: "fixture", sections: SummarySections(actionItems: [action]), inputHash: "x")
        let output = try MarkdownExporter().transcript(transcript)
        XCTAssertTrue(output.contains("누락 구간")); XCTAssertTrue(MarkdownExporter().summary(summary).contains("미정")); XCTAssertTrue(MarkdownExporter().summary(summary).contains("s1"))
    }

    func testLongExportRetainsAllText() throws {
        let transcript = TranscriptRevision(id: "t", segments: [TranscriptSegment(id: "s", text: String(repeating: "가", count: 100_000), startMs: 0, endMs: 1, requestID: "fixture")], coverage: Coverage(startMs: 0, endMs: 1), modelID: "fixture", configurationHash: "fixture")
        XCTAssertEqual(try MarkdownExporter().transcript(transcript).filter { $0 == "가" }.count, 100_000)
        XCTAssertTrue(MarkdownExporter.html(from: "# Title\n- <unsafe>").contains("<h1>")); XCTAssertFalse(MarkdownExporter.html(from: "# Title\n- <unsafe>").contains("<unsafe>"))
    }

    func testCombinedMarksStaleSummaryAndValidatesReferences() throws {
        let transcript = TranscriptRevision(id: "t", segments: [TranscriptSegment(id: "s", text: "text", startMs: 0, endMs: 1, requestID: "x")], coverage: Coverage(startMs: 0, endMs: 1), modelID: "fixture", configurationHash: "fixture")
        let summary = SummaryRevision(id: "sum", purpose: .lecture, sourceTranscriptRevisionID: "t", annotationRevisionID: "a", promptVersion: "1", modelID: "fixture", sections: SummarySections(), inputHash: "x")
        var session = Session(title: "Session", purpose: .lecture, inputSource: .importedFile); session.summaryStale = true
        XCTAssertTrue(try MarkdownExporter().combined(session: session, transcript: transcript, summary: summary).contains("갱신이 필요"))
        let bad = SummaryRevision(id: "bad", purpose: .lecture, sourceTranscriptRevisionID: "missing", annotationRevisionID: "a", promptVersion: "1", modelID: "fixture", sections: SummarySections(), inputHash: "x")
        XCTAssertThrowsError(try MarkdownExporter().combined(session: session, transcript: transcript, summary: bad))
    }
}
