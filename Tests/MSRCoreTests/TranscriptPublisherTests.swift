import AVFoundation
import Foundation
import Testing
@testable import MSRCore
@testable import MSRServices

/// `TranscriptPublisher` against a real `RecordingLibrary` in a temp folder.
@Suite("Transcript publisher")
@MainActor
struct TranscriptPublisherTests {
    private static let transcript = """
    Speaker 1:
    Okay, hello everyone.

    Speaker 2:
    Today we're going to discuss the launch date and onboarding owner for the mobile app.
    """

    @Test func defaultTitleWithRemoteTitleIsRenamedAsGenerated() async throws {
        let fixture = try PublisherFixture()
        let recording = try fixture.makeRecording(name: "Meeting 2026-06-29 14.05")
        let job = fixture.queuedJob(for: recording)
        var checkpoints: [TranscriptionJob] = []

        let result = try await TranscriptPublisher.publish(
            job: job,
            recording: recording,
            decoded: TranscribeResponse(text: Self.transcript, provider: .elevenLabs, languageCode: "en"),
            autoTitleRequested: true,
            library: fixture.library,
            titleGenerator: { _ in "Title: \"Launch Readiness Review.\"" },
            checkpoint: { checkpoints.append($0) }
        )

        #expect(result.generatedTitle == "Launch Readiness Review")
        #expect(result.titleSource == .generated)
        #expect(result.recording.displayName == "Launch Readiness Review")
        #expect(result.job.status == .completed)
        #expect(result.job.recordingName == "Launch Readiness Review")
        #expect(!result.segments.isEmpty)
        // publishing checkpoint (hash) first, completed before the rename, then the name update.
        #expect(checkpoints.first?.transcriptContentSHA256 == TranscriptPublisher.sha256(Self.transcript))
        #expect(checkpoints.first?.status == .running)
        #expect(checkpoints.count == 3)
        #expect(checkpoints[1].status == .completed)
        #expect(checkpoints[1].recordingName == recording.displayName)

        let reloaded = try #require(try fixture.library.loadRecordings().first)
        #expect(reloaded.displayName == "Launch Readiness Review")
        #expect(reloaded.metadata.titleSource == .generated)
        #expect(try String(contentsOf: reloaded.transcriptURL, encoding: .utf8) == Self.transcript)
    }

    @Test func defaultTitleWithoutRemoteUsesLocalHeuristic() async throws {
        let fixture = try PublisherFixture()
        let recording = try fixture.makeRecording(name: "Meeting 2026-06-29 14.05")
        let segments = TranscriptParser.segments(from: Self.transcript)
        let expected = try #require(MeetingTitleGenerator.localTitle(from: Self.transcript, segments: segments))

        let result = try await TranscriptPublisher.publish(
            job: fixture.queuedJob(for: recording),
            recording: recording,
            decoded: TranscribeResponse(text: Self.transcript, provider: .elevenLabs, languageCode: "en"),
            autoTitleRequested: true,
            library: fixture.library,
            titleGenerator: nil
        )

        #expect(result.generatedTitle == expected)
        #expect(result.titleSource == .generated)
        #expect(!MeetingTitleGenerator.isDefaultName(result.recording.displayName))
        #expect(result.job.status == .completed)
    }

    @Test func userRenamedRecordingIsNotRetitled() async throws {
        let fixture = try PublisherFixture()
        let original = try fixture.makeRecording(name: "Meeting 2026-06-29 14.05")
        let userRenamed = try fixture.library.rename(original, to: "Client Demo")
        var remoteCalls = 0

        // The job holds the stale (pre-rename) snapshot, as when the user
        // renames while transcription is running.
        let result = try await TranscriptPublisher.publish(
            job: fixture.queuedJob(for: original),
            recording: original,
            decoded: TranscribeResponse(text: Self.transcript, provider: .elevenLabs, languageCode: "en"),
            autoTitleRequested: true,
            library: fixture.library,
            titleGenerator: { _ in
                remoteCalls += 1
                return "Generated Title"
            }
        )

        #expect(userRenamed.metadata.titleSource == .user)
        #expect(result.generatedTitle == nil)
        #expect(result.titleSource == .user)
        #expect(result.recording.displayName == "Client Demo")
        #expect(remoteCalls == 0)
        #expect(result.job.status == .completed)
        #expect(try fixture.library.loadRecordings().first?.displayName == "Client Demo")
    }

    @Test func remoteFailureFallsBackToLocalAndJobStillCompletes() async throws {
        let fixture = try PublisherFixture()
        let recording = try fixture.makeRecording(name: "Meeting 2026-06-29 14.05")
        let segments = TranscriptParser.segments(from: Self.transcript)
        let expected = try #require(MeetingTitleGenerator.localTitle(from: Self.transcript, segments: segments))

        let result = try await TranscriptPublisher.publish(
            job: fixture.queuedJob(for: recording),
            recording: recording,
            decoded: TranscribeResponse(text: Self.transcript, provider: .openAI, languageCode: "en"),
            autoTitleRequested: true,
            library: fixture.library,
            titleGenerator: { _ in throw URLError(.timedOut) }
        )

        #expect(result.job.status == .completed)
        #expect(result.generatedTitle == expected)
        #expect(result.titleSource == .generated)
        #expect(result.titleNote?.contains("remote title failed") == true)
    }

    @Test func autoTitleOffKeepsDefaultTitle() async throws {
        let fixture = try PublisherFixture()
        let recording = try fixture.makeRecording(name: "Meeting 2026-06-29 14.05")

        let result = try await TranscriptPublisher.publish(
            job: fixture.queuedJob(for: recording),
            recording: recording,
            decoded: TranscribeResponse(text: Self.transcript, provider: .elevenLabs, languageCode: "en"),
            autoTitleRequested: false,
            library: fixture.library,
            titleGenerator: { _ in "Should Not Be Used" }
        )

        #expect(result.generatedTitle == nil)
        #expect(result.titleSource == .default)
        #expect(result.recording.displayName == "Meeting 2026-06-29 14.05")
    }

    @Test func replacingTranscriptClearsSummary() async throws {
        let fixture = try PublisherFixture()
        let recording = try fixture.library.rename(try fixture.makeRecording(name: "Meeting 2026-06-29 14.05"), to: "Weekly Sync")
        let withTranscript = try fixture.library.writeTranscript("old transcript", for: recording)
        let withSummary = try fixture.library.writeSummary("## Old summary", for: withTranscript)
        #expect(FileManager.default.fileExists(atPath: withSummary.summaryURL.path))

        var job = fixture.queuedJob(for: withSummary)
        job.replacingExistingTranscript = true
        let result = try await TranscriptPublisher.publish(
            job: job,
            recording: withSummary,
            decoded: TranscribeResponse(text: Self.transcript, provider: .elevenLabs, languageCode: "en"),
            autoTitleRequested: true,
            library: fixture.library,
            titleGenerator: nil
        )

        #expect(!FileManager.default.fileExists(atPath: result.recording.summaryURL.path))
        #expect(try String(contentsOf: result.recording.transcriptURL, encoding: .utf8) == Self.transcript)
        #expect(result.recording.displayName == "Weekly Sync")
        #expect(result.titleSource == .user)
    }

    @Test func recoveryCompletesCheckpointedJobAndAppliesSkippedSideEffects() async throws {
        let fixture = try PublisherFixture()
        let recording = try fixture.makeRecording(name: "Meeting 2026-06-29 14.05")
        let withSummary = try fixture.library.writeSummary("## Old summary", for: recording)
        let published = try fixture.library.writeTranscriptBundle(
            Self.transcript,
            segments: TranscriptParser.segments(from: Self.transcript),
            for: withSummary
        )
        var job = fixture.queuedJob(for: published)
        job.replacingExistingTranscript = true
        job.markPublishing(
            transcriptFileName: published.transcriptURL.lastPathComponent,
            contentSHA256: TranscriptPublisher.sha256(Self.transcript)
        )
        job.markInterruptedIfRunning()

        let result = try #require(TranscriptPublisher.recoverIfPublished(job: job, recording: published, library: fixture.library))
        #expect(result.job.status == .completed)
        #expect(result.titleSource == .generated)
        #expect(result.generatedTitle != nil)
        #expect(!FileManager.default.fileExists(atPath: result.recording.summaryURL.path))

        var mismatched = job
        mismatched.transcriptContentSHA256 = TranscriptPublisher.sha256("something else")
        #expect(TranscriptPublisher.recoverIfPublished(job: mismatched, recording: published, library: fixture.library) == nil)
    }
}

@MainActor
private struct PublisherFixture {
    let folder: PublisherTestFolder
    let library: RecordingLibrary

    init() throws {
        folder = try PublisherTestFolder()
        library = RecordingLibrary(folderURL: folder.url)
    }

    func makeRecording(name: String) throws -> RecordingItem {
        let wav = folder.url.appendingPathComponent("capture-\(UUID().uuidString).wav")
        try makeToneWAV(at: wav, duration: 1)
        return try library.finishRecording(
            temporaryAudioURL: wav,
            requestedName: name,
            source: .micAndSystem,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_060)
        )
    }

    func queuedJob(for recording: RecordingItem) -> TranscriptionJob {
        var job = TranscriptionJob.queue(
            recordingID: recording.id,
            recordingName: recording.displayName,
            audioFileName: recording.audioURL.lastPathComponent,
            provider: .elevenLabs,
            origin: .automatic,
            autoTitleRequested: true
        )
        job.markRunning()
        return job
    }
}

private func makeToneWAV(at url: URL, duration: TimeInterval) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let frameCount = AVAudioFrameCount(duration * format.sampleRate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    let channel = try #require(buffer.floatChannelData?[0])
    for frame in 0..<Int(frameCount) {
        let phase = 2.0 * Double.pi * 440.0 * Double(frame) / format.sampleRate
        channel[frame] = Float(0.1 * sin(phase))
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private final class PublisherTestFolder: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("msr-publisher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
