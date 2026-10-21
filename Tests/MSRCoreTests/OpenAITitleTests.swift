import Foundation
import Testing
@testable import MSRCore
@testable import MSRServices

/// Exercises `OpenAIClient` against a stubbed `URLProtocol`; nothing leaves the process.
@Suite("OpenAI title generation")
struct OpenAITitleTests {
    @Test func generateTitleCleansReplyAndDoesNotStoreTranscript() async throws {
        let stub = StubResponses(json: #"""
        {"output":[
          {"type":"reasoning","summary":[]},
          {"type":"message","content":[{"type":"output_text","text":"Title: \"Q3 Budget Review.\""}]}
        ]}
        """#)
        let transcript = "Speaker 1: we talked about the budget " + String(repeating: "x", count: 20_000)
        let title = try await stub.client.generateTitle(transcript: transcript, apiKey: "sk-test")
        #expect(title == "Q3 Budget Review")

        let json = try stub.capturedJSON()
        #expect(json["store"] as? Bool == false)
        #expect(json["max_output_tokens"] as? Int == 32)
        let input = try #require(json["input"] as? String)
        #expect(input.hasPrefix(OpenAIClient.titlePrompt))
        #expect(input.contains("we talked about the budget"))
        #expect(input.count <= OpenAIClient.titlePrompt.count + 12_000 + 20)
    }

    @Test func generateTitleThrowsWhenCleanedReplyIsEmpty() async throws {
        let stub = StubResponses(json: #"{"output":[{"content":[{"type":"output_text","text":"**\"\"**"}]}]}"#)
        await #expect(throws: ProviderError.self) {
            _ = try await stub.client.generateTitle(transcript: "Budget planning", apiKey: "sk-test")
        }
    }

    @Test func summaryRequestsAlsoDisableStorageWithoutTokenCap() async throws {
        let stub = StubResponses(json: #"{"output":[{"content":[{"type":"output_text","text":"Brief Summary: done."}]}]}"#)
        let summary = try await stub.client.summarize(transcript: "Short transcript", apiKey: "sk-test")
        #expect(summary.markdown == "Brief Summary: done.")
        let json = try stub.capturedJSON()
        #expect(json["store"] as? Bool == false)
        #expect(json["max_output_tokens"] == nil)
    }
}

private struct StubResponses {
    let client: OpenAIClient
    let path: String

    init(json: String) {
        path = "/v1/responses/\(UUID().uuidString)"
        StubResponsesProtocol.register(Data(json.utf8), for: path)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubResponsesProtocol.self]
        client = OpenAIClient(
            responsesEndpoint: URL(string: "https://openai.stub.invalid\(path)")!,
            urlSession: URLSession(configuration: configuration)
        )
    }

    func capturedJSON() throws -> [String: Any] {
        let body = try #require(StubResponsesProtocol.capturedBody(for: path))
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

/// Answers every request with the JSON registered for its URL path and records
/// the request body. State is keyed by path so parallel tests do not interfere.
private final class StubResponsesProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Data] = [:]
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]

    static func register(_ response: Data, for path: String) {
        lock.lock()
        defer { lock.unlock() }
        responses[path] = response
    }

    static func capturedBody(for path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return bodies[path]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = Self.body(of: request)
        Self.lock.lock()
        Self.bodies[path] = body
        let response = Self.responses[path]
        Self.lock.unlock()

        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response == nil ? 404 : 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
