import Foundation
import MSRCore

public final class OpenAIClient {
    private static let transcriptionTimeout: TimeInterval = 60 * 60

    private let transcriptionEndpoint: URL
    private let responsesEndpoint: URL
    private let urlSession: URLSession

    public init(
        transcriptionEndpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
        responsesEndpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        urlSession: URLSession = .shared
    ) {
        self.transcriptionEndpoint = transcriptionEndpoint
        self.responsesEndpoint = responsesEndpoint
        self.urlSession = urlSession
    }

    public func transcribe(audioURL: URL, apiKey: String) async throws -> TranscribeResponse {
        let audioData = try Data(contentsOf: audioURL)
        var multipart = MultipartFormData()
        multipart.appendField(name: "model", value: "gpt-4o-transcribe")
        multipart.appendFile(
            name: "file",
            fileName: audioURL.lastPathComponent,
            mimeType: "audio/mp4",
            data: audioData
        )

        var request = URLRequest(url: transcriptionEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.transcriptionTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.finalize()

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
        return TranscribeResponse(text: decoded.text, provider: .openAI, languageCode: nil)
    }

    public func summarize(transcript: String, apiKey: String) async throws -> SummarizeResponse {
        var request = URLRequest(url: responsesEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OpenAIResponsesRequest(
            model: ProcessInfo.processInfo.environment["OPENAI_SUMMARY_MODEL"] ?? "gpt-4.1-mini",
            input: """
            Summarize this meeting transcript in Markdown with exactly these sections:
            ## Brief Summary
            ## Key Points
            ## Action Items

            Keep it concise. If there are no action items, write "- None".

            Transcript:
            \(transcript)
            """
        ))

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
        guard let text = decoded.outputText, !text.isEmpty else {
            throw ProviderError.invalidResponse
        }
        return SummarizeResponse(markdown: text)
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "No response body"
            throw ProviderError.providerRejected(http.statusCode, message)
        }
    }
}

private struct OpenAITranscriptionResponse: Decodable {
    let text: String
}

private struct OpenAIResponsesRequest: Encodable {
    let model: String
    let input: String
}

private struct OpenAIResponsesResponse: Decodable {
    let output: [OutputItem]

    var outputText: String? {
        output
            .flatMap(\.content)
            .compactMap(\.text)
            .joined(separator: "\n")
    }

    struct OutputItem: Decodable {
        let content: [Content]
    }

    struct Content: Decodable {
        let text: String?
    }
}
