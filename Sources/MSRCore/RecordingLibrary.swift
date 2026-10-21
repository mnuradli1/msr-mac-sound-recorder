import Foundation

public enum RecordingLibraryError: Error, LocalizedError, Equatable {
    case audioMissing(String)
    case unsupportedAudioType(String)
    case duplicateRecordingID(UUID)
    case invalidMetadata(String)
    case recordingNotFound(UUID)
    case speakerNotFound(String)
    case speakerNameInUse(String)

    public var errorDescription: String? {
        switch self {
        case let .audioMissing(name): "The audio file is missing: \(name)"
        case let .unsupportedAudioType(ext): "Only WAV, MP3, and M4A files can be imported (received .\(ext))."
        case let .duplicateRecordingID(id): "A recording with ID \(id.uuidString) already exists."
        case let .invalidMetadata(message): message
        case .recordingNotFound: "The recording is no longer in the library."
        case let .speakerNotFound(label): "\(label) is not a speaker in this transcript."
        case let .speakerNameInUse(name): "Another speaker is already called \(name)."
        }
    }
}

public protocol RecordingLibraryServing: Sendable {
    var folderURL: URL { get }
    func loadRecordings() throws -> [RecordingItem]
    func finishRecording(
        temporaryAudioURL: URL, requestedName: String, source: AudioSource,
        startedAt: Date, endedAt: Date, durationSecondsOverride: TimeInterval?,
        recoveredAt: Date?, recoveryNote: String?, segmentCount: Int?,
        confidenceReport: RecordingConfidenceReport?, recordingID: UUID?
    ) throws -> RecordingItem
    func importRecording(
        sourceURL: URL, requestedName: String, source: AudioSource,
        startedAt: Date, durationSeconds: TimeInterval, importedAt: Date,
        confidenceReport: RecordingConfidenceReport?
    ) throws -> RecordingItem
    /// Renames as the user (`titleSource = .user`). See `rename(_:to:source:)`.
    func rename(_ recording: RecordingItem, to requestedName: String) throws -> RecordingItem
    /// Re-reads the recording from disk, applies the new title and its provenance
    /// on top of the on-disk metadata, and writes it durably. Renaming to the
    /// current name is a no-op that keeps `titleSource`.
    @discardableResult
    func rename(_ recording: RecordingItem, to requestedName: String, source: RecordingTitleSource) throws -> RecordingItem
    /// Cleans `newName` with `MeetingTitleGenerator.cleaned(_:fallback:)` and renames
    /// with `source: .generated` only when the on-disk title is still a default
    /// one; returns `nil` and changes nothing otherwise.
    @discardableResult
    func renameIfTitleIsDefault(_ recording: RecordingItem, to newName: String) throws -> RecordingItem?
    /// Moves a legacy recording to immutable storage if needed and returns it.
    @discardableResult
    func migrateIfNeeded(_ recording: RecordingItem) throws -> RecordingItem
    func writeTranscript(_ transcript: String, for recording: RecordingItem) throws -> RecordingItem
    func writeTranscriptBundle(_ transcript: String, segments: [TranscriptSegment], for recording: RecordingItem) throws -> RecordingItem
    func loadTranscriptSegments(for recording: RecordingItem) -> [TranscriptSegment]
    func writeSummary(_ summary: String, for recording: RecordingItem) throws -> RecordingItem
    func clearSummary(for recording: RecordingItem) throws -> RecordingItem
    /// Gives a diarized speaker a display name. See `RecordingLibrary.renameSpeaker(_:label:to:)`.
    @discardableResult
    func renameSpeaker(_ recording: RecordingItem, label: String, to name: String) throws -> RecordingItem
    /// Drops all speaker display names from the metadata without touching the
    /// transcript (used when a new transcript replaces the old one).
    @discardableResult
    func resetSpeakerNames(for recording: RecordingItem) throws -> RecordingItem
    func delete(_ recording: RecordingItem) throws
}

public final class RecordingLibrary: RecordingLibraryServing, @unchecked Sendable {
    public let folderURL: URL
    private let fileManager: FileManager

    public init(folderURL: URL, fileManager: FileManager = .default) {
        self.folderURL = folderURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public func loadRecordings() throws -> [RecordingItem] {
        try ensureFolderExists()
        try resumePendingOperations()
        let urls = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let jsonURLs = urls.filter { $0.pathExtension.lowercased() == "json" }
        // Hidden files (job, session and journal JSON) are already skipped by
        // `.skipsHiddenFiles`. A recording's segments sidecar is never metadata:
        // skip it by name instead of failing to decode it (three reads each).
        let jsonNames = Set(jsonURLs.map(\.lastPathComponent))
        let candidates = jsonURLs
            .filter { !Self.isSegmentsSidecar($0.lastPathComponent, among: jsonNames) }
            .compactMap(readRecording)
        let duplicateIDs = Dictionary(grouping: candidates, by: \.id)
            .filter { $0.value.count > 1 }
            .keys
        return candidates
            .filter { !duplicateIDs.contains($0.id) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// `<base>.transcript.segments.json` next to a `<base>.json`: the segments
    /// file of that recording. Without the sibling (an orphan, or a legacy
    /// recording literally named `… .transcript.segments`) it is still decoded
    /// and ignored when it is not valid metadata, as before.
    static func isSegmentsSidecar(_ fileName: String, among jsonNames: Set<String>) -> Bool {
        let suffix = ".transcript.segments.json"
        guard fileName.hasSuffix(suffix), fileName.count > suffix.count else { return false }
        return jsonNames.contains(String(fileName.dropLast(suffix.count)) + ".json")
    }

    /// Publishes a finished capture. The title is recorded as
    /// `RecordingTitleSource.default`: captures (and crash recoveries) are named
    /// by the app, so auto-title may later replace the name.
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
        confidenceReport: RecordingConfidenceReport? = nil,
        recordingID: UUID? = nil
    ) throws -> RecordingItem {
        try ensureFolderExists()
        guard fileManager.fileExists(atPath: temporaryAudioURL.path) else {
            throw RecordingLibraryError.audioMissing(temporaryAudioURL.lastPathComponent)
        }
        // One listing serves both checks (nothing is written in between).
        let existing = try loadRecordings()
        let displayName = uniqueDisplayName(FileNameSanitizer.sanitizedBaseName(requestedName), excluding: nil, among: existing)
        let id = recordingID ?? UUID()
        try ensureRecordingIDAvailable(id, among: existing)
        let storageKey = Self.storageKey(for: id)
        let ext = temporaryAudioURL.pathExtension.isEmpty ? "m4a" : temporaryAudioURL.pathExtension.lowercased()
        let destination = try StoragePath.containedURL(in: folderURL, fileName: "\(storageKey).\(ext)")
        let now = Date()
        let metadata = RecordingMetadata(
            id: id,
            storageKey: storageKey,
            displayName: displayName,
            source: source,
            audioFileName: destination.lastPathComponent,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: max(0, durationSecondsOverride ?? endedAt.timeIntervalSince(startedAt)),
            createdAt: now,
            updatedAt: now,
            recoveredAt: recoveredAt,
            recoveryNote: recoveryNote?.trimmingCharacters(in: .whitespacesAndNewlines),
            segmentCount: segmentCount,
            confidenceReport: confidenceReport,
            titleSource: .default
        )
        let item = RecordingItem(metadata: metadata, folderURL: folderURL)
        let journal = PublicationJournal(metadata: metadata, sourcePath: temporaryAudioURL.path)
        let journalURL = try publicationJournalURL(id)
        try write(journal, to: journalURL)
        var moved = false
        do {
            if temporaryAudioURL.standardizedFileURL != destination.standardizedFileURL {
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw StorageIntegrityError.destinationExists(destination.lastPathComponent)
                }
                try fileManager.moveItem(at: temporaryAudioURL, to: destination)
                moved = true
            }
            try write(metadata: metadata, to: item.metadataURL)
            try? fileManager.removeItem(at: journalURL)
            return item
        } catch {
            if moved,
               !fileManager.fileExists(atPath: temporaryAudioURL.path),
               fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: destination, to: temporaryAudioURL)
            }
            if !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: journalURL)
            }
            throw error
        }
    }

    /// Copies an external audio file into the library. The title (the source
    /// file name) is recorded as `RecordingTitleSource.user`, because the file
    /// name is the user's choice; auto-title never replaces it.
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
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw RecordingLibraryError.audioMissing(sourceURL.lastPathComponent)
        }
        let ext = sourceURL.pathExtension.lowercased()
        guard ["wav", "mp3", "m4a"].contains(ext) else {
            throw RecordingLibraryError.unsupportedAudioType(ext)
        }
        let displayName = try uniqueDisplayName(FileNameSanitizer.sanitizedBaseName(requestedName))
        let id = UUID()
        let storageKey = Self.storageKey(for: id)
        let destination = try StoragePath.containedURL(in: folderURL, fileName: "\(storageKey).\(ext)")
        let metadata = RecordingMetadata(
            id: id,
            storageKey: storageKey,
            displayName: displayName,
            source: source,
            audioFileName: destination.lastPathComponent,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(max(0, durationSeconds)),
            durationSeconds: max(0, durationSeconds),
            createdAt: importedAt,
            updatedAt: importedAt,
            importedAt: importedAt,
            confidenceReport: confidenceReport,
            titleSource: .user
        )
        let item = RecordingItem(metadata: metadata, folderURL: folderURL)
        let journalURL = try publicationJournalURL(id)
        try write(PublicationJournal(metadata: metadata, sourcePath: nil), to: journalURL)
        do {
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw StorageIntegrityError.destinationExists(destination.lastPathComponent)
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
            try write(metadata: metadata, to: item.metadataURL)
            try? fileManager.removeItem(at: journalURL)
            return item
        } catch {
            try? fileManager.removeItem(at: destination)
            try? fileManager.removeItem(at: journalURL)
            throw error
        }
    }

    /// Renames on behalf of the user; equivalent to `rename(_:to:source: .user)`.
    @discardableResult
    public func rename(_ recording: RecordingItem, to requestedName: String) throws -> RecordingItem {
        try rename(recording, to: requestedName, source: .user)
    }

    /// Renames `recording` and records who chose the title.
    ///
    /// Only `recording.id` (and its folder) is taken from the caller: the
    /// metadata is re-read from disk and the rename is applied on top of it, so
    /// a stale in-memory snapshot can never overwrite newer on-disk edits. The
    /// recording is moved to immutable storage first if needed. Renaming to the
    /// current on-disk name (after sanitizing) is a no-op that returns the
    /// stored recording: no " 2" suffix, no write, and `titleSource` is kept.
    /// Otherwise the name is made unique among the other recordings (matched by
    /// ID, case-insensitively) and `titleSource` is set to `source`.
    ///
    /// - Throws: `RecordingLibraryError.recordingNotFound` when the recording is
    ///   no longer in the library.
    @discardableResult
    public func rename(
        _ recording: RecordingItem,
        to requestedName: String,
        source: RecordingTitleSource
    ) throws -> RecordingItem {
        let (current, recordings) = try onDiskRecording(for: recording)
        return try applyRename(try ensureImmutableStorage(current), to: requestedName, source: source, among: recordings)
    }

    /// Auto-title entry point: renames with `source: .generated` only when the
    /// title on disk is still a default one (`effectiveTitleSource == .default`).
    ///
    /// `newName` is first normalized with `MeetingTitleGenerator.cleaned(_:fallback:)`
    /// (quotes, `Title:` prefixes, trailing periods, 8-word / 80-character cap).
    /// Returns `nil`, without touching disk, when the user (or an earlier
    /// auto-title) already chose a title, for example a manual rename made while
    /// the transcription was running, or when the cleaned name is empty or
    /// itself a default-looking name.
    ///
    /// - Throws: `RecordingLibraryError.recordingNotFound` when the recording is
    ///   no longer in the library.
    @discardableResult
    public func renameIfTitleIsDefault(_ recording: RecordingItem, to newName: String) throws -> RecordingItem? {
        let sanitized = MeetingTitleGenerator.cleaned(newName, fallback: "")
        guard !sanitized.isEmpty, !MeetingTitleGenerator.isDefaultName(sanitized) else { return nil }
        let (current, recordings) = try onDiskRecording(for: recording)
        guard current.effectiveTitleSource == .default else { return nil }
        return try applyRename(try ensureImmutableStorage(current), to: sanitized, source: .generated, among: recordings)
    }

    /// Moves a legacy (name-keyed) recording to immutable storage if needed and
    /// returns the recording as stored. Use this instead of renaming a recording
    /// to its own name just to obtain stable file URLs.
    @discardableResult
    public func migrateIfNeeded(_ recording: RecordingItem) throws -> RecordingItem {
        try ensureImmutableStorage(recording)
    }

    @discardableResult
    public func writeTranscript(_ transcript: String, for recording: RecordingItem) throws -> RecordingItem {
        let item = try ensureImmutableStorage(recording)
        try DurableFile.write(Data(transcript.utf8), to: item.transcriptURL, fileManager: fileManager)
        return item
    }

    @discardableResult
    public func writeTranscriptSegments(_ segments: [TranscriptSegment], for recording: RecordingItem) throws -> RecordingItem {
        let item = try ensureImmutableStorage(recording)
        try DurableFile.write(segments, to: item.transcriptSegmentsURL, encoder: Self.makeEncoder(), fileManager: fileManager)
        return item
    }

    @discardableResult
    public func writeTranscriptBundle(_ transcript: String, segments: [TranscriptSegment], for recording: RecordingItem) throws -> RecordingItem {
        let item = try ensureImmutableStorage(recording)
        try DurableFile.write(Data(transcript.utf8), to: item.transcriptURL, fileManager: fileManager)
        do {
            try DurableFile.write(segments, to: item.transcriptSegmentsURL, encoder: Self.makeEncoder(), fileManager: fileManager)
        } catch {
            restoreBackup(of: item.transcriptURL)
            throw error
        }
        return item
    }

    public func loadTranscriptSegments(for recording: RecordingItem) -> [TranscriptSegment] {
        DurableFile.readRecoveringBackup(
            [TranscriptSegment].self,
            from: recording.transcriptSegmentsURL,
            decoder: Self.makeDecoder(),
            fileManager: fileManager
        ) ?? []
    }

    @discardableResult
    public func writeSummary(_ summary: String, for recording: RecordingItem) throws -> RecordingItem {
        let item = try ensureImmutableStorage(recording)
        try DurableFile.write(Data(summary.utf8), to: item.summaryURL, fileManager: fileManager)
        return item
    }

    @discardableResult
    public func clearSummary(for recording: RecordingItem) throws -> RecordingItem {
        let item = try ensureImmutableStorage(recording)
        for url in [item.summaryURL, DurableFile.backupURL(for: item.summaryURL)] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        return item
    }

    /// Renames a diarized speaker everywhere it appears for `recording`.
    ///
    /// `label` may be the provider's original label (`"Speaker 1"`) or the
    /// speaker's current display name (`"Sarah"`); either resolves to the
    /// original label, which is the key stored in `RecordingMetadata.speakerNames`,
    /// so a re-rename updates the mapping instead of chaining it. `name` is
    /// cleaned with `SpeakerNames.sanitized(_:)`; an empty result (or the
    /// original label itself) reverts the speaker to its original label.
    ///
    /// Metadata is re-read from disk (like `rename`). The transcript text
    /// (`Label:` block headers) and the segments file (`TranscriptSegment.speaker`)
    /// are rewritten first and the metadata last, so Read mode, Edit mode,
    /// search and exports agree, and a failed write never leaves metadata
    /// claiming a rename the transcript does not show. Headers still showing
    /// either the original label or the previous display name are rewritten,
    /// so an interrupted rename is completed by the next one, including a
    /// retry with the name the metadata already holds. Renaming to the current
    /// name is otherwise a no-op.
    ///
    /// - Throws: `RecordingLibraryError.speakerNotFound` when `label` is neither
    ///   a stored speaker nor a label in the transcript/segments;
    ///   `.speakerNameInUse` when another speaker already uses the name (or has
    ///   it as its original label), compared case-insensitively;
    ///   `.recordingNotFound` when the recording was deleted.
    @discardableResult
    public func renameSpeaker(_ recording: RecordingItem, label: String, to name: String) throws -> RecordingItem {
        let (onDisk, _) = try onDiskRecording(for: recording)
        let current = try ensureImmutableStorage(onDisk)
        var names = current.speakerNames
        let transcriptExists = fileManager.fileExists(atPath: current.transcriptURL.path)
        let transcript = transcriptExists ? ((try? String(contentsOf: current.transcriptURL, encoding: .utf8)) ?? "") : ""
        let segmentsExist = fileManager.fileExists(atPath: current.transcriptSegmentsURL.path)
        let segments = loadTranscriptSegments(for: current)

        let requested = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let original: String
        if names[requested] != nil {
            original = requested
        } else if let key = names.filter({ $0.value == requested }).keys.sorted().first {
            original = key
        } else {
            original = requested
        }
        let currentDisplay = names[original] ?? original
        let present = Set(SpeakerNames.labels(in: transcript)).union(segments.map(\.speaker).filter { !$0.isEmpty })
        guard !original.isEmpty, names[original] != nil || present.contains(original) else {
            throw RecordingLibraryError.speakerNotFound(requested)
        }

        let cleaned = SpeakerNames.sanitized(name)
        let newDisplay = cleaned.isEmpty ? original : cleaned
        // Same name again: still finish an interrupted rename whose headers or
        // segments kept the original label.
        let completesInterruptedRename = newDisplay == currentDisplay
            && original != newDisplay
            && present.contains(original)
        guard newDisplay != currentDisplay || completesInterruptedRename else { return current }

        var reserved = Set<String>()
        for (key, value) in names where key != original {
            reserved.insert(key.lowercased())
            reserved.insert(value.lowercased())
        }
        for other in present where other != currentDisplay && other != original {
            reserved.insert(other.lowercased())
        }
        guard !reserved.contains(newDisplay.lowercased()) else {
            throw RecordingLibraryError.speakerNameInUse(newDisplay)
        }

        if newDisplay == original {
            names.removeValue(forKey: original)
        } else {
            names[original] = newDisplay
        }
        var metadata = current.metadata
        metadata.speakerNames = names.isEmpty ? nil : names
        metadata.updatedAt = Date()
        let updated = RecordingItem(metadata: metadata, folderURL: folderURL)

        let replaced: Set<String> = [currentDisplay, original]
        let newTranscript = SpeakerNames.renaming(replaced, to: newDisplay, in: transcript)
        let newSegments = segments.map { segment -> TranscriptSegment in
            guard replaced.contains(segment.speaker) else { return segment }
            var renamed = segment
            renamed.speaker = newDisplay
            return renamed
        }
        let transcriptChanged = transcriptExists && newTranscript != transcript
        let segmentsChanged = segmentsExist && newSegments != segments
        if transcriptChanged, segmentsChanged {
            try writeTranscriptBundle(newTranscript, segments: newSegments, for: updated)
        } else if transcriptChanged {
            try writeTranscript(newTranscript, for: updated)
        } else if segmentsChanged {
            try writeTranscriptSegments(newSegments, for: updated)
        }
        try write(metadata: metadata, to: updated.metadataURL)
        return updated
    }

    @discardableResult
    public func resetSpeakerNames(for recording: RecordingItem) throws -> RecordingItem {
        let (onDisk, _) = try onDiskRecording(for: recording)
        let current = try ensureImmutableStorage(onDisk)
        guard current.metadata.speakerNames != nil else { return current }
        var metadata = current.metadata
        metadata.speakerNames = nil
        metadata.updatedAt = Date()
        let updated = RecordingItem(metadata: metadata, folderURL: folderURL)
        try write(metadata: metadata, to: updated.metadataURL)
        return updated
    }

    public func delete(_ recording: RecordingItem) throws {
        let item = try ensureImmutableStorage(recording)
        let files = ownedURLs(for: item).flatMap { [$0.lastPathComponent, DurableFile.backupURL(for: $0).lastPathComponent] }
        let operation = DeleteJournal(recordingID: item.id, fileNames: files)
        let journalURL = try deleteJournalURL(item.id)
        try write(operation, to: journalURL)
        try completeDelete(operation, journalURL: journalURL)
    }

    /// The current on-disk state of `recording` plus the whole library listing
    /// (reused for name de-duplication).
    private func onDiskRecording(for recording: RecordingItem) throws -> (RecordingItem, [RecordingItem]) {
        guard recording.folderURL.standardizedFileURL == folderURL else {
            throw StorageIntegrityError.pathEscapesLibrary(recording.audioURL.path)
        }
        let recordings = try loadRecordings()
        guard let current = recordings.first(where: { $0.id == recording.id }) else {
            throw RecordingLibraryError.recordingNotFound(recording.id)
        }
        return (current, recordings)
    }

    private func applyRename(
        _ current: RecordingItem,
        to requestedName: String,
        source: RecordingTitleSource,
        among recordings: [RecordingItem]
    ) throws -> RecordingItem {
        let requested = FileNameSanitizer.sanitizedBaseName(requestedName)
        // Same name: nothing to rename, and confirming a title does not change
        // who chose it (a default title stays replaceable by auto-title).
        guard requested != current.displayName else { return current }
        var metadata = current.metadata
        metadata.displayName = uniqueDisplayName(requested, excluding: current.id, among: recordings)
        metadata.titleSource = source
        metadata.updatedAt = Date()
        let renamed = RecordingItem(metadata: metadata, folderURL: folderURL)
        try write(metadata: metadata, to: renamed.metadataURL)
        return renamed
    }

    public static func storageKey(for id: UUID) -> String {
        "recording-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func readRecording(_ metadataURL: URL) -> RecordingItem? {
        let decoder = Self.makeDecoder()
        let isSupported: (RecordingMetadata) -> Bool = { metadata in
            metadata.schema == RecordingMetadata.currentSchema &&
            metadata.schemaVersion >= RecordingMetadata.minimumSupportedSchemaVersion &&
            metadata.schemaVersion <= RecordingMetadata.currentSchemaVersion &&
            !metadata.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let primary = (try? Data(contentsOf: metadataURL))
            .flatMap { try? decoder.decode(RecordingMetadata.self, from: $0) }
        if let primary,
           primary.schema == RecordingMetadata.currentSchema,
           primary.schemaVersion > RecordingMetadata.currentSchemaVersion {
            // Future schemas belong to a newer MSR. Preserve them byte-for-byte and
            // do not fall back to an older backup that could silently downgrade data.
            return nil
        }
        guard let metadata = primary.flatMap({ isSupported($0) ? $0 : nil }) ?? DurableFile.readRecoveringBackup(
            RecordingMetadata.self,
            from: metadataURL,
            decoder: decoder,
            validate: isSupported,
            fileManager: fileManager
        ) else { return nil }
        let item = RecordingItem(metadata: metadata, folderURL: folderURL)
        guard item.metadataURL.standardizedFileURL == metadataURL.standardizedFileURL,
              StoragePath.isContained(item.audioURL, in: folderURL),
              fileManager.fileExists(atPath: item.audioURL.path) else { return nil }
        return item
    }

    private func ensureImmutableStorage(_ snapshot: RecordingItem) throws -> RecordingItem {
        guard snapshot.folderURL.standardizedFileURL == folderURL else {
            throw StorageIntegrityError.pathEscapesLibrary(snapshot.audioURL.path)
        }
        if snapshot.usesImmutableStorage { return snapshot }

        let storageKey = Self.storageKey(for: snapshot.id)
        // A stale legacy snapshot of a recording that was already migrated:
        // return the migrated on-disk state. Re-running the migration would
        // overwrite newer metadata with the snapshot.
        if let migratedURL = try? StoragePath.containedURL(in: folderURL, fileName: "\(storageKey).json"),
           let onDisk = readRecording(migratedURL),
           onDisk.id == snapshot.id {
            return onDisk
        }
        // Migrate from the legacy metadata as it is on disk now, not from the snapshot.
        let recording = readRecording(snapshot.metadataURL)
            .flatMap { $0.id == snapshot.id && !$0.usesImmutableStorage ? $0 : nil } ?? snapshot

        var metadata = recording.metadata
        metadata.storageKey = storageKey
        metadata.schema = RecordingMetadata.currentSchema
        metadata.schemaVersion = RecordingMetadata.currentSchemaVersion
        metadata.audioFileName = "\(storageKey).\(recording.audioURL.pathExtension.lowercased())"
        metadata.updatedAt = Date()
        let migrated = RecordingItem(metadata: metadata, folderURL: folderURL)
        let moves = zip(ownedURLs(for: recording), ownedURLs(for: migrated)).compactMap { source, destination -> MigrationMove? in
            guard source.standardizedFileURL != destination.standardizedFileURL else { return nil }
            return MigrationMove(sourceFileName: source.lastPathComponent, destinationFileName: destination.lastPathComponent)
        }
        let operation = MigrationJournal(
            recordingID: recording.id,
            legacyMetadataFileName: recording.metadataURL.lastPathComponent,
            metadata: metadata,
            moves: moves
        )
        let journalURL = try migrationJournalURL(recording.id)
        try write(operation, to: journalURL)
        try completeMigration(operation, journalURL: journalURL)
        return migrated
    }

    private func resumePendingOperations() throws {
        let urls = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        for url in urls where url.lastPathComponent.hasPrefix(".delete-") && url.pathExtension == "json" {
            if let operation = DurableFile.readRecoveringBackup(DeleteJournal.self, from: url, decoder: Self.makeDecoder(), fileManager: fileManager) {
                try completeDelete(operation, journalURL: url)
            }
        }
        for url in urls where url.lastPathComponent.hasPrefix(".migrate-") && url.pathExtension == "json" {
            if let operation = DurableFile.readRecoveringBackup(MigrationJournal.self, from: url, decoder: Self.makeDecoder(), fileManager: fileManager) {
                try completeMigration(operation, journalURL: url)
            }
        }
        for url in urls where url.lastPathComponent.hasPrefix(".publish-") && url.pathExtension == "json" {
            guard let operation = DurableFile.readRecoveringBackup(PublicationJournal.self, from: url, decoder: Self.makeDecoder(), fileManager: fileManager) else { continue }
            let item = RecordingItem(metadata: operation.metadata, folderURL: folderURL)
            guard StoragePath.isContained(item.audioURL, in: folderURL) else { continue }
            if !fileManager.fileExists(atPath: item.audioURL.path),
               let sourcePath = operation.sourcePath,
               fileManager.fileExists(atPath: sourcePath) {
                try fileManager.moveItem(at: URL(fileURLWithPath: sourcePath), to: item.audioURL)
            }
            if fileManager.fileExists(atPath: item.audioURL.path) {
                try write(metadata: operation.metadata, to: item.metadataURL)
                try? fileManager.removeItem(at: url)
            } else if operation.sourcePath == nil {
                // An interrupted import copies rather than moves its source. If no
                // destination exists there is nothing safe to resume; keep the
                // external source untouched and discard only the empty journal.
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func completeMigration(_ operation: MigrationJournal, journalURL: URL) throws {
        for move in operation.moves {
            let source = try StoragePath.containedURL(in: folderURL, fileName: move.sourceFileName)
            let destination = try StoragePath.containedURL(in: folderURL, fileName: move.destinationFileName)
            if fileManager.fileExists(atPath: destination.path) { continue }
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(at: source, to: destination)
            }
        }
        let item = RecordingItem(metadata: operation.metadata, folderURL: folderURL)
        guard fileManager.fileExists(atPath: item.audioURL.path) else {
            throw RecordingLibraryError.audioMissing(item.audioURL.lastPathComponent)
        }
        try write(metadata: operation.metadata, to: item.metadataURL)
        let legacy = try StoragePath.containedURL(in: folderURL, fileName: operation.legacyMetadataFileName)
        if legacy != item.metadataURL, fileManager.fileExists(atPath: legacy.path) {
            try fileManager.removeItem(at: legacy)
        }
        try? fileManager.removeItem(at: journalURL)
    }

    private func completeDelete(_ operation: DeleteJournal, journalURL: URL) throws {
        for name in operation.fileNames {
            let url = try StoragePath.containedURL(in: folderURL, fileName: name)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        try? fileManager.removeItem(at: journalURL)
    }

    private func ownedURLs(for recording: RecordingItem) -> [URL] {
        [recording.audioURL, recording.metadataURL, recording.transcriptURL, recording.transcriptSegmentsURL, recording.summaryURL]
    }

    private func ensureRecordingIDAvailable(_ id: UUID, among recordings: [RecordingItem]) throws {
        if recordings.contains(where: { $0.id == id }) {
            throw RecordingLibraryError.duplicateRecordingID(id)
        }
    }

    private func uniqueDisplayName(_ requested: String) throws -> String {
        uniqueDisplayName(requested, excluding: nil, among: try loadRecordings())
    }

    /// `requested`, or `requested N` when another recording (by ID, not by
    /// name) already uses that name case-insensitively.
    private func uniqueDisplayName(_ requested: String, excluding id: UUID?, among recordings: [RecordingItem]) -> String {
        let used = Set(recordings.filter { $0.id != id }.map { $0.displayName.lowercased() })
        var candidate = requested
        var index = 2
        while used.contains(candidate.lowercased()) {
            candidate = "\(requested) \(index)"
            index += 1
        }
        return candidate
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try DurableFile.write(value, to: url, encoder: Self.makeEncoder(), fileManager: fileManager)
    }

    private func write(metadata: RecordingMetadata, to url: URL) throws {
        try write(metadata, to: url)
    }

    private func publicationJournalURL(_ id: UUID) throws -> URL {
        try StoragePath.containedURL(in: folderURL, fileName: ".publish-\(id.uuidString).json")
    }

    private func migrationJournalURL(_ id: UUID) throws -> URL {
        try StoragePath.containedURL(in: folderURL, fileName: ".migrate-\(id.uuidString).json")
    }

    private func deleteJournalURL(_ id: UUID) throws -> URL {
        try StoragePath.containedURL(in: folderURL, fileName: ".delete-\(id.uuidString).json")
    }

    private func restoreBackup(of url: URL) {
        let backup = DurableFile.backupURL(for: url)
        guard let data = try? Data(contentsOf: backup) else { return }
        try? DurableFile.write(data, to: url, fileManager: fileManager)
    }

    private func ensureFolderExists() throws {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
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

private struct PublicationJournal: Codable {
    var metadata: RecordingMetadata
    var sourcePath: String?
}

private struct MigrationMove: Codable {
    var sourceFileName: String
    var destinationFileName: String
}

private struct MigrationJournal: Codable {
    var recordingID: UUID
    var legacyMetadataFileName: String
    var metadata: RecordingMetadata
    var moves: [MigrationMove]
}

private struct DeleteJournal: Codable {
    var recordingID: UUID
    var fileNames: [String]
}
