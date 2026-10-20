import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import MSRCore

public protocol AudioRecording: AnyObject, Sendable {
    var isRecording: Bool { get }
    var captureArtifacts: RecordingCaptureArtifacts? { get }
    var onLevelUpdate: (@Sendable (Float) -> Void)? { get set }
    var onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)? { get set }
    var onCaptureFailure: (@Sendable (String) -> Void)? { get set }
    func start(source: AudioSource, outputURL: URL) async throws
    func stop() async throws
    func setMicrophoneDeviceUID(_ uid: String?)
}

public struct RecordingCaptureArtifacts: Equatable, Sendable {
    public var outputFileName: String
    public var microphoneFileName: String?
    public var systemFileName: String?

    public init(outputFileName: String, microphoneFileName: String? = nil, systemFileName: String? = nil) {
        self.outputFileName = outputFileName
        self.microphoneFileName = microphoneFileName
        self.systemFileName = systemFileName
    }
}

public extension AudioRecording {
    var onCaptureFailure: (@Sendable (String) -> Void)? { get { nil } set {} }
    var captureArtifacts: RecordingCaptureArtifacts? { nil }
    func setMicrophoneDeviceUID(_ uid: String?) {}
}

public final class MeetingAudioRecorder: AudioRecording, @unchecked Sendable {
    private var microphoneRecorder: MicrophoneAudioRecorder?
    private var screenRecorder: ScreenCaptureAudioRecorder?
    private var combinedRecorder: CombinedAudioRecorder?
    private var microphoneDeviceUID: String?

    public private(set) var isRecording = false
    public var captureArtifacts: RecordingCaptureArtifacts? {
        if let combinedRecorder { return combinedRecorder.captureArtifacts }
        if let microphoneRecorder { return microphoneRecorder.captureArtifacts }
        if let screenRecorder { return screenRecorder.captureArtifacts }
        return nil
    }
    public var onLevelUpdate: (@Sendable (Float) -> Void)?
    public var onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)?
    public var onCaptureFailure: (@Sendable (String) -> Void)?

    public init() {}

    public func setMicrophoneDeviceUID(_ uid: String?) {
        microphoneDeviceUID = uid
    }

    public func start(source: AudioSource, outputURL: URL) async throws {
        guard !isRecording else {
            throw RecordingError.alreadyRecording
        }
        try removeExistingFile(at: outputURL)

        switch RecordingCaptureStrategy.strategy(for: source) {
        case .microphoneOnly:
            let recorder = MicrophoneAudioRecorder(
                onCaptureFailure: onCaptureFailure,
                channel: .microphone,
                deviceUID: microphoneDeviceUID,
                onLevelUpdate: onLevelUpdate,
                onSourceLevelUpdate: onSourceLevelUpdate
            )
            try await recorder.start(outputURL: outputURL)
            microphoneRecorder = recorder
        case .systemOnly:
            let recorder = ScreenCaptureAudioRecorder(
                onCaptureFailure: onCaptureFailure,
                onLevelUpdate: onLevelUpdate,
                onSourceLevelUpdate: onSourceLevelUpdate
            )
            try await recorder.start(source: source, outputURL: outputURL)
            screenRecorder = recorder
        case .separateMicAndSystemMixdown:
            let recorder = CombinedAudioRecorder(
                onCaptureFailure: onCaptureFailure,
                microphoneDeviceUID: microphoneDeviceUID,
                onLevelUpdate: onLevelUpdate,
                onSourceLevelUpdate: onSourceLevelUpdate
            )
            try await recorder.start(outputURL: outputURL)
            combinedRecorder = recorder
        }
        isRecording = true
    }

    public func stop() async throws {
        guard isRecording else { return }
        var stopError: Error?
        defer {
            microphoneRecorder = nil
            screenRecorder = nil
            combinedRecorder = nil
            isRecording = false
            onLevelUpdate?(0)
            onSourceLevelUpdate?(.microphone, 0)
            onSourceLevelUpdate?(.system, 0)
        }

        microphoneRecorder?.stop()
        if let microphoneRecorder {
            do { try await microphoneRecorder.publish() } catch { stopError = error }
        }
        if let screenRecorder {
            do {
                try await screenRecorder.stop()
            } catch {
                stopError = error
            }
        }
        if let combinedRecorder {
            do {
                try await combinedRecorder.stop()
            } catch {
                stopError = stopError ?? error
            }
        }
        if let stopError {
            throw stopError
        }
    }

    private func removeExistingFile(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

private final class MicrophoneAudioRecorder: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
    private let onCaptureFailure: (@Sendable (String) -> Void)?
    private var recorder: AVAudioRecorder?
    private let channel: AudioSignalChannel
    private let deviceUID: String?
    private let onLevelUpdate: (@Sendable (Float) -> Void)?
    private let onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)?
    private var meterTimer: DispatchSourceTimer?
    private var outputURL: URL?
    private var rawURL: URL?

    private var previousDefaultDeviceID: AudioDeviceID?
    private let meterQueue = DispatchQueue(label: "app.msr.microphone-meter")

    init(
        onCaptureFailure: (@Sendable (String) -> Void)? = nil,
        channel: AudioSignalChannel,
        deviceUID: String? = nil,
        onLevelUpdate: (@Sendable (Float) -> Void)? = nil,
        onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)? = nil
    ) {
        self.onCaptureFailure = onCaptureFailure
        self.channel = channel
        self.deviceUID = deviceUID
        self.onLevelUpdate = onLevelUpdate
        self.onSourceLevelUpdate = onSourceLevelUpdate
        super.init()
    }

    func start(outputURL: URL) async throws {
        guard await requestMicrophonePermission() else {
            throw RecordingError.microphonePermissionDenied
        }
        previousDefaultDeviceID = AudioDeviceCatalog.selectInputDevice(uid: deviceUID)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let rawURL = outputURL.pathExtension == "caf" ? outputURL : DurableCaptureFiles.rawURL(for: outputURL, channel: .microphone)
        let recorder = try AVAudioRecorder(url: rawURL, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw RecordingError.couldNotStartRecording
        }
        self.recorder = recorder
        self.outputURL = outputURL
        self.rawURL = rawURL
        startMetering()
    }

    var captureArtifacts: RecordingCaptureArtifacts? {
        outputURL.map { RecordingCaptureArtifacts(outputFileName: $0.lastPathComponent, microphoneFileName: rawURL?.lastPathComponent) }
    }

    func publish() async throws {
        guard let outputURL, let rawURL, outputURL != rawURL else { return }
        try await AudioTrackMixer.mixToSingleM4A(inputs: [rawURL], outputURL: outputURL)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        onCaptureFailure?(error?.localizedDescription ?? "Microphone audio could not be written.")
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag { onCaptureFailure?("Microphone audio stopped unexpectedly.") }
    }

    func stop() {
        meterTimer?.cancel()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        AudioDeviceCatalog.restoreInputDevice(previousDefaultDeviceID)
        previousDefaultDeviceID = nil
        onLevelUpdate?(0)
        onSourceLevelUpdate?(channel, 0)
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func startMetering() {
        let timer = DispatchSource.makeTimerSource(queue: meterQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80))
        timer.setEventHandler { [weak self] in
            guard let self, let recorder else { return }
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            let level = Self.normalizedPower(power)
            onLevelUpdate?(level)
            onSourceLevelUpdate?(channel, level)
        }
        meterTimer = timer
        timer.resume()
    }

    private static func normalizedPower(_ decibels: Float) -> Float {
        if decibels <= -60 { return 0 }
        if decibels >= 0 { return 1 }
        return pow(10, decibels / 20)
    }
}

private final class CombinedAudioRecorder {
    private let microphoneRecorder: MicrophoneAudioRecorder
    private let systemRecorder: ScreenCaptureAudioRecorder
    private var outputURL: URL?
    private var microphoneURL: URL?
    private var systemURL: URL?
    private var microphoneStartedAt: Date?
    private var systemStartedAt: Date?

    var captureArtifacts: RecordingCaptureArtifacts? {
        guard let outputURL else { return nil }
        return RecordingCaptureArtifacts(
            outputFileName: outputURL.lastPathComponent,
            microphoneFileName: microphoneURL?.lastPathComponent,
            systemFileName: systemURL?.lastPathComponent
        )
    }

    init(
        onCaptureFailure: (@Sendable (String) -> Void)? = nil,
        microphoneDeviceUID: String? = nil,
        onLevelUpdate: (@Sendable (Float) -> Void)? = nil,
        onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)? = nil
    ) {
        microphoneRecorder = MicrophoneAudioRecorder(
            onCaptureFailure: onCaptureFailure,
            channel: .microphone,
            deviceUID: microphoneDeviceUID,
            onLevelUpdate: onLevelUpdate,
            onSourceLevelUpdate: onSourceLevelUpdate
        )
        systemRecorder = ScreenCaptureAudioRecorder(
            onCaptureFailure: onCaptureFailure,
            onLevelUpdate: onLevelUpdate,
            onSourceLevelUpdate: onSourceLevelUpdate
        )
    }

    func start(outputURL: URL) async throws {
        let microphoneURL = DurableCaptureFiles.rawURL(for: outputURL, channel: .microphone)
        let systemURL = DurableCaptureFiles.rawURL(for: outputURL, channel: .system)
        self.outputURL = outputURL
        self.microphoneURL = microphoneURL
        self.systemURL = systemURL

        do {
            try await systemRecorder.start(source: .system, outputURL: systemURL)
            systemStartedAt = Date()
            try await microphoneRecorder.start(outputURL: microphoneURL)
            microphoneStartedAt = Date()
        } catch {
            microphoneRecorder.stop()
            try? await systemRecorder.stop()
            // Preserve any PCM already captured, even if the other source failed.
            throw error
        }
    }

    func stop() async throws {
        microphoneRecorder.stop()
        try await systemRecorder.stop()
        guard let outputURL, let microphoneURL, let systemURL else {
            throw RecordingError.writerFailed("Missing temporary recording files.")
        }
        let origin = min(systemStartedAt ?? .distantFuture, microphoneStartedAt ?? .distantFuture)
        try await AudioTrackMixer.mixToSingleM4A(
            inputs: [
                TimedAudioInput(url: systemURL, offset: max(0, (systemStartedAt ?? origin).timeIntervalSince(origin))),
                TimedAudioInput(url: microphoneURL, offset: max(0, (microphoneStartedAt ?? origin).timeIntervalSince(origin)))
            ],
            outputURL: outputURL
        )
        // Raw tracks remain until the session publication/checkpoint succeeds.
    }

}

public enum RecordingError: Error, LocalizedError {
    case alreadyRecording
    case microphonePermissionDenied
    case screenCapturePermissionDenied
    case couldNotStartRecording
    case noDisplayAvailable
    case writerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already running."
        case .microphonePermissionDenied:
            return "Microphone permission is required to record meeting audio."
        case .screenCapturePermissionDenied:
            return "Screen/System Audio permission is required to record system audio."
        case .couldNotStartRecording:
            return "Could not start audio recording."
        case .noDisplayAvailable:
            return "No display is available for system audio capture."
        case let .writerFailed(message):
            return "Could not write recording: \(message)"
        }
    }
}

final class ScreenCaptureAudioRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onCaptureFailure: (@Sendable (String) -> Void)?
    // Accessed exclusively on the sample queue, including writer teardown.
    private var acceptingSamples = false
    private let queue = DispatchQueue(label: "app.msr.screen-audio")
    private let onLevelUpdate: (@Sendable (Float) -> Void)?
    private let onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)?
    private var stream: SCStream?
    private var sink: DurableSystemAudioSink?
    private var captureError: Error?
    private var outputURL: URL?

    var captureArtifacts: RecordingCaptureArtifacts? {
        outputURL.map { RecordingCaptureArtifacts(outputFileName: $0.lastPathComponent,
            systemFileName: ($0.pathExtension == "caf" ? $0 : DurableCaptureFiles.rawURL(for: $0, channel: .system)).lastPathComponent) }
    }

    init(
        onCaptureFailure: (@Sendable (String) -> Void)? = nil,
        onLevelUpdate: (@Sendable (Float) -> Void)? = nil,
        onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)? = nil
    ) {
        self.onCaptureFailure = onCaptureFailure
        self.onLevelUpdate = onLevelUpdate
        self.onSourceLevelUpdate = onSourceLevelUpdate
    }

    func start(source _: AudioSource, outputURL: URL) async throws {
        self.outputURL = outputURL
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecordingError.screenCapturePermissionDenied
        }
        guard let display = content.displays.first else {
            throw RecordingError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        let rawURL = outputURL.pathExtension == "caf" ? outputURL : DurableCaptureFiles.rawURL(for: outputURL, channel: .system)
        queue.sync {
            self.sink = DurableSystemAudioSink(url: rawURL)
            self.captureError = nil
            self.acceptingSamples = true
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            // A partially started stream still owns a writer; close it before losing the handle.
            try? await stop()
            throw error
        }
    }

    func stop() async throws {
        var stopError: Error?
        defer {
            stream = nil
            onLevelUpdate?(0)
            onSourceLevelUpdate?(.system, 0)
        }

        let result: (URL?, Error?) = queue.sync {
            acceptingSamples = false
            sink?.close()
            let result = (sink?.url, captureError)
            sink = nil
            captureError = nil
            return result
        }
        // Close PCM before invoking ScreenCaptureKit, whose stop callback can
        // stall on sleep. Its bounded wait never holds the only audio file open.
        if let stream { stopError = await stopStreamWithDeadline(stream) }
        if let error = result.1 { throw error }
        if let rawURL = result.0, let outputURL,
           FileManager.default.fileExists(atPath: rawURL.path) {
            if outputURL != rawURL {
                try await AudioTrackMixer.mixToSingleM4A(inputs: [rawURL], outputURL: outputURL)
            }
            // Already-stopped SCStream is benign only after PCM was closed successfully.
            stopError = nil
        }
        if let stopError {
            throw stopError
        }
    }

    private func stopStreamWithDeadline(_ stream: SCStream) async -> Error? {
        await withCheckedContinuation { continuation in
            let completion = StreamStopCompletion(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                completion.finish(RecordingError.writerFailed("System capture stop timed out; PCM was preserved."))
            }
            stream.stopCapture { error in completion.finish(error) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        guard acceptingSamples, type == .audio, let sink else {
            return
        }
        do {
            try sink.append(sampleBuffer)
            let level = AudioSampleLevelMeter.normalizedLevel(from: sampleBuffer)
            onLevelUpdate?(level)
            onSourceLevelUpdate?(.system, level)
        } catch {
            captureError = captureError ?? error
            acceptingSamples = false
            onCaptureFailure?(error.localizedDescription)
        }
    }
}

private final class StreamStopCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Error?, Never>?
    init(_ continuation: CheckedContinuation<Error?, Never>) { self.continuation = continuation }
    func finish(_ error: Error?) {
        let waiter = lock.withLock {
            let waiter = continuation
            continuation = nil
            return waiter
        }
        waiter?.resume(returning: error)
    }
}
