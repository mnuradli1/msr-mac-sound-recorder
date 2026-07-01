import Foundation

public enum TranscriptionJobStatus: String, Codable, Equatable, Sendable {
    case running
    case completed
    case failed
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
        errorMessage: String? = nil
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
