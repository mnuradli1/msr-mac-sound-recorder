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
            try await testElevenLabsTranscriptionEnablesDiarizationAndFormatsSpeakerTurns()
            try testTranscriptionJobStoreRoundTripsHiddenJob()
            try testTranscriptionJobTracksRunningCompletedFailedAttempts()
            try testTranscriptionErrorMessageClassifiesFailures()
            try testTranscriptionProgressDisplayAnimatesMessageAndElapsedTime()
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
            try testRecordingInteractionPolicyProtectsPausedBusyAndTargetedWork()
            try testRecordingSessionClockExcludesPausedSleepTime()
            try testRecordingSessionManifestTracksPauseResumeSegments()
            try testRecordingSessionManifestStoreRoundTripsHiddenSession()
            try testRecordingLibraryPersistsRecoveryMetadataAndDurationOverride()
            try await testRecoveryUsesSessionManifestToRecoverSegments()
            try await testRecoveryFailsSessionManifestWithMissingSegment()
            try await testRecoveryKeepsSourceForSingleInterruptedSystemRecording()
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
    try expect((timeout ?? 0) >= 3_600, "long transcription request timeout should be at least one hour")
}

private func testElevenLabsTranscriptionEnablesDiarizationAndFormatsSpeakerTurns() async throws {
    let folder = try TemporaryFolder()
    let audioURL = folder.url.appendingPathComponent("meeting.m4a")
    try Data("audio".utf8).write(to: audioURL)

    CapturingURLProtocol.reset(
        statusCode: 200,
        body: Data("""
        {
          "text": "Hello there Hi Adli",
          "language_code": "en",
          "words": [
            {"text": "Hello", "type": "word", "speaker_id": "speaker_0"},
            {"text": " ", "type": "spacing", "speaker_id": "speaker_0"},
            {"text": "there", "type": "word", "speaker_id": "speaker_0"},
            {"text": "Hi", "type": "word", "speaker_id": "speaker_1"},
            {"text": " ", "type": "spacing", "speaker_id": "speaker_1"},
            {"text": "Adli", "type": "word", "speaker_id": "speaker_1"}
          ]
        }
        """.utf8)
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CapturingURLProtocol.self]
    let client = ElevenLabsTranscriptionClient(
        endpoint: URL(string: "https://example.test/speech-to-text")!,
        urlSession: URLSession(configuration: configuration)
    )

    let response = try await client.transcribe(audioURL: audioURL, apiKey: "test-key")
    let requestBody = CapturingURLProtocol.capturedRequestBody

    try expect(requestBody?.contains("name=\"diarize\"") == true, "ElevenLabs request should include diarize field")
    try expect(requestBody?.contains("\r\n\r\ntrue\r\n") == true, "ElevenLabs diarize field should be true")
    try expect(
        response.text == """
        Speaker 1:
        Hello there

        Speaker 2:
        Hi Adli
        """,
        "ElevenLabs diarized words should be formatted as speaker turns"
    )
}

private func testTranscriptionJobStoreRoundTripsHiddenJob() throws {
    let folder = try TemporaryFolder()
    let recordingID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let job = TranscriptionJob(
        recordingID: recordingID,
        recordingName: "Long Meeting",
        audioFileName: "Long Meeting.m4a",
        provider: .elevenLabs,
        status: .running,
        attemptCount: 1,
        startedAt: startedAt,
        updatedAt: startedAt
    )
    let store = TranscriptionJobStore(folderURL: folder.url)

    try store.save(job)
    let storedURL = store.url(for: recordingID)
    let loaded = try store.load(recordingID: recordingID)
    let recordings = try RecordingLibrary(folderURL: folder.url).loadRecordings()

    try expect(storedURL.lastPathComponent == ".transcription-\(recordingID.uuidString).json", "transcription job should use a hidden filename")
    try expect(FileManager.default.fileExists(atPath: storedURL.path), "transcription job should be written")
    try expect(loaded == job, "transcription job should round-trip through JSON")
    try expect(recordings.isEmpty, "hidden transcription jobs should not appear in recording history")
}

private func testTranscriptionJobTracksRunningCompletedFailedAttempts() throws {
    let recordingID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    var job = TranscriptionJob.start(
        recordingID: recordingID,
        recordingName: "Retry Meeting",
        audioFileName: "Retry Meeting.m4a",
        provider: .elevenLabs,
        previousAttemptCount: 1,
        at: Date(timeIntervalSince1970: 2_000)
    )

    try expect(job.status == .running, "started job should be running")
    try expect(job.attemptCount == 2, "started job should increment previous attempt count")
    try expect(job.errorMessage == nil, "started job should clear error")

    job.markFailed("Upload timed out.", at: Date(timeIntervalSince1970: 2_100))
    try expect(job.status == .failed, "failed job should persist failed status")
    try expect(job.errorMessage == "Upload timed out.", "failed job should persist readable error")
    try expect(job.completedAt == nil, "failed job should not set completed timestamp")

    job.markCompleted(transcriptFileName: "Retry Meeting.transcript.txt", at: Date(timeIntervalSince1970: 2_200))
    try expect(job.status == .completed, "completed job should persist completed status")
    try expect(job.transcriptFileName == "Retry Meeting.transcript.txt", "completed job should remember transcript file")
    try expect(job.completedAt == Date(timeIntervalSince1970: 2_200), "completed job should persist completed timestamp")
    try expect(job.errorMessage == nil, "completed job should clear previous error")

    var interrupted = TranscriptionJob.start(
        recordingID: recordingID,
        recordingName: "Retry Meeting",
        audioFileName: "Retry Meeting.m4a",
        provider: .elevenLabs,
        at: Date(timeIntervalSince1970: 3_000)
    )
    interrupted.markInterruptedIfRunning(at: Date(timeIntervalSince1970: 3_100))
    try expect(interrupted.status == .failed, "running job from previous launch should become retryable")
    try expect(interrupted.errorMessage?.contains("interrupted") == true, "interrupted job should explain retry state")
}

private func testTranscriptionErrorMessageClassifiesFailures() throws {
    try expect(
        TranscriptionErrorMessage.message(for: ProviderError.missingAPIKey("ELEVENLABS_API_KEY")).contains("API key"),
        "missing API key should produce credential guidance"
    )
    try expect(
        TranscriptionErrorMessage.message(for: ProviderError.audioFileMissing("/tmp/missing.m4a")).contains("Audio file"),
        "missing audio should mention audio file"
    )
    try expect(
        TranscriptionErrorMessage.message(for: ProviderError.providerRejected(413, "too large")).contains("Provider rejected"),
        "provider rejection should include provider context"
    )
    let timeout = URLError(.timedOut)
    try expect(
        TranscriptionErrorMessage.message(for: timeout).contains("timed out"),
        "timeout should produce retryable timeout guidance"
    )
}

private func testTranscriptionProgressDisplayAnimatesMessageAndElapsedTime() throws {
    try expect(
        TranscriptionProgressDisplay.message(provider: .elevenLabs, tick: 0) == "Transcribing with ElevenLabs",
        "first transcription message frame should not include dots"
    )
    try expect(
        TranscriptionProgressDisplay.message(provider: .elevenLabs, tick: 3) == "Transcribing with ElevenLabs...",
        "transcription message should animate dots"
    )
    try expect(
        TranscriptionProgressDisplay.elapsedText(seconds: 65) == "01:05",
        "short transcription elapsed text should use MM:SS"
    )
    try expect(
        TranscriptionProgressDisplay.elapsedText(seconds: 3_665) == "01:01:05",
        "long transcription elapsed text should use HH:MM:SS"
    )
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

private func testRecordingInteractionPolicyProtectsPausedBusyAndTargetedWork() throws {
    let paused = RecordingWorkflowState.paused(source: .micAndSystem, reason: .systemSleep)
    let recording = RecordingWorkflowState.recording(source: .micAndSystem)
    let transcribing = RecordingWorkflowState.transcribing
    let saved = RecordingWorkflowState.saved
    let targetID = UUID()
    let otherID = UUID()

    try expect(!RecordingInteractionPolicy.canSelectHistory(during: paused), "paused sessions should keep Resume/Save controls visible")
    try expect(!RecordingInteractionPolicy.canRecoverInterruptedRecordings(during: paused), "paused live segments should not be recovered as orphans")
    try expect(!RecordingInteractionPolicy.canPlayBack(during: recording), "playback should be disabled while recording")
    try expect(!RecordingInteractionPolicy.canPlayBack(during: transcribing), "playback should be disabled while AI work is busy")
    try expect(RecordingInteractionPolicy.canPlayBack(during: saved), "playback should be available for saved recordings")
    try expect(
        RecordingInteractionPolicy.shouldApplyAsyncResult(targetID: targetID, selectedID: targetID),
        "AI results should apply to the visible recording only when the target is still selected"
    )
    try expect(
        !RecordingInteractionPolicy.shouldApplyAsyncResult(targetID: targetID, selectedID: otherID),
        "AI results should not overwrite the UI after the user switches recordings"
    )
    try expect(
        !RecordingInteractionPolicy.shouldApplyAsyncResult(targetID: targetID, selectedID: nil),
        "AI results should not repopulate the UI after the target is no longer selected"
    )
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

private func testRecordingSessionManifestTracksPauseResumeSegments() throws {
    var manifest = RecordingSessionManifest(
        id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
        source: .microphone,
        requestedName: "Manifest Flow",
        startedAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100),
        activeSegment: RecordingSessionSegment(
            fileName: ".in-progress-microphone-first.m4a",
            startedAt: Date(timeIntervalSince1970: 100)
        )
    )

    manifest.finishActiveSegment(
        endedAt: Date(timeIntervalSince1970: 160),
        accumulatedActiveDuration: 60,
        reason: .systemSleep,
        updatedAt: Date(timeIntervalSince1970: 161)
    )
    try expect(manifest.completedSegments.count == 1, "pause should move active segment to completed list")
    try expect(manifest.completedSegments.first?.endedAt == Date(timeIntervalSince1970: 160), "completed segment should capture ended timestamp")
    try expect(manifest.activeSegment == nil, "pause should clear active segment")
    try expect(manifest.pauseReason == .systemSleep, "pause should store reason")
    try expect(manifest.accumulatedActiveDuration == 60, "pause should persist active duration")

    manifest.startActiveSegment(
        fileName: ".in-progress-microphone-second.m4a",
        startedAt: Date(timeIntervalSince1970: 220),
        updatedAt: Date(timeIntervalSince1970: 220)
    )
    try expect(manifest.completedSegments.count == 1, "resume should keep completed segment list")
    try expect(manifest.activeSegment?.fileName == ".in-progress-microphone-second.m4a", "resume should store new active segment")
    try expect(manifest.pauseReason == nil, "resume should clear pause reason")

    manifest.finishActiveSegment(
        endedAt: Date(timeIntervalSince1970: 260),
        accumulatedActiveDuration: 100,
        reason: .manual,
        updatedAt: Date(timeIntervalSince1970: 260)
    )
    try expect(manifest.completedSegments.map(\.fileName) == [".in-progress-microphone-first.m4a", ".in-progress-microphone-second.m4a"], "final pause should preserve segment order")
    try expect(manifest.accumulatedActiveDuration == 100, "final pause should update active duration")
}

private func testRecordingSessionManifestStoreRoundTripsHiddenSession() throws {
    let folder = try TemporaryFolder()
    let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let startedAt = Date(timeIntervalSince1970: 100)
    let updatedAt = Date(timeIntervalSince1970: 180)
    let manifest = RecordingSessionManifest(
        id: id,
        source: .micAndSystem,
        requestedName: "Meeting 2026-07-01",
        startedAt: startedAt,
        updatedAt: updatedAt,
        accumulatedActiveDuration: 80,
        completedSegments: [
            RecordingSessionSegment(
                fileName: ".in-progress-micAndSystem-first.m4a",
                startedAt: startedAt,
                endedAt: Date(timeIntervalSince1970: 180)
            )
        ],
        activeSegment: RecordingSessionSegment(
            fileName: ".in-progress-micAndSystem-second.m4a",
            startedAt: Date(timeIntervalSince1970: 220)
        ),
        pauseReason: nil
    )
    let store = RecordingSessionManifestStore(folderURL: folder.url)

    try store.save(manifest)
    let storedURL = store.url(for: id)
    let loaded = try store.load(id: id)
    let all = try store.loadAll()
    let recordings = try RecordingLibrary(folderURL: folder.url).loadRecordings()

    try expect(storedURL.lastPathComponent == ".session-\(id.uuidString).json", "manifest should use a hidden session filename")
    try expect(FileManager.default.fileExists(atPath: storedURL.path), "manifest should be written to disk")
    try expect(loaded == manifest, "manifest should round-trip through JSON")
    try expect(all.map(\.id) == [id], "store should list saved manifests")
    try expect(recordings.isEmpty, "hidden session manifests should not appear in recording history")
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

private func testRecoveryUsesSessionManifestToRecoverSegments() async throws {
    let folder = try TemporaryFolder()
    let firstWAV = folder.url.appendingPathComponent("first.wav")
    let secondWAV = folder.url.appendingPathComponent("second.wav")
    let firstSegment = folder.url.appendingPathComponent(".in-progress-micAndSystem-first.m4a")
    let secondSegment = folder.url.appendingPathComponent(".in-progress-micAndSystem-second.m4a")
    try writeToneWAV(to: firstWAV, frequency: 440, duration: 0.25)
    try writeToneWAV(to: secondWAV, frequency: 660, duration: 0.30)
    try await AudioTrackMixer.mixToSingleM4A(inputs: [firstWAV], outputURL: firstSegment)
    try await AudioTrackMixer.mixToSingleM4A(inputs: [secondWAV], outputURL: secondSegment)

    let manifest = RecordingSessionManifest(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        source: .micAndSystem,
        requestedName: "Recovered From Manifest",
        startedAt: Date(timeIntervalSince1970: 500),
        updatedAt: Date(timeIntervalSince1970: 560),
        accumulatedActiveDuration: 55,
        completedSegments: [
            RecordingSessionSegment(fileName: firstSegment.lastPathComponent, startedAt: Date(timeIntervalSince1970: 500), endedAt: Date(timeIntervalSince1970: 525)),
            RecordingSessionSegment(fileName: secondSegment.lastPathComponent, startedAt: Date(timeIntervalSince1970: 530), endedAt: Date(timeIntervalSince1970: 560))
        ],
        activeSegment: nil,
        pauseReason: .systemSleep
    )
    let store = RecordingSessionManifestStore(folderURL: folder.url)
    try store.save(manifest)

    let results = try await RecordingRecoveryService(folderURL: folder.url).recoverInterruptedRecordings(now: Date(timeIntervalSince1970: 1_000))
    let recordings = try RecordingLibrary(folderURL: folder.url).loadRecordings()

    try expect(results.count == 1, "one manifest should produce one recovery result")
    try expect(results.first?.status == .recoveredSession(segmentCount: 2), "manifest recovery should report recovered segment count")
    try expect(recordings.count == 1, "manifest recovery should create one visible recording")
    try expect(recordings.first?.source == .micAndSystem, "manifest recovery should preserve original source")
    try expect(recordings.first?.metadata.segmentCount == 2, "manifest recovery should persist segment count")
    try expect(recordings.first?.metadata.recoveryNote?.contains("2 segments") == true, "recovery note should mention segment recovery")
    try expect(!FileManager.default.fileExists(atPath: store.url(for: manifest.id).path), "successful manifest recovery should delete manifest")
    try expect(!FileManager.default.fileExists(atPath: firstSegment.path), "successful manifest recovery should consume first segment")
    try expect(!FileManager.default.fileExists(atPath: secondSegment.path), "successful manifest recovery should consume second segment")
}

private func testRecoveryFailsSessionManifestWithMissingSegment() async throws {
    let folder = try TemporaryFolder()
    let firstWAV = folder.url.appendingPathComponent("first.wav")
    let firstSegment = folder.url.appendingPathComponent(".in-progress-microphone-first.m4a")
    try writeToneWAV(to: firstWAV, frequency: 440, duration: 0.25)
    try await AudioTrackMixer.mixToSingleM4A(inputs: [firstWAV], outputURL: firstSegment)

    let missingSegmentName = ".in-progress-microphone-missing.m4a"
    let manifest = RecordingSessionManifest(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        source: .microphone,
        requestedName: "Incomplete Manifest",
        startedAt: Date(timeIntervalSince1970: 700),
        updatedAt: Date(timeIntervalSince1970: 740),
        accumulatedActiveDuration: 40,
        completedSegments: [
            RecordingSessionSegment(fileName: firstSegment.lastPathComponent, startedAt: Date(timeIntervalSince1970: 700), endedAt: Date(timeIntervalSince1970: 725)),
            RecordingSessionSegment(fileName: missingSegmentName, startedAt: Date(timeIntervalSince1970: 730), endedAt: Date(timeIntervalSince1970: 740))
        ],
        activeSegment: nil,
        pauseReason: .manual
    )
    let store = RecordingSessionManifestStore(folderURL: folder.url)
    try store.save(manifest)

    let results = try await RecordingRecoveryService(folderURL: folder.url).recoverInterruptedRecordings(now: Date(timeIntervalSince1970: 1_000))
    let recordings = try RecordingLibrary(folderURL: folder.url).loadRecordings()
    let failedFolder = folder.url.appendingPathComponent("recovery-failed", isDirectory: true)

    try expect(results.count == 1, "one incomplete manifest should produce one recovery result")
    if case .failed = results.first?.status {
    } else {
        throw TestFailure("missing manifest segment should fail recovery")
    }
    try expect(recordings.isEmpty, "missing manifest segment should not produce a shorter recording")
    try expect(!FileManager.default.fileExists(atPath: store.url(for: manifest.id).path), "failed manifest recovery should move manifest out of active folder")
    try expect(!FileManager.default.fileExists(atPath: firstSegment.path), "failed manifest recovery should move existing segment out of active folder")
    try expect(FileManager.default.fileExists(atPath: failedFolder.appendingPathComponent(firstSegment.lastPathComponent).path), "existing segment should be moved to recovery-failed")
    try expect(FileManager.default.fileExists(atPath: failedFolder.appendingPathComponent(store.url(for: manifest.id).lastPathComponent).path), "manifest should be moved to recovery-failed")
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

private func testRecoveryKeepsSourceForSingleInterruptedSystemRecording() async throws {
    let folder = try TemporaryFolder()
    let wavURL = folder.url.appendingPathComponent("system.wav")
    let interruptedURL = folder.url.appendingPathComponent(".in-progress-system-\(UUID().uuidString).m4a")
    try writeToneWAV(to: wavURL, frequency: 660, duration: 0.35)
    try await AudioTrackMixer.mixToSingleM4A(inputs: [wavURL], outputURL: interruptedURL)

    let service = RecordingRecoveryService(folderURL: folder.url)
    _ = try await service.recoverInterruptedRecordings(now: Date(timeIntervalSince1970: 1_000))
    let recordings = try RecordingLibrary(folderURL: folder.url).loadRecordings()

    try expect(recordings.count == 1, "single interrupted source-tagged recording should recover")
    try expect(recordings.first?.source == .system, "source-tagged single recovery should preserve system source")
    try expect(recordings.first?.metadata.recoveryNote?.contains("system") == true, "recovery note should mention system source")
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
    nonisolated(unsafe) private static var requestBody: String?
    nonisolated(unsafe) private static var statusCode = 200
    nonisolated(unsafe) private static var responseBody = Data()

    static var capturedTimeoutInterval: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return timeoutInterval
    }

    static var capturedRequestBody: String? {
        lock.lock()
        defer { lock.unlock() }
        return requestBody
    }

    static func reset(statusCode: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.timeoutInterval = nil
        self.requestBody = nil
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
        Self.requestBody = Self.bodyString(for: request)
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

    private static func bodyString(for request: URLRequest) -> String? {
        if let httpBody = request.httpBody {
            return String(data: httpBody, encoding: .utf8)
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: 4_096)
            if readCount > 0 {
                data.append(buffer, count: readCount)
            } else {
                break
            }
        }

        return String(data: data, encoding: .utf8)
    }
}
