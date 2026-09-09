import Foundation
import WhisperKit
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers
import ListenUpDomain
import NaturalLanguage

/// Concrete WhisperKit bridge. The model and tokenizer folders are required to exist before
/// initialization; `download: false` prevents WhisperKit's setup path from contacting Hub.
public final class ProductionWhisperInferenceEngine: WhisperKitEngine, @unchecked Sendable {
    private let whisper: WhisperKit

    static func validateTokenizer(at folder: URL) async throws {
        _ = try await StrictLocalWhisperTokenizer.load(from: folder)
    }

    public init(modelFolder: URL, tokenizerFolder: URL) async throws {
        guard FileManager.default.fileExists(atPath: modelFolder.path),
              FileManager.default.fileExists(atPath: tokenizerFolder.path) else {
            throw ListenUpError.modelUnavailable("local Whisper model/tokenizer")
        }
        self.whisper = try await OfflineWhisperKit(
            model: modelFolder.lastPathComponent,
            modelFolder: modelFolder.path,
            tokenizerFolder: tokenizerFolder,
            load: true,
            download: false
        )
    }

    public func transcribe(samples: [Float], language: String?) async throws -> [WhisperSegment] {
        let options = DecodingOptions(language: language, temperatureFallbackCount: 0, skipSpecialTokens: true)
        let transcriptions = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let sourceSegments = transcriptions.flatMap(\.segments)
        return sourceSegments.map { segment in
            WhisperSegment(
                text: segment.text,
                startSeconds: Double(segment.start),
                endSeconds: Double(segment.end)
            )
        }
    }
}

/// WhisperKit 1.1.0 falls back to Hugging Face when local tokenizer parsing fails, even when
/// model downloads are disabled. This subclass loads and injects the tokenizer directly from
/// the selected folder so an invalid local install fails without making a network request.
private final class OfflineWhisperKit: WhisperKit, @unchecked Sendable {
    override func loadTokenizerIfNeeded() async throws {
        guard tokenizer == nil else { return }
        guard let tokenizerFolder else {
            throw ListenUpError.modelUnavailable("local Whisper tokenizer")
        }
        guard let logitsSize = textDecoder.logitsSize else {
            throw ListenUpError.modelUnavailable("Whisper decoder metadata")
        }
        textDecoder.isModelMultilingual = logitsSize != 51_864
        tokenizer = try await StrictLocalWhisperTokenizer.load(from: tokenizerFolder)
    }
}

private final class StrictLocalWhisperTokenizer: WhisperTokenizer, @unchecked Sendable {
    private let tokenizer: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    static func load(from folder: URL) async throws -> StrictLocalWhisperTokenizer {
        let required = ["tokenizer.json", "tokenizer_config.json"]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }) else {
            throw ListenUpError.modelUnavailable("local Whisper tokenizer files")
        }
        // `from(modelFolder:)` is the local-only API. It parses the files at `folder` and has
        // no pretrained repository identifier from which it could download a replacement.
        let tokenizer = try await AutoTokenizerWrapper.from(modelFolder: folder, strict: true)
        return try StrictLocalWhisperTokenizer(tokenizer: tokenizer)
    }

    private init(tokenizer: TokenizerWrapper) throws {
        self.tokenizer = tokenizer
        func requiredToken(_ value: String) throws -> Int {
            guard let id = tokenizer.convertTokenToId(value) else {
                throw ListenUpError.modelUnavailable("Whisper tokenizer token \(value)")
            }
            return id
        }
        let end = try requiredToken("<|endoftext|>")
        specialTokens = try SpecialTokens(
            endToken: end,
            englishToken: requiredToken("<|en|>"),
            noSpeechToken: requiredToken("<|nospeech|>"),
            noTimestampsToken: requiredToken("<|notimestamps|>"),
            specialTokenBegin: end,
            startOfPreviousToken: requiredToken("<|startofprev|>"),
            startOfTranscriptToken: requiredToken("<|startoftranscript|>"),
            timeTokenBegin: requiredToken("<|0.00|>"),
            transcribeToken: requiredToken("<|transcribe|>"),
            translateToken: requiredToken("<|translate|>"),
            // Whisper's byte-level vocabulary represents this as `Ġ`; WhisperKit's
            // canonical whitespace token is 220 when a literal-space lookup is absent.
            whitespaceToken: tokenizer.convertTokenToId(" ") ?? 220
        )
        allLanguageTokens = Set(
            Constants.languages
                .compactMap { tokenizer.convertTokenToId("<|\($0.value)|>") }
                .filter { $0 > end }
        )
        guard !allLanguageTokens.isEmpty else {
            throw ListenUpError.modelUnavailable("Whisper tokenizer languages")
        }
    }

    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let decoded = tokenizer.decode(tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin })
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(decoded)
        let languageCode = recognizer.dominantLanguage.flatMap {
            Locale(identifier: $0.rawValue).language.languageCode?.identifier
        }
        if ["zh", "ja", "th", "lo", "my", "yue"].contains(languageCode) {
            return splitTokensOnUnicode(tokenIds)
        }
        return splitTokensOnSpaces(tokenIds)
    }

    private func splitTokensOnUnicode(_ tokens: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let decodedFull = tokenizer.decode(tokens: tokens)
        let replacement = "\u{fffd}"
        var words: [String] = []
        var wordTokens: [[Int]] = []
        var current: [Int] = []
        for token in tokens {
            current.append(token)
            let decoded = tokenizer.decode(tokens: current)
            var replacementIsInSource = false
            if let range = decoded.range(of: replacement), range.lowerBound < decodedFull.endIndex {
                replacementIsInSource = decodedFull[range] == replacement
            }
            if !decoded.contains(replacement) || replacementIsInSource {
                words.append(decoded)
                wordTokens.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            words.append(tokenizer.decode(tokens: current))
            wordTokens.append(current)
        }
        return (words, wordTokens)
    }

    private func splitTokensOnSpaces(_ tokens: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let (subwords, subwordTokens) = splitTokensOnUnicode(tokens)
        var words: [String] = []
        var wordTokens: [[Int]] = []
        for (subword, ids) in zip(subwords, subwordTokens) {
            let special = ids.first.map { $0 >= specialTokens.specialTokenBegin } ?? false
            let punctuation = !subword.isEmpty && subword.trimmingCharacters(in: .whitespaces).unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
            if special || subword.hasPrefix(" ") || punctuation || words.isEmpty {
                words.append(subword)
                wordTokens.append(ids)
            } else {
                words[words.count - 1] += subword
                wordTokens[words.count - 1].append(contentsOf: ids)
            }
        }
        return (words, wordTokens)
    }
}

enum ProductionModelRuntimeValidator {
    static func validate(manifest: ModelManifest, directory: URL, whisperTokenizerDirectory: URL?) async throws {
        switch manifest.id {
        case ModelCatalog.whisperTokenizer.id:
            _ = try await StrictLocalWhisperTokenizer.load(from: directory)
        case ModelCatalog.whisper.id:
            guard let tokenizer = whisperTokenizerDirectory else {
                throw ListenUpError.modelUnavailable("local Whisper tokenizer")
            }
            let component = manifest.files.first?.path.split(separator: "/").first.map(String.init)
            let modelDirectory = component.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
            _ = try await ProductionWhisperInferenceEngine(modelFolder: modelDirectory, tokenizerFolder: tokenizer)
        case ModelCatalog.qwen.id:
            _ = try await ProductionQwenInferenceEngine(modelFolder: directory)
        default:
            throw ListenUpError.modelUnavailable("unsupported model manifest: \(manifest.id)")
        }
    }
}

/// Concrete MLX Swift LM bridge. It resolves both model and tokenizer files from the supplied
/// directory and never uses a Hub downloader. The caller controls chunking through SummaryPrompt.
public final class ProductionQwenInferenceEngine: LocalLanguageModelEngine, @unchecked Sendable {
    private let container: ModelContainer

    public init(modelFolder: URL) async throws {
        let required = ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent($0).path) }) else {
            throw ListenUpError.modelUnavailable("local Qwen model/tokenizer")
        }
        self.container = try await LLMModelFactory.shared.loadContainer(
            from: modelFolder,
            using: #huggingFaceTokenizerLoader()
        )
    }

    public func generate(prompt: String, maxTokens: Int) async throws -> String {
        let input = try await container.prepare(input: UserInput(prompt: prompt))
        let stream = try await container.generate(
            input: input,
            parameters: GenerateParameters(maxTokens: min(maxTokens, 1_500), temperature: 0)
        )
        var output = ""
        for await event in stream {
            if let chunk = event.chunk { output += chunk }
        }
        return output
    }
}
