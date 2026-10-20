import AVFoundation
import Foundation
import Testing
import MSRCore
import MSRServices

@Suite("Durable capture recovery")
struct DurableRecoveryTests {
    @Test func badLegacySessionDoesNotBlockNewCAFSessionOrMoveLegacySources() async throws {
        let folder = try RecoveryTestFolder()
        let oldOutput = folder.url.appendingPathComponent(".in-progress-micAndSystem-old.m4a")
        let oldMic = folder.url.appendingPathComponent("..in-progress-micAndSystem-old-mic-old.m4a")
        let oldSystem = folder.url.appendingPathComponent("..in-progress-micAndSystem-old-system-old.m4a")
        let corrupt = Data("Synthetic truncated legacy M4A".utf8)
        try corrupt.write(to: oldMic)
        try corrupt.write(to: oldSystem)
        let old = RecordingSessionManifest(source: .micAndSystem, requestedName: "Old damaged session",
            startedAt: Date(timeIntervalSince1970: 1),
            activeSegment: RecordingSessionSegment(fileName: oldOutput.lastPathComponent, startedAt: Date(timeIntervalSince1970: 1)),
            microphoneFileName: oldMic.lastPathComponent, systemFileName: oldSystem.lastPathComponent)
        let store = RecordingSessionManifestStore(folderURL: folder.url)
        try store.save(old)
        let output = folder.url.appendingPathComponent(".in-progress-microphone-new.m4a")
        try writeRecoveryTone(to: DurableCaptureFiles.rawURL(for: output, channel: .microphone), seconds: 2)
        let healthy = recoveryManifest(output: output, source: .microphone, startedAt: Date(timeIntervalSince1970: 2))
        try store.save(healthy)

        let results = try await RecordingRecoveryService(folderURL: folder.url).recoverInterruptedRecordings()
        #expect(results.count == 2)
        #expect(results.filter { $0.recording != nil }.count == 1)
        #expect(results.contains { if case .failed = $0.status { return true }; return false })
        #expect(try Data(contentsOf: oldMic) == corrupt)
        #expect(try Data(contentsOf: oldSystem) == corrupt)
        #expect(FileManager.default.fileExists(atPath: store.url(for: old.id).path))
        #expect(try RecordingLibrary(folderURL: folder.url).loadRecordings().count == 1)
    }

    @Test func shorterReadableExportIsRebuiltFromFullRetainedCAF() async throws {
        let folder = try RecoveryTestFolder()
        let output = folder.url.appendingPathComponent(".in-progress-microphone-short.m4a")
        let short = folder.url.appendingPathComponent("short.caf")
        try writeRecoveryTone(to: short, seconds: 0.25)
        try await AudioTrackMixer.mixToSingleM4A(inputs: [short], outputURL: output)
        try writeRecoveryTone(to: DurableCaptureFiles.rawURL(for: output, channel: .microphone), seconds: 2)
        try RecordingSessionManifestStore(folderURL: folder.url).save(recoveryManifest(output: output, source: .microphone))
        let results = try await RecordingRecoveryService(folderURL: folder.url).recoverInterruptedRecordings()
        let recording = try #require(results.compactMap(\.recording).first)
        let duration = try await AVURLAsset(url: recording.audioURL).load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)
    }

    @Test func damagedOneSourceRecoversHealthyAudioAndRetainsDamagedArtifact() async throws {
        let folder = try RecoveryTestFolder()
        let output = folder.url.appendingPathComponent(".in-progress-micAndSystem-degraded.m4a")
        let mic = DurableCaptureFiles.rawURL(for: output, channel: .microphone)
        let system = DurableCaptureFiles.rawURL(for: output, channel: .system)
        try writeRecoveryTone(to: mic, seconds: 2)
        let damaged = Data("Synthetic damaged system CAF".utf8)
        try damaged.write(to: system)
        try RecordingSessionManifestStore(folderURL: folder.url).save(recoveryManifest(output: output, source: .micAndSystem))
        let results = try await RecordingRecoveryService(folderURL: folder.url).recoverInterruptedRecordings()
        let recording = try #require(results.compactMap(\.recording).first)
        #expect(recording.metadata.recoveryNote?.localizedCaseInsensitiveContains("source") == true)
        let duration = try await AVURLAsset(url: recording.audioURL).load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)
        let candidates = [system, folder.url.appendingPathComponent("recovery-failed").appendingPathComponent(system.lastPathComponent)]
        #expect(candidates.contains { (try? Data(contentsOf: $0)) == damaged })
    }

    @Test func alreadyPublishedSessionDeduplicatesBeforeReadingCorruptInputs() async throws {
        let folder = try RecoveryTestFolder()
        let raw = folder.url.appendingPathComponent("published-source.caf")
        let output = folder.url.appendingPathComponent(".in-progress-micAndSystem-published.m4a")
        try writeRecoveryTone(to: raw, seconds: 1)
        try await AudioTrackMixer.mixToSingleM4A(inputs: [raw], outputURL: output)
        let library = RecordingLibrary(folderURL: folder.url)
        let id = UUID()
        let recording = try library.finishRecording(temporaryAudioURL: output, requestedName: "Published session",
            source: .micAndSystem, startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 2),
            recordingID: id)
        var manifest = recoveryManifest(output: output, source: .micAndSystem)
        manifest.finalRecordingID = id
        let oldMic = folder.url.appendingPathComponent("..in-progress-micAndSystem-published-mic-old.m4a")
        let oldSystem = folder.url.appendingPathComponent("..in-progress-micAndSystem-published-system-old.m4a")
        try FileManager.default.copyItem(at: recording.audioURL, to: oldMic)
        try FileManager.default.copyItem(at: recording.audioURL, to: oldSystem)
        manifest.microphoneFileName = oldMic.lastPathComponent
        manifest.systemFileName = oldSystem.lastPathComponent
        try RecordingSessionManifestStore(folderURL: folder.url).save(manifest)
        try Data("Corrupt leftover export".utf8).write(to: output)
        let results = try await RecordingRecoveryService(folderURL: folder.url).recoverInterruptedRecordings()
        #expect(results.count == 1)
        #expect(results.first?.recording?.id == recording.id)
        #expect(try library.loadRecordings().count == 1)
        let secondPass = try await RecordingRecoveryService(folderURL: folder.url).recoverInterruptedRecordings()
        #expect(secondPass.isEmpty)
        #expect(try library.loadRecordings().count == 1)
    }
}

private func recoveryManifest(output: URL, source: AudioSource, startedAt: Date = Date(timeIntervalSince1970: 2)) -> RecordingSessionManifest {
    RecordingSessionManifest(source: source, requestedName: "Synthetic recovered session", startedAt: startedAt,
        activeSegment: RecordingSessionSegment(fileName: output.lastPathComponent, startedAt: startedAt),
        microphoneFileName: source == .system ? nil : DurableCaptureFiles.rawURL(for: output, channel: .microphone).lastPathComponent,
        systemFileName: source == .microphone ? nil : DurableCaptureFiles.rawURL(for: output, channel: .system).lastPathComponent)
}

private func writeRecoveryTone(to url: URL, seconds: Double) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let frames = AVAudioFrameCount(48_000 * seconds)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let channel = try #require(buffer.floatChannelData?[0])
    for frame in 0..<Int(frames) { channel[frame] = Float(sin(2 * .pi * 440 * Double(frame) / 48_000) * 0.15) }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private final class RecoveryTestFolder {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("msr-durable-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
