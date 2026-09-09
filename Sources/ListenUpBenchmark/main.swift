import Foundation
@preconcurrency import AVFoundation
import ListenUpAI
import ListenUpDomain

@main
struct ListenUpBenchmark {
    enum HarnessError: LocalizedError {
        case usage(String)
        case missingFile(String)
        case audio(String)
        var errorDescription: String? {
            switch self {
            case .usage(let message): return message
            case .missingFile(let path): return "missing local path: \(path)"
            case .audio(let message): return message
            }
        }
    }

    static func main() async {
        do {
            let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
            let required = [args.qwenModel] + (args.qwenOnly ? [args.fixtureText].compactMap { $0 } : [args.whisperModel, args.whisperTokenizer, args.audio].compactMap { $0 })
            for path in required {
                guard FileManager.default.fileExists(atPath: path.path) else { throw HarnessError.missingFile(path.path) }
            }

            let transcript: TranscriptRevision
            if args.qwenOnly {
                if let fixtureText = args.fixtureText {
                    transcript = fixtureTranscript(text: try String(contentsOf: fixtureText, encoding: .utf8))
                    log("[benchmark] using local text fixture \(fixtureText.path)")
                } else {
                    transcript = fixtureTranscript()
                    log("[benchmark] using deterministic Korean transcript fixture")
                }
            } else {
                guard let audio = args.audio, let whisperModel = args.whisperModel, let whisperTokenizer = args.whisperTokenizer else {
                    throw HarnessError.usage(Arguments.usage)
                }
                log("[audio] loading \(audio.path)")
                let samples = try loadMono16kSamples(from: audio)
                log("[audio] loaded \(samples.count) samples")
                let stt = try await transcribeAndRelease(samples: samples, model: whisperModel, tokenizer: whisperTokenizer)
                let segments = stt.enumerated().map { index, segment in
                    TranscriptSegment(id: "benchmark-\(index)", text: segment.text, startMs: Int64((segment.startSeconds * 1000).rounded()), endMs: Int64((segment.endSeconds * 1000).rounded()), requestID: "benchmark")
                }
                let endMs = Int64((Double(samples.count) / 16.0).rounded())
                transcript = TranscriptRevision(id: "benchmark-transcript", segments: segments, coverage: Coverage(startMs: 0, endMs: endMs), modelID: ModelCatalog.whisper.id, configurationHash: ModelCatalog.whisper.revision)
                let transcriptData = try JSONEncoder.pretty.encode(transcript)
                print("[whisper] transcript:\n\(String(decoding: transcriptData, as: UTF8.self))")
                fflush(stdout)
            }

            log("[qwen] loading local model")
            let qwen = try await ProductionQwenInferenceEngine(modelFolder: args.qwenModel)
            let summaryInput = SummaryInput(purpose: .meeting, transcript: transcript, inputHash: "benchmark")
            if args.qwenOnly {
                log("[qwen] generating one raw diagnostic response")
                let prompt = SummaryPrompt.make(input: summaryInput, schema: .meeting)
                let raw = try await qwen.generate(prompt: prompt, maxTokens: Qwen3SummaryAdapter.maxOutputTokens)
                print("[qwen] raw-response-begin\n\(raw)\n[qwen] raw-response-end")
                fflush(stdout)
                let decoded = try SummaryPrompt.decodeAndValidate(from: raw, schema: .meeting, segments: transcript.segments)
                print("[qwen] decoded-sections:\n\(String(decoding: try JSONEncoder.pretty.encode(decoded), as: UTF8.self))")
                fflush(stdout)
            } else {
                log("[qwen] summarizing")
                let summary = try await Qwen3SummaryAdapter(engine: qwen).summarize(summaryInput)
                let summaryData = try JSONEncoder.pretty.encode(summary)
                print("[qwen] summary:\n\(String(decoding: summaryData, as: UTF8.self))")
                fflush(stdout)
            }
        } catch {
            fputs("[benchmark] failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func transcribeAndRelease(samples: [Float], model: URL, tokenizer: URL) async throws -> [WhisperSegment] {
        log("[whisper] loading local model")
        let whisper = try await ProductionWhisperInferenceEngine(modelFolder: model, tokenizerFolder: tokenizer)
        log("[whisper] transcribing")
        return try await whisper.transcribe(samples: samples, language: "ko")
    }

    private static func log(_ message: String) {
        fputs("\(message)\n", stderr)
        fflush(stderr)
    }

    private static func fixtureTranscript() -> TranscriptRevision {
        fixtureTranscript(texts: [
            "오늘 회의에서는 녹음 앱의 첫 번째 시험 일정을 논의했습니다.",
            "지민은 금요일까지 화면 초안을 작성하기로 했습니다.",
            "모델 속도는 아직 측정하지 않았습니다.",
            "다음 회의 날짜는 정하지 않았습니다.",
        ])
    }

    private static func fixtureTranscript(text: String) -> TranscriptRevision {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { sentences.append(value) }
        }
        if sentences.isEmpty {
            sentences = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return fixtureTranscript(texts: sentences)
    }

    private static func fixtureTranscript(texts: [String]) -> TranscriptRevision {
        let segments = texts.enumerated().map { index, text in
            TranscriptSegment(id: "benchmark-\(index)", text: text, startMs: Int64(index * 3_000), endMs: Int64((index + 1) * 3_000), sourceTrack: .imported, requestID: "fixture")
        }
        return TranscriptRevision(id: "benchmark-transcript", segments: segments, coverage: Coverage(startMs: 0, endMs: 12_000), modelID: ModelCatalog.whisper.id, configurationHash: ModelCatalog.whisper.revision)
    }

    private static func loadMono16kSamples(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw HarnessError.audio("cannot open WAV: \(error)") }
        let sourceFormat = file.processingFormat
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else { throw HarnessError.audio("WAV has no audio channels") }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else { throw HarnessError.audio("cannot create 16 kHz mono format") }
        let frameCapacity = AVAudioFrameCount(max(1, Int(ceil(Double(file.length) * 16_000 / sourceFormat.sampleRate))))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { throw HarnessError.audio("cannot allocate conversion buffer") }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { throw HarnessError.audio("unsupported WAV conversion") }
        let input = BenchmarkConverterInput(file: file, format: sourceFormat)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            input.provide(status)
        }
        guard input.error == nil,
              status == .haveData || status == .inputRanDry || status == .endOfStream else {
            throw HarnessError.audio("conversion failed: \(input.error?.localizedDescription ?? conversionError?.localizedDescription ?? "unknown error")")
        }
        guard let channel = output.floatChannelData?[0] else { throw HarnessError.audio("conversion produced no samples") }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

private final class BenchmarkConverterInput: @unchecked Sendable {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private var supplied = false
    private(set) var error: NSError?

    init(file: AVAudioFile, format: AVAudioFormat) {
        self.file = file
        self.format = format
    }

    func provide(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !supplied else { status.pointee = .endOfStream; return nil }
        supplied = true
        do {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
                status.pointee = .endOfStream
                return nil
            }
            try file.read(into: buffer)
            status.pointee = .haveData
            return buffer
        } catch {
            self.error = error as NSError
            status.pointee = .endOfStream
            return nil
        }
    }
}

private struct Arguments {
    static let usage = "usage: ListenUpBenchmark --qwen-model FOLDER [--qwen-only [--fixture-text FILE] | --whisper-model FOLDER --whisper-tokenizer FOLDER --audio FILE.wav]"
    let whisperModel: URL?; let whisperTokenizer: URL?; let qwenModel: URL; let audio: URL?; let fixtureText: URL?; let qwenOnly: Bool
    init(_ values: [String]) throws {
        var parsed: [String: String] = [:]; var index = 0; var qwenOnly = false
        while index < values.count {
            if values[index] == "--qwen-only" { qwenOnly = true; index += 1; continue }
            guard values[index].hasPrefix("--"), index + 1 < values.count else { throw ListenUpBenchmark.HarnessError.usage(Self.usage) }
            parsed[values[index]] = values[index + 1]; index += 2
        }
        guard let qwenModel = parsed["--qwen-model"] else { throw ListenUpBenchmark.HarnessError.usage(Self.usage) }
        if !qwenOnly, parsed["--whisper-model"] == nil || parsed["--whisper-tokenizer"] == nil || parsed["--audio"] == nil {
            throw ListenUpBenchmark.HarnessError.usage(Self.usage)
        }
        self.whisperModel = parsed["--whisper-model"].map(URL.init(fileURLWithPath:))
        self.whisperTokenizer = parsed["--whisper-tokenizer"].map(URL.init(fileURLWithPath:))
        self.qwenModel = URL(fileURLWithPath: qwenModel)
        self.audio = parsed["--audio"].map(URL.init(fileURLWithPath:))
        self.fixtureText = parsed["--fixture-text"].map(URL.init(fileURLWithPath:))
        self.qwenOnly = qwenOnly
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder }
}
