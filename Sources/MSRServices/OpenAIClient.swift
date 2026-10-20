import Foundation
import MSRCore

public final class OpenAIClient {
    private static let transcriptionTimeout: TimeInterval = 15 * 60
    private static let textTimeout: TimeInterval = 5 * 60
    private static let maximumResponseBytes = 64 * 1_024 * 1_024

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
        let media = MultipartFileBody.neutralMediaDescriptor(for: audioURL)
        let multipart = try MultipartFileBody.create(
            fields: [("model", "gpt-4o-transcribe")],
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
        guard data.count <= Self.maximumResponseBytes else { throw ProviderError.responseTooLarge }
        try Self.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
        return TranscribeResponse(text: decoded.text, provider: .openAI, languageCode: nil)
    }

    public func summarize(transcript: String, apiKey: String) async throws -> SummarizeResponse {
        let chunks = transcript.chunked(maximumCharacters: 60_000)
        if chunks.count == 1 {
            return SummarizeResponse(markdown: try await summaryText(for: chunks[0], apiKey: apiKey))
        }
        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            partials.append(try await responseText(
                prompt: "Summarize meeting transcript chunk \(index + 1) of \(chunks.count). Preserve decisions, owners, and action items.\n\n\(chunk)",
                apiKey: apiKey
            ))
        }
        let combined = partials.enumerated().map { "Chunk \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n")
        return SummarizeResponse(markdown: try await summaryText(for: combined, apiKey: apiKey))
    }

    static let titlePrompt = "You name meeting recordings. Write a specific, descriptive title of at most 8 words in the same language as the transcript. No quotes, no trailing period, no prefix like 'Title:'. Return only the title."

    /// Asks OpenAI for a title from the first 12,000 characters of `transcript`
    /// and cleans the reply with `MeetingTitleGenerator.cleaned(_:fallback:)`.
    ///
    /// - Throws: `ProviderError.invalidResponse` when the cleaned reply is empty.
    public func generateTitle(transcript: String, apiKey: String) async throws -> String {
        let value = try await responseText(
            prompt: "\(Self.titlePrompt)\n\nTranscript:\n\(String(transcript.prefix(12_000)))",
            apiKey: apiKey,
            timeout: 60,
            maximumOutputTokens: 32
        )
        let title = MeetingTitleGenerator.cleaned(value, fallback: "")
        guard !title.isEmpty else { throw ProviderError.invalidResponse }
        return title
    }

    private func summaryText(for transcript: String, apiKey: String) async throws -> String {
        try await responseText(prompt: """
        Summarize this meeting transcript in Markdown with exactly these sections:
        ## Brief Summary
        ## Key Points
        ## Action Items

        Keep it concise. If there are no action items, write "- None".

        Transcript:
        \(transcript)
        """, apiKey: apiKey)
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
        guard data.count <= Self.maximumResponseBytes else { throw ProviderError.responseTooLarge }
        try Self.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
        guard let text = decoded.outputText, !text.isEmpty else {
            throw ProviderError.invalidResponse
        }
        return text
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String((String(data: data, encoding: .utf8) ?? "No response body").prefix(500))
            throw ProviderError.providerRejected(http.statusCode, message)
        }
    }
}

private extension String {
    func chunked(maximumCharacters: Int) -> [String] {
        guard count > maximumCharacters else { return [self] }
        var chunks: [String] = []
        var cursor = startIndex
        while cursor < endIndex {
            let proposed = index(cursor, offsetBy: maximumCharacters, limitedBy: endIndex) ?? endIndex
            var boundary = proposed
            if proposed < endIndex,
               let newline = self[cursor..<proposed].lastIndex(of: "\n") {
                boundary = index(after: newline)
            }
            chunks.append(String(self[cursor..<boundary]))
            cursor = boundary
        }
        return chunks
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
