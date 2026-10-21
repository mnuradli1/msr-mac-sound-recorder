import Foundation
import MSRCore

public final class OpenAIClient {
    private static let transcriptionTimeout: TimeInterval = 15 * 60
    private static let textTimeout: TimeInterval = 5 * 60

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

    /// Uploads `audioURL` to `gpt-4o-transcribe`.
    /// - Parameter languageCode: Optional ISO-639-1 hint sent as the multipart
    ///   `language` field. `nil`, blank or malformed values are omitted so the
    ///   model auto-detects the language.
    public func transcribe(audioURL: URL, apiKey: String, languageCode: String? = nil) async throws -> TranscribeResponse {
        let media = MultipartFileBody.neutralMediaDescriptor(for: audioURL)
        var fields: [(name: String, value: String)] = [("model", "gpt-4o-transcribe")]
        if let languageCode = ElevenLabsTranscriptionClient.sanitizedLanguageCode(languageCode) {
            fields.append(("language", languageCode))
        }
        let multipart = try MultipartFileBody.create(
            fields: fields,
            fileFieldName: "file",
            neutralFileName: media.fileName,
            mimeType: media.mimeType,
            sourceURL: audioURL
        )
        defer { try? FileManager.default.removeItem(at: multipart.url) }

        var request = URLRequest(url: transcriptionEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.transcriptionTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await urlSession.upload(for: request, fromFile: multipart.url)
        try MeetingTextPrompts.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
        return TranscribeResponse(text: decoded.text, provider: .openAI, languageCode: nil)
    }

    public func summarize(transcript: String, apiKey: String) async throws -> SummarizeResponse {
        let markdown = try await MeetingTextPrompts.summarize(transcript: transcript) { prompt in
            try await responseText(prompt: prompt, apiKey: apiKey)
        }
        return SummarizeResponse(markdown: markdown)
    }

    static let titlePrompt = MeetingTextPrompts.titlePrompt

    /// Asks OpenAI for a title from the first 12,000 characters of `transcript`
    /// and cleans the reply with `MeetingTitleGenerator.cleaned(_:fallback:)`.
    ///
    /// - Throws: `ProviderError.invalidResponse` when the cleaned reply is empty.
    public func generateTitle(transcript: String, apiKey: String) async throws -> String {
        let value = try await responseText(
            prompt: MeetingTextPrompts.titleInput(transcript: transcript),
            apiKey: apiKey,
            timeout: 60,
            maximumOutputTokens: 32
        )
        return try MeetingTextPrompts.cleanedTitle(value)
    }

    private func responseText(
        prompt: String,
        apiKey: String,
        timeout: TimeInterval = textTimeout,
        maximumOutputTokens: Int? = nil
    ) async throws -> String {
        var request = URLRequest(url: responsesEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OpenAIResponsesRequest(
            model: ProcessInfo.processInfo.environment["OPENAI_SUMMARY_MODEL"] ?? "gpt-4.1-mini",
            input: prompt,
            store: false,
            maxOutputTokens: maximumOutputTokens
        ))

        let (data, response) = try await urlSession.data(for: request)
        try MeetingTextPrompts.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
        guard let text = decoded.outputText, !text.isEmpty else {
            throw ProviderError.invalidResponse
        }
        return text
    }
}

private struct OpenAITranscriptionResponse: Decodable {
    let text: String
}

private struct OpenAIResponsesRequest: Encodable {
    let model: String
    let input: String
    /// `false` so OpenAI does not retain transcripts or summaries.
    let store: Bool
    /// Omitted from the JSON when `nil`.
    let maxOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model, input, store
        case maxOutputTokens = "max_output_tokens"
    }
}

private struct OpenAIResponsesResponse: Decodable {
    let output: [OutputItem]

    var outputText: String? {
        output
            .compactMap(\.content)
            .flatMap { $0 }
            .compactMap(\.text)
            .joined(separator: "\n")
    }

    struct OutputItem: Decodable {
        /// `nil` for items without content, such as `reasoning` items.
        let content: [Content]?
    }

    struct Content: Decodable {
        let text: String?
    }
}
