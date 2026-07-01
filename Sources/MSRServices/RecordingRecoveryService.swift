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

    public init(
        status: RecordingRecoveryStatus,
        recording: RecordingItem?,
        message: String,
        recoveredFiles: [String],
        failedFiles: [String]
    ) {
        self.status = status
        self.recording = recording
        self.message = message
        self.recoveredFiles = recoveredFiles
        self.failedFiles = failedFiles
    }
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
        let sessionManifests = try RecordingSessionManifestStore(folderURL: folderURL, fileManager: fileManager).loadAll()
        for manifest in sessionManifests {
            results.append(try await recoverSession(manifest, now: now))
        }
        let candidates = try interruptedCandidates()
        for candidate in candidates {
            results.append(try await recover(candidate, now: now))
        }
        return results
    }

    private func interruptedCandidates() throws -> [RecoveryCandidate] {
        let urls = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: []
        )
        var grouped: [String: PairedCandidate] = [:]
        var singles: [RecoveryCandidate] = []

        for url in urls where url.pathExtension == "m4a" {
            let name = url.lastPathComponent
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
        let manifestStore = RecordingSessionManifestStore(folderURL: folderURL, fileManager: fileManager)
        let manifestURL = manifestStore.url(for: manifest.id)
        let segments = manifest.allSegments
        guard !segments.isEmpty else {
            try moveManifestSessionToFailed(manifest, extraFailedFiles: [])
            return RecordingRecoveryResult(
                status: .failed("Session manifest had no recorded segments."),
                recording: nil,
                message: "Could not recover \(manifest.requestedName).",
                recoveredFiles: [],
                failedFiles: [manifestURL.lastPathComponent]
            )
        }

        let segmentURLs = segments.map { folderURL.appendingPathComponent($0.fileName) }
        let missingFiles = zip(segments, segmentURLs)
            .filter { _, url in !fileManager.fileExists(atPath: url.path) }
            .map { segment, _ in segment.fileName }
        guard missingFiles.isEmpty else {
            try moveManifestSessionToFailed(manifest, extraFailedFiles: missingFiles)
            return RecordingRecoveryResult(
                status: .failed("Session manifest referenced missing segment files."),
                recording: nil,
                message: "Could not recover \(manifest.requestedName).",
                recoveredFiles: [],
                failedFiles: [manifestURL.lastPathComponent] + segments.map(\.fileName)
            )
        }

        let audioInfos = try await readableAudioInfos(for: segmentURLs)
        guard audioInfos.count == segmentURLs.count else {
            try moveManifestSessionToFailed(manifest, extraFailedFiles: [])
            return RecordingRecoveryResult(
                status: .failed("Session manifest contained unreadable segment files."),
                recording: nil,
                message: "Could not recover \(manifest.requestedName).",
                recoveredFiles: [],
                failedFiles: [manifestURL.lastPathComponent] + segments.map(\.fileName)
            )
        }

        let finalTemporaryURL: URL
        if segmentURLs.count == 1, let onlySegment = segmentURLs.first {
            finalTemporaryURL = onlySegment
        } else {
            finalTemporaryURL = folderURL.appendingPathComponent(".recovered-session-\(manifest.id.uuidString).m4a")
            try await AudioTrackMixer.concatenateToSingleM4A(inputs: segmentURLs, outputURL: finalTemporaryURL)
        }

        let audioDuration = audioInfos.reduce(0) { $0 + $1.duration }
        let duration = max(manifest.accumulatedActiveDuration, audioDuration)
        let endedAt = manifest.startedAt.addingTimeInterval(duration)
        let recording = try RecordingLibrary(folderURL: folderURL, fileManager: fileManager).finishRecording(
            temporaryAudioURL: finalTemporaryURL,
            requestedName: manifest.requestedName,
            source: manifest.source,
            startedAt: manifest.startedAt,
            endedAt: endedAt,
            durationSecondsOverride: duration,
            recoveredAt: now,
            recoveryNote: "Recovered \(segmentURLs.count) segment\(segmentURLs.count == 1 ? "" : "s") from an interrupted recording session.",
            segmentCount: segmentURLs.count
        )

        if segmentURLs.count > 1 {
            for url in segmentURLs {
                try? fileManager.removeItem(at: url)
            }
        }
        try manifestStore.delete(manifest)
        return RecordingRecoveryResult(
            status: .recoveredSession(segmentCount: segmentURLs.count),
            recording: recording,
            message: "Recovered \(recording.displayName).",
            recoveredFiles: [recording.audioURL.lastPathComponent],
            failedFiles: []
        )
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
            try? fileManager.removeItem(at: microphoneURL)
            try? fileManager.removeItem(at: systemURL)
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

    private func readableAudioInfos(for urls: [URL]) async throws -> [AudioFileInfo] {
        var infos: [AudioFileInfo] = []
        for url in urls {
            guard let info = try? await audioInfo(for: url) else {
                return infos
            }
            infos.append(info)
        }
        return infos
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

    private func moveManifestSessionToFailed(_ manifest: RecordingSessionManifest, extraFailedFiles: [String]) throws {
        let store = RecordingSessionManifestStore(folderURL: folderURL, fileManager: fileManager)
        let existingURLs = ([store.url(for: manifest.id)] + manifest.allSegments.map { folderURL.appendingPathComponent($0.fileName) })
            .filter { fileManager.fileExists(atPath: $0.path) }
        for url in existingURLs {
            try moveToFailedFolder(url)
        }
        _ = extraFailedFiles
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
