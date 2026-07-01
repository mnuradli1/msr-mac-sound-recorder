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

public struct RecordingMetadata: Codable, Equatable, Sendable {
    public var id: UUID
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

    public init(
        id: UUID,
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
        confidenceReport: RecordingConfidenceReport? = nil
    ) {
        self.id = id
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

    public var audioURL: URL {
        folderURL.appendingPathComponent(metadata.audioFileName)
    }

    public var metadataURL: URL {
        folderURL.appendingPathComponent("\(displayName).json")
    }

    public var transcriptURL: URL {
        folderURL.appendingPathComponent("\(displayName).transcript.txt")
    }

    public var summaryURL: URL {
        folderURL.appendingPathComponent("\(displayName).summary.md")
    }

    public var transcriptSegmentsURL: URL {
        folderURL.appendingPathComponent("\(displayName).transcript.segments.json")
    }

    public init(metadata: RecordingMetadata, folderURL: URL) {
        self.metadata = metadata
        self.folderURL = folderURL
    }
}
