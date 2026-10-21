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

/// Which API key a credential belongs to. Transcription providers
/// (`AIProvider`) and text-model providers (`TextModelProvider`) both map onto
/// it. `keychainAccount` values are the identifiers saved keys already use, so
/// they must never change.
public enum CredentialProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case elevenLabs, openAI, deepSeek

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        }
    }

    /// The exported variable read before the Keychain.
    public var environmentVariableName: String {
        switch self {
        case .elevenLabs: "ELEVENLABS_API_KEY"
        case .openAI: "OPENAI_API_KEY"
        case .deepSeek: "DEEPSEEK_API_KEY"
        }
    }

    /// The Keychain account (service `MSRMeetingRecorder`).
    public var keychainAccount: String {
        switch self {
        case .elevenLabs: "elevenlabs"
        case .openAI: "openai"
        case .deepSeek: "deepseek"
        }
    }

    public init(_ provider: AIProvider) {
        switch provider {
        case .elevenLabs: self = .elevenLabs
        case .openAI: self = .openAI
        }
    }

    /// The transcription provider using this credential, or `nil` for DeepSeek.
    public var transcriptionProvider: AIProvider? {
        switch self {
        case .elevenLabs: .elevenLabs
        case .openAI: .openAI
        case .deepSeek: nil
        }
    }
}

extension AIProvider {
    public var credentialProvider: CredentialProvider { CredentialProvider(self) }
}

/// The chat model used for summaries and remote titles (independent of the
/// transcription provider).
public enum TextModelProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case deepSeek = "deepseek"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        }
    }

    public var credentialProvider: CredentialProvider {
        switch self {
        case .openAI: .openAI
        case .deepSeek: .deepSeek
        }
    }

    /// The other provider, tried when this one has no key.
    public var alternative: TextModelProvider {
        switch self {
        case .openAI: .deepSeek
        case .deepSeek: .openAI
        }
    }
}

/// The spoken language hint sent with transcription requests.
public enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case english = "en"
    case indonesian = "id"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .english: "English"
        case .indonesian: "Bahasa Indonesia"
        }
    }

    /// ISO-639-1 code for the provider, or `nil` to let it auto-detect.
    public var languageCode: String? {
        switch self {
        case .automatic: nil
        case .english: "en"
        case .indonesian: "id"
        }
    }
}

public enum RecordingSortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case newest, oldest, nameAscending, nameDescending, durationLongest, durationShortest
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .nameAscending: "Name A–Z"
        case .nameDescending: "Name Z–A"
        case .durationLongest: "Longest"
        case .durationShortest: "Shortest"
        }
    }
}

public enum AppTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, english, indonesian
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .indonesian: "Bahasa Indonesia"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var provider: AIProvider
    public var recordingsFolderPath: String?
    public var recordingsFolderBookmark: Data?
    public var preferredSource: AudioSource
    public var microphoneDeviceID: String?
    public var sortOrder: RecordingSortOrder
    public var silenceThreshold: Double
    public var playbackSpeed: Double
    public var theme: AppTheme
    public var language: AppLanguage
    public var compressUploads: Bool
    /// When `true`, every recording is renamed from its transcript once a
    /// transcription finishes, for ANY transcription provider (ElevenLabs or
    /// OpenAI). Only recordings whose title is still machine-generated
    /// (`RecordingTitleSource.default`) are renamed; a user-chosen title is
    /// never overwritten. The title comes from the OpenAI title endpoint when an
    /// OpenAI credential is available, otherwise from
    /// `MeetingTitleGenerator.localTitle(from:segments:)`.
    public var autoTitle: Bool
    /// When `true`, a transcription job is queued automatically as soon as a
    /// recording finishes (see `RecordingInteractionPolicy.shouldAutoTranscribe`).
    /// Defaults to `false`; settings saved before this key existed decode as `false`.
    public var autoTranscribe: Bool
    /// When `true`, a summary is generated automatically after an
    /// auto-transcribed (or any queued, per the view model) transcript is
    /// published. Defaults to `false`.
    public var autoSummarize: Bool
    /// Preferred text model for summaries and remote titles. When its key is
    /// missing the other provider is used if it has one
    /// (`ProviderAIService.resolvedTextModelProvider`).
    public var summaryProvider: TextModelProvider
    /// Language hint for transcription; `.automatic` lets the provider detect it.
    public var transcriptionLanguage: TranscriptionLanguage
    public var rememberCredentials: Bool
    public var showMenuBarControl: Bool
    /// Shows the elapsed time next to the menu-bar icon while a recording is
    /// running or paused (only when `showMenuBarControl` is on). Defaults to `true`.
    public var showMenuBarTimer: Bool
    public var globalShortcutEnabled: Bool
    public var localAPIEnabled: Bool
    public var windowWidth: Double
    public var windowHeight: Double

    public static let `default` = AppSettings(
        provider: .elevenLabs,
        recordingsFolderPath: nil,
        recordingsFolderBookmark: nil,
        preferredSource: .micAndSystem,
        microphoneDeviceID: nil,
        sortOrder: .newest,
        silenceThreshold: 0.01,
        playbackSpeed: 1,
        theme: .system,
        language: .system,
        compressUploads: true,
        autoTitle: true,
        autoTranscribe: false,
        autoSummarize: false,
        summaryProvider: .openAI,
        transcriptionLanguage: .automatic,
        rememberCredentials: false,
        showMenuBarControl: true,
        showMenuBarTimer: true,
        globalShortcutEnabled: true,
        localAPIEnabled: false,
        windowWidth: 1_180,
        windowHeight: 760
    )

    public init(
        provider: AIProvider,
        recordingsFolderPath: String?,
        recordingsFolderBookmark: Data? = nil,
        preferredSource: AudioSource = .micAndSystem,
        microphoneDeviceID: String? = nil,
        sortOrder: RecordingSortOrder = .newest,
        silenceThreshold: Double = 0.01,
        playbackSpeed: Double = 1,
        theme: AppTheme = .system,
        language: AppLanguage = .system,
        compressUploads: Bool = true,
        autoTitle: Bool = true,
        autoTranscribe: Bool = false,
        autoSummarize: Bool = false,
        summaryProvider: TextModelProvider = .openAI,
        transcriptionLanguage: TranscriptionLanguage = .automatic,
        rememberCredentials: Bool = false,
        showMenuBarControl: Bool = true,
        showMenuBarTimer: Bool = true,
        globalShortcutEnabled: Bool = true,
        localAPIEnabled: Bool = false,
        windowWidth: Double = 1_180,
        windowHeight: Double = 760
    ) {
        self.provider = provider
        self.recordingsFolderPath = recordingsFolderPath
        self.recordingsFolderBookmark = recordingsFolderBookmark
        self.preferredSource = preferredSource
        self.microphoneDeviceID = microphoneDeviceID
        self.sortOrder = sortOrder
        self.silenceThreshold = silenceThreshold
        self.playbackSpeed = playbackSpeed
        self.theme = theme
        self.language = language
        self.compressUploads = compressUploads
        self.autoTitle = autoTitle
        self.autoTranscribe = autoTranscribe
        self.autoSummarize = autoSummarize
        self.summaryProvider = summaryProvider
        self.transcriptionLanguage = transcriptionLanguage
        self.rememberCredentials = rememberCredentials
        self.showMenuBarControl = showMenuBarControl
        self.showMenuBarTimer = showMenuBarTimer
        self.globalShortcutEnabled = globalShortcutEnabled
        self.localAPIEnabled = localAPIEnabled
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
    }

    private enum CodingKeys: String, CodingKey {
        case provider, recordingsFolderPath, recordingsFolderBookmark, preferredSource, microphoneDeviceID
        case sortOrder, silenceThreshold, playbackSpeed, theme, language, compressUploads, autoTitle
        case autoTranscribe, autoSummarize, summaryProvider, transcriptionLanguage
        case rememberCredentials, showMenuBarControl, globalShortcutEnabled, localAPIEnabled, windowWidth, windowHeight
        case showMenuBarTimer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default
        provider = try c.decodeIfPresent(AIProvider.self, forKey: .provider) ?? defaults.provider
        recordingsFolderPath = try c.decodeIfPresent(String.self, forKey: .recordingsFolderPath)
        recordingsFolderBookmark = try c.decodeIfPresent(Data.self, forKey: .recordingsFolderBookmark)
        preferredSource = try c.decodeIfPresent(AudioSource.self, forKey: .preferredSource) ?? defaults.preferredSource
        microphoneDeviceID = try c.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
        sortOrder = try c.decodeIfPresent(RecordingSortOrder.self, forKey: .sortOrder) ?? defaults.sortOrder
        silenceThreshold = try c.decodeIfPresent(Double.self, forKey: .silenceThreshold) ?? defaults.silenceThreshold
        playbackSpeed = try c.decodeIfPresent(Double.self, forKey: .playbackSpeed) ?? defaults.playbackSpeed
        theme = try c.decodeIfPresent(AppTheme.self, forKey: .theme) ?? defaults.theme
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? defaults.language
        compressUploads = try c.decodeIfPresent(Bool.self, forKey: .compressUploads) ?? defaults.compressUploads
        autoTitle = try c.decodeIfPresent(Bool.self, forKey: .autoTitle) ?? defaults.autoTitle
        autoTranscribe = try c.decodeIfPresent(Bool.self, forKey: .autoTranscribe) ?? defaults.autoTranscribe
        autoSummarize = try c.decodeIfPresent(Bool.self, forKey: .autoSummarize) ?? defaults.autoSummarize
        // `try?`: a provider/language written by a newer build falls back instead of failing all settings.
        summaryProvider = (try? c.decodeIfPresent(TextModelProvider.self, forKey: .summaryProvider)) ?? defaults.summaryProvider
        transcriptionLanguage = (try? c.decodeIfPresent(TranscriptionLanguage.self, forKey: .transcriptionLanguage)) ?? defaults.transcriptionLanguage
        rememberCredentials = try c.decodeIfPresent(Bool.self, forKey: .rememberCredentials) ?? defaults.rememberCredentials
        showMenuBarControl = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarControl) ?? defaults.showMenuBarControl
        showMenuBarTimer = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarTimer) ?? defaults.showMenuBarTimer
        globalShortcutEnabled = try c.decodeIfPresent(Bool.self, forKey: .globalShortcutEnabled) ?? defaults.globalShortcutEnabled
        localAPIEnabled = try c.decodeIfPresent(Bool.self, forKey: .localAPIEnabled) ?? defaults.localAPIEnabled
        windowWidth = try c.decodeIfPresent(Double.self, forKey: .windowWidth) ?? defaults.windowWidth
        windowHeight = try c.decodeIfPresent(Double.self, forKey: .windowHeight) ?? defaults.windowHeight
    }
}

public struct TranscribeRequest: Codable, Equatable, Sendable {
    public var audioPath: String
    public var provider: AIProvider
    /// Optional ISO-639-1 language hint (`TranscriptionLanguage.languageCode`);
    /// absent or `nil` lets the provider auto-detect (requests without it still decode).
    public var languageCode: String?

    public init(audioPath: String, provider: AIProvider, languageCode: String? = nil) {
        self.audioPath = audioPath
        self.provider = provider
        self.languageCode = languageCode
    }
}

public struct TranscribeResponse: Codable, Equatable, Sendable {
    public var text: String
    public var provider: AIProvider
    public var languageCode: String?
    public var segments: [TranscriptSegment]

    public init(
        text: String,
        provider: AIProvider,
        languageCode: String?,
        segments: [TranscriptSegment] = []
    ) {
        self.text = text
        self.provider = provider
        self.languageCode = languageCode
        self.segments = segments
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
