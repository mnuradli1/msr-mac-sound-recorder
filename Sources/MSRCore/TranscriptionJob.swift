import Foundation

public enum TranscriptionJobStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

public struct TranscriptionJob: Codable, Equatable, Sendable {
    public var id: UUID
    public var recordingID: UUID
    public var recordingName: String
    public var audioFileName: String
    public var provider: AIProvider
    public var status: TranscriptionJobStatus
    public var attemptCount: Int
    public var startedAt: Date
    public var queuedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var transcriptFileName: String?
    public var errorMessage: String?
    public var replacingExistingTranscript: Bool
    public var trimStartSeconds: TimeInterval?
    public var trimEndSeconds: TimeInterval?
    public var transcriptContentSHA256: String?
    public var publicationStartedAt: Date?
    public var usedUncompressedAudioFallback: Bool
    public var audioPreparationWarning: String?

    public init(
        id: UUID = UUID(),
        recordingID: UUID,
        recordingName: String,
        audioFileName: String,
        provider: AIProvider,
        status: TranscriptionJobStatus,
        attemptCount: Int,
        startedAt: Date,
        queuedAt: Date? = nil,
        updatedAt: Date,
        completedAt: Date? = nil,
        transcriptFileName: String? = nil,
        errorMessage: String? = nil,
        replacingExistingTranscript: Bool = false,
        trimStartSeconds: TimeInterval? = nil,
        trimEndSeconds: TimeInterval? = nil,
        transcriptContentSHA256: String? = nil,
        publicationStartedAt: Date? = nil,
        usedUncompressedAudioFallback: Bool = false,
        audioPreparationWarning: String? = nil
    ) {
        self.id = id
        self.recordingID = recordingID
        self.recordingName = recordingName
        self.audioFileName = audioFileName
        self.provider = provider
        self.status = status
        self.attemptCount = attemptCount
        self.startedAt = startedAt
        self.queuedAt = queuedAt ?? startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.transcriptFileName = transcriptFileName
        self.errorMessage = errorMessage
        self.replacingExistingTranscript = replacingExistingTranscript
        self.trimStartSeconds = trimStartSeconds
        self.trimEndSeconds = trimEndSeconds
        self.transcriptContentSHA256 = transcriptContentSHA256
        self.publicationStartedAt = publicationStartedAt
        self.usedUncompressedAudioFallback = usedUncompressedAudioFallback
        self.audioPreparationWarning = audioPreparationWarning
    }

    enum CodingKeys: String, CodingKey {
        case id
        case recordingID
        case recordingName
        case audioFileName
        case provider
        case status
        case attemptCount
        case startedAt
        case queuedAt
        case updatedAt
        case completedAt
        case transcriptFileName
        case errorMessage
        case replacingExistingTranscript
        case trimStartSeconds
        case trimEndSeconds
        case transcriptContentSHA256
        case publicationStartedAt
        case usedUncompressedAudioFallback
        case audioPreparationWarning
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordingID = try container.decode(UUID.self, forKey: .recordingID)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? recordingID
        recordingName = try container.decode(String.self, forKey: .recordingName)
        audioFileName = try container.decode(String.self, forKey: .audioFileName)
        provider = try container.decode(AIProvider.self, forKey: .provider)
        status = try container.decode(TranscriptionJobStatus.self, forKey: .status)
        attemptCount = try container.decode(Int.self, forKey: .attemptCount)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        queuedAt = try container.decodeIfPresent(Date.self, forKey: .queuedAt) ?? startedAt
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        transcriptFileName = try container.decodeIfPresent(String.self, forKey: .transcriptFileName)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        replacingExistingTranscript = try container.decodeIfPresent(Bool.self, forKey: .replacingExistingTranscript) ?? false
        trimStartSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .trimStartSeconds)
        trimEndSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .trimEndSeconds)
        transcriptContentSHA256 = try container.decodeIfPresent(String.self, forKey: .transcriptContentSHA256)
        publicationStartedAt = try container.decodeIfPresent(Date.self, forKey: .publicationStartedAt)
        usedUncompressedAudioFallback = try container.decodeIfPresent(Bool.self, forKey: .usedUncompressedAudioFallback) ?? false
        audioPreparationWarning = try container.decodeIfPresent(String.self, forKey: .audioPreparationWarning)
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
        trimStartSeconds: TimeInterval? = nil,
        trimEndSeconds: TimeInterval? = nil,
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
            replacingExistingTranscript: replacingExistingTranscript,
            trimStartSeconds: trimStartSeconds.flatMap { $0 > 0 ? $0 : nil },
            trimEndSeconds: trimEndSeconds.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    public mutating func markRunning(at date: Date = Date()) {
        status = .running
        startedAt = date
        updatedAt = date
        completedAt = nil
        transcriptFileName = nil
        transcriptContentSHA256 = nil
        publicationStartedAt = nil
        usedUncompressedAudioFallback = false
        audioPreparationWarning = nil
        errorMessage = nil
    }

    public mutating func markPublishing(
        transcriptFileName: String,
        contentSHA256: String,
        at date: Date = Date()
    ) {
        status = .running
        updatedAt = date
        self.transcriptFileName = transcriptFileName
        transcriptContentSHA256 = contentSHA256
        publicationStartedAt = date
        completedAt = nil
        errorMessage = nil
    }

    public mutating func markFailed(_ message: String, at date: Date = Date()) {
        status = .failed
        updatedAt = date
        completedAt = nil
        transcriptFileName = nil
        transcriptContentSHA256 = nil
        publicationStartedAt = nil
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
        status = .queued
        updatedAt = date
        completedAt = nil
        usedUncompressedAudioFallback = false
        audioPreparationWarning = nil
        errorMessage = "The app closed while this job was running; it was queued again."
    }

    public mutating func markCancelled(at date: Date = Date()) {
        status = .cancelled
        updatedAt = date
        completedAt = nil
        transcriptFileName = nil
        transcriptContentSHA256 = nil
        publicationStartedAt = nil
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

    public func url(for jobID: UUID) -> URL {
        folderURL.appendingPathComponent(".transcription-\(jobID.uuidString).json")
    }

    public func save(_ job: TranscriptionJob) throws {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(job)
        try DurableFile.write(data, to: url(for: job.id), fileManager: fileManager)
    }

    public func load(jobID: UUID) throws -> TranscriptionJob {
        let data = try Data(contentsOf: url(for: jobID))
        return try Self.makeDecoder().decode(TranscriptionJob.self, from: data)
    }

    public func load(recordingID: UUID) throws -> TranscriptionJob {
        guard let job = try loadAll().first(where: { $0.recordingID == recordingID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return job
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
        return urls
            .filter { Self.isJobFileName($0.lastPathComponent) }
            .map { url in
                DurableFile.readRecoveringBackup(
                    TranscriptionJob.self,
                    from: url,
                    decoder: Self.makeDecoder(),
                    fileManager: fileManager
                )
            }
            .compactMap { $0 }
            .sorted { lhs, rhs in
                lhs.updatedAt > rhs.updatedAt
            }
    }

    public func delete(recordingID: UUID) throws {
        for job in try loadAll() where job.recordingID == recordingID {
            try delete(jobID: job.id)
        }
    }

    public func delete(jobID: UUID) throws {
        for url in [url(for: jobID), DurableFile.backupURL(for: url(for: jobID))]
        where fileManager.fileExists(atPath: url.path) {
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
