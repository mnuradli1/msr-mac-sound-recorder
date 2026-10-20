import Foundation
import MSRCore

/// Development-only `AudioRecording` that "records" by copying a pre-recorded
/// clip to the requested output URL when stopped. No microphone, Screen
/// Recording permission or audio hardware is touched, so scripted UI runs and
/// end-to-end checks are deterministic.
///
/// The app uses it instead of `MeetingAudioRecorder` when the environment
/// variable `MSR_FAKE_RECORDER_CLIP` points at an existing audio file (already
/// in the format the output URL expects, normally `.m4a`; nothing is converted).
public final class FileReplayRecorder: AudioRecording, @unchecked Sendable {
    public enum ReplayError: LocalizedError {
        case alreadyRecording
        case clipMissing(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "A recording is already in progress."
            case let .clipMissing(path):
                return "The replay clip was not found: \(path)"
            }
        }
    }

    public let clipURL: URL
    public var onLevelUpdate: (@Sendable (Float) -> Void)?
    public var onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)?
    /// Mirrors the requirement being added to `AudioRecording`; never invoked here.
    public var onCaptureFailure: (@Sendable (Error) -> Void)?

    private let lock = NSLock()
    private var recording = false
    private var outputURL: URL?
    private var levelTask: Task<Void, Never>?

    public init(clipURL: URL) {
        self.clipURL = clipURL
    }

    public var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recording
    }

    public var captureArtifacts: RecordingCaptureArtifacts? {
        lock.lock()
        defer { lock.unlock() }
        return outputURL.map { RecordingCaptureArtifacts(outputFileName: $0.lastPathComponent) }
    }

    public func setMicrophoneDeviceUID(_ uid: String?) {}

    public func start(source: AudioSource, outputURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: clipURL.path) else {
            throw ReplayError.clipMissing(clipURL.path)
        }
        let started: Bool = lock.withLock {
            guard !recording else { return false }
            recording = true
            self.outputURL = outputURL
            return true
        }
        guard started else { throw ReplayError.alreadyRecording }

        let channels: [AudioSignalChannel] = switch source {
        case .microphone: [.microphone]
        case .system: [.system]
        case .micAndSystem: [.microphone, .system]
        }
        let onLevel = onLevelUpdate
        let onSourceLevel = onSourceLevelUpdate
        let task = Task.detached {
            // A short burst of plausible levels, then hold a steady low level.
            let pattern: [Float] = [0.18, 0.42, 0.65, 0.38, 0.55, 0.27, 0.48, 0.33]
            var index = 0
            while !Task.isCancelled, index < 600 {
                let level = pattern[index % pattern.count]
                onLevel?(level)
                for channel in channels {
                    onSourceLevel?(channel, channel == .system ? level * 0.8 : level)
                }
                index += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        lock.withLock { levelTask = task }
    }

    public func stop() async throws {
        let (destination, task): (URL?, Task<Void, Never>?) = lock.withLock {
            let snapshot = (outputURL, levelTask)
            levelTask = nil
            recording = false
            return snapshot
        }
        task?.cancel()

        guard let destination else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: clipURL, to: destination)
    }
}
