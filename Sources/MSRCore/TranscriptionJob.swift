import Foundation

public enum TranscriptionJobStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

public struct TranscriptionJob: Codable, Equatable, Sendable {
    public var recordingID: UUID
    public var recordingName: String
    public var audioFileName: String
    public var provider: AIProvider
    public var status: TranscriptionJobStatus
    public var attemptCount: Int
    public var startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var transcriptFileName: String?
    public var errorMessage: String?
    public var replacingExistingTranscript: Bool

    public init(
        recordingID: UUID,
        recordingName: String,
        audioFileName: String,
        provider: AIProvider,
        status: TranscriptionJobStatus,
        attemptCount: Int,
        startedAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil,
        transcriptFileName: String? = nil,
        errorMessage: String? = nil,
        replacingExistingTranscript: Bool = false
    ) {
        self.recordingID = recordingID
        self.recordingName = recordingName
        self.audioFileName = audioFileName
        self.provider = provider
        self.status = status
        self.attemptCount = attemptCount
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.transcriptFileName = transcriptFileName
        self.errorMessage = errorMessage
        self.replacingExistingTranscript = replacingExistingTranscript
    }

    enum CodingKeys: String, CodingKey {
        case recordingID
        case recordingName
        case audioFileName
        case provider
        case status
        case attemptCount
        case startedAt
        case updatedAt
        case completedAt
        case transcriptFileName
        case errorMessage
        case replacingExistingTranscript
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordingID = try container.decode(UUID.self, forKey: .recordingID)
        recordingName = try container.decode(String.self, forKey: .recordingName)
        audioFileName = try container.decode(String.self, forKey: .audioFileName)
        provider = try container.decode(AIProvider.self, forKey: .provider)
        status = try container.decode(TranscriptionJobStatus.self, forKey: .status)
        attemptCount = try container.decode(Int.self, forKey: .attemptCount)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        transcriptFileName = try container.decodeIfPresent(String.self, forKey: .transcriptFileName)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        replacingExistingTranscript = try container.decodeIfPresent(Bool.self, forKey: .replacingExistingTranscript) ?? false
    }

    public static func start(
        recordingID: UUID,
        recordingName: String,
        audioFileName: String,
        provider: AIProvider,
        previousAttemptCount: Int = 0,
        at date: Date = Date()
    ) -> TranscriptionJob {
        TranscriptionJob(
            recordingID: recordingID,
            recordingName: recordingName,
            audioFileName: audioFileName,
            provider: provider,
            status: .running,
            attemptCount: previousAttemptCount + 1,
            startedAt: date,
            updatedAt: date
        )
    }

    public static func queue(
        recordingID: UUID,
        recordingName: String,
        audioFileName: String,
        provider: AIProvider,
        replacingExistingTranscript: Bool = false,
        previousAttemptCount: Int = 0,
        at date: Date = Date()
    ) -> TranscriptionJob {
        TranscriptionJob(
            recordingID: recordingID,
            recordingName: recordingName,
            audioFileName: audioFileName,
            provider: provider,
            status: .queued,
            attemptCount: previousAttemptCount + 1,
            startedAt: date,
            updatedAt: date,
            replacingExistingTranscript: replacingExistingTranscript
        )
    }

    public mutating func markRunning(at date: Date = Date()) {
        status = .running
        startedAt = date
        updatedAt = date
        completedAt = nil
        transcriptFileName = nil
        errorMessage = nil
    }

    public mutating func markFailed(_ message: String, at date: Date = Date()) {
        status = .failed
        updatedAt = date
        completedAt = nil
        transcriptFileName = nil
        errorMessage = message
    }

    public mutating func markCompleted(transcriptFileName: String, at date: Date = Date()) {
        status = .completed
        updatedAt = date
        completedAt = date
        self.transcriptFileName = transcriptFileName
        errorMessage = nil
    }

    public mutating func markInterruptedIfRunning(at date: Date = Date()) {
        guard status == .running else { return }
        markFailed("Transcription was interrupted before it finished. Retry transcription to upload the same recording again.", at: date)
    }

    public mutating func markCancelled(at date: Date = Date()) {
        status = .cancelled
        updatedAt = date
        completedAt = nil
        transcriptFileName = nil
        errorMessage = "Transcription was cancelled."
    }
}

public final class TranscriptionJobStore {
    private let folderURL: URL
    private let fileManager: FileManager

    public init(folderURL: URL, fileManager: FileManager = .default) {
        self.folderURL = folderURL
        self.fileManager = fileManager
    }

    public func url(for recordingID: UUID) -> URL {
        folderURL.appendingPathComponent(".transcription-\(recordingID.uuidString).json")
    }

    public func save(_ job: TranscriptionJob) throws {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(job)
        try data.write(to: url(for: job.recordingID), options: .atomic)
    }

    public func load(recordingID: UUID) throws -> TranscriptionJob {
        let data = try Data(contentsOf: url(for: recordingID))
        return try Self.makeDecoder().decode(TranscriptionJob.self, from: data)
    }

    public func loadIfExists(recordingID: UUID) -> TranscriptionJob? {
        try? load(recordingID: recordingID)
    }

    public func loadAll() throws -> [TranscriptionJob] {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let urls = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        return try urls
            .filter { Self.isJobFileName($0.lastPathComponent) }
            .map { url in
                let data = try Data(contentsOf: url)
                return try Self.makeDecoder().decode(TranscriptionJob.self, from: data)
            }
            .sorted { lhs, rhs in
                lhs.updatedAt > rhs.updatedAt
            }
    }

    public func delete(recordingID: UUID) throws {
        let url = url(for: recordingID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public static func isJobFileName(_ fileName: String) -> Bool {
        fileName.hasPrefix(".transcription-") && fileName.hasSuffix(".json")
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
