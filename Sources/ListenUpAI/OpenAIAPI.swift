import Foundation
import ListenUpDomain

public enum OpenAIConfiguration {
    public static let defaultTranscriptionModel = "gpt-transcribe"
    public static let economicalTranscriptionModel = "gpt-4o-mini-transcribe"
    public static let defaultSummaryModel = "gpt-5.6-luna"
    public static let qualitySummaryModel = "gpt-5.6-terra"
}

public enum OpenAIAPIError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case invalidResponse(String)
    case httpStatus(Int, String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API 키가 설정되지 않았습니다."
        case .invalidResponse(let detail):
            return "OpenAI 응답을 읽지 못했습니다: \(detail)"
        case .httpStatus(let status, let message):
            switch status {
            case 401: return "OpenAI API 키가 올바르지 않거나 비활성화되었습니다."
            case 403: return "이 API 키에 선택한 OpenAI 모델을 사용할 권한이 없습니다."
            case 404: return "선택한 OpenAI 모델을 찾을 수 없습니다. 모델 설정을 확인해 주세요."
            case 413: return "전송할 오디오가 OpenAI 파일 크기 제한을 초과했습니다."
            case 429: return "OpenAI 사용량 또는 속도 제한에 도달했습니다. 잠시 후 사용량 한도를 확인해 주세요."
            case 500...599: return "OpenAI 서버에서 일시적인 문제가 발생했습니다. 잠시 후 다시 시도해 주세요."
            default: return "OpenAI API 요청이 실패했습니다(HTTP \(status)): \(message)"
            }
        case .network(let detail):
            return "OpenAI에 연결할 수 없습니다. 인터넷 연결을 확인해 주세요: \(detail)"
        }
    }
}

public struct OpenAITranscriptionResult: Sendable {
    public let text: String
    public let requestID: String?

    public init(text: String, requestID: String? = nil) {
        self.text = text
        self.requestID = requestID
    }
}

public actor OpenAIAPIClient {
    private let apiKey: String
    private let session: URLSession
    private let baseURL: URL

    public init(
        apiKey: String,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
        self.baseURL = baseURL
    }

    public func validateCredentials() async throws {
        guard !apiKey.isEmpty else { throw OpenAIAPIError.missingAPIKey }
        var request = authorizedRequest(path: "models")
        request.httpMethod = "GET"
        _ = try await perform(request)
    }

    public func transcribe(
        samples: [Float],
        model: String,
        languages: [String],
        keywords: [String],
        prompt: String?
    ) async throws -> OpenAITranscriptionResult {
        guard !apiKey.isEmpty else { throw OpenAIAPIError.missingAPIKey }

        let request = makeTranscriptionRequest(
            samples: samples,
            model: model,
            languages: languages,
            keywords: keywords,
            prompt: prompt
        )
        let (data, response) = try await perform(request)
        struct Envelope: Decodable { let text: String }
        guard let value = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw OpenAIAPIError.invalidResponse("전사 text 필드 없음")
        }
        return OpenAITranscriptionResult(
            text: value.text.trimmingCharacters(in: .whitespacesAndNewlines),
            requestID: response.value(forHTTPHeaderField: "x-request-id")
        )
    }

    func makeTranscriptionRequest(
        samples: [Float],
        model: String,
        languages: [String],
        keywords: [String],
        prompt: String?
    ) -> URLRequest {
        let boundary = "ListenUp-\(UUID().uuidString)"
        var form = MultipartForm(boundary: boundary)
        form.addField(name: "model", value: model)

        let cleanPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanPrompt, !cleanPrompt.isEmpty {
            form.addField(name: "prompt", value: cleanPrompt)
        }

        if model == OpenAIConfiguration.defaultTranscriptionModel {
            for language in languages where !language.isEmpty {
                form.addField(name: "languages[]", value: language)
            }
            for keyword in keywords where Self.isValidKeyword(keyword) {
                form.addField(name: "keywords[]", value: keyword)
            }
        } else if let language = languages.first, !language.isEmpty {
            form.addField(name: "language", value: language)
        }

        form.addFile(name: "file", filename: "listenup-chunk.wav", contentType: "audio/wav", data: Self.wavData(samples: samples))

        var request = authorizedRequest(path: "audio/transcriptions")
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalizedData()
        request.timeoutInterval = 600
        return request
    }

    public func generateText(prompt: String, model: String, maxOutputTokens: Int = 4_000) async throws -> String {
        guard !apiKey.isEmpty else { throw OpenAIAPIError.missingAPIKey }
        let request = try makeTextRequest(prompt: prompt, model: model, maxOutputTokens: maxOutputTokens)
        let (data, _) = try await perform(request)
        let envelope: ResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        } catch {
            throw OpenAIAPIError.invalidResponse("요약 응답 형식 오류")
        }
        let text = envelope.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OpenAIAPIError.invalidResponse(envelope.refusal ?? "요약 텍스트 없음")
        }
        return text
    }

    func makeTextRequest(prompt: String, model: String, maxOutputTokens: Int = 4_000) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "input": prompt,
            "store": false,
            "reasoning": ["effort": "none"],
            "max_output_tokens": maxOutputTokens,
        ]

        var request = authorizedRequest(path: "responses")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 600
        return request
    }

    private func authorizedRequest(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("ListenUp/0.2", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenAIAPIError.invalidResponse("HTTP 응답 없음")
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data).error.message)
                    ?? String(data: data, encoding: .utf8)
                    ?? "알 수 없는 오류"
                throw OpenAIAPIError.httpStatus(http.statusCode, message)
            }
            return (data, http)
        } catch let error as OpenAIAPIError {
            throw error
        } catch {
            throw OpenAIAPIError.network(error.localizedDescription)
        }
    }

    private static func isValidKeyword(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && !clean.contains("<") && !clean.contains(">") && !clean.contains("\r") && !clean.contains("\n")
    }

    private static func wavData(samples: [Float]) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16((clamped * 32_767).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }

        var wav = Data(capacity: 44 + pcm.count)
        wav.appendASCII("RIFF")
        wav.appendLittleEndian(UInt32(36 + pcm.count))
        wav.appendASCII("WAVEfmt ")
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt32(16_000))
        wav.appendLittleEndian(UInt32(32_000))
        wav.appendLittleEndian(UInt16(2))
        wav.appendLittleEndian(UInt16(16))
        wav.appendASCII("data")
        wav.appendLittleEndian(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}

public struct OpenAISummaryAdapter: SummaryProvider {
    private let client: OpenAIAPIClient
    public let modelID: String

    public init(client: OpenAIAPIClient, modelID: String = OpenAIConfiguration.defaultSummaryModel) {
        self.client = client
        self.modelID = modelID
    }

    public func summarize(_ input: SummaryInput) async throws -> SummaryRevision {
        let schema: SummarySchema = input.purpose == .meeting ? .meeting : .lecture
        var decodedChunks: [SummarySections] = []
        for chunk in SummaryPrompt.segmentChunks(input: input) {
            try Task.checkCancellation()
            let raw = try await client.generateText(
                prompt: SummaryPrompt.make(input: input, schema: schema, segments: chunk),
                model: modelID
            )
            decodedChunks.append(try SummaryPrompt.decodeAndValidate(from: raw, schema: schema, segments: chunk))
        }
        let revision = SummaryRevision(
            id: "summary-\(UUID().uuidString)",
            purpose: input.purpose,
            sourceTranscriptRevisionID: input.transcript.id,
            annotationRevisionID: input.annotations?.id ?? "none",
            promptVersion: "openai-v1",
            modelID: modelID,
            sections: SummaryPrompt.merge(decodedChunks),
            inputHash: input.inputHash
        )
        try DomainValidator.validate(revision, transcript: input.transcript)
        return revision
    }
}

private struct APIErrorEnvelope: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}

private struct ResponseEnvelope: Decodable {
    struct Output: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
            let refusal: String?
        }
        let content: [Content]?
    }

    let outputText: String?
    let output: [Output]?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }

    var text: String {
        if let outputText, !outputText.isEmpty { return outputText }
        return output?.flatMap { $0.content ?? [] }.compactMap { $0.type == "output_text" ? $0.text : nil }.joined(separator: "\n") ?? ""
    }

    var refusal: String? {
        output?.flatMap { $0.content ?? [] }.compactMap(\.refusal).first
    }
}

private struct MultipartForm {
    let boundary: String
    private(set) var data = Data()

    mutating func addField(name: String, value: String) {
        data.appendASCII("--\(boundary)\r\n")
        data.appendASCII("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        data.append(Data(value.utf8))
        data.appendASCII("\r\n")
    }

    mutating func addFile(name: String, filename: String, contentType: String, data fileData: Data) {
        data.appendASCII("--\(boundary)\r\n")
        data.appendASCII("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        data.appendASCII("Content-Type: \(contentType)\r\n\r\n")
        data.append(fileData)
        data.appendASCII("\r\n")
    }

    func finalizedData() -> Data {
        var result = data
        result.appendASCII("--\(boundary)--\r\n")
        return result
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(Data(value.utf8))
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
