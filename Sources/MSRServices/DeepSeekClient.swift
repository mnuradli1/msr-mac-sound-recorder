import Foundation
import MSRCore

/// DeepSeek chat completions (OpenAI-compatible) for summaries and titles.
/// Uses the same prompts and chunking as `OpenAIClient` (`MeetingTextPrompts`).
public final class DeepSeekClient {
    public static let defaultEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    public static let defaultModel = "deepseek-chat"
    /// Overrides the model when set (like `OPENAI_SUMMARY_MODEL` for OpenAI).
    public static let modelEnvironmentVariable = "DEEPSEEK_SUMMARY_MODEL"

    private static let textTimeout: TimeInterval = 5 * 60
    private static let titleTimeout: TimeInterval = 60
    private static let summaryMaximumTokens = 4_096
    private static let titleMaximumTokens = 32
    private static let temperature = 0.3

    private let endpoint: URL
    private let urlSession: URLSession
    private let model: String

    public init(
        endpoint: URL = DeepSeekClient.defaultEndpoint,
        urlSession: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.endpoint = endpoint
        self.urlSession = urlSession
        let override = environment[Self.modelEnvironmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.model = override.isEmpty ? Self.defaultModel : override
    }

    public func summarize(transcript: String, apiKey: String) async throws -> SummarizeResponse {
        let markdown = try await MeetingTextPrompts.summarize(transcript: transcript) { prompt in
            try await completion(
                prompt: prompt,
                apiKey: apiKey,
                timeout: Self.textTimeout,
                maximumTokens: Self.summaryMaximumTokens
            )
        }
        return SummarizeResponse(markdown: markdown)
    }

    /// Asks DeepSeek for a title from the first 12,000 characters of `transcript`
    /// and cleans the reply with `MeetingTitleGenerator.cleaned(_:fallback:)`.
    ///
    /// - Throws: `ProviderError.invalidResponse` when the cleaned reply is empty.
    public func generateTitle(transcript: String, apiKey: String) async throws -> String {
        let reply = try await completion(
            prompt: MeetingTextPrompts.titleInput(transcript: transcript),
            apiKey: apiKey,
            timeout: Self.titleTimeout,
            maximumTokens: Self.titleMaximumTokens
        )
        return try MeetingTextPrompts.cleanedTitle(reply)
    }

    private func completion(
        prompt: String,
        apiKey: String,
        timeout: TimeInterval,
        maximumTokens: Int
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(DeepSeekChatRequest(
            model: model,
            messages: [.init(role: "user", content: prompt)],
            temperature: Self.temperature,
            maxTokens: maximumTokens
        ))

        let (data, response) = try await urlSession.data(for: request)
        try MeetingTextPrompts.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(DeepSeekChatResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw ProviderError.invalidResponse
        }
        return text
    }
}

private struct DeepSeekChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
    }
}

private struct DeepSeekChatResponse: Decodable {
    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        /// `null` for some refusals/tool calls.
        let content: String?
    }

    let choices: [Choice]
}
