import Foundation

public enum RecordingSessionState: String, Codable, CaseIterable, Sendable {
    case starting, capturing, paused, finalizing, completed, failed
}

public struct RecordingSessionManifest: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var state: RecordingSessionState
    public var finalRecordingID: UUID?
    public var source: AudioSource
    public var requestedName: String
    public var startedAt: Date
    public var updatedAt: Date
    public var accumulatedActiveDuration: TimeInterval
    public var completedSegments: [RecordingSessionSegment]
    public var activeSegment: RecordingSessionSegment?
    public var pauseReason: RecordingPauseReason?
    public var microphoneFileName: String?
    public var systemFileName: String?
    public var finalizationProgress: Double?
    public var recoveryNote: String?

    public init(
        schemaVersion: Int = 2,
        id: UUID = UUID(),
        state: RecordingSessionState = .starting,
        finalRecordingID: UUID? = nil,
        source: AudioSource,
        requestedName: String,
        startedAt: Date,
        updatedAt: Date = Date(),
        accumulatedActiveDuration: TimeInterval = 0,
        completedSegments: [RecordingSessionSegment] = [],
        activeSegment: RecordingSessionSegment? = nil,
        pauseReason: RecordingPauseReason? = nil,
        microphoneFileName: String? = nil,
        systemFileName: String? = nil,
        finalizationProgress: Double? = nil,
        recoveryNote: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.state = state
        self.finalRecordingID = finalRecordingID
        self.source = source
        self.requestedName = requestedName
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.accumulatedActiveDuration = accumulatedActiveDuration
        self.completedSegments = completedSegments
        self.activeSegment = activeSegment
        self.pauseReason = pauseReason
        self.microphoneFileName = microphoneFileName
        self.systemFileName = systemFileName
        self.finalizationProgress = finalizationProgress
        self.recoveryNote = recoveryNote
    }

    public var allSegments: [RecordingSessionSegment] {
        completedSegments + [activeSegment].compactMap { $0 }
    }

    public mutating func startActiveSegment(fileName: String, startedAt: Date, updatedAt: Date = Date()) {
        state = .capturing
        activeSegment = RecordingSessionSegment(fileName: fileName, startedAt: startedAt)
        pauseReason = nil
        self.updatedAt = updatedAt
    }

    public mutating func finishActiveSegment(
        endedAt: Date,
        accumulatedActiveDuration: TimeInterval,
        reason: RecordingPauseReason,
        updatedAt: Date = Date()
    ) {
        if var activeSegment {
            activeSegment.endedAt = endedAt
            completedSegments.append(activeSegment)
        }
        activeSegment = nil
        self.accumulatedActiveDuration = accumulatedActiveDuration
        pauseReason = reason
        state = .paused
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, state, finalRecordingID, source, requestedName, startedAt, updatedAt
        case accumulatedActiveDuration, completedSegments, activeSegment, pauseReason
        case microphoneFileName, systemFileName, finalizationProgress, recoveryNote
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        state = try c.decodeIfPresent(RecordingSessionState.self, forKey: .state) ?? .capturing
        finalRecordingID = try c.decodeIfPresent(UUID.self, forKey: .finalRecordingID)
        source = try c.decode(AudioSource.self, forKey: .source)
        requestedName = try c.decode(String.self, forKey: .requestedName)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        accumulatedActiveDuration = try c.decode(TimeInterval.self, forKey: .accumulatedActiveDuration)
        completedSegments = try c.decode([RecordingSessionSegment].self, forKey: .completedSegments)
        activeSegment = try c.decodeIfPresent(RecordingSessionSegment.self, forKey: .activeSegment)
        pauseReason = try c.decodeIfPresent(RecordingPauseReason.self, forKey: .pauseReason)
        microphoneFileName = try c.decodeIfPresent(String.self, forKey: .microphoneFileName)
        systemFileName = try c.decodeIfPresent(String.self, forKey: .systemFileName)
        finalizationProgress = try c.decodeIfPresent(Double.self, forKey: .finalizationProgress)
        recoveryNote = try c.decodeIfPresent(String.self, forKey: .recoveryNote)
    }
}

public struct RecordingSessionSegment: Codable, Equatable, Sendable {
    public var fileName: String
    public var startedAt: Date
    public var endedAt: Date?

    public init(fileName: String, startedAt: Date, endedAt: Date? = nil) {
        self.fileName = fileName
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public final class RecordingSessionManifestStore {
    private let folderURL: URL
    private let fileManager: FileManager

    public init(folderURL: URL, fileManager: FileManager = .default) {
        self.folderURL = folderURL
        self.fileManager = fileManager
    }

    public func url(for id: UUID) -> URL {
        folderURL.appendingPathComponent(".session-\(id.uuidString).json")
    }

    public func save(_ manifest: RecordingSessionManifest) throws {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(manifest)
        try DurableFile.write(data, to: url(for: manifest.id), fileManager: fileManager)
    }

    public func load(id: UUID) throws -> RecordingSessionManifest {
        guard let manifest = DurableFile.readRecoveringBackup(
            RecordingSessionManifest.self,
            from: url(for: id),
            decoder: Self.makeDecoder(),
            validate: { $0.schemaVersion <= 2 },
            fileManager: fileManager
        ) else { throw CocoaError(.fileReadCorruptFile) }
        return manifest
    }

    public func loadAll() throws -> [RecordingSessionManifest] {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let urls = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        return urls
            .filter { Self.isManifestFileName($0.lastPathComponent) }
            .compactMap { url in
                DurableFile.readRecoveringBackup(
                    RecordingSessionManifest.self,
                    from: url,
                    decoder: Self.makeDecoder(),
                    validate: { $0.schemaVersion <= 2 },
                    fileManager: fileManager
                )
            }
            .sorted { lhs, rhs in
                lhs.startedAt < rhs.startedAt
            }
    }

    public func delete(_ manifest: RecordingSessionManifest) throws {
        let manifestURL = url(for: manifest.id)
        if fileManager.fileExists(atPath: manifestURL.path) {
            try fileManager.removeItem(at: manifestURL)
        }
        let backup = DurableFile.backupURL(for: manifestURL)
        if fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }
    }

    public static func isManifestFileName(_ fileName: String) -> Bool {
        fileName.hasPrefix(".session-") && fileName.hasSuffix(".json")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
