import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import MSRCore

public protocol AudioRecording: AnyObject, Sendable {
    var isRecording: Bool { get }
    var onLevelUpdate: (@Sendable (Float) -> Void)? { get set }
    var onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)? { get set }
    func start(source: AudioSource, outputURL: URL) async throws
    func stop() async throws
}

public final class MeetingAudioRecorder: AudioRecording, @unchecked Sendable {
    private var microphoneRecorder: MicrophoneAudioRecorder?
    private var screenRecorder: ScreenCaptureAudioRecorder?
    private var combinedRecorder: CombinedAudioRecorder?

    public private(set) var isRecording = false
    public var onLevelUpdate: (@Sendable (Float) -> Void)?
    public var onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)?

    public init() {}

    public func start(source: AudioSource, outputURL: URL) async throws {
        guard !isRecording else {
            throw RecordingError.alreadyRecording
        }
        try removeExistingFile(at: outputURL)

        switch RecordingCaptureStrategy.strategy(for: source) {
        case .microphoneOnly:
            let recorder = MicrophoneAudioRecorder(
                channel: .microphone,
                onLevelUpdate: onLevelUpdate,
                onSourceLevelUpdate: onSourceLevelUpdate
            )
            try await recorder.start(outputURL: outputURL)
            microphoneRecorder = recorder
        case .systemOnly:
            let recorder = ScreenCaptureAudioRecorder(
                onLevelUpdate: onLevelUpdate,
                onSourceLevelUpdate: onSourceLevelUpdate
            )
            try await recorder.start(source: source, outputURL: outputURL)
            screenRecorder = recorder
        case .separateMicAndSystemMixdown:
            let recorder = CombinedAudioRecorder(
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

private final class MicrophoneAudioRecorder {
    private var recorder: AVAudioRecorder?
    private let channel: AudioSignalChannel
    private let onLevelUpdate: (@Sendable (Float) -> Void)?
    private let onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)?
    private var meterTimer: DispatchSourceTimer?
    private let meterQueue = DispatchQueue(label: "app.msr.microphone-meter")

    init(
        channel: AudioSignalChannel,
        onLevelUpdate: (@Sendable (Float) -> Void)? = nil,
        onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)? = nil
    ) {
        self.channel = channel
        self.onLevelUpdate = onLevelUpdate
        self.onSourceLevelUpdate = onSourceLevelUpdate
    }

    func start(outputURL: URL) async throws {
        guard await requestMicrophonePermission() else {
            throw RecordingError.microphonePermissionDenied
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw RecordingError.couldNotStartRecording
        }
        self.recorder = recorder
        startMetering()
    }

    func stop() {
        meterTimer?.cancel()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
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

    init(
        onLevelUpdate: (@Sendable (Float) -> Void)? = nil,
        onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)? = nil
    ) {
        microphoneRecorder = MicrophoneAudioRecorder(
            channel: .microphone,
            onLevelUpdate: onLevelUpdate,
            onSourceLevelUpdate: onSourceLevelUpdate
        )
        systemRecorder = ScreenCaptureAudioRecorder(
            onLevelUpdate: onLevelUpdate,
            onSourceLevelUpdate: onSourceLevelUpdate
        )
    }

    func start(outputURL: URL) async throws {
        let base = outputURL.deletingPathExtension().lastPathComponent
        let folder = outputURL.deletingLastPathComponent()
        let microphoneURL = folder.appendingPathComponent(".\(base)-mic-\(UUID().uuidString).m4a")
        let systemURL = folder.appendingPathComponent(".\(base)-system-\(UUID().uuidString).m4a")
        self.outputURL = outputURL
        self.microphoneURL = microphoneURL
        self.systemURL = systemURL

        do {
            try await systemRecorder.start(source: .system, outputURL: systemURL)
            try await microphoneRecorder.start(outputURL: microphoneURL)
        } catch {
            microphoneRecorder.stop()
            try? await systemRecorder.stop()
            cleanupTemporaryFiles()
            throw error
        }
    }

    func stop() async throws {
        microphoneRecorder.stop()
        try await systemRecorder.stop()
        guard let outputURL, let microphoneURL, let systemURL else {
            throw RecordingError.writerFailed("Missing temporary recording files.")
        }
        try await AudioTrackMixer.mixToSingleM4A(inputs: [systemURL, microphoneURL], outputURL: outputURL)
        cleanupTemporaryFiles()
    }

    private func cleanupTemporaryFiles() {
        for url in [microphoneURL, systemURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
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
    private let queue = DispatchQueue(label: "app.msr.screen-audio")
    private let onLevelUpdate: (@Sendable (Float) -> Void)?
    private let onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)?
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var systemInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var didStartSession = false

    init(
        onLevelUpdate: (@Sendable (Float) -> Void)? = nil,
        onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)? = nil
    ) {
        self.onLevelUpdate = onLevelUpdate
        self.onSourceLevelUpdate = onSourceLevelUpdate
    }

    func start(source: AudioSource, outputURL: URL) async throws {
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
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = source == .micAndSystem
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let systemInput = makeAudioInput()
        guard writer.canAdd(systemInput) else {
            throw RecordingError.writerFailed("System audio input could not be added.")
        }
        writer.add(systemInput)
        self.systemInput = systemInput

        if #available(macOS 15.0, *), source == .micAndSystem {
            let microphoneInput = makeAudioInput()
            guard writer.canAdd(microphoneInput) else {
                throw RecordingError.writerFailed("Microphone audio input could not be added.")
            }
            writer.add(microphoneInput)
            self.microphoneInput = microphoneInput
        }

        guard writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "Writer failed to start.")
        }
        self.writer = writer

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if #available(macOS 15.0, *), source == .micAndSystem {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async throws {
        var stopError: Error?
        defer {
            stream = nil
            writer = nil
            systemInput = nil
            microphoneInput = nil
            didStartSession = false
            onLevelUpdate?(0)
            onSourceLevelUpdate?(.system, 0)
        }

        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                stopError = error
            }
        }
        if let writer, !didStartSession {
            writer.startSession(atSourceTime: .zero)
            didStartSession = true
        }
        systemInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        do {
            try await finishWriter()
        } catch {
            stopError = stopError ?? error
        }
        if let stopError {
            throw stopError
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        let input: AVAssetWriterInput?
        if type == .audio {
            input = systemInput
        } else if #available(macOS 15.0, *), type == .microphone {
            input = microphoneInput
        } else {
            input = nil
        }
        guard let writer, let input else {
            return
        }
        if !didStartSession {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            didStartSession = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
            let level = AudioSampleLevelMeter.normalizedLevel(from: sampleBuffer)
            onLevelUpdate?(level)
            onSourceLevelUpdate?(signalChannel(for: type), level)
        }
    }

    private func signalChannel(for type: SCStreamOutputType) -> AudioSignalChannel {
        if #available(macOS 15.0, *), type == .microphone {
            return .microphone
        }
        return .system
    }

    private func makeAudioInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }

    private func finishWriter() async throws {
        guard let writer else { return }
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if writer.status == .failed {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "Writer failed.")
        }
    }
}
