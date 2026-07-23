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
    public var autoTitle: Bool
    public var rememberCredentials: Bool
    public var showMenuBarControl: Bool
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
        rememberCredentials: false,
        showMenuBarControl: true,
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
        rememberCredentials: Bool = false,
        showMenuBarControl: Bool = true,
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
        self.rememberCredentials = rememberCredentials
        self.showMenuBarControl = showMenuBarControl
        self.globalShortcutEnabled = globalShortcutEnabled
        self.localAPIEnabled = localAPIEnabled
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
    }

    private enum CodingKeys: String, CodingKey {
        case provider, recordingsFolderPath, recordingsFolderBookmark, preferredSource, microphoneDeviceID
        case sortOrder, silenceThreshold, playbackSpeed, theme, language, compressUploads, autoTitle
        case rememberCredentials, showMenuBarControl, globalShortcutEnabled, localAPIEnabled, windowWidth, windowHeight
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
        rememberCredentials = try c.decodeIfPresent(Bool.self, forKey: .rememberCredentials) ?? defaults.rememberCredentials
        showMenuBarControl = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarControl) ?? defaults.showMenuBarControl
        globalShortcutEnabled = try c.decodeIfPresent(Bool.self, forKey: .globalShortcutEnabled) ?? defaults.globalShortcutEnabled
        localAPIEnabled = try c.decodeIfPresent(Bool.self, forKey: .localAPIEnabled) ?? defaults.localAPIEnabled
        windowWidth = try c.decodeIfPresent(Double.self, forKey: .windowWidth) ?? defaults.windowWidth
        windowHeight = try c.decodeIfPresent(Double.self, forKey: .windowHeight) ?? defaults.windowHeight
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
