import Foundation

public final class RecordingLibrary {
    private let fileManager: FileManager
    public let folderURL: URL

    public init(folderURL: URL, fileManager: FileManager = .default) {
        self.folderURL = folderURL
        self.fileManager = fileManager
    }

    public func loadRecordings() throws -> [RecordingItem] {
        try ensureFolderExists()
        let urls = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let decoder = Self.makeDecoder()
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let metadata = try? decoder.decode(RecordingMetadata.self, from: data) else {
                    return nil
                }
                return RecordingItem(metadata: metadata, folderURL: folderURL)
            }
            .sorted { lhs, rhs in
                lhs.startedAt > rhs.startedAt
            }
    }

    @discardableResult
    public func finishRecording(
        temporaryAudioURL: URL,
        requestedName: String,
        source: AudioSource,
        startedAt: Date,
        endedAt: Date,
        durationSecondsOverride: TimeInterval? = nil,
        recoveredAt: Date? = nil,
        recoveryNote: String? = nil,
        segmentCount: Int? = nil,
        confidenceReport: RecordingConfidenceReport? = nil
    ) throws -> RecordingItem {
        try ensureFolderExists()
        let baseName = try uniqueBaseName(FileNameSanitizer.sanitizedBaseName(requestedName))
        let destinationAudioURL = folderURL.appendingPathComponent("\(baseName).m4a")
        if temporaryAudioURL.standardizedFileURL != destinationAudioURL.standardizedFileURL {
            if fileManager.fileExists(atPath: destinationAudioURL.path) {
                try fileManager.removeItem(at: destinationAudioURL)
            }
            try fileManager.moveItem(at: temporaryAudioURL, to: destinationAudioURL)
        }
        let now = Date()
        let metadata = RecordingMetadata(
            id: UUID(),
            displayName: baseName,
            source: source,
            audioFileName: destinationAudioURL.lastPathComponent,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: max(0, durationSecondsOverride ?? endedAt.timeIntervalSince(startedAt)),
            createdAt: now,
            updatedAt: now,
            recoveredAt: recoveredAt,
            recoveryNote: recoveryNote,
            segmentCount: segmentCount,
            confidenceReport: confidenceReport
        )
        let recording = RecordingItem(metadata: metadata, folderURL: folderURL)
        try write(metadata: metadata, to: recording.metadataURL)
        return recording
    }

    @discardableResult
    public func importRecording(
        sourceURL: URL,
        requestedName: String,
        source: AudioSource,
        startedAt: Date,
        durationSeconds: TimeInterval,
        importedAt: Date = Date(),
        confidenceReport: RecordingConfidenceReport? = nil
    ) throws -> RecordingItem {
        try ensureFolderExists()
        let baseName = try uniqueBaseName(FileNameSanitizer.sanitizedBaseName(requestedName))
        let fileExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let destinationAudioURL = folderURL.appendingPathComponent("\(baseName).\(fileExtension)")
        if sourceURL.standardizedFileURL != destinationAudioURL.standardizedFileURL {
            if fileManager.fileExists(atPath: destinationAudioURL.path) {
                try fileManager.removeItem(at: destinationAudioURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationAudioURL)
        }
        let now = Date()
        let metadata = RecordingMetadata(
            id: UUID(),
            displayName: baseName,
            source: source,
            audioFileName: destinationAudioURL.lastPathComponent,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(max(0, durationSeconds)),
            durationSeconds: max(0, durationSeconds),
            createdAt: now,
            updatedAt: now,
            importedAt: importedAt,
            confidenceReport: confidenceReport
        )
        let recording = RecordingItem(metadata: metadata, folderURL: folderURL)
        try write(metadata: metadata, to: recording.metadataURL)
        return recording
    }

    @discardableResult
    public func rename(_ recording: RecordingItem, to requestedName: String) throws -> RecordingItem {
        try ensureFolderExists()
        let baseName = try uniqueBaseName(
            FileNameSanitizer.sanitizedBaseName(requestedName),
            allowing: recording.displayName
        )
        let newAudioURL = folderURL.appendingPathComponent("\(baseName).m4a")
        let newTranscriptURL = folderURL.appendingPathComponent("\(baseName).transcript.txt")
        let newTranscriptSegmentsURL = folderURL.appendingPathComponent("\(baseName).transcript.segments.json")
        let newSummaryURL = folderURL.appendingPathComponent("\(baseName).summary.md")
        let oldMetadataURL = recording.metadataURL

        try moveIfExists(from: recording.audioURL, to: newAudioURL)
        try moveIfExists(from: recording.transcriptURL, to: newTranscriptURL)
        try moveIfExists(from: recording.transcriptSegmentsURL, to: newTranscriptSegmentsURL)
        try moveIfExists(from: recording.summaryURL, to: newSummaryURL)

        var metadata = recording.metadata
        metadata.displayName = baseName
        metadata.audioFileName = newAudioURL.lastPathComponent
        metadata.updatedAt = Date()
        let renamed = RecordingItem(metadata: metadata, folderURL: folderURL)
        try write(metadata: metadata, to: renamed.metadataURL)
        if oldMetadataURL.standardizedFileURL != renamed.metadataURL.standardizedFileURL,
           fileManager.fileExists(atPath: oldMetadataURL.path) {
            try fileManager.removeItem(at: oldMetadataURL)
        }
        return renamed
    }

    public func writeTranscript(_ transcript: String, for recording: RecordingItem) throws {
        try transcript.write(to: recording.transcriptURL, atomically: true, encoding: .utf8)
    }

    public func writeTranscriptSegments(_ segments: [TranscriptSegment], for recording: RecordingItem) throws {
        let data = try Self.makeEncoder().encode(segments)
        try data.write(to: recording.transcriptSegmentsURL, options: .atomic)
    }

    public func loadTranscriptSegments(for recording: RecordingItem) -> [TranscriptSegment] {
        guard fileManager.fileExists(atPath: recording.transcriptSegmentsURL.path),
              let data = try? Data(contentsOf: recording.transcriptSegmentsURL),
              let segments = try? Self.makeDecoder().decode([TranscriptSegment].self, from: data) else {
            return []
        }
        return segments
    }

    public func writeSummary(_ summary: String, for recording: RecordingItem) throws {
        try summary.write(to: recording.summaryURL, atomically: true, encoding: .utf8)
    }

    public func clearSummary(for recording: RecordingItem) throws {
        if fileManager.fileExists(atPath: recording.summaryURL.path) {
            try fileManager.removeItem(at: recording.summaryURL)
        }
    }

    public func delete(_ recording: RecordingItem) throws {
        for url in [recording.audioURL, recording.metadataURL, recording.transcriptURL, recording.transcriptSegmentsURL, recording.summaryURL] {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func ensureFolderExists() throws {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    private func uniqueBaseName(_ requested: String, allowing currentName: String? = nil) throws -> String {
        var candidate = requested
        var index = 2
        while candidate != currentName && nameExists(candidate) {
            candidate = "\(requested) \(index)"
            index += 1
        }
        return candidate
    }

    private func nameExists(_ baseName: String) -> Bool {
        let candidates = [
            "\(baseName).m4a",
            "\(baseName).json",
            "\(baseName).transcript.txt",
            "\(baseName).transcript.segments.json",
            "\(baseName).summary.md"
        ]
        return candidates.contains { fileManager.fileExists(atPath: folderURL.appendingPathComponent($0).path) }
    }

    private func moveIfExists(from source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path),
              source.standardizedFileURL != destination.standardizedFileURL else {
            return
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    private func write(metadata: RecordingMetadata, to url: URL) throws {
        let data = try Self.makeEncoder().encode(metadata)
        try data.write(to: url, options: .atomic)
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
