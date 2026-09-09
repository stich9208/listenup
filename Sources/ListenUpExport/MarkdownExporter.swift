import Foundation
import AppKit
import ListenUpDomain

public enum ExportKind: Sendable { case transcript, summary, combined }

public struct MarkdownExporter: Sendable {
    public init() {}

    public func transcript(_ revision: TranscriptRevision, title: String? = nil) throws -> String {
        try DomainValidator.validate(revision)
        var out = "# \(title ?? "Transcript")\n\n"
        out += "Revision: `\(revision.id)`\n\n"
        for segment in revision.segments.sorted(by: { $0.startMs < $1.startMs }) {
            out += "### [\(Self.timestamp(segment.startMs))–\(Self.timestamp(segment.endMs))]\n\n\(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        }
        if !revision.coverage.isComplete {
            out += "> 일부 구간을 처리하지 못했습니다.\n\n"
            for gap in revision.coverage.failedRanges { out += "> 누락 구간: [\(Self.timestamp(gap.startMs))–\(gap.endMs.map(Self.timestamp) ?? "진행 중")] (\(gap.reason.rawValue))\n" }
            out += "\n"
        }
        return out
    }

    public func summary(_ revision: SummaryRevision, title: String? = nil) -> String {
        var out = "# \(title ?? "Summary")\n\n"
        out += "Revision: `\(revision.id)` · Purpose: `\(revision.purpose.rawValue)`\n\n"
        func section(_ heading: String, _ items: [SummaryItem]) { if !items.isEmpty { out += "## \(heading)\n\n"; for item in items { out += "- \(item.text)"; if !item.evidenceSegmentIDs.isEmpty { out += " _(근거: \(item.evidenceSegmentIDs.joined(separator: ", ")))" }; out += "\n" }; out += "\n" } }
        section("Overview", revision.sections.overview); section("Topics", revision.sections.topics); section("Concepts", revision.sections.concepts); section("Examples", revision.sections.examples); section("Emphasized points", revision.sections.emphasizedPoints); section("Agenda", revision.sections.agendaItems); section("Decisions", revision.sections.decisions); section("Open issues", revision.sections.openIssues); section("Disagreements", revision.sections.disagreements); section("Uncertainties", revision.sections.uncertainties)
        if !revision.sections.actionItems.isEmpty { out += "## Action items\n\n"; for item in revision.sections.actionItems { out += "- \(item.task) — owner: \(item.owner ?? "미정") — due: \(item.dueOriginal ?? item.dueNormalized ?? "미정")"; if !item.evidenceSegmentIDs.isEmpty { out += " _(근거: \(item.evidenceSegmentIDs.joined(separator: ", ")))" }; out += "\n" }; out += "\n" }
        if !revision.sections.reviewQuestions.isEmpty { out += "## Review questions\n\n"; for item in revision.sections.reviewQuestions { out += "- 검토 질문: \(item.text)\n" }; out += "\n" }
        return out
    }

    public func combined(session: Session, transcript: TranscriptRevision, summary: SummaryRevision? = nil) throws -> String {
        var out = "# \(session.title)\n\nPurpose: \(session.purpose.displayName)\n\n"
        if session.summaryStale { out += "> 요약이 최신 전사 또는 주석과 일치하지 않아 갱신이 필요합니다.\n\n" }
        if let summary { try DomainValidator.validate(summary, transcript: transcript); out += self.summary(summary) + "\n" }
        out += try transcriptMarkdown(transcript, title: "Full transcript")
        return out
    }

    @discardableResult public func write(_ content: String, to directory: URL, filename: String, conflictIfModified: Bool = true) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = Self.safeFilename(filename); let target = directory.appendingPathComponent(safe).appendingPathExtension("md")
        if conflictIfModified, FileManager.default.fileExists(atPath: target.path) {
            let existing = try String(contentsOf: target, encoding: .utf8)
            if existing != content {
                let stamp = Int(Date().timeIntervalSince1970)
                var index = 0
                while true {
                    index += 1
                    let suffix = "-conflict-\(stamp)-\(index)"
                    let stem = String(safe.prefix(max(1, 100 - suffix.count))) + suffix
                    let candidate = directory.appendingPathComponent(stem).appendingPathExtension("md")
                    if !FileManager.default.fileExists(atPath: candidate.path) { try content.data(using: .utf8)!.write(to: candidate, options: .atomic); return candidate }
                }
            }
        }
        try content.data(using: .utf8)!.write(to: target, options: .atomic); return target
    }

    @discardableResult public func copyMarkdownToPasteboard(_ markdown: String) -> Bool { let p = NSPasteboard.general; p.clearContents(); return p.setString(markdown, forType: .string) && p.setString(Self.html(from: markdown), forType: .html) }
    private func transcriptMarkdown(_ revision: TranscriptRevision, title: String) throws -> String { try transcript(revision, title: title) }
    private static func timestamp(_ ms: Int64) -> String { String(format: "%02d:%02d:%02d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1_000) % 60) }
    public static func safeFilename(_ filename: String) -> String { let base = filename.replacingOccurrences(of: ".md", with: "").unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" }; return String((String(base).trimmingCharacters(in: CharacterSet(charactersIn: "_.-" )).isEmpty ? "export" : String(base).trimmingCharacters(in: CharacterSet(charactersIn: "_.-"))).prefix(100)) }
    public static func html(from markdown: String) -> String {
        func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
        var html = ""; for line in markdown.components(separatedBy: .newlines) { if line.hasPrefix("### ") { html += "<h3>\(escape(String(line.dropFirst(4))))</h3>" } else if line.hasPrefix("## ") { html += "<h2>\(escape(String(line.dropFirst(3))))</h2>" } else if line.hasPrefix("# ") { html += "<h1>\(escape(String(line.dropFirst(2))))</h1>" } else if line.hasPrefix("- ") { html += "<li>\(escape(String(line.dropFirst(2))))</li>" } else if !line.isEmpty { html += "<p>\(escape(line))</p>" } }; return html
    }
}
