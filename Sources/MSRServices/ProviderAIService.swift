import Foundation
import MSRCore

public final class ProviderAIService: AIService, @unchecked Sendable {
    private let keyStore: APIKeyStore
    private let elevenLabs: ElevenLabsTranscriptionClient
    private let openAI: OpenAIClient
    private let deepSeek: DeepSeekClient
    private let lock = NSLock()
    private var selectedTextModelProvider: TextModelProvider

    public init(
        keyStore: APIKeyStore = APIKeyStore(),
        elevenLabs: ElevenLabsTranscriptionClient = ElevenLabsTranscriptionClient(),
        openAI: OpenAIClient = OpenAIClient(),
        deepSeek: DeepSeekClient = DeepSeekClient(),
        textModelProvider: TextModelProvider = .openAI
    ) {
        self.keyStore = keyStore
        self.elevenLabs = elevenLabs
        self.openAI = openAI
        self.deepSeek = deepSeek
        self.selectedTextModelProvider = textModelProvider
    }

    /// The preferred provider for summaries and remote titles
    /// (`AppSettings.summaryProvider`). Thread-safe; set it whenever the setting changes.
    public var textModelProvider: TextModelProvider {
        get { lock.withLock { selectedTextModelProvider } }
        set { lock.withLock { selectedTextModelProvider = newValue } }
    }

    /// The provider `summarize` / `generateTitle` will use right now: the
    /// selected one when its key is available, otherwise the other one when
    /// ITS key is available, otherwise `nil`.
    public var resolvedTextModelProvider: TextModelProvider? {
        let preferred = textModelProvider
        if hasCredential(for: preferred.credentialProvider) { return preferred }
        if hasCredential(for: preferred.alternative.credentialProvider) { return preferred.alternative }
        return nil
    }

    /// Whether a summary can be requested (an OpenAI or DeepSeek key is available).
    public var canSummarize: Bool { resolvedTextModelProvider != nil }

    public func transcribe(audioURL: URL, provider: AIProvider) async throws -> TranscribeResponse {
        try await transcribe(audioURL: audioURL, provider: provider, languageCode: nil)
    }

    /// - Parameter languageCode: ISO-639-1 hint (`TranscriptionLanguage.languageCode`);
    ///   `nil` lets the provider auto-detect. Sent as `language_code` to
    ///   ElevenLabs and as `language` to OpenAI.
    public func transcribe(audioURL: URL, provider: AIProvider, languageCode: String?) async throws -> TranscribeResponse {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ProviderError.audioFileMissing(audioURL.path)
        }
        switch provider {
        case .elevenLabs:
            guard let apiKey = keyStore.apiKey(for: .elevenLabs) else {
                throw ProviderError.missingAPIKey("ELEVENLABS_API_KEY")
            }
            return try await elevenLabs.transcribe(audioURL: audioURL, apiKey: apiKey, languageCode: languageCode)
        case .openAI:
            guard let apiKey = keyStore.apiKey(for: .openAI) else {
                throw ProviderError.missingAPIKey("OPENAI_API_KEY")
            }
            return try await openAI.transcribe(audioURL: audioURL, apiKey: apiKey, languageCode: languageCode)
        }
    }

    /// Summarizes with `resolvedTextModelProvider`.
    /// - Throws: `ProviderError.missingAPIKey(ProviderError.textModelKeyNames)`
    ///   when neither an OpenAI nor a DeepSeek key is available.
    public func summarize(transcript: String) async throws -> SummarizeResponse {
        let (provider, apiKey) = try textModelCredential()
        switch provider {
        case .openAI:
            return try await openAI.summarize(transcript: transcript, apiKey: apiKey)
        case .deepSeek:
            return try await deepSeek.summarize(transcript: transcript, apiKey: apiKey)
        }
    }

    /// Titles come from `resolvedTextModelProvider` (OpenAI or DeepSeek),
    /// whatever provider transcribed the audio. Throws
    /// `ProviderError.missingAPIKey` without either key; check
    /// `canGenerateTitlesRemotely` first and fall back to
    /// `MeetingTitleGenerator.localTitle(from:segments:)` when it is `false`.
    public func generateTitle(transcript: String) async throws -> String {
        let (provider, apiKey) = try textModelCredential()
        switch provider {
        case .openAI:
            return try await openAI.generateTitle(transcript: transcript, apiKey: apiKey)
        case .deepSeek:
            return try await deepSeek.generateTitle(transcript: transcript, apiKey: apiKey)
        }
    }

    /// Whether an API key for `provider` is available (session, environment or Keychain).
    public func hasCredential(for provider: AIProvider) -> Bool {
        keyStore.apiKey(for: provider) != nil
    }

    /// Whether an API key for `credential` is available (session, environment or Keychain).
    @_disfavoredOverload
    public func hasCredential(for credential: CredentialProvider) -> Bool {
        keyStore.apiKey(for: credential) != nil
    }

    /// Whether `generateTitle(transcript:)` can reach a text model (an OpenAI or DeepSeek key is available).
    public var canGenerateTitlesRemotely: Bool {
        resolvedTextModelProvider != nil
    }

    private func textModelCredential() throws -> (TextModelProvider, String) {
        let preferred = textModelProvider
        for provider in [preferred, preferred.alternative] {
            if let apiKey = keyStore.apiKey(for: provider.credentialProvider) {
                return (provider, apiKey)
            }
        }
        throw ProviderError.missingAPIKey(ProviderError.textModelKeyNames)
    }
}

public enum ProviderError: Error, LocalizedError {
    case missingAPIKey(String)
    case audioFileMissing(String)
    case invalidResponse
    case providerRejected(Int, String)
    case responseTooLarge

    /// The `missingAPIKey` payload when no summary/title key is available.
    public static let textModelKeyNames = "OPENAI_API_KEY or DEEPSEEK_API_KEY"

    public var errorDescription: String? {
        switch self {
        case let .missingAPIKey(name) where name == Self.textModelKeyNames:
            return "An OpenAI or DeepSeek API key is needed (\(name)). Add one in Settings or export it before launching the app."
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
