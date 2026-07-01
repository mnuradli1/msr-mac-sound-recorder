import Foundation

public struct RecordingSessionManifest: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var source: AudioSource
    public var requestedName: String
    public var startedAt: Date
    public var updatedAt: Date
    public var accumulatedActiveDuration: TimeInterval
    public var completedSegments: [RecordingSessionSegment]
    public var activeSegment: RecordingSessionSegment?
    public var pauseReason: RecordingPauseReason?

    public init(
        id: UUID = UUID(),
        source: AudioSource,
        requestedName: String,
        startedAt: Date,
        updatedAt: Date = Date(),
        accumulatedActiveDuration: TimeInterval = 0,
        completedSegments: [RecordingSessionSegment] = [],
        activeSegment: RecordingSessionSegment? = nil,
        pauseReason: RecordingPauseReason? = nil
    ) {
        self.id = id
        self.source = source
        self.requestedName = requestedName
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.accumulatedActiveDuration = accumulatedActiveDuration
        self.completedSegments = completedSegments
        self.activeSegment = activeSegment
        self.pauseReason = pauseReason
    }

    public var allSegments: [RecordingSessionSegment] {
        completedSegments + [activeSegment].compactMap { $0 }
    }

    public mutating func startActiveSegment(fileName: String, startedAt: Date, updatedAt: Date = Date()) {
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
        self.updatedAt = updatedAt
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
        try data.write(to: url(for: manifest.id), options: .atomic)
    }

    public func load(id: UUID) throws -> RecordingSessionManifest {
        let data = try Data(contentsOf: url(for: id))
        return try Self.makeDecoder().decode(RecordingSessionManifest.self, from: data)
    }

    public func loadAll() throws -> [RecordingSessionManifest] {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let urls = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        return try urls
            .filter { Self.isManifestFileName($0.lastPathComponent) }
            .map { url in
                let data = try Data(contentsOf: url)
                return try Self.makeDecoder().decode(RecordingSessionManifest.self, from: data)
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
