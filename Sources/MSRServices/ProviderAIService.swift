import Foundation
import MSRCore

public final class ProviderAIService: AIService, @unchecked Sendable {
    private let keyStore: APIKeyStore
    private let elevenLabs: ElevenLabsTranscriptionClient
    private let openAI: OpenAIClient

    public init(
        keyStore: APIKeyStore = APIKeyStore(),
        elevenLabs: ElevenLabsTranscriptionClient = ElevenLabsTranscriptionClient(),
        openAI: OpenAIClient = OpenAIClient()
    ) {
        self.keyStore = keyStore
        self.elevenLabs = elevenLabs
        self.openAI = openAI
    }

    public func transcribe(audioURL: URL, provider: AIProvider) async throws -> TranscribeResponse {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ProviderError.audioFileMissing(audioURL.path)
        }
        switch provider {
        case .elevenLabs:
            guard let apiKey = keyStore.apiKey(for: .elevenLabs) else {
                throw ProviderError.missingAPIKey("ELEVENLABS_API_KEY")
            }
            return try await elevenLabs.transcribe(audioURL: audioURL, apiKey: apiKey)
        case .openAI:
            guard let apiKey = keyStore.apiKey(for: .openAI) else {
                throw ProviderError.missingAPIKey("OPENAI_API_KEY")
            }
            return try await openAI.transcribe(audioURL: audioURL, apiKey: apiKey)
        }
    }

    public func summarize(transcript: String) async throws -> SummarizeResponse {
        guard let apiKey = keyStore.apiKey(for: .openAI) else {
            throw ProviderError.missingAPIKey("OPENAI_API_KEY")
        }
        return try await openAI.summarize(transcript: transcript, apiKey: apiKey)
    }

    public func generateTitle(transcript: String) async throws -> String {
        guard let apiKey = keyStore.apiKey(for: .openAI) else {
            throw ProviderError.missingAPIKey("OPENAI_API_KEY")
        }
        return try await openAI.generateTitle(transcript: transcript, apiKey: apiKey)
    }
}

public enum ProviderError: Error, LocalizedError {
    case missingAPIKey(String)
    case audioFileMissing(String)
    case invalidResponse
    case providerRejected(Int, String)
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case let .missingAPIKey(name):
            return "\(name) is missing. Add it in Settings or export it before launching the app."
        case let .audioFileMissing(path):
            return "Audio file was not found: \(path)"
        case .invalidResponse:
            return "Provider returned an invalid response."
        case let .providerRejected(status, message):
            return "Provider request failed with HTTP \(status): \(message)"
        case .responseTooLarge:
            return "Provider response exceeded the 64 MB safety limit."
        }
    }
}
