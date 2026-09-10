import Foundation
import AppKit
import ListenUpDomain

public enum ExportKind: Sendable { case transcript, summary, combined }

public struct SummaryDocumentItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let detail: String?

    public init(id: UUID, text: String, detail: String? = nil) {
        self.id = id
        self.text = text
        self.detail = detail
    }
}

public struct SummaryDocumentSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let items: [SummaryDocumentItem]
    public let numbered: Bool

    public init(title: String, items: [SummaryDocumentItem], numbered: Bool = false) {
        self.id = title
        self.title = title
        self.items = items
        self.numbered = numbered
    }
}

public struct SummaryDocument: Equatable, Sendable {
    public let title: String
    public let sections: [SummaryDocumentSection]

    public init(title: String, sections: [SummaryDocumentSection]) {
        self.title = title
        self.sections = sections
    }
}

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
        let document = summaryDocument(revision, title: title)
        var out = "# \(document.title)\n\n"
        for section in document.sections {
            out += "## \(section.title)\n\n"
            for (index, item) in section.items.enumerated() {
                let marker = section.numbered ? "\(index + 1)." : "-"
                out += "\(marker) \(item.text)"
                if let detail = item.detail { out += " — \(detail)" }
                out += "\n"
            }
            out += "\n"
        }
        return out
    }

    public func summaryDocument(_ revision: SummaryRevision, title: String? = nil) -> SummaryDocument {
        func items(_ values: [SummaryItem]) -> [SummaryDocumentItem] {
            values.map { SummaryDocumentItem(id: $0.id, text: $0.text) }
        }
        func section(_ title: String, _ values: [SummaryItem], numbered: Bool = false) -> SummaryDocumentSection? {
            guard !values.isEmpty else { return nil }
            return SummaryDocumentSection(title: title, items: items(values), numbered: numbered)
        }

        var sections: [SummaryDocumentSection?]
        if revision.purpose == .meeting {
            let actionItems = revision.sections.actionItems.map {
                SummaryDocumentItem(
                    id: $0.id,
                    text: $0.task,
                    detail: "\($0.owner ?? "담당 미정") / \($0.dueOriginal ?? $0.dueNormalized ?? "기한 미정")"
                )
            }
            sections = [
                section("요약", revision.sections.overview),
                section("결정사항", revision.sections.decisions, numbered: true),
                actionItems.isEmpty ? nil : SummaryDocumentSection(title: "Action Items", items: actionItems, numbered: true),
                section("미결사항", revision.sections.openIssues + revision.sections.disagreements + revision.sections.uncertainties, numbered: true),
            ]
        } else {
            sections = [
                section("강의 개요", revision.sections.overview),
                section("주제", revision.sections.topics),
                section("개념", revision.sections.concepts),
                section("예시와 계산", revision.sections.examples),
                section("핵심 정리", revision.sections.emphasizedPoints),
                section("복습 질문", revision.sections.reviewQuestions),
                section("불확실한 내용", revision.sections.uncertainties),
            ]
        }
        return SummaryDocument(
            title: title ?? (revision.purpose == .meeting ? "회의 요약" : "강의 요약"),
            sections: sections.compactMap { $0 }
        )
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
