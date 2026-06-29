import Foundation

public enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case elevenLabs = "elevenlabs"
    case openAI = "openai"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .elevenLabs:
            return "ElevenLabs"
        case .openAI:
            return "OpenAI"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var provider: AIProvider
    public var recordingsFolderPath: String?

    public static let `default` = AppSettings(
        provider: .elevenLabs,
        recordingsFolderPath: nil
    )

    public init(provider: AIProvider, recordingsFolderPath: String?) {
        self.provider = provider
        self.recordingsFolderPath = recordingsFolderPath
    }
}

public struct TranscribeRequest: Codable, Equatable, Sendable {
    public var audioPath: String
    public var provider: AIProvider

    public init(audioPath: String, provider: AIProvider) {
        self.audioPath = audioPath
        self.provider = provider
    }
}

public struct TranscribeResponse: Codable, Equatable, Sendable {
    public var text: String
    public var provider: AIProvider
    public var languageCode: String?

    public init(text: String, provider: AIProvider, languageCode: String?) {
        self.text = text
        self.provider = provider
        self.languageCode = languageCode
    }
}

public struct SummarizeRequest: Codable, Equatable, Sendable {
    public var transcript: String

    public init(transcript: String) {
        self.transcript = transcript
    }
}

public struct SummarizeResponse: Codable, Equatable, Sendable {
    public var markdown: String

    public init(markdown: String) {
        self.markdown = markdown
    }
}
