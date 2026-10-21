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
    /// Called (on an arbitrary queue) when capture stops or fails while a recording is running,
    /// typically with `RecordingError.captureInterrupted`. Reported at most once per recording.
    var onCaptureFailure: (@Sendable (Error) -> Void)? { get set }
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
    var captureArtifacts: RecordingCaptureArtifacts? { nil }
    /// Default for conformers (e.g. test fakes) that never report asynchronous capture failures.
    var onCaptureFailure: (@Sendable (Error) -> Void)? {
        get { nil }
        set {}
    }
    func setMicrophoneDeviceUID(_ uid: String?) {}
}

public final class MeetingAudioRecorder: AudioRecording, @unchecked Sendable {
    private var microphoneRecorder: MicrophoneAudioRecorder?
    private var screenRecorder: ScreenCaptureAudioRecorder?
    private var combinedRecorder: CombinedAudioRecorder?
    private var microphoneDeviceUID: String?

    private let failureLock = NSLock()
    private var captureFailureHandler: (@Sendable (Error) -> Void)?
    private var captureSessionActive = false
    private var captureFailureReported = false

    public private(set) var isRecording = false
    public var captureArtifacts: RecordingCaptureArtifacts? {
        if let combinedRecorder { return combinedRecorder.captureArtifacts }
        if let microphoneRecorder { return microphoneRecorder.captureArtifacts }
        if let screenRecorder { return screenRecorder.captureArtifacts }
        return nil
    }
    public var onLevelUpdate: (@Sendable (Float) -> Void)?
    public var onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)?
    public var onCaptureFailure: (@Sendable (Error) -> Void)? {
        get { failureLock.withLock { captureFailureHandler } }
        set { failureLock.withLock { captureFailureHandler = newValue } }
    }

    public init() {}

    public func setMicrophoneDeviceUID(_ uid: String?) {
        microphoneDeviceUID = uid
    }

    public func start(source: AudioSource, outputURL: URL) async throws {
        guard !isRecording else {
            throw RecordingError.alreadyRecording
        }
        try removeExistingFile(at: outputURL)
        failureLock.withLock {
            captureSessionActive = false
            captureFailureReported = false
        }
        let forwardFailure: @Sendable (Error) -> Void = { [weak self] error in
            self?.reportCaptureFailure(error)
        }

        switch RecordingCaptureStrategy.strategy(for: source) {
        case .microphoneOnly:
            let recorder = MicrophoneAudioRecorder(
                channel: .microphone,
                deviceUID: microphoneDeviceUID,
                onLevelUpdate: onLevelUpdate,
                onSourceLevelUpdate: onSourceLevelUpdate,
                onCaptureFailure: forwardFailure
            )
            try await recorder.start(outputURL: outputURL)
            microphoneRecorder = recorder
        case .systemOnly:
            let recorder = ScreenCaptureAudioRecorder(
                onLevelUpdate: onLevelUpdate,
                onSourceLevelUpdate: onSourceLevelUpdate,
                onCaptureFailure: forwardFailure
            )
            try await recorder.start(source: source, outputURL: outputURL)
            screenRecorder = recorder
        case .separateMicAndSystemMixdown:
            let recorder = CombinedAudioRecorder(
                microphoneDeviceUID: microphoneDeviceUID,
                onLevelUpdate: onLevelUpdate,
                onSourceLevelUpdate: onSourceLevelUpdate,
                onCaptureFailure: forwardFailure
            )
            try await recorder.start(outputURL: outputURL)
            combinedRecorder = recorder
        }
        isRecording = true
        // Failures before this point are thrown from `start`; only later ones go through the callback.
        failureLock.withLock { captureSessionActive = true }
    }

    public func stop() async throws {
        guard isRecording else { return }
        failureLock.withLock { captureSessionActive = false }
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
            // Mic capture is PCM CAF; export the M4A segment. The CAF stays until publication.
            do { try await microphoneRecorder.publish() } catch { stopError = error }
        }
        if let screenRecorder {
            do {
                try await screenRecorder.stop()
            } catch {
                stopError = stopError ?? error
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

    private func reportCaptureFailure(_ error: Error) {
        let handler: (@Sendable (Error) -> Void)? = failureLock.withLock {
            guard captureSessionActive, !captureFailureReported else { return nil }
            captureFailureReported = true
            return captureFailureHandler
        }
        handler?(error)
    }

    private func removeExistingFile(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

private final class MicrophoneAudioRecorder: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
    // `recorder` and `meterTimer` are only read or written on `meterQueue`, so the meter tick,
    // the delegate callbacks, and `stop()` never race on them.
    private var recorder: AVAudioRecorder?
    private var meterTimer: DispatchSourceTimer?
    private let channel: AudioSignalChannel
    private let deviceUID: String?
    private let onLevelUpdate: (@Sendable (Float) -> Void)?
    private let onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)?
    private let onCaptureFailure: (@Sendable (Error) -> Void)?
    private var outputURL: URL?
    /// Durable PCM CAF actually being recorded; `outputURL` is the M4A exported on `publish()`.
    private var rawURL: URL?
    private var previousDefaultDeviceID: AudioDeviceID?
    private let meterQueue = DispatchQueue(label: "app.msr.microphone-meter")

    init(
        channel: AudioSignalChannel,
        deviceUID: String? = nil,
        onLevelUpdate: (@Sendable (Float) -> Void)? = nil,
        onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)? = nil,
        onCaptureFailure: (@Sendable (Error) -> Void)? = nil
    ) {
        self.channel = channel
        self.deviceUID = deviceUID
        self.onLevelUpdate = onLevelUpdate
        self.onSourceLevelUpdate = onSourceLevelUpdate
        self.onCaptureFailure = onCaptureFailure
        super.init()
    }

    func start(outputURL: URL) async throws {
        guard await requestMicrophonePermission() else {
            throw RecordingError.microphonePermissionDenied
        }
        let previousDefault = AudioDeviceCatalog.selectInputDevice(uid: deviceUID)
        do {
            // Uncompressed PCM CAF does not depend on an end-of-session movie index (sleep safety).
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false
            ]
            let rawURL = outputURL.pathExtension == "caf"
                ? outputURL
                : DurableCaptureFiles.rawURL(for: outputURL, channel: .microphone)
            let recorder = try AVAudioRecorder(url: rawURL, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw RecordingError.couldNotStartRecording
            }
            previousDefaultDeviceID = previousDefault
            self.outputURL = outputURL
            self.rawURL = rawURL
            meterQueue.sync { self.recorder = recorder }
            startMetering()
        } catch {
            // Never leave the user's system-wide default input switched after a failed start.
            AudioDeviceCatalog.restoreInputDevice(previousDefault)
            throw error
        }
    }

    var captureArtifacts: RecordingCaptureArtifacts? {
        outputURL.map { RecordingCaptureArtifacts(outputFileName: $0.lastPathComponent, microphoneFileName: rawURL?.lastPathComponent) }
    }

    /// Exports the retained PCM to the M4A output. Call after `stop()`.
    func publish() async throws {
        guard let outputURL, let rawURL, outputURL != rawURL else { return }
        try await AudioTrackMixer.mixToSingleM4A(inputs: [rawURL], outputURL: outputURL)
    }

    func stop() {
        let current: AVAudioRecorder? = meterQueue.sync {
            meterTimer?.cancel()
            meterTimer = nil
            let current = recorder
            recorder = nil
            return current
        }
        current?.stop()
        AudioDeviceCatalog.restoreInputDevice(previousDefaultDeviceID)
        previousDefaultDeviceID = nil
        onLevelUpdate?(0)
        onSourceLevelUpdate?(channel, 0)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard isActive(recorder) else { return }
        let reason = error?.localizedDescription ?? "unknown encoder error"
        onCaptureFailure?(RecordingError.captureInterrupted("Microphone audio could not be encoded (\(reason))."))
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // `stop()` detaches the recorder first, so only unexpected stops reach the callback.
        guard !flag, isActive(recorder) else { return }
        onCaptureFailure?(RecordingError.captureInterrupted("Microphone recording stopped unexpectedly."))
    }

    private func isActive(_ candidate: AVAudioRecorder) -> Bool {
        meterQueue.sync { recorder === candidate }
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
            // Runs on `meterQueue`; `recorder` is nil once `stop()` has run.
            guard let self, let recorder = self.recorder else { return }
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            let level = Self.normalizedPower(power)
            onLevelUpdate?(level)
            onSourceLevelUpdate?(channel, level)
        }
        meterQueue.sync { meterTimer = timer }
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
        microphoneDeviceUID: String? = nil,
        onLevelUpdate: (@Sendable (Float) -> Void)? = nil,
        onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)? = nil,
        onCaptureFailure: (@Sendable (Error) -> Void)? = nil
    ) {
        microphoneRecorder = MicrophoneAudioRecorder(
            channel: .microphone,
            deviceUID: microphoneDeviceUID,
            onLevelUpdate: onLevelUpdate,
            onSourceLevelUpdate: onSourceLevelUpdate,
            onCaptureFailure: onCaptureFailure
        )
        systemRecorder = ScreenCaptureAudioRecorder(
            onLevelUpdate: onLevelUpdate,
            onSourceLevelUpdate: onSourceLevelUpdate,
            onCaptureFailure: onCaptureFailure
        )
    }

    func start(outputURL: URL) async throws {
        // Deterministic names (persisted in the session manifest before capture starts)
        // let recovery find the PCM even if start never returned.
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
    /// Capture stopped or failed while recording (device removed, permission revoked, encoder error).
    case captureInterrupted(String)

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
        case let .captureInterrupted(message):
            return "Recording was interrupted: \(message)"
        }
    }
}

final class ScreenCaptureAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.msr.screen-audio")
    private let onLevelUpdate: (@Sendable (Float) -> Void)?
    private let onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)?
    private let onCaptureFailure: (@Sendable (Error) -> Void)?
    private var stream: SCStream?
    private var outputURL: URL?
    // Sink state below is only read or written on `queue` (the sample-handler queue),
    // including PCM writer teardown.
    private var sink: DurableSystemAudioSink?
    private var captureError: Error?
    private var acceptingSamples = false
    private var isStopping = false
    private var streamStoppedUnexpectedly = false
    private var failureReported = false

    var captureArtifacts: RecordingCaptureArtifacts? {
        outputURL.map {
            RecordingCaptureArtifacts(
                outputFileName: $0.lastPathComponent,
                systemFileName: Self.rawURL(for: $0).lastPathComponent
            )
        }
    }

    init(
        onLevelUpdate: (@Sendable (Float) -> Void)? = nil,
        onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)? = nil,
        onCaptureFailure: (@Sendable (Error) -> Void)? = nil
    ) {
        self.onLevelUpdate = onLevelUpdate
        self.onSourceLevelUpdate = onSourceLevelUpdate
        self.onCaptureFailure = onCaptureFailure
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
        let rawURL = Self.rawURL(for: outputURL)
        queue.sync {
            self.sink = DurableSystemAudioSink(url: rawURL)
            captureError = nil
            acceptingSamples = true
            isStopping = false
            streamStoppedUnexpectedly = false
            failureReported = false
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            self.stream = stream
            try await stream.startCapture()
        } catch {
            self.stream = nil
            // Close (never delete) the PCM: anything captured stays available for recovery.
            queue.sync {
                acceptingSamples = false
                isStopping = true
                sink?.close()
                sink = nil
                captureError = nil
            }
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

        // Close PCM on the sample queue before invoking ScreenCaptureKit, whose stop callback can
        // stall on sleep; its bounded wait then never holds the only audio file open.
        let detached: (rawURL: URL?, captureError: Error?, streamAlreadyStopped: Bool) = queue.sync {
            isStopping = true
            acceptingSamples = false
            sink?.close()
            let result = (sink?.url, captureError, streamStoppedUnexpectedly)
            sink = nil
            captureError = nil
            return result
        }
        if let stream, !detached.streamAlreadyStopped {
            stopError = await stopStreamWithDeadline(stream)
        }
        if let error = detached.captureError { throw error }
        if let rawURL = detached.rawURL, let outputURL,
           FileManager.default.fileExists(atPath: rawURL.path) {
            if outputURL != rawURL {
                try await AudioTrackMixer.mixToSingleM4A(inputs: [rawURL], outputURL: outputURL)
            }
            // An already-stopped SCStream is benign once the PCM was closed successfully.
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
        guard type == .audio, acceptingSamples, let sink else {
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
            reportFailure(RecordingError.captureInterrupted("System audio could not be written (\(error.localizedDescription))."))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, !self.isStopping else { return }
            self.streamStoppedUnexpectedly = true
            self.reportFailure(RecordingError.captureInterrupted("System audio capture stopped (\(error.localizedDescription))."))
        }
    }

    /// Must run on `queue`.
    private func reportFailure(_ error: Error) {
        guard !isStopping, !failureReported else { return }
        failureReported = true
        onCaptureFailure?(error)
    }

    private static func rawURL(for outputURL: URL) -> URL {
        outputURL.pathExtension == "caf" ? outputURL : DurableCaptureFiles.rawURL(for: outputURL, channel: .system)
    }
}

/// Exactly-once bridge between `SCStream.stopCapture`'s callback and its deadline.
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
