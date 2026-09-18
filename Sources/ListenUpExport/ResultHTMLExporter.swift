import Foundation
import ListenUpDomain

public struct ResultHTMLExporter {
    public init() {}

    public func html(
        title: String,
        transcript: TranscriptRevision,
        summary: SummaryRevision
    ) throws -> String {
        try DomainValidator.validate(transcript)
        try DomainValidator.validate(summary, transcript: transcript)

        let document = MarkdownExporter().summaryDocument(summary, title: title)
        func renderItems(_ items: [SummaryDocumentItem], numbered: Bool) -> String {
            let listTag = numbered ? "ol" : "ul"
            let values = items.map { item in
                var value = "<span>\(Self.escape(item.text))</span>"
                if let detail = item.detail {
                    value += "<small>\(Self.escape(detail))</small>"
                }
                if !item.children.isEmpty {
                    value += renderItems(item.children, numbered: false)
                }
                return "<li>\(value)</li>"
            }.joined(separator: "\n")
            return "<\(listTag)>\(values)</\(listTag)>"
        }
        let summarySections = document.sections.map { section in
            let headingTag = "h\(min(6, max(2, section.headingLevel)))"
            return """
            <section class="summary-section">
              <\(headingTag)>\(Self.escape(section.title))</\(headingTag)>
              \(renderItems(section.items, numbered: section.numbered))
            </section>
            """
        }.joined(separator: "\n")

        let transcriptSections = transcript.segments
            .sorted { $0.startMs < $1.startMs }
            .map { segment in
                """
                <article class="transcript-segment">
                  <time>\(Self.timestamp(segment.startMs))–\(Self.timestamp(segment.endMs))</time>
                  <p>\(Self.escape(segment.text.trimmingCharacters(in: .whitespacesAndNewlines)))</p>
                </article>
                """
            }
            .joined(separator: "\n")

        let coverageNotice = transcript.coverage.isComplete ? "" : """
        <p class="notice">일부 녹음 구간을 처리하지 못해 전사에 누락이 있을 수 있습니다.</p>
        """

        return """
        <!doctype html>
        <html lang="ko">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(Self.escape(title))</title>
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Noto Sans KR", sans-serif; }
            body { margin: 0; background: Canvas; color: CanvasText; line-height: 1.65; -webkit-user-select: text; user-select: text; }
            main { width: min(880px, calc(100% - 40px)); margin: 0 auto; padding: 48px 0 80px; }
            h1 { margin: 0 0 24px; font-size: clamp(2rem, 5vw, 3rem); line-height: 1.15; }
            h2 { margin: 0 0 12px; font-size: 1.25rem; }
            h3 { margin: 0 0 12px; font-size: 1.12rem; }
            .summary-section, .transcript-segment, .notice { border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: 14px; padding: 18px; }
            .summary-grid { display: grid; gap: 14px; margin-bottom: 48px; }
            .summary-section ul, .summary-section ol { margin: 0; padding-left: 24px; }
            .summary-section li > ul, .summary-section li > ol { margin-top: 6px; }
            .summary-section li + li { margin-top: 8px; }
            .summary-section small { display: block; opacity: .7; margin-top: 2px; }
            .transcript { display: grid; gap: 12px; }
            .transcript-segment time { display: block; margin-bottom: 6px; font: 600 .85rem ui-monospace, SFMono-Regular, Menlo, monospace; opacity: .7; }
            .transcript-segment p { margin: 0; white-space: pre-wrap; }
            .notice { margin-bottom: 16px; border-color: #d29922; background: color-mix(in srgb, #d29922 12%, transparent); }
            ::selection { background: color-mix(in srgb, #0a84ff 32%, transparent); }
            @media (max-width: 560px) { main { width: min(100% - 24px, 880px); padding-top: 28px; } }
          </style>
        </head>
        <body>
          <main>
            <h1>\(Self.escape(title))</h1>
            <section aria-labelledby="summary-heading">
              <h1 id="summary-heading">요약</h1>
              <div class="summary-grid">\(summarySections)</div>
            </section>
            <section aria-labelledby="transcript-heading">
              <h1 id="transcript-heading">전체 전사</h1>
              \(coverageNotice)
              <div class="transcript">\(transcriptSections)</div>
            </section>
          </main>
        </body>
        </html>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
        String(
            format: "%02d:%02d:%02d",
            milliseconds / 3_600_000,
            (milliseconds / 60_000) % 60,
            (milliseconds / 1_000) % 60
        )
    }
}
