import AVFoundation
import Foundation
import Testing
@testable import MSRCore
@testable import MSRServices

// Release 1.2: text-model providers (OpenAI / DeepSeek), auto-summarize,
// transcription language, speaker names and meeting-notes export. Every
// network call goes to a stubbed `URLProtocol`; nothing leaves the process.

// MARK: - Provider enums and credentials

@Suite("1.2 provider enums and credentials")
struct ProviderCredentialTests {
    @Test func enumsExposeStableIdentifiers() {
        #expect(TextModelProvider.allCases.map(\.rawValue) == ["openai", "deepseek"])
        #expect(TextModelProvider.allCases.map(\.displayName) == ["OpenAI", "DeepSeek"])
        #expect(TextModelProvider.openAI.credentialProvider == .openAI)
        #expect(TextModelProvider.deepSeek.credentialProvider == .deepSeek)
        #expect(CredentialProvider.allCases.map(\.environmentVariableName) == ["ELEVENLABS_API_KEY", "OPENAI_API_KEY", "DEEPSEEK_API_KEY"])
        // Saved keys must keep working: the 1.1 Keychain accounts are AIProvider raw values.
        #expect(CredentialProvider.elevenLabs.keychainAccount == AIProvider.elevenLabs.rawValue)
        #expect(CredentialProvider.openAI.keychainAccount == AIProvider.openAI.rawValue)
        #expect(CredentialProvider.deepSeek.keychainAccount == "deepseek")
        #expect(TranscriptionLanguage.allCases.map(\.rawValue) == ["auto", "en", "id"])
        #expect(TranscriptionLanguage.allCases.map(\.languageCode) == [nil, "en", "id"])
        #expect(TranscriptionLanguage.indonesian.displayName == "Bahasa Indonesia")
    }

    @Test func keyStoreHoldsDeepSeekWithEnvironmentBeforeKeychain() throws {
        let keychain = MemoryKeychain()
        let store = APIKeyStore(environment: ["DEEPSEEK_API_KEY": " env-ds "], keychain: keychain)
        #expect(store.apiKey(for: .deepSeek) == "env-ds")
        #expect(store.apiKey(for: .openAI) == nil)

        try keychain.write("kc-ds", service: "MSRMeetingRecorder", account: "deepseek")
        #expect(store.apiKey(for: .deepSeek) == "env-ds")

        try store.save(apiKey: "saved-ds", for: .deepSeek)
        #expect(store.apiKey(for: .deepSeek) == "saved-ds")
        #expect(keychain.value(account: "deepseek") == "saved-ds")

        try store.forget(.deepSeek)
        #expect(keychain.value(account: "deepseek") == nil)
        #expect(store.apiKey(for: .deepSeek) == "env-ds")
    }

    @Test func transcriptionOverloadsShareTheCredentialSlots() throws {
        let keychain = MemoryKeychain()
        let store = APIKeyStore(environment: [:], keychain: keychain)
        try store.save(apiKey: "oa", for: AIProvider.openAI)
        #expect(store.apiKey(for: CredentialProvider.openAI) == "oa")
        #expect(keychain.value(account: "openai") == "oa")
        try store.setSession(apiKey: "el", for: CredentialProvider.elevenLabs)
        #expect(store.apiKey(for: AIProvider.elevenLabs) == "el")
    }

    @Test func deepSeekValidationRequestAndResult() async throws {
        let request = try CredentialValidator.validationRequest(credential: .deepSeek, apiKey: " ds-key ")
        #expect(request.url?.absoluteString == "https://api.deepseek.com/models")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ds-key")

        let ok = Stub.session(replies: [.json(#"{"object":"list","data":[]}"#)], hosts: ["api.deepseek.com"])
        let valid = await CredentialValidator(urlSession: ok.session).validate(credential: .deepSeek, apiKey: "ds-key")
        #expect(valid.isValid)
        #expect(valid.credential == .deepSeek)
        #expect(valid.provider == nil)
        #expect(valid.message.contains("DeepSeek"))
        #expect(ok.script.requests.first?.url?.host == "api.deepseek.com")

        let rejected = Stub.session(replies: [.status(401, body: "bad")], hosts: ["api.deepseek.com"])
        let invalid = await CredentialValidator(urlSession: rejected.session).validate(credential: .deepSeek, apiKey: "ds-key")
        #expect(!invalid.isValid)
        #expect(invalid.message.contains("DeepSeek rejected the key"))

        // The AIProvider entry point still reports the transcription provider.
        let legacy = await CredentialValidator(urlSession: ok.session).validate(provider: .openAI, apiKey: "")
        #expect(legacy.provider == .openAI)
    }

    @Test func missingTextModelKeyMessagesNameBothKeys() {
        let error = ProviderError.missingAPIKey(ProviderError.textModelKeyNames)
        #expect(error.localizedDescription.contains("OpenAI or DeepSeek"))
        #expect(error.localizedDescription.contains("DEEPSEEK_API_KEY"))
        #expect(TranscriptionErrorMessage.message(for: error).contains("OpenAI or DeepSeek"))
        #expect(TranscriptionErrorMessage.message(for: ProviderError.missingAPIKey("ELEVENLABS_API_KEY"))
            == "Transcription needs an API key. Add it in Settings, then retry.")
    }
}

// MARK: - DeepSeek client

@Suite("1.2 DeepSeek client")
struct DeepSeekClientTests {
    private static func chat(_ content: String) -> Stub.Reply {
        let escaped = String(data: try! JSONEncoder().encode(content), encoding: .utf8)!
        return .json(#"{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":\#(escaped)}}]}"#)
    }

    @Test func summarizeSendsChatCompletionWithSharedPrompt() async throws {
        let stub = Stub.session(replies: [Self.chat("## Brief Summary\nDone.")])
        let client = DeepSeekClient(endpoint: stub.url("/chat/completions"), urlSession: stub.session, environment: [:])
        let summary = try await client.summarize(transcript: "Speaker 1:\nShip Friday.", apiKey: "ds-key")
        #expect(summary.markdown == "## Brief Summary\nDone.")

        let request = try #require(stub.script.requests.first)
        #expect(request.url?.path == "/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ds-key")
        let json = try stub.script.json(at: 0)
        #expect(json["model"] as? String == "deepseek-chat")
        #expect(json["temperature"] as? Double == 0.3)
        #expect(json["max_tokens"] as? Int == 4_096)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.count == 1)
        #expect(messages.first?["role"] == "user")
        #expect(messages.first?["content"] == MeetingTextPrompts.summaryPrompt(transcript: "Speaker 1:\nShip Friday."))
    }

    @Test func longTranscriptsAreChunkedLikeOpenAI() async throws {
        let stub = Stub.session(replies: [Self.chat("partial")])
        let client = DeepSeekClient(endpoint: stub.url("/chat/completions"), urlSession: stub.session, environment: [:])
        let line = String(repeating: "word ", count: 20) + "\n"
        let transcript = String(repeating: line, count: 1_300) // ~131k characters → 3 chunks
        let chunks = MeetingTextPrompts.chunked(transcript, maximumCharacters: MeetingTextPrompts.summaryChunkCharacters)
        #expect(chunks.count == 3)
        _ = try await client.summarize(transcript: transcript, apiKey: "ds-key")
        #expect(stub.script.requests.count == chunks.count + 1)
        let first = try #require((try stub.script.json(at: 0)["messages"] as? [[String: String]])?.first?["content"])
        #expect(first.hasPrefix("Summarize meeting transcript chunk 1 of 3."))
    }

    @Test func generateTitleCleansReplyAndCapsTokens() async throws {
        let stub = Stub.session(replies: [Self.chat("Title: \"Rapat Anggaran Q3.\"")])
        let client = DeepSeekClient(endpoint: stub.url("/chat/completions"), urlSession: stub.session, environment: ["DEEPSEEK_SUMMARY_MODEL": "deepseek-reasoner"])
        let title = try await client.generateTitle(transcript: "Pembahasan anggaran " + String(repeating: "x", count: 20_000), apiKey: "ds-key")
        #expect(title == "Rapat Anggaran Q3")
        let json = try stub.script.json(at: 0)
        #expect(json["model"] as? String == "deepseek-reasoner")
        #expect(json["max_tokens"] as? Int == 32)
        let content = try #require((json["messages"] as? [[String: String]])?.first?["content"])
        #expect(content.hasPrefix(OpenAIClient.titlePrompt))
        #expect(content.count <= OpenAIClient.titlePrompt.count + 12_000 + 20)
    }

    @Test func rejectedAndEmptyRepliesThrow() async throws {
        let rejected = Stub.session(replies: [.status(402, body: "Insufficient Balance")])
        let client = DeepSeekClient(endpoint: rejected.url("/chat/completions"), urlSession: rejected.session, environment: [:])
        do {
            _ = try await client.summarize(transcript: "hi", apiKey: "k")
            Issue.record("expected a rejection")
        } catch let ProviderError.providerRejected(status, message) {
            #expect(status == 402)
            #expect(message.contains("Insufficient Balance"))
        }

        let empty = Stub.session(replies: [.json(#"{"choices":[{"message":{"role":"assistant","content":null}}]}"#)])
        let emptyClient = DeepSeekClient(endpoint: empty.url("/chat/completions"), urlSession: empty.session, environment: [:])
        await #expect(throws: ProviderError.self) { _ = try await emptyClient.summarize(transcript: "hi", apiKey: "k") }

        let blankTitle = Stub.session(replies: [Self.chat("\"\"")])
        let titleClient = DeepSeekClient(endpoint: blankTitle.url("/chat/completions"), urlSession: blankTitle.session, environment: [:])
        await #expect(throws: ProviderError.self) { _ = try await titleClient.generateTitle(transcript: "hi", apiKey: "k") }
    }
}

// MARK: - Routing and transcription language

@Suite("1.2 ProviderAIService routing")
struct ProviderRoutingTests {
    private func service(
        keys: [String: String],
        selected: TextModelProvider = .openAI,
        stub: Stub.Session
    ) -> ProviderAIService {
        ProviderAIService(
            keyStore: APIKeyStore(environment: keys, keychain: MemoryKeychain()),
            elevenLabs: ElevenLabsTranscriptionClient(endpoint: stub.url("/v1/speech-to-text"), urlSession: stub.session),
            openAI: OpenAIClient(
                transcriptionEndpoint: stub.url("/v1/audio/transcriptions"),
                responsesEndpoint: stub.url("/v1/responses"),
                urlSession: stub.session
            ),
            deepSeek: DeepSeekClient(endpoint: stub.url("/chat/completions"), urlSession: stub.session, environment: [:]),
            textModelProvider: selected
        )
    }

    @Test func resolvesSelectedThenFallbackThenNone() {
        let stub = Stub.session(replies: [])
        let both = service(keys: ["OPENAI_API_KEY": "oa", "DEEPSEEK_API_KEY": "ds"], selected: .deepSeek, stub: stub)
        #expect(both.resolvedTextModelProvider == .deepSeek)
        both.textModelProvider = .openAI
        #expect(both.resolvedTextModelProvider == .openAI)

        let onlyDeepSeek = service(keys: ["DEEPSEEK_API_KEY": "ds"], selected: .openAI, stub: stub)
        #expect(onlyDeepSeek.resolvedTextModelProvider == .deepSeek)
        #expect(onlyDeepSeek.canSummarize)
        #expect(onlyDeepSeek.canGenerateTitlesRemotely)

        let onlyOpenAI = service(keys: ["OPENAI_API_KEY": "oa"], selected: .deepSeek, stub: stub)
        #expect(onlyOpenAI.resolvedTextModelProvider == .openAI)

        let none = service(keys: ["ELEVENLABS_API_KEY": "el"], stub: stub)
        #expect(none.resolvedTextModelProvider == nil)
        #expect(!none.canSummarize)
        #expect(!none.canGenerateTitlesRemotely)
    }

    @Test func summarizeAndTitleGoToTheResolvedProvider() async throws {
        let stub = Stub.session(replies: [.json(#"{"choices":[{"message":{"content":"DeepSeek summary"}}]}"#)])
        let ai = service(keys: ["DEEPSEEK_API_KEY": "ds", "OPENAI_API_KEY": "oa"], selected: .deepSeek, stub: stub)
        #expect(try await ai.summarize(transcript: "hello").markdown == "DeepSeek summary")
        #expect(try await ai.generateTitle(transcript: "hello") == "DeepSeek summary")
        #expect(stub.script.requests.map(\.url?.path) == ["/chat/completions", "/chat/completions"])
        #expect(stub.script.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer ds")

        let openAIStub = Stub.session(replies: [.json(#"{"output":[{"content":[{"type":"output_text","text":"OpenAI summary"}]}]}"#)])
        let fallback = service(keys: ["OPENAI_API_KEY": "oa"], selected: .deepSeek, stub: openAIStub)
        #expect(try await fallback.summarize(transcript: "hello").markdown == "OpenAI summary")
        #expect(openAIStub.script.requests.first?.url?.path == "/v1/responses")
    }

    @Test func missingTextModelKeysThrowNamingBoth() async {
        let ai = service(keys: [:], stub: Stub.session(replies: []))
        do {
            _ = try await ai.summarize(transcript: "hello")
            Issue.record("expected missing key")
        } catch let ProviderError.missingAPIKey(name) {
            #expect(name == "OPENAI_API_KEY or DEEPSEEK_API_KEY")
        } catch {
            Issue.record("unexpected \(error)")
        }
        await #expect(throws: ProviderError.self) { _ = try await ai.generateTitle(transcript: "hello") }
    }

    @Test func openAITranscriptionSendsLanguageOnlyWhenSet() async throws {
        let folder = try Release12Folder()
        let audio = folder.url.appendingPathComponent("clip.m4a")
        try Data("audio".utf8).write(to: audio)
        let stub = Stub.session(replies: [.json(#"{"text":"halo"}"#)])
        let ai = service(keys: ["OPENAI_API_KEY": "oa"], stub: stub)

        _ = try await ai.transcribe(audioURL: audio, provider: .openAI, languageCode: TranscriptionLanguage.indonesian.languageCode)
        _ = try await ai.transcribe(audioURL: audio, provider: .openAI, languageCode: TranscriptionLanguage.automatic.languageCode)
        _ = try await ai.transcribe(audioURL: audio, provider: .openAI)
        let bodies = stub.script.bodies
        #expect(bodies.count == 3)
        #expect(bodies[0].contains("name=\"language\"\r\n\r\nid\r\n"))
        #expect(bodies[0].contains("name=\"model\"\r\n\r\ngpt-4o-transcribe\r\n"))
        #expect(!bodies[1].contains("name=\"language\""))
        #expect(!bodies[2].contains("name=\"language\""))
    }

    @Test func elevenLabsTranscriptionReceivesLanguageCode() async throws {
        let folder = try Release12Folder()
        let audio = folder.url.appendingPathComponent("clip.m4a")
        try Data("audio".utf8).write(to: audio)
        let stub = Stub.session(replies: [.json(#"{"text":"hello","language_code":"en"}"#)])
        let ai = service(keys: ["ELEVENLABS_API_KEY": "el"], stub: stub)

        _ = try await ai.transcribe(audioURL: audio, provider: .elevenLabs, languageCode: "en")
        _ = try await ai.transcribe(audioURL: audio, provider: .elevenLabs, languageCode: nil)
        // Through the protocol existential, too.
        let existential: any AIService = ai
        _ = try await existential.transcribe(audioURL: audio, provider: .elevenLabs, languageCode: "id")
        let bodies = stub.script.bodies
        #expect(bodies[0].contains("name=\"language_code\"\r\n\r\nen\r\n"))
        #expect(!bodies[1].contains("language_code"))
        #expect(bodies[2].contains("name=\"language_code\"\r\n\r\nid\r\n"))
    }
}

// MARK: - Auto-summarize

@Suite("1.2 auto-summarize publishing")
@MainActor
struct AutoSummarizePublisherTests {
    private static let transcript = """
    Speaker 1:
    Okay, hello everyone.

    Speaker 2:
    Today we're going to discuss the launch date and onboarding owner for the mobile app.
    """

    private func job(for recording: RecordingItem, summarize: Bool, replacing: Bool = false) -> TranscriptionJob {
        var job = TranscriptionJob.queue(
            recordingID: recording.id,
            recordingName: recording.displayName,
            audioFileName: recording.audioURL.lastPathComponent,
            provider: .elevenLabs,
            replacingExistingTranscript: replacing,
            origin: .automatic,
            autoTitleRequested: true,
            autoSummarizeRequested: summarize
        )
        job.markRunning()
        return job
    }

    @Test func summaryIsWrittenAfterCompletionAndTitle() async throws {
        let fixture = try LibraryFixture()
        let recording = try fixture.makeRecording(name: "Meeting 2026-06-29 14.05")
        var statusWhenSummarizing: TranscriptionJobStatus?
        var checkpoints: [TranscriptionJob] = []
        var receivedTranscript: String?

        let result = try await TranscriptPublisher.publish(
            job: job(for: recording, summarize: true),
            recording: recording,
            decoded: TranscribeResponse(text: Self.transcript, provider: .elevenLabs, languageCode: "en"),
            autoTitleRequested: true,
            library: fixture.library,
            titleGenerator: { _ in "Launch Planning" },
            summarizer: { transcript in
                statusWhenSummarizing = checkpoints.last?.status
                receivedTranscript = transcript
                return SummarizeResponse(markdown: "## Brief Summary\nLaunch planning.\n\n## Action Items\n- Pick a date\n")
            },
            checkpoint: { checkpoints.append($0) }
        )

        #expect(statusWhenSummarizing == .completed)
        #expect(receivedTranscript == Self.transcript)
        #expect(result.job.status == .completed)
        #expect(result.generatedTitle == "Launch Planning")
        #expect(result.summaryError == nil)
        #expect(result.summaryMarkdown == "## Brief Summary\nLaunch planning.\n\n## Action Items\n- Pick a date")
        let reloaded = try #require(try fixture.library.loadRecordings().first)
        #expect(reloaded.displayName == "Launch Planning")
        #expect(try String(contentsOf: reloaded.summaryURL, encoding: .utf8) == result.summaryMarkdown)

        // The search indexer picks the summary up from disk.
        let documents = await RecordingSearchIndexer().documents(for: [reloaded])
        #expect(RecordingSearch.filter(documents, query: "pick a date").count == 1)
    }

    @Test func summarizerFailureNeverFailsTheJob() async throws {
        let fixture = try LibraryFixture()
        let recording = try fixture.makeRecording(name: "Meeting 2026-06-29 14.05")
        let result = try await TranscriptPublisher.publish(
            job: job(for: recording, summarize: true),
            recording: recording,
            decoded: TranscribeResponse(text: Self.transcript, provider: .elevenLabs, languageCode: "en"),
            autoTitleRequested: false,
            library: fixture.library,
            summarizer: { _ in throw ProviderError.missingAPIKey(ProviderError.textModelKeyNames) }
        )
        #expect(result.job.status == .completed)
        #expect(result.summaryMarkdown == nil)
        guard case .missingAPIKey? = result.summaryError as? ProviderError else {
            Issue.record("expected the summarizer error, got \(String(describing: result.summaryError))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: result.recording.summaryURL.path))
        #expect(try String(contentsOf: result.recording.transcriptURL, encoding: .utf8) == Self.transcript)
    }

    @Test func emptySummaryIsReportedNotWritten() async throws {
        let fixture = try LibraryFixture()
        let recording = try fixture.makeRecording(name: "Weekly")
        let result = try await TranscriptPublisher.publish(
            job: job(for: recording, summarize: true),
            recording: recording,
            decoded: TranscribeResponse(text: Self.transcript, provider: .elevenLabs, languageCode: "en"),
            autoTitleRequested: false,
            library: fixture.library,
            summarizer: { _ in SummarizeResponse(markdown: "  \n") }
        )
        #expect(result.summaryError is TranscriptPublisher.EmptySummaryError)
        #expect(!FileManager.default.fileExists(atPath: result.recording.summaryURL.path))
    }

    @Test func summarizerIsNotCalledWhenNotRequested() async throws {
        let fixture = try LibraryFixture()
        let recording = try fixture.makeRecording(name: "Meeting 2026-06-29 14.05")
        var calls = 0
        let result = try await TranscriptPublisher.publish(
            job: job(for: recording, summarize: false),
            recording: recording,
            decoded: TranscribeResponse(text: Self.transcript, provider: .elevenLabs, languageCode: "en"),
            autoTitleRequested: true,
            library: fixture.library,
            summarizer: { _ in
                calls += 1
                return SummarizeResponse(markdown: "never")
            }
        )
        #expect(calls == 0)
        #expect(result.summaryMarkdown == nil)
        #expect(result.summaryError == nil)

        // Empty transcripts are skipped silently, too.
        let other = try fixture.makeRecording(name: "Silence")
        let skipped = try await TranscriptPublisher.publish(
            job: job(for: other, summarize: true),
            recording: other,
            decoded: TranscribeResponse(text: "  ", provider: .elevenLabs, languageCode: nil),
            autoTitleRequested: false,
            library: fixture.library,
            summarizer: { _ in
                calls += 1
                return SummarizeResponse(markdown: "never")
            }
        )
        #expect(calls == 0)
        #expect(skipped.summaryError == nil)
    }

    @Test func replacingTranscriptResetsSpeakerNames() async throws {
        let fixture = try LibraryFixture()
        let recording = try fixture.makeRecording(name: "Weekly")
        let withTranscript = try fixture.library.writeTranscriptBundle(
            Self.transcript, segments: TranscriptParser.segments(from: Self.transcript), for: recording
        )
        let named = try fixture.library.renameSpeaker(withTranscript, label: "Speaker 1", to: "Sarah")
        #expect(named.speakerNames == ["Speaker 1": "Sarah"])

        let result = try await TranscriptPublisher.publish(
            job: job(for: named, summarize: false, replacing: true),
            recording: named,
            decoded: TranscribeResponse(text: Self.transcript, provider: .elevenLabs, languageCode: "en"),
            autoTitleRequested: false,
            library: fixture.library
        )
        #expect(result.recording.speakerNames.isEmpty)
        #expect(try fixture.library.loadRecordings().first?.metadata.speakerNames == nil)
    }
}

// MARK: - Speaker names

@Suite("1.2 speaker names")
struct SpeakerNameTests {
    private static let transcript = """
    Speaker 1:
    Okay, hello everyone.

    Speaker 2:
    Let's review the launch: dates first.

    [00:01:05] Speaker 1:
    Speaker 2: said dates first, so dates.
    """

    private func seeded() throws -> (LibraryFixture, RecordingItem) {
        let fixture = try LibraryFixture()
        let recording = try fixture.makeRecording(name: "Weekly Sync")
        var segments = TranscriptParser.segments(from: Self.transcript)
        segments[0].startTime = 0
        segments[1].startTime = 4
        let published = try fixture.library.writeTranscriptBundle(Self.transcript, segments: segments, for: recording)
        return (fixture, published)
    }

    @Test func sanitizerProducesParserSafeLabels() {
        #expect(SpeakerNames.sanitized("  Sarah \n Connor ") == "Sarah Connor")
        #expect(SpeakerNames.sanitized("Dr. Smith: PM") == "Dr Smith PM")
        #expect(SpeakerNames.sanitized("one two three four five") == "one two three four")
        #expect(SpeakerNames.sanitized(String(repeating: "a", count: 60)).count == 40)
        #expect(SpeakerNames.sanitized(" :: \n ") == "")
        #expect(SpeakerNames.sanitized("Budi O'Neil-Santoso") == "Budi O'Neil-Santoso")
    }

    @Test func renameRewritesTranscriptSegmentsAndMetadata() throws {
        let (fixture, recording) = try seeded()
        let renamed = try fixture.library.renameSpeaker(recording, label: "Speaker 1", to: "Sarah")
        #expect(renamed.speakerNames == ["Speaker 1": "Sarah"])

        let text = try String(contentsOf: renamed.transcriptURL, encoding: .utf8)
        #expect(text == """
        Sarah:
        Okay, hello everyone.

        Speaker 2:
        Let's review the launch: dates first.

        [00:01:05] Sarah:
        Speaker 2: said dates first, so dates.
        """)
        let segments = fixture.library.loadTranscriptSegments(for: renamed)
        #expect(segments.map(\.speaker) == ["Sarah", "Speaker 2", "Sarah"])
        #expect(segments.first?.startTime == 0)
        // Parser round trip: `Sarah:` headers parse like provider labels, and
        // Read mode still treats the saved segments as current.
        #expect(TranscriptParser.segments(from: text).map(\.speaker) == ["Sarah", "Speaker 2", "Sarah"])
        #expect(!TranscriptParser.readableTranscript(saved: segments, transcript: text).isEdited)

        let reloaded = try #require(try fixture.library.loadRecordings().first)
        #expect(reloaded.metadata.speakerNames == ["Speaker 1": "Sarah"])
        #expect(reloaded.displayName == "Weekly Sync")
    }

    @Test func reRenameUpdatesMappingByOriginalLabelAndRevertRestoresIt() throws {
        let (fixture, recording) = try seeded()
        _ = try fixture.library.renameSpeaker(recording, label: "Speaker 1", to: "Sarah")
        // Rename by current display name...
        let second = try fixture.library.renameSpeaker(recording, label: "Sarah", to: "Sarah Lee")
        #expect(second.speakerNames == ["Speaker 1": "Sarah Lee"])
        // ...or by original label.
        let third = try fixture.library.renameSpeaker(recording, label: "Speaker 1", to: "Sari")
        #expect(third.speakerNames == ["Speaker 1": "Sari"])
        #expect(fixture.library.loadTranscriptSegments(for: third).map(\.speaker) == ["Sari", "Speaker 2", "Sari"])

        let reverted = try fixture.library.renameSpeaker(recording, label: "Sari", to: "  ")
        #expect(reverted.metadata.speakerNames == nil)
        #expect(try String(contentsOf: reverted.transcriptURL, encoding: .utf8) == Self.transcript)
        #expect(fixture.library.loadTranscriptSegments(for: reverted).map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1"])

        // Same name is a no-op.
        let unchanged = try fixture.library.renameSpeaker(recording, label: "Speaker 2", to: "Speaker 2")
        #expect(unchanged.metadata.speakerNames == nil)
    }

    @Test func collisionsAndUnknownSpeakersAreRejected() throws {
        let (fixture, recording) = try seeded()
        _ = try fixture.library.renameSpeaker(recording, label: "Speaker 1", to: "Sarah")
        #expect(throws: RecordingLibraryError.speakerNameInUse("sarah")) {
            try fixture.library.renameSpeaker(recording, label: "Speaker 2", to: "sarah")
        }
        // Another speaker's original label is reserved too, so originals stay recoverable.
        #expect(throws: RecordingLibraryError.speakerNameInUse("Speaker 1")) {
            try fixture.library.renameSpeaker(recording, label: "Speaker 2", to: "Speaker 1")
        }
        #expect(throws: RecordingLibraryError.speakerNotFound("Speaker 9")) {
            try fixture.library.renameSpeaker(recording, label: "Speaker 9", to: "Budi")
        }
    }

    @Test func exportsAndSearchUseTheName() async throws {
        let (fixture, recording) = try seeded()
        let renamed = try fixture.library.renameSpeaker(recording, label: "Speaker 2", to: "Budi")
        let text = try String(contentsOf: renamed.transcriptURL, encoding: .utf8)
        let input = MeetingNotesExportInput(
            recording: renamed,
            transcript: text,
            segments: fixture.library.loadTranscriptSegments(for: renamed),
            summary: ""
        )
        let markdown = try TranscriptExporter.preview(input, format: .markdown)
        #expect(markdown.contains("Budi:\nLet's review the launch"))
        #expect(!markdown.contains("Speaker 2:\n"))
        let srt = try TranscriptExporter.preview(input, format: .srt)
        #expect(srt.contains("Budi: Let's review the launch"))
        #expect(TranscriptExporter.meetingNotesMarkdown(input).contains("**[00:00:04] Budi:** Let's review the launch"))

        let documents = await RecordingSearchIndexer().documents(for: [renamed])
        #expect(RecordingSearch.filter(documents, query: "budi").count == 1)
    }

    @Test func legacyMetadataWithoutSpeakerNamesDecodes() throws {
        let data = Data("""
        {"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","displayName":"Legacy","source":"microphone",
         "audioFileName":"legacy.m4a","startedAt":"1970-01-01T00:00:01Z","endedAt":"1970-01-01T00:00:02Z",
         "durationSeconds":1,"createdAt":"1970-01-01T00:00:01Z","updatedAt":"1970-01-01T00:00:01Z"}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(RecordingMetadata.self, from: data)
        #expect(metadata.speakerNames == nil)
        #expect(metadata.schemaVersion == 1)
    }
}

// MARK: - Meeting notes

@Suite("1.2 meeting notes export")
struct MeetingNotesExportTests {
    @Test func meetingNotesHaveSummaryActionItemsAndTimestampedTranscript() throws {
        let fixture = try LibraryFixture()
        let recording = try fixture.makeRecording(name: "Launch Review")
        let transcript = "Sarah:\nShip on Friday.\n\nBudi:\nI'll update the checklist."
        let segments = [
            TranscriptSegment(speaker: "Sarah", startTime: 0, endTime: 2, text: "Ship on Friday."),
            TranscriptSegment(speaker: "Budi", startTime: 65, endTime: 70, text: "I'll update the checklist.")
        ]
        let summary = """
        ## Brief Summary
        Launch is on Friday.

        ## Action Items
        - Budi: update the checklist

        ## Key Points
        - Friday launch
        """
        let notes = TranscriptExporter.meetingNotesMarkdown(
            MeetingNotesExportInput(recording: recording, transcript: transcript, segments: segments, summary: summary)
        )
        let lines = notes.components(separatedBy: "\n")
        #expect(lines.first == "# Launch Review")
        #expect(lines[2].contains(" · 00:01:00 · Mic + System"))
        #expect(notes.contains("## Summary\n\n## Brief Summary\nLaunch is on Friday.\n\n## Key Points\n- Friday launch"))
        #expect(notes.contains("## Action Items\n\n- Budi: update the checklist\n\n## Transcript"))
        #expect(notes.components(separatedBy: "- Budi: update the checklist").count == 2) // listed once, not duplicated
        #expect(notes.contains("## Transcript\n\n**[00:00:00] Sarah:** Ship on Friday.\n\n**[00:01:05] Budi:** I'll update the checklist.\n"))
    }

    @Test func meetingNotesWithoutSummaryOrSegments() throws {
        let fixture = try LibraryFixture()
        let recording = try fixture.makeRecording(name: "Plain")
        let notes = TranscriptExporter.meetingNotesMarkdown(
            MeetingNotesExportInput(recording: recording, transcript: "Just some notes.", segments: [], summary: "  ")
        )
        #expect(notes.contains("## Summary\n\n_No summary yet._\n\n## Transcript\n\nJust some notes.\n"))
        #expect(!notes.contains("## Action Items"))

        // An edited transcript (saved segments are stale) falls back to the text's speaker blocks.
        let edited = TranscriptExporter.meetingNotesMarkdown(MeetingNotesExportInput(
            recording: recording,
            transcript: "Sarah:\nEdited line.",
            segments: [TranscriptSegment(speaker: "Sarah", startTime: 3, text: "Original line.")],
            summary: "## Brief Summary\nShort.\n\n## Action Items\n- None"
        ))
        #expect(edited.contains("**Sarah:** Edited line."))
        #expect(!edited.contains("[00:00:03]"))
        #expect(edited.contains("## Action Items\n\n- None"))
    }
}

// MARK: - Helpers

private final class MemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    func value(account: String) -> String? { lock.withLock { items[account] } }
    func read(service: String, account: String) -> String? { lock.withLock { items[account] } }
    func write(_ value: String, service: String, account: String) throws { lock.withLock { items[account] = value } }
    func delete(service: String, account: String) throws { lock.withLock { _ = items.removeValue(forKey: account) } }
}

private final class Release12Folder: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("msr-1.2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private struct LibraryFixture {
    let folder: Release12Folder
    let library: RecordingLibrary

    init() throws {
        folder = try Release12Folder()
        library = RecordingLibrary(folderURL: folder.url)
    }

    func makeRecording(name: String) throws -> RecordingItem {
        let wav = folder.url.appendingPathComponent("capture-\(UUID().uuidString).wav")
        try Data("RIFF-not-really-audio".utf8).write(to: wav)
        return try library.finishRecording(
            temporaryAudioURL: wav,
            requestedName: name,
            source: .micAndSystem,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_060)
        )
    }
}

/// Scripted HTTP replies per stub session. Every request made through the
/// session (whatever its host) is answered and recorded, so tests can also
/// exercise clients with hard-coded URLs (credential validation).
enum Stub {
    struct Reply: Sendable {
        var status: Int
        var body: Data

        static func json(_ text: String) -> Reply { Reply(status: 200, body: Data(text.utf8)) }
        static func status(_ code: Int, body: String = "") -> Reply { Reply(status: code, body: Data(body.utf8)) }
    }

    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Reply]
        private var captured: [(URLRequest, Data)] = []

        init(_ replies: [Reply]) { self.replies = replies }

        var requests: [URLRequest] { lock.withLock { captured.map(\.0) } }
        var bodies: [String] { lock.withLock { captured.map { String(decoding: $0.1, as: UTF8.self) } } }

        func json(at index: Int) throws -> [String: Any] {
            let body = lock.withLock { captured[index].1 }
            return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }

        /// The next reply; the last one repeats.
        func next(_ request: URLRequest, body: Data) -> Reply {
            lock.withLock {
                captured.append((request, body))
                if replies.count > 1 { return replies.removeFirst() }
                return replies.first ?? .status(404)
            }
        }
    }

    struct Session {
        let session: URLSession
        let script: Script
        let host: String

        func url(_ path: String) -> URL { URL(string: "https://\(host)\(path)")! }
    }

    /// - Parameter hosts: extra real hosts answered by this script (for clients
    ///   with hard-coded URLs); each such host may be used by one test only.
    static func session(replies: [Reply], hosts: [String] = []) -> Session {
        let host = "stub-\(UUID().uuidString.lowercased()).example.test"
        let script = Script(replies)
        for name in [host] + hosts {
            StubProtocol.register(script, host: name)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return Session(session: URLSession(configuration: configuration), script: script, host: host)
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Stub.Script] = [:]

    static func register(_ script: Stub.Script, host: String) {
        lock.withLock { scripts[host] = script }
    }

    private static func script(for request: URLRequest) -> Stub.Script? {
        guard let host = request.url?.host else { return nil }
        return lock.withLock { scripts[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let script = Self.script(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let reply = script.next(request, body: Self.body(of: request))
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
