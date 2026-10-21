import AppKit
import Combine
import Foundation
import Testing
import MSRCore
import MSRServices
@testable import MSRMeetingRecorder

/// Phase 2 structure: high-frequency state lives outside `AppViewModel`, and
/// library loads run off the main actor without losing ordering guarantees.
@Suite("Live state and off-main library loads", .serialized)
@MainActor
struct LiveStateAndLoaderTests {
    @Test func meterTicksPublishOnLiveStateOnlyAndStopPublishesBeforeReturning() async throws {
        let fixture = try ModelFixture()
        let model = fixture.makeModel()
        model.selectedSource = .microphone
        var modelChanges = 0
        var liveChanges = 0
        let modelSink = model.objectWillChange.sink { _ in modelChanges += 1 }
        let liveSink = model.live.objectWillChange.sink { _ in liveChanges += 1 }
        defer { modelSink.cancel(); liveSink.cancel() }

        await model.startRecording()
        #expect(model.isRecording)
        modelChanges = 0
        liveChanges = 0
        // The replay recorder reports a level every 100 ms.
        for _ in 0..<40 where liveChanges < 3 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(liveChanges >= 3)
        #expect(modelChanges == 0)

        await model.stopRecording()
        // `finishRecording` and the reload ran off the main actor, but the new
        // recording is listed and selected by the time the stop returns.
        #expect(model.workflowState == .saved)
        #expect(model.recordings.count == 1)
        #expect(model.selectedRecording?.id == model.recordings.first?.id)
    }

    @Test func playbackStateIsSeparateAndForwarded() throws {
        let fixture = try ModelFixture()
        let model = fixture.makeModel()
        var modelChanges = 0
        let sink = model.objectWillChange.sink { _ in modelChanges += 1 }
        defer { sink.cancel() }
        model.trimStartSeconds = 2
        model.playback.trimEndSeconds = 5
        model.playback.playbackPosition = 1.5
        #expect(model.playback.trimStartSeconds == 2)
        #expect(model.trimEndSeconds == 5)
        #expect(model.playbackPosition == 1.5)
        #expect(modelChanges == 0)
    }

    @Test func asyncRefreshMatchesSyncLoadAndDropsAStaleResult() async throws {
        let fixture = try ModelFixture()
        _ = try fixture.addRecording(name: "First")
        let model = fixture.makeModel()
        await model.refreshLibrary()
        #expect(model.recordings.map(\.displayName) == ["First"])
        #expect(model.libraryFolderSnapshot == LibraryFolderSnapshot.capture(folderURL: fixture.folder))

        // A background load that is still running when a newer (sync) load
        // finishes must not publish its older result over it.
        let gate = Gate()
        let stale = Task { await model.refreshLibrary(beforeLoad: { gate.enterAndWait() }) }
        while !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        let second = try fixture.addRecording(name: "Second")
        model.loadRecordings()
        #expect(model.recordings.count == 2)
        try RecordingLibrary(folderURL: fixture.folder).delete(second)
        gate.release()
        await stale.value
        #expect(model.recordings.count == 2, "the superseded load was applied")

        await model.refreshLibrary()
        #expect(model.recordings.map(\.displayName) == ["First"])
    }

    @Test func importingSeveralFilesReloadsOnceAndSelectsTheLast() async throws {
        let fixture = try ModelFixture()
        let model = fixture.makeModel()
        let first = fixture.folder.deletingLastPathComponent().appendingPathComponent("import-a-\(UUID().uuidString).m4a")
        let second = fixture.folder.deletingLastPathComponent().appendingPathComponent("import-b-\(UUID().uuidString).m4a")
        try FileManager.default.copyItem(at: ModelFixture.clip, to: first)
        try FileManager.default.copyItem(at: ModelFixture.clip, to: second)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        await model.importRecordings(from: [first, second])
        #expect(model.recordings.count == 2)
        #expect(model.selectedRecording?.displayName == second.deletingPathExtension().lastPathComponent)
        #expect(model.workflowState == .saved)
        #expect(model.libraryFolderSnapshot == LibraryFolderSnapshot.capture(folderURL: fixture.folder))
    }

    @Test func aLoadThatReadBeforeARenameDoesNotPutTheOldTitleBack() async throws {
        let fixture = try ModelFixture()
        _ = try fixture.addRecording(name: "Before")
        let library = GatedLibrary(folderURL: fixture.folder)
        let model = fixture.makeModel(library: library)
        model.loadRecordings()
        model.select(try #require(model.recordings.first))

        // A background load has read the library and is about to publish it…
        library.armGate()
        let load = Task { await model.refreshLibrary() }
        while !library.gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        // …when the user renames the recording (patched into memory at once).
        model.renameDraft = "After"
        model.applyRename()
        #expect(model.recordings.map(\.displayName) == ["After"])
        library.gate.release()
        await load.value
        // The stale result was discarded and the load re-run.
        #expect(model.recordings.map(\.displayName) == ["After"])
        #expect(model.selectedRecording?.displayName == "After")
        #expect(model.libraryFolderSnapshot == LibraryFolderSnapshot.capture(folderURL: fixture.folder))
    }

    @Test func anIdleOnlyLoadSupersedingARequiredOneStillAppliesWhileBusy() async throws {
        let fixture = try ModelFixture()
        _ = try fixture.addRecording(name: "First")
        let model = fixture.makeModel()
        await model.refreshLibrary()
        let gate = Gate()
        let required = Task { await model.refreshLibrary(beforeLoad: { gate.enterAndWait() }) }
        while !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        _ = try fixture.addRecording(name: "Second")
        model.workflowState = .transcribing
        // A folder-watcher style refresh supersedes the required load.
        let idle = Task { await model.refreshLibrary(onlyWhenIdle: true) }
        try await Task.sleep(for: .milliseconds(50))
        gate.release()
        await required.value
        #expect(model.recordings.count == 2, "the superseded caller returned without a newer library")
        await idle.value
        model.workflowState = .ready
    }

    @Test func anOutsideTranscriptEditIsNotHiddenByAnOwnSummaryWrite() throws {
        let fixture = try ModelFixture()
        let recording = try fixture.addRecording(name: "Notes")
        let model = fixture.makeModel()
        model.loadRecordings()
        model.select(try #require(model.recordings.first))
        #expect(model.libraryFolderSnapshot == LibraryFolderSnapshot.capture(folderURL: fixture.folder))
        // Someone else writes the transcript, then the app saves a summary edit.
        try Data("Speaker 1:\nWritten elsewhere".utf8).write(to: recording.transcriptURL)
        model.summaryText = "Mine"
        model.flushSummaryEdits()
        #expect(model.libraryFolderSnapshot != LibraryFolderSnapshot.capture(folderURL: fixture.folder))
    }

    @Test func savedJobsUpdateMemoryInLoadAllOrder() throws {
        let fixture = try ModelFixture()
        let recording = try fixture.addRecording(name: "Jobs")
        let store = TranscriptionJobStore(folderURL: fixture.folder)
        var older = TranscriptionJob.queue(
            recordingID: UUID(), recordingName: "Other", audioFileName: "other.m4a", provider: .elevenLabs
        )
        older.markFailed("x")
        try store.save(older)
        try store.save(TranscriptionJob.queue(
            recordingID: recording.id, recordingName: recording.displayName,
            audioFileName: recording.audioURL.lastPathComponent, provider: .elevenLabs
        ))
        let model = fixture.makeModel()
        model.loadRecordings()
        #expect(model.job(for: recording.id)?.status == .queued)

        model.cancelTranscription(recordingID: recording.id)
        #expect(model.job(for: recording.id)?.status == .cancelled)
        // Same jobs as on disk, newest first (same-second ties keep no particular order).
        let onDisk = try store.loadAll()
        #expect(model.transcriptionJobs.sorted { $0.id.uuidString < $1.id.uuidString }
            == onDisk.sorted { $0.id.uuidString < $1.id.uuidString })
        #expect(model.transcriptionJobs.map(\.updatedAt) == onDisk.map(\.updatedAt))
        #expect(model.libraryFolderSnapshot == LibraryFolderSnapshot.capture(folderURL: fixture.folder))
    }

    @Test func durableWritesAndRecoveringReadsDoNotRaceAcrossThreads() async throws {
        let fixture = try ModelFixture()
        let url = fixture.folder.appendingPathComponent("counter.json")
        try DurableFile.write(Data("0".utf8), to: url)
        let rounds = 300
        // Before `LibraryIO`, a read landing between the primary→backup and
        // temp→primary moves "recovered" the stale backup over the new file.
        async let writes: Void = Task.detached {
            for value in 1...rounds { try? DurableFile.write(Data("\(value)".utf8), to: url) }
        }.value
        async let reads: Void = Task.detached {
            for _ in 0..<(rounds * 2) {
                _ = DurableFile.readRecoveringBackup(Int.self, from: url, decoder: JSONDecoder())
            }
        }.value
        _ = await (writes, reads)
        let final = try Data(contentsOf: url)
        #expect(String(decoding: final, as: UTF8.self) == "\(rounds)")
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent(".corrupt").path))
    }
}

/// A one-shot barrier the loader's `beforeLoad` hook blocks on.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didEnter = false

    var entered: Bool { lock.withLock { didEnter } }

    func enterAndWait() {
        lock.withLock { didEnter = true }
        semaphore.wait()
    }

    func release() { semaphore.signal() }
}

@MainActor
private final class ModelFixture {
    static let clip = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/meeting-en.m4a")
    let folder: URL

    init() throws {
        _ = NSApplication.shared
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("msr-phase2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func makeModel() -> AppViewModel {
        let model = AppViewModel(recorder: FileReplayRecorder(clipURL: Self.clip), recordingsFolderOverride: folder)
        model.settingsPersistenceSuspended = true
        return model
    }

    func makeModel(library: GatedLibrary) -> AppViewModel {
        let model = AppViewModel(
            recorder: FileReplayRecorder(clipURL: Self.clip),
            libraryFactory: { _ in library },
            recordingsFolderOverride: folder
        )
        model.settingsPersistenceSuspended = true
        return model
    }

    func addRecording(name: String) throws -> RecordingItem {
        let capture = folder.appendingPathComponent("capture-\(UUID().uuidString).m4a")
        try FileManager.default.copyItem(at: Self.clip, to: capture)
        return try RecordingLibrary(folderURL: folder).finishRecording(
            temporaryAudioURL: capture, requestedName: name, source: .microphone,
            startedAt: Date(), endedAt: Date().addingTimeInterval(5)
        )
    }
}

/// A `RecordingLibrary` whose next `loadRecordings()` (once armed) blocks on
/// `gate` after reading, outside `LibraryIO`: a background load that has read
/// the library but not yet published it.
private final class GatedLibrary: RecordingLibraryServing, @unchecked Sendable {
    let base: RecordingLibrary
    let gate = Gate()
    private let lock = NSLock()
    private var armed = false

    init(folderURL: URL) { base = RecordingLibrary(folderURL: folderURL) }

    func armGate() { lock.withLock { armed = true } }

    var folderURL: URL { base.folderURL }

    func loadRecordings() throws -> [RecordingItem] {
        let loaded = try base.loadRecordings()
        let block = lock.withLock { () -> Bool in
            defer { armed = false }
            return armed
        }
        if block { gate.enterAndWait() }
        return loaded
    }

    func finishRecording(
        temporaryAudioURL: URL, requestedName: String, source: AudioSource,
        startedAt: Date, endedAt: Date, durationSecondsOverride: TimeInterval?,
        recoveredAt: Date?, recoveryNote: String?, segmentCount: Int?,
        confidenceReport: RecordingConfidenceReport?, recordingID: UUID?
    ) throws -> RecordingItem {
        try base.finishRecording(
            temporaryAudioURL: temporaryAudioURL, requestedName: requestedName, source: source,
            startedAt: startedAt, endedAt: endedAt, durationSecondsOverride: durationSecondsOverride,
            recoveredAt: recoveredAt, recoveryNote: recoveryNote, segmentCount: segmentCount,
            confidenceReport: confidenceReport, recordingID: recordingID
        )
    }

    func importRecording(
        sourceURL: URL, requestedName: String, source: AudioSource,
        startedAt: Date, durationSeconds: TimeInterval, importedAt: Date,
        confidenceReport: RecordingConfidenceReport?
    ) throws -> RecordingItem {
        try base.importRecording(
            sourceURL: sourceURL, requestedName: requestedName, source: source,
            startedAt: startedAt, durationSeconds: durationSeconds, importedAt: importedAt,
            confidenceReport: confidenceReport
        )
    }

    func rename(_ recording: RecordingItem, to requestedName: String) throws -> RecordingItem {
        try base.rename(recording, to: requestedName)
    }

    func rename(_ recording: RecordingItem, to requestedName: String, source: RecordingTitleSource) throws -> RecordingItem {
        try base.rename(recording, to: requestedName, source: source)
    }

    func renameIfTitleIsDefault(_ recording: RecordingItem, to newName: String) throws -> RecordingItem? {
        try base.renameIfTitleIsDefault(recording, to: newName)
    }

    func migrateIfNeeded(_ recording: RecordingItem) throws -> RecordingItem { try base.migrateIfNeeded(recording) }

    func writeTranscript(_ transcript: String, for recording: RecordingItem) throws -> RecordingItem {
        try base.writeTranscript(transcript, for: recording)
    }

    func writeTranscriptBundle(_ transcript: String, segments: [TranscriptSegment], for recording: RecordingItem) throws -> RecordingItem {
        try base.writeTranscriptBundle(transcript, segments: segments, for: recording)
    }

    func loadTranscriptSegments(for recording: RecordingItem) -> [TranscriptSegment] { base.loadTranscriptSegments(for: recording) }

    func writeSummary(_ summary: String, for recording: RecordingItem) throws -> RecordingItem {
        try base.writeSummary(summary, for: recording)
    }

    func clearSummary(for recording: RecordingItem) throws -> RecordingItem { try base.clearSummary(for: recording) }

    func renameSpeaker(_ recording: RecordingItem, label: String, to name: String) throws -> RecordingItem {
        try base.renameSpeaker(recording, label: label, to: name)
    }

    func resetSpeakerNames(for recording: RecordingItem) throws -> RecordingItem { try base.resetSpeakerNames(for: recording) }

    func resetAllSpeakerNames(for recording: RecordingItem) throws -> RecordingItem { try base.resetAllSpeakerNames(for: recording) }

    func delete(_ recording: RecordingItem) throws { try base.delete(recording) }

    func loadWaveformCache(for recording: RecordingItem, bucketCount: Int) -> [Float]? {
        base.loadWaveformCache(for: recording, bucketCount: bucketCount)
    }

    func storeWaveformCache(_ samples: [Float], for recording: RecordingItem) throws {
        try base.storeWaveformCache(samples, for: recording)
    }

    func storeWaveformCache(_ samples: [Float], for recording: RecordingItem, scannedAudio: WaveformCacheFile.AudioStamp) throws -> Bool {
        try base.storeWaveformCache(samples, for: recording, scannedAudio: scannedAudio)
    }
}
