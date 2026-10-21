import AppKit
import Foundation
import Testing
import MSRCore
import MSRServices
@testable import MSRMeetingRecorder

/// Render-path state (row facts, job index, Read-mode cache, folder snapshot)
/// stays in memory and in step with the app's own writes.
@Suite("Render paths stay in memory", .serialized)
@MainActor
struct RenderPathTests {
    @Test func rowFactsJobIndexAndReadModeFollowTheAppsOwnWrites() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("msr-render-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/meeting-en.m4a")
        let capture = folder.appendingPathComponent("capture.m4a")
        try FileManager.default.copyItem(at: fixture, to: capture)
        let library = RecordingLibrary(folderURL: folder)
        let recording = try library.finishRecording(
            temporaryAudioURL: capture, requestedName: "Sync", source: .microphone,
            startedAt: Date(timeIntervalSince1970: 10), endedAt: Date(timeIntervalSince1970: 20)
        )

        let model = AppViewModel(recorder: FileReplayRecorder(clipURL: fixture), recordingsFolderOverride: folder)
        model.settingsPersistenceSuspended = true
        model.loadRecordings()
        let row = try #require(model.recordings.first)
        #expect(row.id == recording.id)
        #expect(!model.rowBadges(for: row).contains(.transcript))
        #expect(model.libraryFolderSnapshot == LibraryFolderSnapshot.capture(folderURL: folder))

        // A job file appearing on disk is not read by render paths until the
        // jobs are reloaded (the index is the single in-memory source).
        let job = TranscriptionJob.queue(
            recordingID: row.id, recordingName: row.displayName,
            audioFileName: row.audioURL.lastPathComponent, provider: .elevenLabs
        )
        try TranscriptionJobStore(folderURL: folder).save(job)
        #expect(model.job(for: row.id) == nil)
        #expect(model.jobChip(for: row) == nil)
        model.loadRecordings()
        #expect(model.job(for: row.id)?.id == job.id)
        #expect(model.jobChip(for: row)?.title == "Queued")

        // An edit saved by the app updates the row badge and is recorded as
        // the app's own write (the folder watcher will not reload for it).
        model.select(row)
        model.transcriptText = "Speaker 1: Hello there"
        model.flushTranscriptEdits()
        #expect(model.rowBadges(for: row).contains(.transcript))
        #expect(model.libraryFolderSnapshot == LibraryFolderSnapshot.capture(folderURL: folder))
        model.summaryText = "Notes"
        model.flushSummaryEdits()
        #expect(model.rowBadges(for: row).contains(.summary))
        #expect(model.libraryFolderSnapshot == LibraryFolderSnapshot.capture(folderURL: folder))

        // Read mode is parsed once and re-parsed after a text or segments change.
        let saved = [TranscriptSegment(speaker: "Speaker 1", startTime: 0, endTime: 1, text: "Hello there")]
        model.transcriptSegments = saved
        model.transcriptText = "Speaker 1:\nHello there"
        #expect(model.readModeTranscript.segments == saved)
        #expect(!model.readModeTranscript.isEdited)
        model.transcriptText = "Speaker 2:\nBye"
        #expect(model.readModeTranscript.isEdited)
        #expect(model.readModeSegments.map(\.speaker) == ["Speaker 2"])
        model.transcriptSegments = [TranscriptSegment(speaker: "Speaker 2", startTime: 0, endTime: 1, text: "Bye")]
        #expect(!model.readModeTranscript.isEdited)
        #expect(model.readModeSegments.first?.startTime == 0)
    }
}
