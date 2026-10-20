import AVFoundation
import Foundation
import Testing
import MSRCore
import MSRServices

@Suite("Recording recovery hardening")
struct RecoveryHardeningTests {
    @Test func corruptManifestDoesNotBlockValidManifest() async throws {
        let folder = try RecoveryTestFolder()
        let segment = try await folder.makeSegment(named: ".in-progress-microphone-valid.m4a", duration: 0.4)
        let store = RecordingSessionManifestStore(folderURL: folder.url)
        let valid = makeManifest(id: "44444444-4444-4444-4444-444444444444", name: "Valid Session", segments: [segment])
        try store.save(valid)
        let corruptID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        try Data("{ this is not json".utf8).write(to: store.url(for: corruptID))

        let results = try await RecordingRecoveryService(folderURL: folder.url).recoverInterruptedRecordings(now: Date(timeIntervalSince1970: 2_000))
        let recordings = try RecordingLibrary(folderURL: folder.url).loadRecordings()

        #expect(recordings.map(\.displayName) == ["Valid Session"])
        #expect(results.contains { $0.status == .recoveredSession(segmentCount: 1) })
        #expect(results.contains { $0.status == .failed("Session manifest was unreadable.") })
        #expect(!FileManager.default.fileExists(atPath: store.url(for: corruptID).path))
        #expect(FileManager.default.fileExists(atPath: folder.failedURL(store.url(for: corruptID).lastPathComponent).path))
        #expect(!FileManager.default.fileExists(atPath: store.url(for: valid.id).path))
    }

    @Test func unreadableMiddleSegmentIsSkippedAndNoted() async throws {
        let folder = try RecoveryTestFolder()
        let first = try await folder.makeSegment(named: ".in-progress-micAndSystem-a.m4a", duration: 0.5, frequency: 440)
        let middle = folder.url.appendingPathComponent(".in-progress-micAndSystem-b.m4a")
        try Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: middle)
        let last = try await folder.makeSegment(named: ".in-progress-micAndSystem-c.m4a", duration: 0.7, frequency: 660)
        let store = RecordingSessionManifestStore(folderURL: folder.url)
        let manifest = makeManifest(
            id: "66666666-6666-6666-6666-666666666666",
            name: "Partial Session",
            source: .micAndSystem,
            segments: [first, middle, last],
            accumulatedActiveDuration: 120
        )
        try store.save(manifest)

        let results = try await RecordingRecoveryService(folderURL: folder.url).recoverInterruptedRecordings(now: Date(timeIntervalSince1970: 2_000))
        let recording = try #require(try RecordingLibrary(folderURL: folder.url).loadRecordings().first)

        #expect(results.count == 1)
        #expect(results.first?.status == .recoveredSession(segmentCount: 2))
        #expect(results.first?.failedFiles == [middle.lastPathComponent])
        #expect(recording.metadata.recoveryNote == "Recovered 2 of 3 segments; 1 unreadable segment was moved to recovery-failed.")
        #expect(recording.metadata.segmentCount == 2)
        #expect(recording.source == .micAndSystem)
        // Duration reflects the readable audio, not the manifest's 120 s (which includes the lost segment).
        #expect(abs(recording.durationSeconds - 1.2) < 0.25)
        let asset = AVURLAsset(url: recording.audioURL)
        let recoveredDuration = try await asset.load(.duration).seconds
        #expect(abs(recoveredDuration - 1.2) < 0.25)
        #expect(FileManager.default.fileExists(atPath: folder.failedURL(middle.lastPathComponent).path))
        for consumed in [first, middle, last] {
            #expect(!FileManager.default.fileExists(atPath: consumed.path))
        }
        #expect(!FileManager.default.fileExists(atPath: store.url(for: manifest.id).path))
    }

    @Test func allSegmentsUnreadableFailsTheSession() async throws {
        let folder = try RecoveryTestFolder()
        let garbage = folder.url.appendingPathComponent(".in-progress-microphone-bad.m4a")
        try Data("not audio".utf8).write(to: garbage)
        let store = RecordingSessionManifestStore(folderURL: folder.url)
        let manifest = makeManifest(id: "77777777-7777-7777-7777-777777777777", name: "Lost Session", segments: [garbage])
        try store.save(manifest)

        let results = try await RecordingRecoveryService(folderURL: folder.url).recoverInterruptedRecordings()

        #expect(results.count == 1)
        #expect(results.first?.status == .failed("Session manifest contained unreadable segment files."))
        #expect(try RecordingLibrary(folderURL: folder.url).loadRecordings().isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.failedURL(garbage.lastPathComponent).path))
    }

    @Test func completedFinalRecordingCleansLeftoverSegments() async throws {
        let folder = try RecoveryTestFolder()
        let first = try await folder.makeSegment(named: ".in-progress-micAndSystem-done-1.m4a", duration: 0.4)
        let second = try await folder.makeSegment(named: ".in-progress-micAndSystem-done-2.m4a", duration: 0.4)
        let micSide = try await folder.makeSegment(named: "..in-progress-micAndSystem-done-2-mic-AAA.m4a", duration: 0.4)
        let systemSide = try await folder.makeSegment(named: "..in-progress-micAndSystem-done-2-system-BBB.m4a", duration: 0.4)
        let published = try await folder.makeSegment(named: ".final-published.m4a", duration: 0.8)
        let finalID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let library = RecordingLibrary(folderURL: folder.url)
        let recording = try library.finishRecording(
            temporaryAudioURL: published,
            requestedName: "Already Published",
            source: .micAndSystem,
            startedAt: Date(timeIntervalSince1970: 500),
            endedAt: Date(timeIntervalSince1970: 501),
            recordingID: finalID
        )
        var manifest = makeManifest(
            id: "99999999-9999-9999-9999-999999999999",
            name: "Already Published",
            source: .micAndSystem,
            segments: [first, second]
        )
        manifest.finalRecordingID = finalID
        manifest.state = .finalizing
        manifest.microphoneFileName = micSide.lastPathComponent
        manifest.systemFileName = systemSide.lastPathComponent
        let store = RecordingSessionManifestStore(folderURL: folder.url)
        try store.save(manifest)

        let results = try await RecordingRecoveryService(folderURL: folder.url).recoverInterruptedRecordings()
        let recordings = try RecordingLibrary(folderURL: folder.url).loadRecordings()

        #expect(results.count == 1)
        #expect(results.first?.recording?.id == recording.id)
        #expect(recordings.map(\.id) == [recording.id])
        #expect(!recordings.contains { $0.displayName.hasPrefix("Recovered Meeting") })
        for leftover in [first, second, micSide, systemSide] {
            #expect(!FileManager.default.fileExists(atPath: leftover.path))
        }
        #expect(FileManager.default.fileExists(atPath: recording.audioURL.path))
        #expect(!FileManager.default.fileExists(atPath: store.url(for: manifest.id).path))
    }

    @Test func throwingSessionIsIsolatedFromOtherManifestsAndLeftovers() async throws {
        let folder = try RecoveryTestFolder()
        let poisoned = try await folder.makeSegment(named: ".in-progress-microphone-poison.m4a", duration: 0.4)
        let healthy = try await folder.makeSegment(named: ".in-progress-microphone-healthy.m4a", duration: 0.4)
        let leftover = try await folder.makeSegment(named: ".in-progress-system-\(UUID().uuidString).m4a", duration: 0.4)
        let store = RecordingSessionManifestStore(folderURL: folder.url)
        let poisonedManifest = makeManifest(id: "AAAAAAAA-0000-0000-0000-000000000001", name: "Poisoned", segments: [poisoned], startedAt: 100)
        let healthyManifest = makeManifest(id: "AAAAAAAA-0000-0000-0000-000000000002", name: "Healthy", segments: [healthy], startedAt: 200)
        try store.save(poisonedManifest)
        try store.save(healthyManifest)

        let service = RecordingRecoveryService(folderURL: folder.url, fileManager: PoisonedMoveFileManager())
        let results = try await service.recoverInterruptedRecordings(now: Date(timeIntervalSince1970: 2_000))
        let recordings = try RecordingLibrary(folderURL: folder.url).loadRecordings()

        #expect(results.count == 3)
        let failure = try #require(results.first { $0.message == "Could not recover Poisoned." })
        guard case let .failed(reason) = failure.status else {
            Issue.record("poisoned session should fail, got \(failure.status)")
            return
        }
        #expect(reason.hasPrefix("Session recovery failed:"))
        #expect(results.contains { $0.status == .recoveredSession(segmentCount: 1) && $0.recording?.displayName == "Healthy" })
        #expect(results.contains { $0.status == .recoveredSingleSource(.system) })
        #expect(Set(recordings.map(\.source)) == [.microphone, .system])
        #expect(recordings.count == 2)
        #expect(FileManager.default.fileExists(atPath: folder.failedURL(poisoned.lastPathComponent).path))
        #expect(FileManager.default.fileExists(atPath: folder.failedURL(store.url(for: poisonedManifest.id).lastPathComponent).path))
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    private func makeManifest(
        id: String,
        name: String,
        source: AudioSource = .microphone,
        segments: [URL],
        accumulatedActiveDuration: TimeInterval = 0,
        startedAt: TimeInterval = 500
    ) -> RecordingSessionManifest {
        RecordingSessionManifest(
            id: UUID(uuidString: id)!,
            state: .paused,
            source: source,
            requestedName: name,
            startedAt: Date(timeIntervalSince1970: startedAt),
            updatedAt: Date(timeIntervalSince1970: startedAt + 60),
            accumulatedActiveDuration: accumulatedActiveDuration,
            completedSegments: segments.enumerated().map { index, url in
                RecordingSessionSegment(
                    fileName: url.lastPathComponent,
                    startedAt: Date(timeIntervalSince1970: startedAt + Double(index) * 10),
                    endedAt: Date(timeIntervalSince1970: startedAt + Double(index) * 10 + 5)
                )
            },
            pauseReason: .systemSleep
        )
    }
}

/// Simulates a filesystem failure while publishing one specific session, to prove per-manifest isolation.
private final class PoisonedMoveFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.lastPathComponent.contains("poison"), !dstURL.path.contains("/recovery-failed/") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class RecoveryTestFolder: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("msr-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func failedURL(_ name: String) -> URL {
        url.appendingPathComponent("recovery-failed", isDirectory: true).appendingPathComponent(name)
    }

    /// Synthesizes a sine tone and converts it to an AAC .m4a segment like the recorder produces.
    func makeSegment(named name: String, duration: TimeInterval, frequency: Double = 440) async throws -> URL {
        let wav = url.appendingPathComponent("\(UUID().uuidString).wav")
        try Self.writeToneWAV(to: wav, duration: duration, frequency: frequency)
        let output = url.appendingPathComponent(name)
        try await AudioTrackMixer.mixToSingleM4A(inputs: [wav], outputURL: output)
        try FileManager.default.removeItem(at: wav)
        return output
    }

    private static func writeToneWAV(to url: URL, duration: TimeInterval, frequency: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * format.sampleRate)),
              let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.featureUnsupported)
        }
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            channel[frame] = Float(0.2 * sin(2 * Double.pi * frequency * Double(frame) / format.sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
