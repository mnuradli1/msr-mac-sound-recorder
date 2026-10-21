import AVFoundation
import Foundation
import MSRCore

public enum RecordingRecoveryStatus: Equatable, Sendable {
    case recoveredMixed
    case recoveredSingleSource(AudioSignalChannel)
    case recoveredSession(segmentCount: Int)
    case failed(String)
}

public struct RecordingRecoveryResult: Equatable, Sendable {
    public let status: RecordingRecoveryStatus
    public let recording: RecordingItem?
    public let message: String
    public let recoveredFiles: [String]
    public let failedFiles: [String]
    public let warnings: [String]

    public init(
        status: RecordingRecoveryStatus,
        recording: RecordingItem?,
        message: String,
        recoveredFiles: [String],
        failedFiles: [String],
        warnings: [String] = []
    ) {
        self.status = status
        self.recording = recording
        self.message = message
        self.recoveredFiles = recoveredFiles
        self.failedFiles = failedFiles
        self.warnings = warnings
    }
}

/// A session whose only source audio is damaged (for example a legacy AAC file without its movie
/// index). Its manifest and inputs are left exactly where they are for a later retry or manual repair.
private struct RetainedSessionInputsError: LocalizedError {
    let errorDescription: String?
}

public final class RecordingRecoveryService: @unchecked Sendable {
    private let folderURL: URL
    private let fileManager: FileManager

    public init(folderURL: URL, fileManager: FileManager = .default) {
        self.folderURL = folderURL
        self.fileManager = fileManager
    }

    public func recoverInterruptedRecordings(now: Date = Date()) async throws -> [RecordingRecoveryResult] {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        var results: [RecordingRecoveryResult] = []
        let manifestStore = RecordingSessionManifestStore(folderURL: folderURL, fileManager: fileManager)
        let sessionManifests = try manifestStore.loadAll()
        results.append(contentsOf: quarantineUnreadableManifests(loaded: sessionManifests, store: manifestStore))
        // Each manifest and leftover file is isolated: one bad session never blocks the rest.
        for manifest in sessionManifests {
            do {
                results.append(try await recoverSession(manifest, now: now))
            } catch let error as CancellationError {
                throw error
            } catch let error as RetainedSessionInputsError {
                results.append(retainedSessionResult(manifest, error: error))
            } catch {
                results.append(failedSessionResult(manifest, error: error))
            }
        }
        // Inputs of a session whose manifest is still in place belong to that session's retry,
        // never to the orphan scanner (which would publish or quarantine them separately).
        let retainedFiles = Set(sessionManifests
            .filter { fileManager.fileExists(atPath: manifestStore.url(for: $0.id).path) }
            .flatMap(referencedFileNames(of:)))
        let candidates = try interruptedCandidates(excluding: retainedFiles)
        for candidate in candidates {
            do {
                results.append(try await recover(candidate, now: now))
            } catch let error as CancellationError {
                throw error
            } catch {
                results.append(failedCandidateResult(candidate, error: error))
            }
        }
        return results
    }

    private func interruptedCandidates(excluding fileNames: Set<String>) throws -> [RecoveryCandidate] {
        let urls = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: []
        )
        var grouped: [String: PairedCandidate] = [:]
        var singles: [RecoveryCandidate] = []

        for url in urls where url.pathExtension == "m4a" {
            let name = url.lastPathComponent
            if fileNames.contains(name) { continue }
            if let parsed = parsePairedSide(name: name) {
                var candidate = grouped[parsed.sessionID, default: PairedCandidate(sessionID: parsed.sessionID)]
                switch parsed.channel {
                case .microphone:
                    candidate.microphoneURL = url
                case .system:
                    candidate.systemURL = url
                }
                grouped[parsed.sessionID] = candidate
            } else if let single = parseSingle(name: name, url: url) {
                singles.append(.single(single))
            }
        }

        let paired = grouped.values.map { RecoveryCandidate.paired($0) }
        return (paired + singles).sorted { lhs, rhs in
            lhs.sortKey < rhs.sortKey
        }
    }

    private func recover(_ candidate: RecoveryCandidate, now: Date) async throws -> RecordingRecoveryResult {
        switch candidate {
        case let .single(candidate):
            return try await recoverSingle(candidate, now: now)
        case let .paired(candidate):
            return try await recoverPaired(candidate, now: now)
        }
    }

    private func recoverSession(_ manifest: RecordingSessionManifest, now: Date) async throws -> RecordingRecoveryResult {
        // Validate before any manifest-directed reads, moves, or cleanup.
        for name in referencedFileNames(of: manifest) {
            let input = try StoragePath.containedURL(in: folderURL, fileName: name)
            guard StoragePath.isContained(input, in: folderURL) else {
                throw StorageIntegrityError.pathEscapesLibrary(name)
            }
            for raw in DurableCaptureFiles.rawURLs(for: input, source: manifest.source) {
                guard StoragePath.isContained(raw, in: folderURL) else {
                    throw StorageIntegrityError.pathEscapesLibrary(raw.lastPathComponent)
                }
            }
        }
        let manifestStore = RecordingSessionManifestStore(folderURL: folderURL, fileManager: fileManager)
        let manifestURL = manifestStore.url(for: manifest.id)
        let library = RecordingLibrary(folderURL: folderURL, fileManager: fileManager)
        if let finalRecordingID = manifest.finalRecordingID,
           let published = try library.loadRecordings().first(where: { $0.id == finalRecordingID }) {
            // Publication finished before the interruption; whatever the manifest still lists is a
            // duplicate of the published audio and must not be re-imported by the leftover pass.
            // Confirm the published audio is intact before discarding any retained source.
            _ = try await audioInfo(for: published.audioURL)
            for segment in manifest.allSegments {
                _ = await DurableCaptureFiles.removeReadableRawFiles(
                    for: folderURL.appendingPathComponent(segment.fileName), source: manifest.source)
            }
            try archiveLegacyInputs(manifest, excluding: published.audioURL)
            try? fileManager.removeItem(at: temporarySessionURL(for: manifest))
            try manifestStore.delete(manifest)
            return RecordingRecoveryResult(
                status: .recoveredSession(segmentCount: manifest.allSegments.count),
                recording: published,
                message: "Finished recovery for \(published.displayName).",
                recoveredFiles: [published.audioURL.lastPathComponent],
                failedFiles: []
            )
        }
        let segments = manifest.allSegments
        guard !segments.isEmpty else {
            moveManifestSessionToFailed(manifest)
            return RecordingRecoveryResult(
                status: .failed("Session manifest had no recorded segments."),
                recording: nil,
                message: "Could not recover \(manifest.requestedName).",
                recoveredFiles: [],
                failedFiles: [manifestURL.lastPathComponent]
            )
        }

        let segmentURLs = segments.map { folderURL.appendingPathComponent($0.fileName) }
        // Retained PCM is authoritative: an M4A export can itself be interrupted (missing or shorter),
        // so rebuild every segment that still has readable raw tracks.
        var degradedCapture = false
        for segmentURL in segmentURLs {
            let degraded = try await DurableCaptureFiles.restoreSegmentIfNeeded(output: segmentURL, source: manifest.source)
            degradedCapture = degradedCapture || degraded
        }
        try await rebuildActiveSegmentIfNeeded(manifest, segments: segments, segmentURLs: segmentURLs)
        let missingFiles = zip(segments, segmentURLs)
            .filter { _, url in !fileManager.fileExists(atPath: url.path) }
            .map { segment, _ in segment.fileName }
        guard missingFiles.isEmpty else {
            // A missing segment means the timeline is incomplete; never publish a silently shorter recording.
            moveManifestSessionToFailed(manifest)
            return RecordingRecoveryResult(
                status: .failed("Session manifest referenced missing segment files."),
                recording: nil,
                message: "Could not recover \(manifest.requestedName).",
                recoveredFiles: [],
                failedFiles: [manifestURL.lastPathComponent] + segments.map(\.fileName)
            )
        }

        // Unreadable (corrupt) segments are set aside; the readable ones are still recovered in order.
        var readable: [(url: URL, info: AudioFileInfo)] = []
        var unreadable: [URL] = []
        for url in segmentURLs {
            if let info = try await readableAudioInfo(for: url) {
                readable.append((url, info))
            } else {
                unreadable.append(url)
            }
        }
        guard !readable.isEmpty else {
            moveManifestSessionToFailed(manifest)
            return RecordingRecoveryResult(
                status: .failed("Session manifest contained unreadable segment files."),
                recording: nil,
                message: "Could not recover \(manifest.requestedName).",
                recoveredFiles: [],
                failedFiles: [manifestURL.lastPathComponent] + segments.map(\.fileName)
            )
        }

        let readableURLs = readable.map(\.url)
        let finalTemporaryURL: URL
        if readableURLs.count == 1, let onlySegment = readableURLs.first {
            finalTemporaryURL = onlySegment
        } else {
            finalTemporaryURL = temporarySessionURL(for: manifest)
            try await AudioTrackMixer.concatenateToSingleM4A(inputs: readableURLs, outputURL: finalTemporaryURL)
        }

        let audioDuration = readable.reduce(0) { $0 + $1.info.duration }
        // The manifest's active duration includes unreadable segments, so only trust it for a complete session.
        let duration = unreadable.isEmpty ? max(manifest.accumulatedActiveDuration, audioDuration) : audioDuration
        let endedAt = manifest.startedAt.addingTimeInterval(duration)
        var recoveryNote: String
        if unreadable.isEmpty {
            recoveryNote = "Recovered \(readable.count) segment\(readable.count == 1 ? "" : "s") from an interrupted recording session."
        } else {
            let verb = unreadable.count == 1 ? "segment was" : "segments were"
            recoveryNote = "Recovered \(readable.count) of \(segmentURLs.count) segments; \(unreadable.count) unreadable \(verb) moved to recovery-failed."
        }
        if degradedCapture {
            recoveryNote += " One or more source tracks were missing or unreadable; only readable audio was recovered."
        }
        let recording = try library.finishRecording(
            temporaryAudioURL: finalTemporaryURL,
            requestedName: manifest.requestedName,
            source: manifest.source,
            startedAt: manifest.startedAt,
            endedAt: endedAt,
            durationSecondsOverride: duration,
            recoveredAt: now,
            recoveryNote: recoveryNote,
            segmentCount: readable.count,
            recordingID: manifest.finalRecordingID ?? manifest.id
        )

        if readableURLs.count > 1 {
            for url in readableURLs {
                try? fileManager.removeItem(at: url)
            }
        }
        for url in unreadable {
            try? moveToFailedFolder(url)
        }
        // Readable PCM is now represented by the publication; damaged PCM is kept for manual recovery.
        var retainedDamagedFiles: [String] = []
        for segmentURL in segmentURLs {
            retainedDamagedFiles += await DurableCaptureFiles.removeReadableRawFiles(for: segmentURL, source: manifest.source)
        }
        // The recording is already published; a failed archive move must not turn this into a failure.
        try? archiveLegacyInputs(manifest, excluding: recording.audioURL)
        try manifestStore.delete(manifest)
        return RecordingRecoveryResult(
            status: .recoveredSession(segmentCount: readable.count),
            recording: recording,
            message: unreadable.isEmpty && !degradedCapture
                ? "Recovered \(recording.displayName)."
                : "Partially recovered \(recording.displayName).",
            recoveredFiles: [recording.audioURL.lastPathComponent],
            failedFiles: unreadable.map(\.lastPathComponent) + retainedDamagedFiles,
            warnings: degradedCapture ? ["One or more source tracks were missing or unreadable; recovery is partial."] : []
        )
    }

    /// Recreates a missing or unreadable active segment from the session's separate mic/system tracks.
    private func rebuildActiveSegmentIfNeeded(
        _ manifest: RecordingSessionManifest,
        segments: [RecordingSessionSegment],
        segmentURLs: [URL]
    ) async throws {
        guard let active = manifest.activeSegment,
              let activeIndex = segments.lastIndex(where: { $0.fileName == active.fileName }) else { return }
        let activeURL = segmentURLs[activeIndex]
        let sideURLs = sideFileURLs(of: manifest).filter { fileManager.fileExists(atPath: $0.path) }
        guard !sideURLs.isEmpty else { return }
        let activeExists = fileManager.fileExists(atPath: activeURL.path)
        if activeExists, try await readableAudioInfo(for: activeURL) != nil { return }
        var readableSides: [URL] = []
        for url in sideURLs {
            if try await readableAudioInfo(for: url) != nil {
                readableSides.append(url)
            }
        }
        guard !readableSides.isEmpty else {
            // The active segment is gone and its only source audio is damaged (for example a legacy
            // AAC export missing its movie index). Retain manifest and sources untouched for repair.
            if !activeExists {
                throw RetainedSessionInputsError(
                    errorDescription: "Source audio for the interrupted segment is unreadable; original files were preserved."
                )
            }
            // Otherwise the unreadable active segment is handled like any other unreadable segment.
            return
        }
        if activeExists {
            try? moveToFailedFolder(activeURL)
        }
        do {
            // Source tracks are retained until publication succeeds (then removed or archived).
            if readableSides.count >= 2 || readableSides.first?.pathExtension == "caf" {
                try await AudioTrackMixer.mixToSingleM4A(inputs: readableSides, outputURL: activeURL)
            } else if let only = readableSides.first {
                try fileManager.copyItem(at: only, to: activeURL)
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            // Leave the raw tracks in place; the leftover pass can still import them.
            try? fileManager.removeItem(at: activeURL)
        }
    }

    /// Separate mic/system capture files listed by the manifest, excluding files that are themselves segments.
    private func sideFileURLs(of manifest: RecordingSessionManifest) -> [URL] {
        let segmentNames = Set(manifest.allSegments.map(\.fileName))
        return [manifest.systemFileName, manifest.microphoneFileName]
            .compactMap { $0 }
            .filter { !segmentNames.contains($0) }
            .map { folderURL.appendingPathComponent($0) }
    }

    /// Segment and side-track file names a manifest refers to.
    private func referencedFileNames(of manifest: RecordingSessionManifest) -> [String] {
        manifest.allSegments.map(\.fileName) + [manifest.microphoneFileName, manifest.systemFileName].compactMap { $0 }
    }

    /// Checkpoint leftovers are retained outside the orphan scanner, so a second
    /// launch cannot publish the same already-saved legacy capture a second time.
    private func archiveLegacyInputs(_ manifest: RecordingSessionManifest, excluding published: URL) throws {
        let archive = folderURL.appendingPathComponent("recovery-archive", isDirectory: true)
            .appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        let publishedBase = published.deletingPathExtension().lastPathComponent
        for name in Set(referencedFileNames(of: manifest)) {
            let input = try StoragePath.containedURL(in: folderURL, fileName: name)
            guard StoragePath.isContained(input, in: folderURL) else {
                throw StorageIntegrityError.pathEscapesLibrary(name)
            }
            // CAF cleanup handles readable tracks; damaged CAF stays available.
            guard input.pathExtension != "caf", input != published,
                  !input.lastPathComponent.hasPrefix(publishedBase + "."),
                  fileManager.fileExists(atPath: input.path) else { continue }
            try fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
            var destination = archive.appendingPathComponent(input.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                destination = archive.appendingPathComponent(UUID().uuidString + "-" + input.lastPathComponent)
            }
            try fileManager.moveItem(at: input, to: destination)
        }
    }

    private func temporarySessionURL(for manifest: RecordingSessionManifest) -> URL {
        folderURL.appendingPathComponent(".recovered-session-\(manifest.id.uuidString).m4a")
    }

    private func failedSessionResult(_ manifest: RecordingSessionManifest, error: Error) -> RecordingRecoveryResult {
        let manifestURL = RecordingSessionManifestStore(folderURL: folderURL, fileManager: fileManager).url(for: manifest.id)
        try? fileManager.removeItem(at: temporarySessionURL(for: manifest))
        moveManifestSessionToFailed(manifest)
        return RecordingRecoveryResult(
            status: .failed("Session recovery failed: \(error.localizedDescription)"),
            recording: nil,
            message: "Could not recover \(manifest.requestedName).",
            recoveredFiles: [],
            failedFiles: [manifestURL.lastPathComponent] + manifest.allSegments.map(\.fileName)
        )
    }

    private func retainedSessionResult(_ manifest: RecordingSessionManifest, error: Error) -> RecordingRecoveryResult {
        let manifestURL = RecordingSessionManifestStore(folderURL: folderURL, fileManager: fileManager).url(for: manifest.id)
        try? fileManager.removeItem(at: temporarySessionURL(for: manifest))
        return RecordingRecoveryResult(
            status: .failed(error.localizedDescription),
            recording: nil,
            message: "Could not recover \(manifest.requestedName): \(error.localizedDescription)",
            recoveredFiles: [],
            failedFiles: [manifestURL.lastPathComponent]
        )
    }

    private func failedCandidateResult(_ candidate: RecoveryCandidate, error: Error) -> RecordingRecoveryResult {
        let urls: [URL]
        switch candidate {
        case let .single(single):
            urls = [single.url]
        case let .paired(paired):
            urls = [paired.microphoneURL, paired.systemURL].compactMap { $0 }
        }
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try? moveToFailedFolder(url)
        }
        return RecordingRecoveryResult(
            status: .failed("Recovery failed: \(error.localizedDescription)"),
            recording: nil,
            message: "Could not recover interrupted recording.",
            recoveredFiles: [],
            failedFiles: urls.map(\.lastPathComponent)
        )
    }

    /// Manifests that neither the primary file nor its backup can decode are moved to `recovery-failed/`
    /// (their segment files stay for the leftover pass). Manifests written by a newer app version are left alone.
    private func quarantineUnreadableManifests(
        loaded: [RecordingSessionManifest],
        store: RecordingSessionManifestStore
    ) -> [RecordingRecoveryResult] {
        let loadedIDs = Set(loaded.map(\.id))
        let urls = (try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: [])) ?? []
        let prefix = ".session-"
        let suffix = ".json"
        return urls
            .filter { RecordingSessionManifestStore.isManifestFileName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> RecordingRecoveryResult? in
                let name = url.lastPathComponent
                guard let id = UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))),
                      !loadedIDs.contains(id),
                      (try? store.load(id: id)) == nil,
                      fileManager.fileExists(atPath: url.path),
                      !isNewerSchemaManifest(at: url) else { return nil }
                try? moveToFailedFolder(url)
                let backup = DurableFile.backupURL(for: url)
                if fileManager.fileExists(atPath: backup.path) {
                    try? moveToFailedFolder(backup)
                }
                return RecordingRecoveryResult(
                    status: .failed("Session manifest was unreadable."),
                    recording: nil,
                    message: "An interrupted session record was unreadable and was moved to recovery-failed.",
                    recoveredFiles: [],
                    failedFiles: [name]
                )
            }
    }

    private func isNewerSchemaManifest(at url: URL) -> Bool {
        struct SchemaProbe: Decodable { let schemaVersion: Int? }
        guard let data = try? Data(contentsOf: url),
              let probe = try? JSONDecoder().decode(SchemaProbe.self, from: data) else { return false }
        return (probe.schemaVersion ?? 0) > 2
    }

    private func recoverSingle(_ candidate: SingleCandidate, now: Date) async throws -> RecordingRecoveryResult {
        let url = candidate.url
        guard let audioInfo = try? await audioInfo(for: url) else {
            try moveToFailedFolder(url)
            return RecordingRecoveryResult(
                status: .failed("Single in-progress recording was unreadable."),
                recording: nil,
                message: "Could not recover \(url.lastPathComponent).",
                recoveredFiles: [],
                failedFiles: [url.lastPathComponent]
            )
        }

        let recording = try RecordingLibrary(folderURL: folderURL, fileManager: fileManager).finishRecording(
            temporaryAudioURL: url,
            requestedName: recoveredName(startedAt: audioInfo.startedAt),
            source: candidate.source,
            startedAt: audioInfo.startedAt,
            endedAt: audioInfo.endedAt,
            durationSecondsOverride: audioInfo.duration,
            recoveredAt: now,
            recoveryNote: "Recovered \(candidate.source.displayName.lowercased()) audio from an interrupted recording.",
            segmentCount: 1
        )
        return RecordingRecoveryResult(
            status: .recoveredSingleSource(channel(for: candidate.source)),
            recording: recording,
            message: "Recovered \(recording.displayName).",
            recoveredFiles: [recording.audioURL.lastPathComponent],
            failedFiles: []
        )
    }

    private func recoverPaired(_ candidate: PairedCandidate, now: Date) async throws -> RecordingRecoveryResult {
        let microphoneInfo = await candidate.microphoneURL.asyncFlatMap { try? await audioInfo(for: $0) }
        let systemInfo = await candidate.systemURL.asyncFlatMap { try? await audioInfo(for: $0) }

        if let microphoneInfo, let systemInfo, let microphoneURL = candidate.microphoneURL, let systemURL = candidate.systemURL {
            let outputURL = folderURL.appendingPathComponent(".recovered-\(candidate.sessionID).m4a")
            try await AudioTrackMixer.mixToSingleM4A(inputs: [systemURL, microphoneURL], outputURL: outputURL)
            let startedAt = min(microphoneInfo.startedAt, systemInfo.startedAt)
            let duration = max(microphoneInfo.duration, systemInfo.duration)
            let recording = try RecordingLibrary(folderURL: folderURL, fileManager: fileManager).finishRecording(
                temporaryAudioURL: outputURL,
                requestedName: recoveredName(startedAt: startedAt),
                source: .micAndSystem,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(duration),
                durationSecondsOverride: duration,
                recoveredAt: now,
                recoveryNote: "Recovered mic and system audio from an interrupted recording.",
                segmentCount: 1
            )
            // Sources are removed only after the mixed recording is published.
            try? fileManager.removeItem(at: microphoneURL)
            try? fileManager.removeItem(at: systemURL)
            return RecordingRecoveryResult(
                status: .recoveredMixed,
                recording: recording,
                message: "Recovered \(recording.displayName).",
                recoveredFiles: [recording.audioURL.lastPathComponent],
                failedFiles: []
            )
        }

        if let microphoneInfo, let microphoneURL = candidate.microphoneURL {
            if let systemURL = candidate.systemURL {
                try moveToFailedFolder(systemURL)
            }
            let recording = try RecordingLibrary(folderURL: folderURL, fileManager: fileManager).finishRecording(
                temporaryAudioURL: microphoneURL,
                requestedName: recoveredName(startedAt: microphoneInfo.startedAt),
                source: .microphone,
                startedAt: microphoneInfo.startedAt,
                endedAt: microphoneInfo.endedAt,
                durationSecondsOverride: microphoneInfo.duration,
                recoveredAt: now,
                recoveryNote: "Recovered microphone audio only; system audio was missing or unreadable.",
                segmentCount: 1
            )
            return RecordingRecoveryResult(
                status: .recoveredSingleSource(.microphone),
                recording: recording,
                message: "Recovered microphone audio for \(recording.displayName).",
                recoveredFiles: [recording.audioURL.lastPathComponent],
                failedFiles: candidate.systemURL.map { [$0.lastPathComponent] } ?? []
            )
        }

        if let systemInfo, let systemURL = candidate.systemURL {
            if let microphoneURL = candidate.microphoneURL {
                try moveToFailedFolder(microphoneURL)
            }
            let recording = try RecordingLibrary(folderURL: folderURL, fileManager: fileManager).finishRecording(
                temporaryAudioURL: systemURL,
                requestedName: recoveredName(startedAt: systemInfo.startedAt),
                source: .system,
                startedAt: systemInfo.startedAt,
                endedAt: systemInfo.endedAt,
                durationSecondsOverride: systemInfo.duration,
                recoveredAt: now,
                recoveryNote: "Recovered system audio only; microphone audio was missing or unreadable.",
                segmentCount: 1
            )
            return RecordingRecoveryResult(
                status: .recoveredSingleSource(.system),
                recording: recording,
                message: "Recovered system audio for \(recording.displayName).",
                recoveredFiles: [recording.audioURL.lastPathComponent],
                failedFiles: candidate.microphoneURL.map { [$0.lastPathComponent] } ?? []
            )
        }

        for url in [candidate.microphoneURL, candidate.systemURL].compactMap({ $0 }) {
            try moveToFailedFolder(url)
        }
        return RecordingRecoveryResult(
            status: .failed("No readable audio was available."),
            recording: nil,
            message: "Could not recover interrupted recording.",
            recoveredFiles: [],
            failedFiles: [candidate.microphoneURL, candidate.systemURL].compactMap { $0?.lastPathComponent }
        )
    }

    private func parsePairedSide(name: String) -> (sessionID: String, channel: AudioSignalChannel)? {
        guard name.hasPrefix("..in-progress-") else { return nil }
        let stem = String(name.dropLast(4))
        if let range = stem.range(of: "-mic-") {
            return (String(stem[..<range.lowerBound]).replacingOccurrences(of: "..in-progress-", with: ""), .microphone)
        }
        if let range = stem.range(of: "-system-") {
            return (String(stem[..<range.lowerBound]).replacingOccurrences(of: "..in-progress-", with: ""), .system)
        }
        return nil
    }

    private func parseSingle(name: String, url: URL) -> SingleCandidate? {
        guard name.hasPrefix(".in-progress-") else { return nil }
        for source in AudioSource.allCases {
            let prefix = ".in-progress-\(source.rawValue)-"
            if name.hasPrefix(prefix) {
                return SingleCandidate(url: url, source: source)
            }
        }
        return SingleCandidate(url: url, source: .microphone)
    }

    private func channel(for source: AudioSource) -> AudioSignalChannel {
        switch source {
        case .microphone, .micAndSystem:
            return .microphone
        case .system:
            return .system
        }
    }

    /// Audio info for a readable file, or nil when the file is corrupt or empty. Cancellation still propagates.
    private func readableAudioInfo(for url: URL) async throws -> AudioFileInfo? {
        do {
            return try await audioInfo(for: url)
        } catch let error as CancellationError {
            throw error
        } catch {
            return nil
        }
    }

    private func audioInfo(for url: URL) async throws -> AudioFileInfo {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        guard !tracks.isEmpty, duration.isFinite, duration > 0 else {
            throw AudioTrackMixerError.noAudioTracks
        }
        let dates = fileDates(for: url)
        let startedAt = dates.createdAt ?? dates.modifiedAt ?? Date()
        return AudioFileInfo(
            duration: duration,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration)
        )
    }

    private func fileDates(for url: URL) -> (createdAt: Date?, modifiedAt: Date?) {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return (values?.creationDate, values?.contentModificationDate)
    }

    private func recoveredName(startedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Recovered Meeting \(formatter.string(from: startedAt))"
    }

    /// Best effort: moves the manifest, its backup, every existing segment, and its raw PCM into `recovery-failed/`.
    private func moveManifestSessionToFailed(_ manifest: RecordingSessionManifest) {
        let manifestURL = RecordingSessionManifestStore(folderURL: folderURL, fileManager: fileManager).url(for: manifest.id)
        let segments = manifest.allSegments.map { folderURL.appendingPathComponent($0.fileName) }
        let raw = segments.flatMap { DurableCaptureFiles.rawURLs(for: $0, source: manifest.source) }
        let urls = [manifestURL, DurableFile.backupURL(for: manifestURL)] + segments + raw
        // Never move anything a (possibly tampered) manifest names outside the library.
        for url in urls where StoragePath.isContained(url, in: folderURL) && fileManager.fileExists(atPath: url.path) {
            try? moveToFailedFolder(url)
        }
    }

    private func moveToFailedFolder(_ url: URL) throws {
        let failedFolder = folderURL.appendingPathComponent("recovery-failed", isDirectory: true)
        try fileManager.createDirectory(at: failedFolder, withIntermediateDirectories: true)
        let destination = uniqueFailedDestination(for: url, in: failedFolder)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: url, to: destination)
    }

    private func uniqueFailedDestination(for url: URL, in folder: URL) -> URL {
        var destination = folder.appendingPathComponent(url.lastPathComponent)
        guard fileManager.fileExists(atPath: destination.path) else {
            return destination
        }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base) \(index).\(ext)")
            index += 1
        }
        return destination
    }
}

private enum RecoveryCandidate {
    case single(SingleCandidate)
    case paired(PairedCandidate)

    var sortKey: String {
        switch self {
        case let .single(candidate):
            return candidate.url.lastPathComponent
        case let .paired(candidate):
            return candidate.sessionID
        }
    }
}

private struct SingleCandidate {
    let url: URL
    let source: AudioSource
}

private struct PairedCandidate {
    let sessionID: String
    var microphoneURL: URL?
    var systemURL: URL?
}

private struct AudioFileInfo {
    let duration: TimeInterval
    let startedAt: Date
    let endedAt: Date
}

private extension Optional {
    func asyncFlatMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let wrapped = self else { return nil }
        return await transform(wrapped)
    }
}
