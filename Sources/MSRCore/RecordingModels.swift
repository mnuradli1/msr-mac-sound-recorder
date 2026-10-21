import Foundation

public enum AudioSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case microphone
    case system
    case micAndSystem

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .microphone:
            return "Mic"
        case .system:
            return "System"
        case .micAndSystem:
            return "Mic + System"
        }
    }
}

/// Who chose a recording's current title.
///
/// Persisted on `RecordingMetadata.titleSource`. Auto-titling only ever replaces
/// a `.default` title, so a name the user typed is never overwritten.
public enum RecordingTitleSource: String, Codable, Sendable {
    /// Machine-generated placeholder such as "Meeting 2026-06-29 14.05".
    case `default` = "default"
    /// Chosen by the user (manual rename, or the file name of an imported file).
    case user = "user"
    /// Generated from the transcript by auto-title.
    case generated = "generated"
}

public struct RecordingMetadata: Codable, Equatable, Sendable {
    public static let currentSchema = "msr.recording"
    public static let minimumSupportedSchemaVersion = 1
    public static let currentSchemaVersion = 2

    public var schema: String
    public var schemaVersion: Int
    public var id: UUID
    public var storageKey: String?
    public var displayName: String
    public var source: AudioSource
    public var audioFileName: String
    public var startedAt: Date
    public var endedAt: Date
    public var durationSeconds: TimeInterval
    public var createdAt: Date
    public var updatedAt: Date
    public var recoveredAt: Date?
    public var recoveryNote: String?
    public var segmentCount: Int?
    public var importedAt: Date?
    public var confidenceReport: RecordingConfidenceReport?
    /// Provenance of `displayName`. `nil` in metadata written before this field
    /// existed; use `effectiveTitleSource` to read it with a legacy fallback.
    /// Adding it did not bump `schemaVersion`, so older builds still open the file.
    public var titleSource: RecordingTitleSource?
    /// Display names for diarized speakers, keyed by the ORIGINAL label the
    /// provider produced (e.g. `"Speaker 1": "Sarah"`). The transcript and
    /// segments files already carry the display names; this map keeps the
    /// original labels recoverable. `nil` when no speaker was renamed. Added
    /// without a `schemaVersion` bump.
    public var speakerNames: [String: String]?

    public init(
        schema: String = RecordingMetadata.currentSchema,
        schemaVersion: Int = RecordingMetadata.currentSchemaVersion,
        id: UUID,
        storageKey: String? = nil,
        displayName: String,
        source: AudioSource,
        audioFileName: String,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: TimeInterval,
        createdAt: Date,
        updatedAt: Date,
        recoveredAt: Date? = nil,
        recoveryNote: String? = nil,
        segmentCount: Int? = nil,
        importedAt: Date? = nil,
        confidenceReport: RecordingConfidenceReport? = nil,
        titleSource: RecordingTitleSource? = nil,
        speakerNames: [String: String]? = nil
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.id = id
        self.storageKey = storageKey
        self.displayName = displayName
        self.source = source
        self.audioFileName = audioFileName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recoveredAt = recoveredAt
        self.recoveryNote = recoveryNote
        self.segmentCount = segmentCount
        self.importedAt = importedAt
        self.confidenceReport = confidenceReport
        self.titleSource = titleSource
        self.speakerNames = speakerNames
    }

    private enum CodingKeys: String, CodingKey {
        case schema, schemaVersion, id, storageKey, displayName, source, audioFileName
        case startedAt, endedAt, durationSeconds, createdAt, updatedAt
        case recoveredAt, recoveryNote, segmentCount, importedAt, confidenceReport
        case titleSource
        case speakerNames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? Self.currentSchema
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.minimumSupportedSchemaVersion
        id = try container.decode(UUID.self, forKey: .id)
        storageKey = try container.decodeIfPresent(String.self, forKey: .storageKey)
        displayName = try container.decode(String.self, forKey: .displayName)
        source = try container.decode(AudioSource.self, forKey: .source)
        audioFileName = try container.decode(String.self, forKey: .audioFileName)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        durationSeconds = try container.decode(TimeInterval.self, forKey: .durationSeconds)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        recoveredAt = try container.decodeIfPresent(Date.self, forKey: .recoveredAt)
        recoveryNote = try container.decodeIfPresent(String.self, forKey: .recoveryNote)
        segmentCount = try container.decodeIfPresent(Int.self, forKey: .segmentCount)
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt)
        confidenceReport = try container.decodeIfPresent(RecordingConfidenceReport.self, forKey: .confidenceReport)
        titleSource = try? container.decodeIfPresent(RecordingTitleSource.self, forKey: .titleSource)
        speakerNames = (try? container.decodeIfPresent([String: String].self, forKey: .speakerNames)) ?? nil
    }

    /// `titleSource` when recorded; otherwise inferred from the name itself:
    /// a default-looking name (`MeetingTitleGenerator.isDefaultName`) is
    /// `.default`, anything else is treated as the user's choice.
    public var effectiveTitleSource: RecordingTitleSource {
        if let titleSource { return titleSource }
        return MeetingTitleGenerator.isDefaultName(displayName) ? .default : .user
    }
}

public struct RecordingItem: Equatable, Identifiable, Sendable {
    public var metadata: RecordingMetadata
    public var folderURL: URL

    public var id: UUID { metadata.id }
    public var displayName: String { metadata.displayName }
    public var source: AudioSource { metadata.source }
    public var startedAt: Date { metadata.startedAt }
    public var endedAt: Date { metadata.endedAt }
    public var durationSeconds: TimeInterval { metadata.durationSeconds }
    public var isRecovered: Bool { metadata.recoveredAt != nil }
    public var isImported: Bool { metadata.importedAt != nil }
    /// See `RecordingMetadata.effectiveTitleSource`.
    public var effectiveTitleSource: RecordingTitleSource { metadata.effectiveTitleSource }
    /// Original speaker label → display name (empty when none were renamed).
    public var speakerNames: [String: String] { metadata.speakerNames ?? [:] }
    public var storageBaseName: String {
        let value = metadata.storageKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? displayName : value
    }
    public var usesImmutableStorage: Bool { metadata.storageKey?.isEmpty == false }

    public var audioURL: URL {
        folderURL.appendingPathComponent(metadata.audioFileName)
    }

    public var metadataURL: URL {
        folderURL.appendingPathComponent("\(storageBaseName).json")
    }

    public var transcriptURL: URL {
        folderURL.appendingPathComponent("\(storageBaseName).transcript.txt")
    }

    public var summaryURL: URL {
        folderURL.appendingPathComponent("\(storageBaseName).summary.md")
    }

    public var transcriptSegmentsURL: URL {
        folderURL.appendingPathComponent("\(storageBaseName).transcript.segments.json")
    }

    /// The review waveform cache (`WaveformCacheFile`), a derived sidecar the
    /// library deletes and migrates with the recording.
    public var waveformURL: URL {
        folderURL.appendingPathComponent("\(storageBaseName).waveform")
    }

    public init(metadata: RecordingMetadata, folderURL: URL) {
        self.metadata = metadata
        self.folderURL = folderURL
    }
}
