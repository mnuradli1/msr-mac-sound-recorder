import AVFoundation
import Foundation
import Testing
@testable import MSRCore
@testable import MSRServices

@Suite("MSR v1 parity contracts")
struct ParityTests {
    @Test func legacySettingsDecodeWithV1Defaults() throws {
        let data = Data(#"{"provider":"openai","recordingsFolderPath":"/tmp/demo"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings.provider == .openAI)
        #expect(settings.preferredSource == .micAndSystem)
        #expect(settings.sortOrder == .newest)
        #expect(settings.compressUploads)
        #expect(settings.autoTitle)
        #expect(!settings.localAPIEnabled)
    }

    @Test func jobsHaveIndependentIdentityAndPreservePublicationCheckpointAcrossRestart() throws {
        let recordingID = UUID()
        var first = TranscriptionJob.queue(
            recordingID: recordingID,
            recordingName: "Meeting",
            audioFileName: "recording.m4a",
            provider: .openAI,
            at: Date(timeIntervalSince1970: 1)
        )
        let second = TranscriptionJob.queue(
            recordingID: recordingID,
            recordingName: "Meeting",
            audioFileName: "recording.m4a",
            provider: .openAI,
            at: Date(timeIntervalSince1970: 2)
        )
        #expect(first.id != second.id)
        first.markRunning(at: Date(timeIntervalSince1970: 3))
        first.markPublishing(transcriptFileName: "recording.transcript.txt", contentSHA256: "abc", at: Date(timeIntervalSince1970: 4))
        first.markInterruptedIfRunning(at: Date(timeIntervalSince1970: 5))
        #expect(first.status == .queued)
        #expect(first.transcriptContentSHA256 == "abc")
        #expect(first.publicationStartedAt != nil)
    }

    @Test func jobStoreKeepsMultipleAttemptsForOneRecording() throws {
        let folder = try TestFolder()
        let store = TranscriptionJobStore(folderURL: folder.url)
        let recordingID = UUID()
        let first = TranscriptionJob.queue(recordingID: recordingID, recordingName: "M", audioFileName: "a.m4a", provider: .openAI)
        let second = TranscriptionJob.queue(recordingID: recordingID, recordingName: "M", audioFileName: "a.m4a", provider: .openAI)
        try store.save(first)
        try store.save(second)
        #expect(try store.loadAll().count == 2)
        try store.delete(recordingID: recordingID)
        #expect(try store.loadAll().isEmpty)
    }

    @Test func manifestV1DecodeGetsSafeLifecycleDefaults() throws {
        let data = Data("""
        {
          "id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
          "source":"microphone",
          "requestedName":"Legacy",
          "startedAt":"1970-01-01T00:00:00Z",
          "updatedAt":"1970-01-01T00:00:01Z",
          "accumulatedActiveDuration":1,
          "completedSegments":[]
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(RecordingSessionManifest.self, from: data)
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.state == .capturing)
    }

    @Test func durableFileRecoversValidBackupAndQuarantinesCorruptPrimary() throws {
        struct Value: Codable, Equatable { var name: String }
        let folder = try TestFolder()
        let url = folder.url.appendingPathComponent("value.json")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        try DurableFile.write(Value(name: "first"), to: url, encoder: encoder)
        try DurableFile.write(Value(name: "second"), to: url, encoder: encoder)
        try Data("not json".utf8).write(to: url)
        let recovered = DurableFile.readRecoveringBackup(Value.self, from: url, decoder: decoder)
        #expect(recovered == Value(name: "first"))
        let quarantine = folder.url.appendingPathComponent(".corrupt")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: quarantine.path).isEmpty) == false)
    }

    @Test func exportsFullNotesSRTAndDOCX() throws {
        let folder = try TestFolder()
        let now = Date(timeIntervalSince1970: 1_000)
        let item = RecordingItem(
            metadata: RecordingMetadata(
                id: UUID(), storageKey: "recording-export", displayName: "Planning",
                source: .micAndSystem, audioFileName: "recording-export.m4a",
                startedAt: now, endedAt: now.addingTimeInterval(10), durationSeconds: 10,
                createdAt: now, updatedAt: now
            ),
            folderURL: folder.url
        )
        let segments = [TranscriptSegment(speaker: "Adli", startTime: 0, endTime: 2, text: "Ship it")]
        let input = MeetingNotesExportInput(recording: item, transcript: "Adli: Ship it", segments: segments, summary: "## Action Items\n- Ship")
        let markdown = try TranscriptExporter.preview(input, format: .markdown)
        let srt = try TranscriptExporter.preview(input, format: .srt)
        #expect(markdown.contains("## Summary"))
        #expect(markdown.contains("## Transcript"))
        #expect(srt.contains("00:00:00,000 --> 00:00:02,000"))
        let docx = folder.url.appendingPathComponent("notes.docx")
        try TranscriptExporter.export(input, format: .docx, to: docx)
        let header = try Data(contentsOf: docx).prefix(2)
        #expect(header == Data([0x50, 0x4B]))
    }

    @Test func localAPIRejectsAudioOutsideApprovedFolder() async throws {
        let folder = try TestFolder()
        let proxy = LocalAPIProxy(aiService: ParityFakeAIService()) { url in
            url.deletingLastPathComponent() == folder.url
        }
        let body = try JSONEncoder().encode(TranscribeRequest(audioPath: "/tmp/outside.m4a", provider: .openAI))
        await #expect(throws: LocalAPIError.self) {
            _ = try await proxy.handle(method: "POST", path: "/transcribe", body: body)
        }

        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("msr-outside-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside)
        let link = folder.url.appendingPathComponent("approved-name.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(!StoragePath.isContained(link, in: folder.url))
    }

    @Test func uploadEstimateUses96KbpsForUncompressedAudio() {
        let estimate = AudioUploadEstimator.estimate(
            audioURL: URL(fileURLWithPath: "/tmp/demo.wav"),
            durationSeconds: 60,
            compressionEnabled: true
        )
        #expect(estimate.willCompress)
        #expect(estimate.uploadBytes == 720_000)
    }

    @Test func wavPreparationProducesTemporaryLowBitrateM4A() async throws {
        let folder = try TestFolder()
        let wav = folder.url.appendingPathComponent("input.wav")
        try makeToneWAV(at: wav, duration: 5)
        let prepared = try await TranscriptionAudioPreparer.prepare(
            sourceURL: wav,
            durationSeconds: 5,
            trimRange: nil,
            compressionEnabled: true
        )
        defer { prepared.cleanUp() }
        #expect(prepared.isTemporary)
        #expect(prepared.url.pathExtension == "m4a")
        let byteCount = try prepared.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(byteCount > 0)
        #expect(byteCount < 90_000)
    }
}

private func makeToneWAV(at url: URL, duration: TimeInterval) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
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

private final class ParityFakeAIService: AIService, @unchecked Sendable {
    func transcribe(audioURL: URL, provider: AIProvider) async throws -> TranscribeResponse {
        TranscribeResponse(text: "ok", provider: provider, languageCode: "en")
    }
    func summarize(transcript: String) async throws -> SummarizeResponse { SummarizeResponse(markdown: transcript) }
}

private final class TestFolder: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
