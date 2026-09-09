import Foundation
import Testing
@testable import ListenUpAI

@Test func openAIClientSendsExpectedTranscriptionAndSummaryRequests() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockOpenAIURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = OpenAIAPIClient(
        apiKey: "test-key",
        session: session,
        baseURL: URL(string: "https://example.invalid/v1")!
    )

    let transcriptionRequest = await client.makeTranscriptionRequest(
        samples: [0, 0.25, -0.25],
        model: OpenAIConfiguration.defaultTranscriptionModel,
        languages: ["ko"],
        keywords: ["ListenUp"],
        prompt: "회의 녹음"
    )
    let transcriptionBody = try #require(transcriptionRequest.httpBody)
    let readableTranscriptionBody = String(decoding: transcriptionBody, as: UTF8.self)
    #expect(readableTranscriptionBody.contains("name=\"model\"\r\n\r\ngpt-transcribe"))
    #expect(readableTranscriptionBody.contains("name=\"languages[]\"\r\n\r\nko"))
    #expect(readableTranscriptionBody.contains("name=\"keywords[]\"\r\n\r\nListenUp"))
    #expect(transcriptionBody.range(of: Data("RIFF".utf8)) != nil)

    let summaryRequest = try await client.makeTextRequest(
        prompt: "요약해 주세요",
        model: OpenAIConfiguration.defaultSummaryModel
    )
    let summaryObject = try #require(try JSONSerialization.jsonObject(with: summaryRequest.httpBody ?? Data()) as? [String: Any])
    #expect(summaryObject["model"] as? String == OpenAIConfiguration.defaultSummaryModel)
    #expect(summaryObject["store"] as? Bool == false)
    #expect(summaryObject["input"] as? String == "요약해 주세요")

    MockOpenAIURLProtocol.handler = { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        switch request.url?.path {
        case "/v1/models":
            #expect(request.httpMethod == "GET")
            return OpenAITestResponse.mock(for: request, body: #"{"data":[]}"#)
        case "/v1/audio/transcriptions":
            #expect(request.httpMethod == "POST")
            return OpenAITestResponse.mock(
                for: request,
                body: #"{"text":"안녕하세요"}"#,
                headers: ["x-request-id": "req_transcription"]
            )
        case "/v1/responses":
            #expect(request.httpMethod == "POST")
            return OpenAITestResponse.mock(
                for: request,
                body: #"{"output":[{"content":[{"type":"output_text","text":"요약 결과"}]}]}"#
            )
        default:
            Issue.record("unexpected OpenAI path: \(request.url?.path ?? "nil")")
            return OpenAITestResponse.mock(for: request, body: #"{"error":{"message":"unexpected path"}}"#, status: 404)
        }
    }
    defer {
        MockOpenAIURLProtocol.handler = nil
        session.invalidateAndCancel()
    }

    try await client.validateCredentials()
    let transcription = try await client.transcribe(
        samples: [0, 0.25, -0.25],
        model: OpenAIConfiguration.defaultTranscriptionModel,
        languages: ["ko"],
        keywords: ["ListenUp"],
        prompt: "회의 녹음"
    )
    #expect(transcription.text == "안녕하세요")
    #expect(transcription.requestID == "req_transcription")

    let summary = try await client.generateText(
        prompt: "요약해 주세요",
        model: OpenAIConfiguration.defaultSummaryModel
    )
    #expect(summary == "요약 결과")
}

private final class MockOpenAIURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw OpenAIAPIError.invalidResponse("missing mock handler")
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum OpenAITestResponse {
    static func mock(
        for request: URLRequest,
        body: String,
        status: Int = 200,
        headers: [String: String] = [:]
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (response, Data(body.utf8))
    }
}
