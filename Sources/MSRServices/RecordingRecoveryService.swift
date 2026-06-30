import AVFoundation
import Foundation
import MSRCore

public enum RecordingRecoveryStatus: Equatable, Sendable {
    case recoveredMixed
    case recoveredSingleSource(AudioSignalChannel)
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
        let candidates = try interruptedCandidates()
        var results: [RecordingRecoveryResult] = []
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
            } else if name.hasPrefix(".in-progress-") {
                singles.append(.single(url))
            }
        }

        let paired = grouped.values.map { RecoveryCandidate.paired($0) }
        return (paired + singles).sorted { lhs, rhs in
            lhs.sortKey < rhs.sortKey
        }
    }

    private func recover(_ candidate: RecoveryCandidate, now: Date) async throws -> RecordingRecoveryResult {
        switch candidate {
        case let .single(url):
            return try await recoverSingle(url, now: now)
        case let .paired(candidate):
            return try await recoverPaired(candidate, now: now)
        }
    }

    private func recoverSingle(_ url: URL, now: Date) async throws -> RecordingRecoveryResult {
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
            source: .microphone,
            startedAt: audioInfo.startedAt,
            endedAt: audioInfo.endedAt,
            durationSecondsOverride: audioInfo.duration,
            recoveredAt: now,
            recoveryNote: "Recovered from an interrupted recording.",
            segmentCount: 1
        )
        return RecordingRecoveryResult(
            status: .recoveredSingleSource(.microphone),
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
    case single(URL)
    case paired(PairedCandidate)

    var sortKey: String {
        switch self {
        case let .single(url):
            return url.lastPathComponent
        case let .paired(candidate):
            return candidate.sessionID
        }
    }
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
