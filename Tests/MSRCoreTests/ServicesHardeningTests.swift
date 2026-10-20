import AVFoundation
import Foundation
import Testing
import MSRCore
@testable import MSRServices

// MARK: - A. ElevenLabs retry/backoff + parsing

@Suite("ElevenLabs transcription hardening")
struct ElevenLabsTranscriptionHardeningTests {
    private static let successBody = Data(#"{"text":"done","language_code":"en"}"#.utf8)

    @Test func retriesRateLimitThenSucceeds() async throws {
        let fixture = try StubFixture([.status(429), .status(200, body: Self.successBody)])
        let response = try await fixture.client().transcribe(audioURL: fixture.audioURL, apiKey: "test-key")

        #expect(response.text == "done")
        #expect(fixture.script.requestCount == 2)
        #expect(fixture.delays.values == [.seconds(2)])
    }

    @Test func retryAfterSecondsHeaderOverridesBackoffAndIsCapped() async throws {
        let fixture = try StubFixture([
            .status(429, headers: ["Retry-After": "7"]),
            .status(503, headers: ["Retry-After": "120"]),
            .status(200, body: Self.successBody)
        ])
        _ = try await fixture.client().transcribe(audioURL: fixture.audioURL, apiKey: "test-key")

        #expect(fixture.script.requestCount == 3)
        #expect(fixture.delays.values == [.seconds(7), .seconds(30)])
    }

    @Test func retryAfterAcceptsHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let header = formatter.string(from: now.addingTimeInterval(12))

        let delay = ElevenLabsTranscriptionClient.retryAfterDelay(from: header, now: now, maximum: .seconds(30))
        #expect(delay == .seconds(12))
        #expect(ElevenLabsTranscriptionClient.retryAfterDelay(from: "-4", now: now, maximum: .seconds(30)) == .zero)
        #expect(ElevenLabsTranscriptionClient.retryAfterDelay(from: "soon", now: now, maximum: .seconds(30)) == nil)
    }

    @Test func backoffJitterStaysWithinTwentyFivePercent() async throws {
        let fixture = try StubFixture([.status(502), .status(504), .status(200, body: Self.successBody)])
        let client = fixture.client(policy: ElevenLabsTranscriptionClient.RetryPolicy())
        _ = try await client.transcribe(audioURL: fixture.audioURL, apiKey: "test-key")

        let delays = fixture.delays.values
        #expect(delays.count == 2)
        #expect(delays.first.map { $0 >= .milliseconds(1_500) && $0 <= .milliseconds(2_500) } == true)
        #expect(delays.last.map { $0 >= .milliseconds(4_500) && $0 <= .milliseconds(7_500) } == true)
    }

    @Test(arguments: [400, 401, 402, 403, 413, 422])
    func clientErrorsFailFast(status: Int) async throws {
        let fixture = try StubFixture([.status(status, body: Data("nope".utf8))])
        let error = await captureError { _ = try await fixture.client().transcribe(audioURL: fixture.audioURL, apiKey: "bad") }

        guard case let .providerRejected(code, _)? = error as? ProviderError else {
            Issue.record("expected providerRejected, got \(String(describing: error))")
            return
        }
        #expect(code == status)
        #expect(fixture.script.requestCount == 1)
        #expect(fixture.delays.values.isEmpty)
    }

    @Test func persistentOutageFailsAfterThreeAttempts() async throws {
        let fixture = try StubFixture([.status(503, body: Data("down".utf8))])
        let error = await captureError { _ = try await fixture.client().transcribe(audioURL: fixture.audioURL, apiKey: "test-key") }

        guard case let .providerRejected(code, message)? = error as? ProviderError else {
            Issue.record("expected providerRejected, got \(String(describing: error))")
            return
        }
        #expect(code == 503)
        #expect(message == "down")
        #expect(fixture.script.requestCount == 3)
        #expect(fixture.delays.values == [.seconds(2), .seconds(6)])
    }

    @Test func transientNetworkErrorIsRetried() async throws {
        let fixture = try StubFixture([.failure(.networkConnectionLost), .status(200, body: Self.successBody)])
        let response = try await fixture.client().transcribe(audioURL: fixture.audioURL, apiKey: "test-key")

        #expect(response.text == "done")
        #expect(fixture.script.requestCount == 2)
    }

    @Test func nonTransientNetworkErrorIsNotRetried() async throws {
        let fixture = try StubFixture([.failure(.badServerResponse)])
        let error = await captureError { _ = try await fixture.client().transcribe(audioURL: fixture.audioURL, apiKey: "test-key") }

        #expect((error as? URLError)?.code == .badServerResponse)
        #expect(fixture.script.requestCount == 1)
    }

    @Test func cancellationDuringBackoffStopsRetrying() async throws {
        let fixture = try StubFixture([.status(503)])
        let client = fixture.client { _ in throw CancellationError() }
        let error = await captureError { _ = try await client.transcribe(audioURL: fixture.audioURL, apiKey: "test-key") }

        #expect(error is CancellationError)
        #expect(fixture.script.requestCount == 1)
    }

    @Test func cancellingTheTaskStopsRetrying() async throws {
        let fixture = try StubFixture([.status(429)])
        let delays = fixture.delays
        let client = fixture.client { duration in
            delays.append(duration)
            try await Task.sleep(for: .seconds(60))
        }
        let task = Task { try await client.transcribe(audioURL: fixture.audioURL, apiKey: "test-key") }
        for _ in 0..<500 where delays.values.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(delays.values.count == 1)
        task.cancel()
        let error = await captureError { _ = try await task.value }

        #expect(error is CancellationError)
        #expect(fixture.script.requestCount == 1)
    }

    @Test func languageCodeIsSentOnlyWhenProvided() async throws {
        let with = try StubFixture([.status(200, body: Self.successBody)])
        _ = try await with.client().transcribe(audioURL: with.audioURL, apiKey: "test-key", languageCode: "id")
        let withBody = try #require(with.script.requestBodies.first)
        #expect(withBody.contains("name=\"language_code\"\r\n\r\nid\r\n"))

        let without = try StubFixture([.status(200, body: Self.successBody)])
        _ = try await without.client().transcribe(audioURL: without.audioURL, apiKey: "test-key")
        let withoutBody = try #require(without.script.requestBodies.first)
        #expect(!withoutBody.contains("language_code"))
        #expect(withoutBody.contains("name=\"diarize\""))

        let malformed = try StubFixture([.status(200, body: Self.successBody)])
        _ = try await malformed.client().transcribe(audioURL: malformed.audioURL, apiKey: "test-key", languageCode: "en\r\n--x")
        #expect(malformed.script.requestBodies.first?.contains("language_code") == false)
    }

    @Test func straightQuoteAfterWordClosesQuotation() async throws {
        let body = Data("""
        {
          "text": "\\"hello\\" world. John's car",
          "language_code": "en",
          "words": [
            {"text": "\\"", "type": "punctuation", "speaker_id": "speaker_0"},
            {"text": "hello", "type": "word", "speaker_id": "speaker_0"},
            {"text": "\\"", "type": "punctuation", "speaker_id": "speaker_0"},
            {"text": "world", "type": "word", "speaker_id": "speaker_0"},
            {"text": ".", "type": "punctuation", "speaker_id": "speaker_0"},
            {"text": "John", "type": "word", "speaker_id": "speaker_0"},
            {"text": "'s", "type": "word", "speaker_id": "speaker_0"},
            {"text": "car", "type": "word", "speaker_id": "speaker_0"}
          ]
        }
        """.utf8)
        let fixture = try StubFixture([.status(200, body: body)])
        let response = try await fixture.client().transcribe(audioURL: fixture.audioURL, apiKey: "test-key")

        #expect(response.segments.first?.text == "\"hello\" world. John's car")
        #expect(response.text == "Speaker 1:\n\"hello\" world. John's car")
    }

    @Test func openingQuoteAfterSpaceStaysAttachedToNextWord() async throws {
        let body = Data("""
        {
          "text": "said \\"hi\\"",
          "words": [
            {"text": "said", "speaker_id": "speaker_0"},
            {"text": " ", "speaker_id": "speaker_0"},
            {"text": "\\"", "speaker_id": "speaker_0"},
            {"text": "hi", "speaker_id": "speaker_0"},
            {"text": "\\"", "speaker_id": "speaker_0"}
          ]
        }
        """.utf8)
        let fixture = try StubFixture([.status(200, body: body)])
        let response = try await fixture.client().transcribe(audioURL: fixture.audioURL, apiKey: "test-key")

        #expect(response.segments.first?.text == "said \"hi\"")
    }
}

// MARK: - B. Transcription error messages

@Suite("Transcription error messages")
struct TranscriptionErrorMessageHardeningTests {
    @Test(arguments: [401, 403])
    func rejectedKey(status: Int) {
        let message = TranscriptionErrorMessage.message(for: ProviderError.providerRejected(status, "invalid key"))
        #expect(message.contains("API key was rejected"))
        #expect(message.contains("\(status)"))
    }

    @Test func outOfCredits() {
        #expect(TranscriptionErrorMessage.message(for: ProviderError.providerRejected(402, "")).contains("out of credits/quota"))
    }

    @Test func fileTooLargeKeepsProviderContext() {
        let message = TranscriptionErrorMessage.message(for: ProviderError.providerRejected(413, "too large"))
        #expect(message.contains("file is too large"))
        #expect(message.contains("Provider rejected"))
    }

    @Test func rateLimited() {
        let message = TranscriptionErrorMessage.message(for: ProviderError.providerRejected(429, ""))
        #expect(message.contains("rate limited"))
        #expect(message.contains("retried automatically"))
    }

    @Test(arguments: [500, 502, 503, 504, 599])
    func providerOutage(status: Int) {
        let message = TranscriptionErrorMessage.message(for: ProviderError.providerRejected(status, "oops"))
        #expect(message.contains("provider outage"))
        #expect(message.contains("try again later"))
    }

    @Test func otherRejectionsKeepProviderMessage() {
        let message = TranscriptionErrorMessage.message(for: ProviderError.providerRejected(422, "bad model"))
        #expect(message == "Provider rejected the transcription request with HTTP 422: bad model")
    }

    @Test func decodingErrorMentionsResponseFormat() async throws {
        struct Shape: Decodable { let text: String }
        let error = try #require(await captureError { _ = try JSONDecoder().decode(Shape.self, from: Data("{}".utf8)) })
        #expect(error is DecodingError)
        #expect(TranscriptionErrorMessage.message(for: error).contains("unexpected response format"))
    }

    @Test func cancellation() {
        #expect(TranscriptionErrorMessage.message(for: CancellationError()) == "Transcription cancelled")
        #expect(TranscriptionErrorMessage.message(for: URLError(.cancelled)) == "Transcription cancelled")
    }

    @Test func existingClassificationsAreUnchanged() {
        #expect(TranscriptionErrorMessage.message(for: ProviderError.missingAPIKey("X")).contains("API key"))
        #expect(TranscriptionErrorMessage.message(for: URLError(.timedOut)).contains("timed out"))
        #expect(TranscriptionErrorMessage.message(for: CocoaError(.fileNoSuchFile)).hasPrefix("Transcription failed:"))
    }
}

// MARK: - C. Local HTTP server

@Suite("Local HTTP server hardening")
struct LocalHTTPServerHardeningTests {
    @Test func duplicateHeadersMergeWithLastValueWinning() throws {
        let request = try HTTPRequestParser.parse(raw("GET /health HTTP/1.1\r\nX-Trace: one\r\nx-trace: two\r\nHost: a\r\nHost: b\r\n\r\n"))
        #expect(request.headers["x-trace"] == "two")
        #expect(request.headers["host"] == "b")
    }

    @Test(arguments: ["-1", "abc", "+5", "12x", "99999999999999999999999"])
    func invalidContentLengthIsBadRequest(value: String) async throws {
        let data = raw("POST /summarize HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n{}")
        #expect(HTTPRequestParser.isReadyToParse(data))
        #expect(throws: HTTPRequestError.self) { try HTTPRequestParser.parse(data) }
        let response = await makeServer().response(for: data)
        #expect(statusCode(of: response) == 400)
    }

    @Test func oversizedContentLengthIsPayloadTooLarge() async {
        let data = raw("POST /summarize HTTP/1.1\r\nContent-Length: 5000000\r\n\r\n{}")
        #expect(HTTPRequestParser.isReadyToParse(data))
        #expect(statusCode(of: await makeServer().response(for: data)) == 413)
    }

    @Test(arguments: ["\r\n", "zz\r\nhello\r\n0\r\n\r\n", "-5\r\nhello\r\n0\r\n\r\n", "5\r\nhelloXX0\r\n\r\n", "FFFFFFFFFFFFFFFFF\r\n"])
    func malformedChunkedBodiesAreBadRequest(body: String) async {
        let data = raw("POST /summarize HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" + body)
        #expect(HTTPRequestParser.isReadyToParse(data))
        #expect(throws: HTTPRequestError.self) { try HTTPRequestParser.parse(data) }
        #expect(statusCode(of: await makeServer().response(for: data)) == 400)
    }

    @Test func validChunkedBodyDecodes() throws {
        let partial = raw("POST /summarize HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel")
        #expect(!HTTPRequestParser.isReadyToParse(partial))
        let data = raw("POST /summarize HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
        #expect(HTTPRequestParser.isReadyToParse(data))
        #expect(try HTTPRequestParser.parse(data).body == Data("hello world".utf8))
    }

    @Test func contentLengthWaitsForFullBody() throws {
        #expect(!HTTPRequestParser.isReadyToParse(raw("POST /x HTTP/1.1\r\nContent-Length: 4\r\n\r\nab")))
        #expect(!HTTPRequestParser.isReadyToParse(raw("POST /x HTTP/1.1\r\nContent-Length: 4\r\n")))
        let complete = raw("POST /x?debug=1 HTTP/1.1\r\nContent-Length: 4\r\n\r\nabcdEXTRA")
        #expect(HTTPRequestParser.isReadyToParse(complete))
        let request = try HTTPRequestParser.parse(complete)
        #expect(request.body == Data("abcd".utf8))
        #expect(request.routePath == "/x")
    }

    @Test func bearerTokenComparison() {
        #expect(LocalHTTPServer.constantTimeEquals("abc123", "abc123"))
        #expect(!LocalHTTPServer.constantTimeEquals("abc123", "abc124"))
        #expect(!LocalHTTPServer.constantTimeEquals("abc123", "abc1234"))
        #expect(!LocalHTTPServer.constantTimeEquals("", "a"))
        #expect(LocalHTTPServer.constantTimeEquals("", ""))
        #expect(LocalHTTPServer.isAuthorized(authorizationHeader: "Bearer secret", token: "secret"))
        #expect(LocalHTTPServer.isAuthorized(authorizationHeader: "bearer  secret ", token: "secret"))
        #expect(!LocalHTTPServer.isAuthorized(authorizationHeader: "Basic secret", token: "secret"))
        #expect(!LocalHTTPServer.isAuthorized(authorizationHeader: "Bearer secrex", token: "secret"))
        #expect(!LocalHTTPServer.isAuthorized(authorizationHeader: nil, token: "secret"))
    }

    @Test func errorBodiesAreValidJSONAndMapProviderFailuresTo502() async throws {
        let service = HardeningFakeAIService(summarizeError: ProviderError.providerRejected(500, #"upstream said "no" \ twice"#))
        let server = makeServer(service: service, token: "tok")
        let body = try JSONEncoder().encode(SummarizeRequest(transcript: "hello"))
        let request = raw("POST /summarize HTTP/1.1\r\nAuthorization: Bearer tok\r\nContent-Length: \(body.count)\r\n\r\n") + body

        let response = await server.response(for: request)
        #expect(statusCode(of: response) == 502)
        let decoded = try JSONDecoder().decode([String: String].self, from: responseBody(of: response))
        #expect(decoded["error"]?.contains(#""no" \ twice"#) == true)
    }

    @Test func statusCodeMapping() {
        #expect(LocalHTTPServer.statusCode(for: LocalAPIError.notFound) == 404)
        #expect(LocalHTTPServer.statusCode(for: LocalAPIError.unauthorized) == 401)
        #expect(LocalHTTPServer.statusCode(for: LocalAPIError.forbidden("x")) == 403)
        #expect(LocalHTTPServer.statusCode(for: LocalAPIError.badRequest("x")) == 400)
        #expect(LocalHTTPServer.statusCode(for: HTTPRequestError.payloadTooLarge) == 413)
        #expect(LocalHTTPServer.statusCode(for: ProviderError.providerRejected(401, "")) == 502)
        #expect(LocalHTTPServer.statusCode(for: URLError(.timedOut)) == 502)
    }

    @Test(.timeLimit(.minutes(1)))
    func realServerRoutesHealthNotFoundUnauthorizedForbiddenAndBadJSON() async throws {
        let proxy = LocalAPIProxy(aiService: HardeningFakeAIService()) { _ in false }
        let server = LocalHTTPServer(proxy: proxy, port: 0, bearerToken: "integration-token")
        try server.start()
        defer { server.stop() }
        #expect(server.isListening)
        #expect(server.port != 0 && server.port != 47837 && server.port != 48937)

        let session = URLSession(configuration: .ephemeral)
        let base = try #require(URL(string: "http://127.0.0.1:\(server.port)"))

        let (healthBody, health) = try await session.data(from: base.appendingPathComponent("health"))
        #expect((health as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: healthBody, encoding: .utf8)?.contains("ok") == true)

        var unknown = URLRequest(url: base.appendingPathComponent("does-not-exist"))
        unknown.setValue("Bearer integration-token", forHTTPHeaderField: "Authorization")
        let (unknownBody, unknownResponse) = try await session.data(for: unknown)
        #expect((unknownResponse as? HTTPURLResponse)?.statusCode == 404)
        #expect((try? JSONDecoder().decode([String: String].self, from: unknownBody))?["error"] != nil)

        var badToken = URLRequest(url: base.appendingPathComponent("transcribe"))
        badToken.httpMethod = "POST"
        badToken.httpBody = try JSONEncoder().encode(TranscribeRequest(audioPath: "/tmp/a.m4a", provider: .elevenLabs))
        badToken.setValue("Bearer wrong-token", forHTTPHeaderField: "Authorization")
        let (_, badTokenResponse) = try await session.data(for: badToken)
        #expect((badTokenResponse as? HTTPURLResponse)?.statusCode == 401)

        var forbidden = badToken
        forbidden.setValue("Bearer integration-token", forHTTPHeaderField: "Authorization")
        let (_, forbiddenResponse) = try await session.data(for: forbidden)
        #expect((forbiddenResponse as? HTTPURLResponse)?.statusCode == 403)

        var badJSON = URLRequest(url: base.appendingPathComponent("summarize"))
        badJSON.httpMethod = "POST"
        badJSON.httpBody = Data("{not json".utf8)
        badJSON.setValue("Bearer integration-token", forHTTPHeaderField: "Authorization")
        let (_, badJSONResponse) = try await session.data(for: badJSON)
        #expect((badJSONResponse as? HTTPURLResponse)?.statusCode == 400)

        server.stop()
        #expect(!server.isListening)
    }

    @Test(.timeLimit(.minutes(1)))
    func startThrowsWhenPortIsTaken() throws {
        let first = LocalHTTPServer(proxy: LocalAPIProxy(aiService: HardeningFakeAIService()), port: 0)
        try first.start()
        defer { first.stop() }
        let second = LocalHTTPServer(proxy: LocalAPIProxy(aiService: HardeningFakeAIService()), port: first.port)
        defer { second.stop() }

        #expect(throws: LocalHTTPServerError.self) { try second.start() }
        #expect(!second.isListening)
        #expect(first.isListening)
    }

    private func makeServer(service: HardeningFakeAIService = HardeningFakeAIService(), token: String = "token") -> LocalHTTPServer {
        LocalHTTPServer(proxy: LocalAPIProxy(aiService: service), port: 0, bearerToken: token)
    }

    private func raw(_ text: String) -> Data { Data(text.utf8) }

    private func statusCode(of response: Data) -> Int? {
        guard let line = String(data: response.prefix(32), encoding: .utf8)?.split(separator: " ").dropFirst().first else { return nil }
        return Int(line)
    }

    private func responseBody(of response: Data) -> Data {
        guard let range = response.range(of: Data("\r\n\r\n".utf8)) else { return Data() }
        return Data(response[range.upperBound...])
    }
}

// MARK: - F. API key store

@Suite("API key store precedence")
struct APIKeyStoreHardeningTests {
    @Test func precedenceIsSessionThenKeychainThenEnvironment() throws {
        let keychain = InMemoryKeychain()
        let store = APIKeyStore(environment: ["ELEVENLABS_API_KEY": " env-key "], keychain: keychain)
        #expect(store.apiKey(for: .elevenLabs) == "env-key")
        #expect(store.apiKey(for: .openAI) == nil)

        try store.save(apiKey: "keychain-key", for: .elevenLabs)
        #expect(store.apiKey(for: .elevenLabs) == "keychain-key")

        try store.setSession(apiKey: "session-key", for: .elevenLabs)
        #expect(store.apiKey(for: .elevenLabs) == "session-key")
    }

    @Test func saveReplacesAStaleSessionValue() throws {
        let store = APIKeyStore(environment: [:], keychain: InMemoryKeychain())
        try store.setSession(apiKey: "old-session-key", for: .openAI)
        try store.save(apiKey: "new-saved-key", for: .openAI)
        #expect(store.apiKey(for: .openAI) == "new-saved-key")
    }

    @Test func failedSaveKeepsSessionValue() throws {
        let keychain = InMemoryKeychain(failWrites: true)
        let store = APIKeyStore(environment: [:], keychain: keychain)
        try store.setSession(apiKey: "session-key", for: .openAI)
        #expect(throws: KeyStoreError.self) { try store.save(apiKey: "new", for: .openAI) }
        #expect(store.apiKey(for: .openAI) == "session-key")
    }

    @Test func forgetClearsSessionAndKeychain() throws {
        let keychain = InMemoryKeychain()
        let store = APIKeyStore(environment: ["OPENAI_API_KEY": "env-key"], keychain: keychain)
        try store.save(apiKey: "saved", for: .openAI)
        try store.setSession(apiKey: "session", for: .openAI)
        try store.forget(.openAI)
        #expect(keychain.value(account: AIProvider.openAI.rawValue) == nil)
        #expect(store.apiKey(for: .openAI) == "env-key")
    }

    @Test func emptyKeysAreRejected() {
        let store = APIKeyStore(environment: [:], keychain: InMemoryKeychain())
        #expect(throws: KeyStoreError.self) { try store.save(apiKey: "  \n", for: .openAI) }
        #expect(throws: KeyStoreError.self) { try store.setSession(apiKey: "", for: .openAI) }
    }
}

// MARK: - G. Search indexer

@Suite("Recording search indexer capacity")
struct RecordingSearchIndexerHardeningTests {
    @Test func capacityCountsRecordingsNotFiles() async throws {
        let folder = try HardeningTestFolder()
        let first = makeRecording(in: folder.url, name: "First")
        let second = makeRecording(in: folder.url, name: "Second")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for (recording, text) in [(first, "alpha"), (second, "beta")] {
            try write("\(text) transcript", to: recording.transcriptURL, modifiedAt: stamp)
            try write("\(text) summary", to: recording.summaryURL, modifiedAt: stamp)
        }
        let indexer = RecordingSearchIndexer(capacity: 2)

        let initial = await indexer.documents(for: [first, second])
        #expect(initial.map(\.transcriptText) == ["alpha transcript", "beta transcript"])
        #expect(await indexer.cachedRecordingCount == 2)

        // Same modification date => served from cache, which proves the entries were not evicted.
        try write("changed transcript", to: first.transcriptURL, modifiedAt: stamp)
        let cached = await indexer.documents(for: [first, second])
        #expect(cached.first?.transcriptText == "alpha transcript")

        // A real modification is picked up.
        try write("changed transcript", to: first.transcriptURL, modifiedAt: stamp.addingTimeInterval(60))
        let refreshed = await indexer.documents(for: [first, second])
        #expect(refreshed.first?.transcriptText == "changed transcript")
    }

    @Test func evictsLeastRecentlyUsedRecordingsBeyondCapacity() async throws {
        let folder = try HardeningTestFolder()
        let recordings = (0..<3).map { makeRecording(in: folder.url, name: "R\($0)") }
        let indexer = RecordingSearchIndexer(capacity: 2)
        _ = await indexer.documents(for: recordings)
        #expect(await indexer.cachedRecordingCount == 2)
    }

    private func makeRecording(in folder: URL, name: String) -> RecordingItem {
        let start = Date(timeIntervalSince1970: 1_000)
        let metadata = RecordingMetadata(
            id: UUID(),
            displayName: name,
            source: .microphone,
            audioFileName: "\(name).m4a",
            startedAt: start,
            endedAt: start.addingTimeInterval(10),
            durationSeconds: 10,
            createdAt: start,
            updatedAt: start
        )
        return RecordingItem(metadata: metadata, folderURL: folder)
    }

    private func write(_ text: String, to url: URL, modifiedAt: Date) throws {
        try text.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }
}

// MARK: - I/J. Audio analysis and preparation

@Suite("Audio analysis hardening")
struct AudioAnalysisHardeningTests {
    @Test func confidenceAnalyzerMeasuresToneLevels() async throws {
        let folder = try HardeningTestFolder()
        let wav = folder.url.appendingPathComponent("tone.wav")
        try writeToneWAV(to: wav, duration: 1.5, amplitude: 0.2)

        let report = try await RecordingConfidenceAnalyzer.analyze(
            audioURL: wav,
            source: .microphone,
            expectedChannels: [.microphone: 0.2],
            minimumDuration: 1
        )
        #expect(abs(report.peakLevel - 0.2) < 0.005)
        #expect(abs(report.averageLevel - 0.2 / Float(2).squareRoot()) < 0.005)
        #expect(abs(report.durationSeconds - 1.5) < 0.01)
        #expect(report.issues.isEmpty)
    }

    @Test func confidenceAnalyzerClampsOverRangeSamples() async throws {
        let folder = try HardeningTestFolder()
        let wav = folder.url.appendingPathComponent("hot.wav")
        try writeToneWAV(to: wav, duration: 0.5, amplitude: 1.8)

        let report = try await RecordingConfidenceAnalyzer.analyze(audioURL: wav, source: .microphone, minimumDuration: 0.1)
        #expect(report.peakLevel <= 1)
        #expect(report.averageLevel <= 1)
    }

    @Test func lowSampleRateSourcesCompressInsteadOfFallingBack() async throws {
        let folder = try HardeningTestFolder()
        let wav = folder.url.appendingPathComponent("phone.wav")
        try writeToneWAV(to: wav, duration: 5, amplitude: 0.1)

        let prepared = try await TranscriptionAudioPreparer.prepare(sourceURL: wav, durationSeconds: 5, trimRange: nil, compressionEnabled: true)
        defer { prepared.cleanUp() }
        #expect(!prepared.usedUncompressedFallback)
        #expect(prepared.isTemporary)
        #expect(prepared.url.pathExtension == "m4a")

        let trimmed = try await TranscriptionAudioPreparer.prepare(
            sourceURL: wav,
            durationSeconds: 5,
            trimRange: AudioTrimRange(startSeconds: 1, endSeconds: 3),
            compressionEnabled: true
        )
        defer { trimmed.cleanUp() }
        let duration = try await AVURLAsset(url: trimmed.url).load(.duration).seconds
        #expect(abs(duration - 2) < 0.15)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledPreparationDoesNotFallBackToUploadingOriginal() async throws {
        let folder = try HardeningTestFolder()
        let wav = folder.url.appendingPathComponent("long.wav")
        try writeToneWAV(to: wav, duration: 240, amplitude: 0.1)

        let task = Task {
            try await TranscriptionAudioPreparer.prepare(sourceURL: wav, durationSeconds: 240, trimRange: nil, compressionEnabled: true)
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            let prepared = try await task.value
            // Finishing before the cancel landed is fine, but it must never be the silent fallback.
            #expect(!prepared.usedUncompressedFallback)
            prepared.cleanUp()
        } catch {
            #expect(error is CancellationError)
        }
    }
}

// MARK: - Helpers

private func captureError(_ body: () async throws -> Void) async -> Error? {
    do {
        try await body()
        return nil
    } catch {
        return error
    }
}

private func writeToneWAV(to url: URL, duration: TimeInterval, amplitude: Float) throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * format.sampleRate)),
          let channel = buffer.floatChannelData?[0] else {
        throw CocoaError(.featureUnsupported)
    }
    buffer.frameLength = buffer.frameCapacity
    for frame in 0..<Int(buffer.frameLength) {
        channel[frame] = amplitude * Float(sin(2 * Double.pi * 440 * Double(frame) / format.sampleRate))
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

final class HardeningTestFolder: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("msr-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

final class HardeningFakeAIService: AIService, @unchecked Sendable {
    private let summarizeError: Error?

    init(summarizeError: Error? = nil) {
        self.summarizeError = summarizeError
    }

    func transcribe(audioURL: URL, provider: AIProvider) async throws -> TranscribeResponse {
        TranscribeResponse(text: "ok", provider: provider, languageCode: "en")
    }

    func summarize(transcript: String) async throws -> SummarizeResponse {
        if let summarizeError { throw summarizeError }
        return SummarizeResponse(markdown: transcript)
    }

    // MERGE NOTE: `generateTitle(transcript:)` is being added to the `AIService` protocol on a parallel
    // branch. Implemented here so this fake still conforms after that merge (harmless extra method before it).
    func generateTitle(transcript: String) async throws -> String {
        "Test Title"
    }
}

private final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private let failWrites: Bool

    init(failWrites: Bool = false) {
        self.failWrites = failWrites
    }

    func value(account: String) -> String? {
        lock.withLock { items[account] }
    }

    func read(service: String, account: String) -> String? {
        lock.withLock { items[account] }
    }

    func write(_ value: String, service: String, account: String) throws {
        if failWrites { throw KeyStoreError.writeFailed(-1) }
        lock.withLock { items[account] = value }
    }

    func delete(service: String, account: String) throws {
        lock.withLock { _ = items.removeValue(forKey: account) }
    }
}

private final class DelayLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Duration] = []

    var values: [Duration] { lock.withLock { storage } }

    func append(_ value: Duration) {
        lock.withLock { storage.append(value) }
    }
}

/// One isolated stub endpoint per test (unique host), so suites can run in parallel.
private struct StubFixture {
    let folder: HardeningTestFolder
    let audioURL: URL
    let endpoint: URL
    let script: StubURLProtocol.Script
    let delays = DelayLog()

    init(_ replies: [StubURLProtocol.Reply]) throws {
        folder = try HardeningTestFolder()
        audioURL = folder.url.appendingPathComponent("meeting.m4a")
        try Data("audio".utf8).write(to: audioURL)
        let registration = StubURLProtocol.register(replies)
        script = registration.script
        endpoint = URL(string: "https://\(registration.host)/v1/speech-to-text")!
    }

    func client(
        policy: ElevenLabsTranscriptionClient.RetryPolicy = .init(jitterFraction: 0),
        sleep: (@Sendable (Duration) async throws -> Void)? = nil
    ) -> ElevenLabsTranscriptionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let delays = self.delays
        return ElevenLabsTranscriptionClient(
            endpoint: endpoint,
            urlSession: URLSession(configuration: configuration),
            retryPolicy: policy,
            sleep: sleep ?? { delays.append($0) }
        )
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        var body = Data()
        var failure: URLError.Code?

        static func status(_ code: Int, headers: [String: String] = [:], body: Data = Data()) -> Reply {
            Reply(statusCode: code, headers: headers, body: body)
        }

        static func failure(_ code: URLError.Code) -> Reply {
            Reply(failure: code)
        }
    }

    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Reply]
        private var bodies: [String] = []

        init(_ replies: [Reply]) {
            self.replies = replies
        }

        var requestCount: Int { lock.withLock { bodies.count } }
        var requestBodies: [String] { lock.withLock { bodies } }

        /// Returns the next scripted reply; the last one repeats forever.
        func nextReply(recordingBody body: String) -> Reply {
            lock.withLock {
                bodies.append(body)
                return replies.count > 1 ? replies.removeFirst() : (replies.first ?? Reply())
            }
        }
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]

    static func register(_ replies: [Reply]) -> (host: String, script: Script) {
        let host = "stub-\(UUID().uuidString.lowercased()).example.test"
        let script = Script(replies)
        registryLock.withLock { scripts[host] = script }
        return (host, script)
    }

    private static func script(for request: URLRequest) -> Script? {
        guard let host = request.url?.host else { return nil }
        return registryLock.withLock { scripts[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        script(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let script = Self.script(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let reply = script.nextReply(recordingBody: Self.bodyString(for: request) ?? "")
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        var headers = reply.headers
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
        let response = HTTPURLResponse(url: url, statusCode: reply.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyString(for request: URLRequest) -> String? {
        if let httpBody = request.httpBody {
            return String(data: httpBody, encoding: .utf8)
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8)
    }
}
