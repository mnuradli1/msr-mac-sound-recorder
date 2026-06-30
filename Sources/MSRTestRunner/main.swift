import Foundation
import AVFoundation
import MSRCore
import MSRServices

@main
struct MSRTestRunner {
    static func main() async {
        do {
            try testCreatesMetadataAndReloads()
            try testRenamesSidecarsTogether()
            testDefaultsProviderToElevenLabs()
            try await testTranscribeEndpointDelegates()
            try await testElevenLabsTranscriptionUsesLongRequestTimeout()
            try await testSummarizeEndpointDelegates()
            try await testHealthEndpoint()
            try await testLocalHTTPServerHealthEndpoint()
            try testAPIKeyNormalizerRemovesPasteWhitespace()
            try testCredentialValidatorBuildsProviderRequests()
            try testWaveformBufferClampsAndRollsSamples()
            try testRecordingCaptureStrategyUsesMixdownForMicAndSystem()
            try testRecordingLibraryDeletesAudioAndSidecars()
            try testRecordingLibraryClearsSummarySidecar()
            try testTranscriptExporterBuildsTextAndMarkdown()
            try testAudioSampleLevelMeterNormalizesPCM()
            try testRecordingWorkflowStateLocksSourceAndChoosesPrimaryAction()
            try testRecordingWorkflowStateSupportsSleepPauseRecovery()
            try testRecordingSessionClockExcludesPausedSleepTime()
            try testRecordingLibraryPersistsRecoveryMetadataAndDurationOverride()
            try await testRecoveryImportsSingleValidSideFromInterruptedMicAndSystem()
            try await testAudioTrackMixerConcatenatesSegmentsSequentially()
            try await testAudioTrackMixerExportsSingleTrack()
            print("MSRTestRunner: all tests passed")
        } catch {
            fputs("MSRTestRunner failed: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}

private func testCreatesMetadataAndReloads() throws {
    let folder = try TemporaryFolder()
    let library = RecordingLibrary(folderURL: folder.url)
    let audioURL = folder.url.appendingPathComponent("Meeting 2026-06-29.m4a")
    FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8))

    let recording = try library.finishRecording(
        temporaryAudioURL: audioURL,
        requestedName: "Weekly Sync",
        source: .micAndSystem,
        startedAt: Date(timeIntervalSince1970: 100),
        endedAt: Date(timeIntervalSince1970: 160)
    )

    try expect(recording.displayName == "Weekly Sync", "display name should be saved")
    try expect(recording.audioURL.lastPathComponent == "Weekly Sync.m4a", "audio should use sanitized name")
    try expect(FileManager.default.fileExists(atPath: recording.metadataURL.path), "metadata sidecar should exist")

    let reloaded = try RecordingLibrary(folderURL: folder.url).loadRecordings()
    try expect(reloaded.map(\.displayName) == ["Weekly Sync"], "history should reload from metadata")
    try expect(reloaded.first?.durationSeconds == 60, "duration should be persisted")
    try expect(reloaded.first?.source == .micAndSystem, "source should be persisted")
}

private func testRenamesSidecarsTogether() throws {
    let folder = try TemporaryFolder()
    let library = RecordingLibrary(folderURL: folder.url)
    let audioURL = folder.url.appendingPathComponent("Original.m4a")
    FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8))
    let recording = try library.finishRecording(
        temporaryAudioURL: audioURL,
        requestedName: "Original",
        source: .microphone,
        startedAt: Date(timeIntervalSince1970: 10),
        endedAt: Date(timeIntervalSince1970: 20)
    )
    try "Transcript".write(to: recording.transcriptURL, atomically: true, encoding: .utf8)
    try "Summary".write(to: recording.summaryURL, atomically: true, encoding: .utf8)

    let renamed = try library.rename(recording, to: "Client Demo / Roadmap?")

    try expect(renamed.displayName == "Client Demo Roadmap", "rename should sanitize display name")
    try expect(FileManager.default.fileExists(atPath: renamed.audioURL.path), "renamed audio should exist")
    try expect(FileManager.default.fileExists(atPath: renamed.metadataURL.path), "renamed metadata should exist")
    try expect(FileManager.default.fileExists(atPath: renamed.transcriptURL.path), "renamed transcript should exist")
    try expect(FileManager.default.fileExists(atPath: renamed.summaryURL.path), "renamed summary should exist")
    try expect(!FileManager.default.fileExists(atPath: recording.audioURL.path), "old audio should be moved")
    try expect(!FileManager.default.fileExists(atPath: recording.metadataURL.path), "old metadata should be moved")
}

private func testDefaultsProviderToElevenLabs() {
    precondition(AppSettings.default.provider == .elevenLabs, "default provider should be ElevenLabs")
}

private func testTranscribeEndpointDelegates() async throws {
    let service = FakeAIService()
    let proxy = LocalAPIProxy(aiService: service)
    let response = try await proxy.handle(
        method: "POST",
        path: "/transcribe",
        body: JSONEncoder().encode(TranscribeRequest(audioPath: "/tmp/demo.m4a", provider: .elevenLabs))
    )

    try expect(response.statusCode == 200, "transcribe should return 200")
    let decoded = try JSONDecoder().decode(TranscribeResponse.self, from: response.body)
    try expect(decoded.text == "Transcript for /tmp/demo.m4a via elevenlabs", "transcribe body should include fake transcript")
    try expect(service.transcribeCalls == 1, "AI service should be called once")
}

private func testElevenLabsTranscriptionUsesLongRequestTimeout() async throws {
    let folder = try TemporaryFolder()
    let audioURL = folder.url.appendingPathComponent("long-meeting.m4a")
    try Data("audio".utf8).write(to: audioURL)

    CapturingURLProtocol.reset(
        statusCode: 200,
        body: Data(#"{"text":"done","language_code":"en"}"#.utf8)
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CapturingURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = ElevenLabsTranscriptionClient(
        endpoint: URL(string: "https://example.test/speech-to-text")!,
        urlSession: session
    )

    _ = try await client.transcribe(audioURL: audioURL, apiKey: "test-key")

    let timeout = CapturingURLProtocol.capturedTimeoutInterval
    try expect((timeout ?? 0) >= 600, "long transcription request timeout should be at least ten minutes")
}

private func testSummarizeEndpointDelegates() async throws {
    let proxy = LocalAPIProxy(aiService: FakeAIService())
    let response = try await proxy.handle(
        method: "POST",
        path: "/summarize",
        body: JSONEncoder().encode(SummarizeRequest(transcript: "Discussed launch, owner is Adli."))
    )

    try expect(response.statusCode == 200, "summarize should return 200")
    let decoded = try JSONDecoder().decode(SummarizeResponse.self, from: response.body)
    try expect(decoded.markdown.contains("Brief Summary"), "summary should include brief section")
    try expect(decoded.markdown.contains("Action Items"), "summary should include action items")
}

private func testHealthEndpoint() async throws {
    let proxy = LocalAPIProxy(aiService: FakeAIService())
    let response = try await proxy.handle(method: "GET", path: "/health", body: Data())

    try expect(response.statusCode == 200, "health should return 200")
    try expect(String(data: response.body, encoding: .utf8)?.contains("ok") == true, "health body should be ok")
}

private func testLocalHTTPServerHealthEndpoint() async throws {
    let proxy = LocalAPIProxy(aiService: FakeAIService())
    let server = LocalHTTPServer(proxy: proxy, port: 48937)
    try server.start()
    defer { server.stop() }
    try await Task.sleep(nanoseconds: 150_000_000)

    let url = URL(string: "http://127.0.0.1:48937/health")!
    let (data, response) = try await URLSession.shared.data(from: url)
    let statusCode = (response as? HTTPURLResponse)?.statusCode
    try expect(statusCode == 200, "HTTP /health should return 200")
    try expect(String(data: data, encoding: .utf8)?.contains("ok") == true, "HTTP /health body should be ok")
}

private func testAPIKeyNormalizerRemovesPasteWhitespace() throws {
    let normalized = APIKeyNormalizer.normalized(" \n demo_key \t")
    try expect(normalized == "demo_key", "API key paste whitespace should be removed")
    try expect(APIKeyNormalizer.normalized(" \n\t") == nil, "empty pasted key should normalize to nil")
}

private func testCredentialValidatorBuildsProviderRequests() throws {
    let elevenRequest = try CredentialValidator.validationRequest(provider: .elevenLabs, apiKey: "demo_key")
    try expect(elevenRequest.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text", "ElevenLabs validation should use speech-to-text endpoint")
    try expect(elevenRequest.httpMethod == "POST", "ElevenLabs validation should POST tiny audio")
    try expect(elevenRequest.value(forHTTPHeaderField: "xi-api-key") == "demo_key", "ElevenLabs validation should set xi-api-key")
    try expect(elevenRequest.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true, "ElevenLabs validation should send multipart data")
    try expect((elevenRequest.httpBody?.count ?? 0) > 100, "ElevenLabs validation should include a tiny audio body")

    let openAIRequest = try CredentialValidator.validationRequest(provider: .openAI, apiKey: "demo_key")
    try expect(openAIRequest.url?.absoluteString == "https://api.openai.com/v1/models", "OpenAI validation should use models endpoint")
    try expect(openAIRequest.value(forHTTPHeaderField: "Authorization") == "Bearer demo_key", "OpenAI validation should set bearer token")
}

private func testWaveformBufferClampsAndRollsSamples() throws {
    var buffer = WaveformBuffer(capacity: 4)
    buffer.append(-1)
    buffer.append(0.25)
    buffer.append(0.5)
    buffer.append(1.5)
    buffer.append(0.75)

    try expect(buffer.samples == [0.25, 0.5, 1.0, 0.75], "waveform buffer should clamp and keep latest samples")
}

private func testRecordingCaptureStrategyUsesMixdownForMicAndSystem() throws {
    try expect(
        RecordingCaptureStrategy.strategy(for: .micAndSystem) == .separateMicAndSystemMixdown,
        "mic+system should use separate capture plus single-track mixdown"
    )
}

private func testRecordingLibraryDeletesAudioAndSidecars() throws {
    let folder = try TemporaryFolder()
    let library = RecordingLibrary(folderURL: folder.url)
    let audioURL = folder.url.appendingPathComponent("Delete Me.m4a")
    FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8))
    let recording = try library.finishRecording(
        temporaryAudioURL: audioURL,
        requestedName: "Delete Me",
        source: .microphone,
        startedAt: Date(timeIntervalSince1970: 10),
        endedAt: Date(timeIntervalSince1970: 20)
    )
    try "Transcript".write(to: recording.transcriptURL, atomically: true, encoding: .utf8)
    try "Summary".write(to: recording.summaryURL, atomically: true, encoding: .utf8)

    try library.delete(recording)

    try expect(!FileManager.default.fileExists(atPath: recording.audioURL.path), "delete should remove audio")
    try expect(!FileManager.default.fileExists(atPath: recording.metadataURL.path), "delete should remove metadata")
    try expect(!FileManager.default.fileExists(atPath: recording.transcriptURL.path), "delete should remove transcript")
    try expect(!FileManager.default.fileExists(atPath: recording.summaryURL.path), "delete should remove summary")
    let remainingRecordings = try library.loadRecordings()
    try expect(remainingRecordings.isEmpty, "delete should remove recording from history")
}

private func testRecordingLibraryClearsSummarySidecar() throws {
    let folder = try TemporaryFolder()
    let library = RecordingLibrary(folderURL: folder.url)
    let audioURL = folder.url.appendingPathComponent("Needs Fresh Transcript.m4a")
    FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8))
    let recording = try library.finishRecording(
        temporaryAudioURL: audioURL,
        requestedName: "Needs Fresh Transcript",
        source: .micAndSystem,
        startedAt: Date(timeIntervalSince1970: 10),
        endedAt: Date(timeIntervalSince1970: 20)
    )
    try "Old summary".write(to: recording.summaryURL, atomically: true, encoding: .utf8)

    try library.clearSummary(for: recording)

    try expect(!FileManager.default.fileExists(atPath: recording.summaryURL.path), "clearing summary should remove stale summary sidecar")
}

private func testTranscriptExporterBuildsTextAndMarkdown() throws {
    let transcript = "Discussed launch.\nOwner is Adli."

    let text = TranscriptExporter.content(
        transcript: transcript,
        recordingName: "Client Weekly Sync",
        format: .text
    )
    try expect(text == transcript, "text export should keep raw transcript")
    try expect(TranscriptExportFormat.text.fileExtension == "txt", "text export should use txt extension")

    let markdown = TranscriptExporter.content(
        transcript: transcript,
        recordingName: "Client Weekly Sync",
        format: .markdown
    )
    try expect(markdown.contains("# Client Weekly Sync"), "markdown export should include title")
    try expect(markdown.contains("## Transcript"), "markdown export should label transcript section")
    try expect(markdown.contains(transcript), "markdown export should include transcript body")
    try expect(TranscriptExportFormat.markdown.fileExtension == "md", "markdown export should use md extension")
}

private func testAudioSampleLevelMeterNormalizesPCM() throws {
    var silence = Data()
    for _ in 0..<16 {
        silence.appendInt16LE(0)
    }
    try expect(AudioSampleLevelMeter.normalizedInt16PCMLevel(silence) == 0, "silent int16 PCM should be zero")

    var tone = Data()
    for sample in [Int16.max / 4, Int16.min / 4, 0, Int16.max / 2] {
        tone.appendInt16LE(sample)
    }
    let toneLevel = AudioSampleLevelMeter.normalizedInt16PCMLevel(tone)
    try expect(toneLevel > 0.2 && toneLevel < 0.6, "int16 PCM level should reflect sample power")

    let floatLevel = AudioSampleLevelMeter.normalizedFloat32PCMLevel([0, 0.25, -0.25, 0.5])
    try expect(floatLevel > 0.2 && floatLevel < 0.5, "float PCM level should reflect sample power")
}

private func testRecordingWorkflowStateLocksSourceAndChoosesPrimaryAction() throws {
    try expect(RecordingWorkflowState.ready.lockedSource == nil, "ready state should not lock source")
    try expect(RecordingWorkflowState.starting(source: .system).lockedSource == .system, "starting should lock selected source")
    try expect(RecordingWorkflowState.recording(source: .micAndSystem).lockedSource == .micAndSystem, "recording should expose locked source")
    try expect(RecordingWorkflowState.finalizing(source: .microphone).isBusy, "finalizing should be busy")
    try expect(RecordingWorkflowState.transcribing.isBusy, "transcribing should be busy")
    try expect(RecordingPrimaryAction.next(transcript: "", summary: "") == .transcribe, "empty transcript should choose transcribe")
    try expect(RecordingPrimaryAction.next(transcript: "hello", summary: "") == .summarize, "transcript without summary should choose summarize")
    try expect(RecordingPrimaryAction.next(transcript: "hello", summary: "summary") == .copySummary, "summary should choose copy summary")
}

private func testRecordingWorkflowStateSupportsSleepPauseRecovery() throws {
    let paused = RecordingWorkflowState.paused(source: .micAndSystem, reason: .systemSleep)
    try expect(paused.lockedSource == .micAndSystem, "sleep-paused state should keep the original source locked")
    try expect(paused.isPaused, "sleep-paused state should report paused")
    try expect(!paused.isRecording, "sleep-paused state should not report active capture")

    let suspending = RecordingWorkflowState.suspending(source: .system)
    try expect(suspending.lockedSource == .system, "suspending should keep the original source locked")
    try expect(suspending.isBusy, "suspending should block duplicate recording actions")

    try expect(RecordingWorkflowState.recovering.isBusy, "recovery should block duplicate recording actions")
    try expect(RecordingWorkflowState.recovering.isRecovering, "recovering state should report recovery")
}

private func testRecordingSessionClockExcludesPausedSleepTime() throws {
    var clock = RecordingSessionClock(startedAt: Date(timeIntervalSince1970: 100))
    try expect(clock.activeDuration(at: Date(timeIntervalSince1970: 220)) == 120, "active duration should start from first segment")

    clock.pause(at: Date(timeIntervalSince1970: 220), reason: .systemSleep)
    try expect(clock.activeDuration(at: Date(timeIntervalSince1970: 520)) == 120, "active duration should exclude paused sleep time")
    try expect(clock.pauseReason == .systemSleep, "clock should remember sleep pause reason")

    clock.resume(at: Date(timeIntervalSince1970: 600))
    try expect(clock.activeDuration(at: Date(timeIntervalSince1970: 660)) == 180, "active duration should include resumed segment only")
    try expect(clock.pauseReason == nil, "resumed clock should clear pause reason")
}

private func testRecordingLibraryPersistsRecoveryMetadataAndDurationOverride() throws {
    let folder = try TemporaryFolder()
    let library = RecordingLibrary(folderURL: folder.url)
    let audioURL = folder.url.appendingPathComponent("Recovered Temp.m4a")
    FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8))
    let recoveredAt = Date(timeIntervalSince1970: 300)

    let recording = try library.finishRecording(
        temporaryAudioURL: audioURL,
        requestedName: "Recovered Meeting",
        source: .microphone,
        startedAt: Date(timeIntervalSince1970: 100),
        endedAt: Date(timeIntervalSince1970: 1_000),
        durationSecondsOverride: 125,
        recoveredAt: recoveredAt,
        recoveryNote: "Recovered microphone only after system track failed.",
        segmentCount: 2
    )

    let reloaded = try RecordingLibrary(folderURL: folder.url).loadRecordings().first
    try expect(reloaded?.durationSeconds == 125, "duration override should be persisted")
    try expect(reloaded?.metadata.recoveredAt == recoveredAt, "recovered timestamp should be persisted")
    try expect(reloaded?.metadata.recoveryNote == "Recovered microphone only after system track failed.", "recovery note should be persisted")
    try expect(reloaded?.metadata.segmentCount == 2, "segment count should be persisted")
    try expect(recording.audioURL.lastPathComponent == "Recovered Meeting.m4a", "recovered audio should use requested display name")
}

private func testRecoveryImportsSingleValidSideFromInterruptedMicAndSystem() async throws {
    let folder = try TemporaryFolder()
    let sessionID = "ABC123"
    let micWAV = folder.url.appendingPathComponent("mic.wav")
    let micURL = folder.url.appendingPathComponent("..in-progress-\(sessionID)-mic-111.m4a")
    let systemURL = folder.url.appendingPathComponent("..in-progress-\(sessionID)-system-222.m4a")
    try writeToneWAV(to: micWAV, frequency: 440, duration: 0.45)
    try await AudioTrackMixer.mixToSingleM4A(inputs: [micWAV], outputURL: micURL)
    try Data("not audio".utf8).write(to: systemURL)

    let service = RecordingRecoveryService(folderURL: folder.url)
    let results = try await service.recoverInterruptedRecordings(now: Date(timeIntervalSince1970: 1_000))
    let recordings = try RecordingLibrary(folderURL: folder.url).loadRecordings()

    try expect(results.count == 1, "one interrupted session should produce one recovery result")
    try expect(results.first?.status == .recoveredSingleSource(.microphone), "valid microphone side should be imported when system side is corrupt")
    try expect(recordings.count == 1, "recovered recording should be visible in the library")
    try expect(recordings.first?.source == .microphone, "metadata should reflect the actual recovered source")
    try expect(recordings.first?.metadata.recoveredAt != nil, "recovered recording should include recovered timestamp")
    try expect(recordings.first?.metadata.recoveryNote?.contains("system") == true, "recovery note should mention the missing system side")
    try expect(!FileManager.default.fileExists(atPath: micURL.path), "valid temp side should be consumed")
    try expect(!FileManager.default.fileExists(atPath: systemURL.path), "corrupt temp side should be moved out of the active folder")
    try expect(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("recovery-failed").path), "failed recovery folder should exist for corrupt leftovers")
}

private func testAudioTrackMixerConcatenatesSegmentsSequentially() async throws {
    let folder = try TemporaryFolder()
    let first = folder.url.appendingPathComponent("first.wav")
    let second = folder.url.appendingPathComponent("second.wav")
    let output = folder.url.appendingPathComponent("joined.m4a")
    try writeToneWAV(to: first, frequency: 440, duration: 0.30)
    try writeToneWAV(to: second, frequency: 660, duration: 0.40)

    try await AudioTrackMixer.concatenateToSingleM4A(inputs: [first, second], outputURL: output)

    let asset = AVURLAsset(url: output)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let duration = try await asset.load(.duration)
    try expect(tracks.count == 1, "concatenated output should contain one audio track")
    try expect(duration.seconds > 0.60, "concatenated duration should add both segment durations")
}

private func testAudioTrackMixerExportsSingleTrack() async throws {
    let folder = try TemporaryFolder()
    let first = folder.url.appendingPathComponent("first.wav")
    let second = folder.url.appendingPathComponent("second.wav")
    let output = folder.url.appendingPathComponent("mixed.m4a")
    try writeToneWAV(to: first, frequency: 440)
    try writeToneWAV(to: second, frequency: 660)

    try await AudioTrackMixer.mixToSingleM4A(inputs: [first, second], outputURL: output)

    try expect(FileManager.default.fileExists(atPath: output.path), "mixed output should exist")
    let asset = AVURLAsset(url: output)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let duration = try await asset.load(.duration)
    try expect(tracks.count == 1, "mixed output should contain one audio track")
    try expect(duration.seconds > 0.2, "mixed output should keep audio duration")
}

private func writeToneWAV(to url: URL, frequency: Double, duration: Double = 0.35) throws {
    let sampleRate = 16_000
    let sampleCount = Int(Double(sampleRate) * duration)
    var data = Data()
    data.appendASCII("RIFF")
    data.appendUInt32LE(UInt32(36 + sampleCount * 2))
    data.appendASCII("WAVE")
    data.appendASCII("fmt ")
    data.appendUInt32LE(16)
    data.appendUInt16LE(1)
    data.appendUInt16LE(1)
    data.appendUInt32LE(UInt32(sampleRate))
    data.appendUInt32LE(UInt32(sampleRate * 2))
    data.appendUInt16LE(2)
    data.appendUInt16LE(16)
    data.appendASCII("data")
    data.appendUInt32LE(UInt32(sampleCount * 2))
    for index in 0..<sampleCount {
        let angle = 2 * Double.pi * frequency * Double(index) / Double(sampleRate)
        let sample = Int16(Double(Int16.max) * 0.2 * sin(angle))
        data.appendInt16LE(sample)
    }
    try data.write(to: url)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure(message)
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("msr-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(Data(value.utf8))
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    mutating func appendInt16LE(_ value: Int16) {
        appendUInt16LE(UInt16(bitPattern: value))
    }
}

private final class FakeAIService: AIService, @unchecked Sendable {
    var transcribeCalls = 0

    func transcribe(audioURL: URL, provider: AIProvider) async throws -> TranscribeResponse {
        transcribeCalls += 1
        return TranscribeResponse(
            text: "Transcript for \(audioURL.path) via \(provider.rawValue)",
            provider: provider,
            languageCode: "en"
        )
    }

    func summarize(transcript: String) async throws -> SummarizeResponse {
        return SummarizeResponse(
            markdown: """
            ## Brief Summary
            Discussed launch.

            ## Key Points
            - Owner is Adli.

            ## Action Items
            - Confirm launch checklist.
            """
        )
    }
}

private final class CapturingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var timeoutInterval: TimeInterval?
    nonisolated(unsafe) private static var statusCode = 200
    nonisolated(unsafe) private static var responseBody = Data()

    static var capturedTimeoutInterval: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return timeoutInterval
    }

    static func reset(statusCode: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.timeoutInterval = nil
        self.statusCode = statusCode
        self.responseBody = body
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.timeoutInterval = request.timeoutInterval
        let statusCode = Self.statusCode
        let responseBody = Self.responseBody
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
