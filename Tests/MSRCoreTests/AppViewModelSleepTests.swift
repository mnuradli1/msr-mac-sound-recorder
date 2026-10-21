import AppKit
import AVFoundation
import Foundation
import Testing
import MSRCore
import MSRServices
@testable import MSRMeetingRecorder

/// Exercises the actual view-model lifecycle with synthetic media and a private library.
/// No real microphone, ScreenCaptureKit stream, user library, or provider is used.
@Suite("App sleep lifecycle", .serialized)
@MainActor
struct AppViewModelSleepTests {
    @Test func activeSleepPublishesAndWakeDoesNotDuplicate() async throws {
        let fixture = try await SleepFixture()
        let model = fixture.model
        await model.startRecording()
        #expect(model.isRecording)
        await model.suspendForSystemSleep()
        #expect(model.workflowState == .saved)
        #expect(fixture.recorder.stopCount == 1)
        #expect(try fixture.library.loadRecordings().count == 1)
        #expect(try fixture.manifests.loadAll().isEmpty)
        await model.startRecording()
        #expect(fixture.recorder.startCount == 1)
        await model.resumeAfterSystemWake()
        await model.resumeAfterSystemWake()
        #expect(try fixture.library.loadRecordings().count == 1)
    }

    @Test func manuallyPausedSessionIsSavedWithoutStoppingTwice() async throws {
        let fixture = try await SleepFixture()
        await fixture.model.startRecording()
        await fixture.model.pauseRecording()
        #expect(fixture.model.workflowState.isPaused)
        await fixture.model.suspendForSystemSleep()
        #expect(fixture.model.workflowState == .saved)
        #expect(fixture.recorder.stopCount == 1)
        #expect(try fixture.library.loadRecordings().count == 1)
    }

    @Test func sleepDuringStartSurvivesWakeBeforeStartCompletes() async throws {
        let fixture = try await SleepFixture()
        let barrier = SleepTestBarrier()
        fixture.recorder.startBarrier = barrier
        let starting = Task { await fixture.model.startRecording() }
        await barrier.waitUntilEntered()
        let sleeping = Task { await fixture.model.suspendForSystemSleep() }
        try await waitForSleepRequest(fixture.model)
        let waking = Task { await fixture.model.resumeAfterSystemWake() }
        await settleActor()
        await barrier.release()
        await starting.value
        await sleeping.value
        await waking.value
        #expect(fixture.recorder.startCount == 1)
        #expect(fixture.recorder.stopCount == 1)
        #expect(fixture.model.workflowState == .saved)
        #expect(try fixture.library.loadRecordings().count == 1)
    }

    @Test func sleepDuringManualStopPublishesOnlyOnce() async throws {
        let fixture = try await SleepFixture()
        await fixture.model.startRecording()
        let barrier = SleepTestBarrier()
        fixture.recorder.stopBarrier = barrier
        let stopping = Task { await fixture.model.stopRecording() }
        await barrier.waitUntilEntered()
        let sleeping = Task { await fixture.model.suspendForSystemSleep() }
        try await waitForSleepRequest(fixture.model)
        let waking = Task { await fixture.model.resumeAfterSystemWake() }
        await barrier.release()
        await stopping.value
        await sleeping.value
        await waking.value
        #expect(fixture.recorder.stopCount == 1)
        #expect(fixture.model.workflowState == .saved)
        #expect(try fixture.library.loadRecordings().count == 1)
    }

    @Test func sleepDuringManualPauseSavesCompletedSegment() async throws {
        let fixture = try await SleepFixture()
        await fixture.model.startRecording()
        let barrier = SleepTestBarrier()
        fixture.recorder.stopBarrier = barrier
        let pausing = Task { await fixture.model.pauseRecording() }
        await barrier.waitUntilEntered()
        let sleeping = Task { await fixture.model.suspendForSystemSleep() }
        try await waitForSleepRequest(fixture.model)
        await barrier.release()
        await pausing.value
        await sleeping.value
        #expect(fixture.recorder.stopCount == 1)
        #expect(fixture.model.workflowState == .saved)
        #expect(try fixture.library.loadRecordings().count == 1)
    }

    @Test func sleepDuringResumeSavesBothSegments() async throws {
        let fixture = try await SleepFixture()
        await fixture.model.startRecording()
        await fixture.model.pauseRecording()
        let barrier = SleepTestBarrier()
        fixture.recorder.startBarrier = barrier
        let resuming = Task { await fixture.model.toggleRecording() }
        await barrier.waitUntilEntered()
        let sleeping = Task { await fixture.model.suspendForSystemSleep() }
        try await waitForSleepRequest(fixture.model)
        await barrier.release()
        await resuming.value
        await sleeping.value
        #expect(fixture.recorder.startCount == 2)
        #expect(fixture.recorder.stopCount == 2)
        #expect(fixture.model.workflowState == .saved)
        let recordings = try fixture.library.loadRecordings()
        #expect(recordings.count == 1)
        #expect(recordings.first?.metadata.segmentCount == 2)
    }

    @Test func stopFailurePreservesAudioAndWakeRecoversWithoutDuplicate() async throws {
        let fixture = try await SleepFixture()
        await fixture.model.startRecording()
        fixture.recorder.failStop = true
        await fixture.model.suspendForSystemSleep()
        #expect(fixture.model.workflowErrorMessage != nil)
        #expect(!fixture.model.recoveryMessage.isEmpty)
        #expect(!fixture.recorder.isRecording)
        let manifest = try #require(fixture.manifests.loadAll().first)
        let active = try #require(manifest.activeSegment)
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent(active.fileName).path))
        await fixture.model.resumeAfterSystemWake()
        #expect(try fixture.library.loadRecordings().count == 1)
        await fixture.model.resumeAfterSystemWake()
        #expect(try fixture.library.loadRecordings().count == 1)
        #expect(try fixture.manifests.loadAll().isEmpty)
    }

    @Test func unavailableLibraryCheckpointStillStopsCapture() async throws {
        let fixture = try await SleepFixture()
        await fixture.model.startRecording()
        let manifest = try #require(fixture.manifests.loadAll().first)
        let active = try #require(manifest.activeSegment)
        let offline = fixture.folder.appendingPathExtension("offline")
        try FileManager.default.moveItem(at: fixture.folder, to: offline)
        try Data("Synthetic unavailable library".utf8).write(to: fixture.folder)
        defer {
            try? FileManager.default.removeItem(at: fixture.folder)
            try? FileManager.default.moveItem(at: offline, to: fixture.folder)
        }
        await fixture.model.suspendForSystemSleep()
        #expect(fixture.model.workflowErrorMessage != nil)
        #expect(!fixture.model.recoveryMessage.isEmpty)
        #expect(!fixture.recorder.isRecording)
        #expect(fixture.recorder.stopCount == 1)
        #expect(FileManager.default.fileExists(atPath: offline.appendingPathComponent(active.fileName).path))
    }

    @Test func lateFailureFromPausedSegmentDoesNotStopResumedCapture() async throws {
        let fixture = try await SleepFixture()
        await fixture.model.startRecording()
        let oldFailure = try #require(fixture.recorder.onCaptureFailure)
        await fixture.model.pauseRecording()
        await fixture.model.toggleRecording()
        oldFailure(RecordingError.captureInterrupted("Synthetic delayed failure from previous segment"))
        await settleActor()
        #expect(fixture.model.isRecording)
        #expect(fixture.recorder.stopCount == 1)
        await fixture.model.stopRecording()
        #expect(try fixture.library.loadRecordings().count == 1)
    }

    @Test func failedResumeThenSleepRetainsThePartiallyStartedSegment() async throws {
        let fixture = try await SleepFixture()
        await fixture.model.startRecording()
        await fixture.model.pauseRecording()
        fixture.recorder.failStartAfterWriting = true
        await fixture.model.toggleRecording()
        #expect(fixture.model.workflowErrorMessage != nil)
        let manifest = try #require(fixture.manifests.loadAll().first)
        #expect(manifest.completedSegments.count == 1)
        #expect(manifest.activeSegment != nil)
        await fixture.model.suspendForSystemSleep()
        await fixture.model.resumeAfterSystemWake()
        let recordings = try fixture.library.loadRecordings()
        #expect(recordings.count == 1)
        #expect(recordings.first?.metadata.segmentCount == 2)
        let recording = try #require(recordings.first)
        let duration = try await AVURLAsset(url: recording.audioURL).load(.duration).seconds
        #expect(duration > 7.5)
    }

    private func waitForSleepRequest(_ model: AppViewModel) async throws {
        for _ in 0..<1_000 {
            if model.sleepSafetyPending { return }
            await Task.yield()
        }
        try #require(model.sleepSafetyPending)
    }

    private func settleActor() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
private final class SleepFixture {
    let folder: URL
    let recorder: SleepFixtureRecorder
    let model: AppViewModel
    var library: RecordingLibrary { RecordingLibrary(folderURL: folder) }
    var manifests: RecordingSessionManifestStore { RecordingSessionManifestStore(folderURL: folder) }

    init() async throws {
        _ = NSApplication.shared
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("msr-sleep-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wave = folder.appendingPathComponent("synthetic-source.wav")
        try Self.writeSyntheticAudio(to: wave)
        let media = folder.appendingPathComponent("synthetic-source.m4a")
        try await AudioTrackMixer.mixToSingleM4A(inputs: [wave], outputURL: media)
        recorder = SleepFixtureRecorder(fixture: media)
        model = AppViewModel(recorder: recorder, recordingsFolderOverride: folder)
        model.selectedSource = .microphone
    }

    private static func writeSyntheticAudio(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = Float(0.15 * sin(2 * .pi * 440 * Double(frame) / 48_000))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

private final class SleepFixtureRecorder: AudioRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var recording = false
    private var starts = 0
    private var stops = 0
    private let fixture: URL
    var startBarrier: SleepTestBarrier?
    var stopBarrier: SleepTestBarrier?
    var failStop = false
    var failStartAfterWriting = false
    var onLevelUpdate: (@Sendable (Float) -> Void)?
    var onSourceLevelUpdate: (@Sendable (AudioSignalChannel, Float) -> Void)?
    var onCaptureFailure: (@Sendable (Error) -> Void)?
    var isRecording: Bool { lock.withLock { recording } }
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    init(fixture: URL) { self.fixture = fixture }

    func start(source: AudioSource, outputURL: URL) async throws {
        lock.withLock { starts += 1 }
        if let startBarrier { await startBarrier.enterAndWait() }
        try FileManager.default.copyItem(at: fixture, to: outputURL)
        lock.withLock { recording = true }
        if failStartAfterWriting { throw SleepFixtureError.startInterrupted }
    }

    func stop() async throws {
        lock.withLock { stops += 1 }
        if let stopBarrier { await stopBarrier.enterAndWait() }
        lock.withLock { recording = false }
        if failStop { throw SleepFixtureError.stopInterrupted }
    }
}

private enum SleepFixtureError: Error { case stopInterrupted, startInterrupted }

private actor SleepTestBarrier {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
