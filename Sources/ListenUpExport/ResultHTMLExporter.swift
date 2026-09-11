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
        let summarySections = document.sections.map { section in
            let listTag = section.numbered ? "ol" : "ul"
            let items = section.items.map { item in
                var value = "<span>\(Self.escape(item.text))</span>"
                if let detail = item.detail {
                    value += "<small>\(Self.escape(detail))</small>"
                }
                return "<li>\(value)</li>"
            }.joined(separator: "\n")
            return """
            <section class="summary-section">
              <h2>\(Self.escape(section.title))</h2>
              <\(listTag)>\(items)</\(listTag)>
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
            body { margin: 0; background: Canvas; color: CanvasText; line-height: 1.65; }
            main { width: min(880px, calc(100% - 40px)); margin: 0 auto; padding: 48px 0 80px; }
            h1 { margin: 0 0 24px; font-size: clamp(2rem, 5vw, 3rem); line-height: 1.15; }
            h2 { margin: 0 0 12px; font-size: 1.25rem; }
            .recording, .summary-section, .transcript-segment, .notice { border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: 14px; padding: 18px; }
            .recording { margin-bottom: 36px; background: color-mix(in srgb, CanvasText 4%, transparent); }
            audio { display: block; width: 100%; margin-top: 10px; }
            .summary-grid { display: grid; gap: 14px; margin-bottom: 48px; }
            .summary-section ul, .summary-section ol { margin: 0; padding-left: 24px; }
            .summary-section li + li { margin-top: 8px; }
            .summary-section small { display: block; opacity: .7; margin-top: 2px; }
            .transcript { display: grid; gap: 12px; }
            .transcript-segment time { display: block; margin-bottom: 6px; font: 600 .85rem ui-monospace, SFMono-Regular, Menlo, monospace; opacity: .7; }
            .transcript-segment p { margin: 0; white-space: pre-wrap; }
            .notice { margin-bottom: 16px; border-color: #d29922; background: color-mix(in srgb, #d29922 12%, transparent); }
            @media (max-width: 560px) { main { width: min(100% - 24px, 880px); padding-top: 28px; } }
          </style>
        </head>
        <body>
          <main>
            <h1>\(Self.escape(title))</h1>
            <section class="recording">
              <h2>녹음</h2>
              <audio controls preload="metadata" src="recording.m4a">이 브라우저에서는 오디오 재생을 지원하지 않습니다.</audio>
            </section>
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
