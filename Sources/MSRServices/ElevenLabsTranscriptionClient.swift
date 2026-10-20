import Foundation
import MSRCore

public final class ElevenLabsTranscriptionClient: Sendable {
    /// Retry behaviour for failures where the upload was certainly not processed
    /// (rate limits, gateway/unavailable responses, connections that never opened).
    public struct RetryPolicy: Sendable, Equatable {
        /// Total attempts including the first request. Values below 1 are treated as 1.
        public var maxAttempts: Int
        /// Base delay before each retry; the last entry is reused when more retries remain.
        public var backoff: [Duration]
        /// Random spread applied to each backoff delay (0.25 means ±25 %). Not applied to `Retry-After`.
        public var jitterFraction: Double
        /// Upper bound for a provider-supplied `Retry-After` delay.
        public var maximumRetryAfter: Duration

        public init(
            maxAttempts: Int = 3,
            backoff: [Duration] = [.seconds(2), .seconds(6)],
            jitterFraction: Double = 0.25,
            maximumRetryAfter: Duration = .seconds(30)
        ) {
            self.maxAttempts = maxAttempts
            self.backoff = backoff
            self.jitterFraction = jitterFraction
            self.maximumRetryAfter = maximumRetryAfter
        }

        public static let `default` = RetryPolicy()
        public static let none = RetryPolicy(maxAttempts: 1)
    }

    /// Statuses where the provider did not run the transcription. 500 and 504
    /// are excluded: the upload may already have been received (and billed).
    static let retryableStatusCodes: Set<Int> = [429, 502, 503]
    /// Errors raised before the request reached the provider. `.timedOut` and
    /// `.networkConnectionLost` are excluded: the upload may already have been
    /// received (and billed), so a retry could charge twice.
    static let retryableURLErrorCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed
    ]

    private static let transcriptionTimeout: TimeInterval = 15 * 60
    private static let maximumResponseBytes = 64 * 1_024 * 1_024

    private let endpoint: URL
    private let urlSession: URLSession
    private let retryPolicy: RetryPolicy
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    public init(
        endpoint: URL = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!,
        urlSession: URLSession = .shared,
        retryPolicy: RetryPolicy = .default,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.retryPolicy = retryPolicy
        self.sleep = sleep
        self.now = now
    }

    /// Uploads `audioURL` to ElevenLabs Scribe.
    ///
    /// HTTP 429/502/503 and `URLError`s raised before a connection opened (no internet,
    /// cannot find/connect to host, DNS failure) are retried per `retryPolicy` (honoring
    /// `Retry-After`). Everything else, including 500, 504, `.timedOut`,
    /// `.networkConnectionLost` (the upload may already have been billed) and any
    /// cancellation, is thrown immediately.
    /// - Parameter languageCode: Optional ISO-639 hint sent as the `language_code` field. Blank or
    ///   malformed values are ignored so the provider keeps auto-detecting the language.
    public func transcribe(audioURL: URL, apiKey: String, languageCode: String? = nil) async throws -> TranscribeResponse {
        let media = MultipartFileBody.neutralMediaDescriptor(for: audioURL)
        var fields: [(name: String, value: String)] = [("model_id", "scribe_v2"), ("diarize", "true")]
        if let languageCode = Self.sanitizedLanguageCode(languageCode) {
            fields.append(("language_code", languageCode))
        }
        let multipart = try MultipartFileBody.create(
            fields: fields,
            fileFieldName: "file",
            neutralFileName: media.fileName,
            mimeType: media.mimeType,
            sourceURL: audioURL
        )
        defer { try? FileManager.default.removeItem(at: multipart.url) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.transcriptionTimeout
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")

        let maxAttempts = max(1, retryPolicy.maxAttempts)
        var attempt = 1
        while true {
            try Task.checkCancellation()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await urlSession.upload(for: request, fromFile: multipart.url)
            } catch {
                guard attempt < maxAttempts, !Task.isCancelled, Self.isRetryable(error) else { throw error }
                try await sleep(backoffDelay(afterAttempt: attempt))
                attempt += 1
                continue
            }
            guard data.count <= Self.maximumResponseBytes else { throw ProviderError.responseTooLarge }
            guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                let message = String((String(data: data, encoding: .utf8) ?? "No response body").prefix(500))
                let rejection = ProviderError.providerRejected(http.statusCode, message)
                guard attempt < maxAttempts,
                      !Task.isCancelled,
                      Self.retryableStatusCodes.contains(http.statusCode) else { throw rejection }
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap {
                    Self.retryAfterDelay(from: $0, now: now(), maximum: retryPolicy.maximumRetryAfter)
                }
                try await sleep(retryAfter ?? backoffDelay(afterAttempt: attempt))
                attempt += 1
                continue
            }
            let decoded = try JSONDecoder().decode(ElevenLabsTranscriptionResponse.self, from: data)
            return TranscribeResponse(
                text: decoded.diarizedText ?? decoded.text,
                provider: .elevenLabs,
                languageCode: decoded.languageCode,
                segments: decoded.segments
            )
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        guard !(error is CancellationError), let urlError = error as? URLError else { return false }
        return retryableURLErrorCodes.contains(urlError.code)
    }

    private func backoffDelay(afterAttempt attempt: Int) -> Duration {
        guard !retryPolicy.backoff.isEmpty else { return .zero }
        let base = retryPolicy.backoff[min(max(0, attempt - 1), retryPolicy.backoff.count - 1)]
        let spread = min(1, max(0, retryPolicy.jitterFraction))
        guard spread > 0 else { return base }
        return base * (1 + Double.random(in: -spread...spread))
    }

    /// Parses a `Retry-After` value (delta-seconds or HTTP-date) into a delay clamped to `0...maximum`.
    static func retryAfterDelay(from value: String, now: Date, maximum: Duration) -> Duration? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let seconds: Double
        if let delta = Double(trimmed), delta.isFinite {
            seconds = delta
        } else if let date = httpDate(from: trimmed) {
            seconds = date.timeIntervalSince(now)
        } else {
            return nil
        }
        let bounded = min(max(0, seconds), 86_400)
        return min(Duration.milliseconds(Int64((bounded * 1_000).rounded())), maximum)
    }

    private static func httpDate(from value: String) -> Date? {
        // RFC 9110 §5.6.7: IMF-fixdate, obsolete RFC 850, and asctime.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        let collapsed = value.replacingOccurrences(of: "  ", with: " ")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: collapsed) {
                return date
            }
        }
        return nil
    }

    static func sanitizedLanguageCode(_ code: String?) -> String? {
        guard let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.count <= 16,
              trimmed.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_" })
        else { return nil }
        return trimmed
    }
}

private struct ElevenLabsTranscriptionResponse: Decodable {
    let text: String
    let languageCode: String?
    let words: [ElevenLabsWord]?

    enum CodingKeys: String, CodingKey {
        case text
        case languageCode = "language_code"
        case words
    }

    var diarizedText: String? {
        guard let words else {
            return nil
        }
        return Self.formatSpeakerTurns(from: words)
    }

    var segments: [TranscriptSegment] {
        guard let words else { return [] }
        return Self.makeSegments(from: words)
    }

    private static func formatSpeakerTurns(from words: [ElevenLabsWord]) -> String? {
        var speakerLabels: [String: String] = [:]
        var turns: [SpeakerTurn] = []

        var currentSpeakerID = "speaker_unknown"
        for word in words {
            guard !word.text.isEmpty else { continue }
            let speakerID = word.speakerID ?? currentSpeakerID
            currentSpeakerID = speakerID
            let label = speakerLabels[speakerID] ?? {
                let newLabel = "Speaker \(speakerLabels.count + 1)"
                speakerLabels[speakerID] = newLabel
                return newLabel
            }()

            if let lastIndex = turns.indices.last, turns[lastIndex].label == label {
                appendToken(word.text, to: &turns[lastIndex].text)
            } else {
                turns.append(SpeakerTurn(label: label, text: word.text))
            }
        }

        let rendered = turns.compactMap { turn -> String? in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            return "\(turn.label):\n\(text)"
        }.joined(separator: "\n\n")

        return rendered.isEmpty ? nil : rendered
    }

    private static func makeSegments(from words: [ElevenLabsWord]) -> [TranscriptSegment] {
        var speakerLabels: [String: String] = [:]
        var turns: [TranscriptSegment] = []

        var currentSpeakerID = "speaker_unknown"
        for word in words {
            guard !word.text.isEmpty else { continue }
            let speakerID = word.speakerID ?? currentSpeakerID
            currentSpeakerID = speakerID
            let label = speakerLabels[speakerID] ?? {
                let newLabel = "Speaker \(speakerLabels.count + 1)"
                speakerLabels[speakerID] = newLabel
                return newLabel
            }()
            let trimmedText = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                // Keep explicit spacing tokens inside a turn so quote/punctuation spacing matches the diarized text.
                if let lastIndex = turns.indices.last, turns[lastIndex].speaker == label {
                    appendToken(word.text, to: &turns[lastIndex].text)
                }
                continue
            }

            if let lastIndex = turns.indices.last, turns[lastIndex].speaker == label {
                appendToken(word.text, to: &turns[lastIndex].text)
                turns[lastIndex].endTime = word.end ?? turns[lastIndex].endTime
            } else {
                turns.append(
                    TranscriptSegment(
                        speaker: label,
                        startTime: word.start,
                        endTime: word.end,
                        text: trimmedText
                    )
                )
            }
        }

        return turns.map { segment in
            var cleaned = segment
            cleaned.text = cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned
        }.filter { !$0.text.isEmpty }
    }

    private static func appendToken(_ token: String, to text: inout String) {
        guard !token.isEmpty else { return }
        // Collapse runs of spacing tokens so explicit spaces never double up.
        if token.allSatisfy(\.isWhitespace), text.last?.isWhitespace == true {
            return
        }
        if text.isEmpty {
            text += token
            return
        }
        if shouldInsertSpace(before: token, after: text) {
            text += " "
        }
        text += token
    }

    private static func shouldInsertSpace(before token: String, after existingText: String) -> Bool {
        guard let firstTokenCharacter = token.first,
              let lastExistingCharacter = existingText.last else {
            return false
        }
        if firstTokenCharacter.isWhitespace || lastExistingCharacter.isWhitespace {
            return false
        }
        if isClosingPunctuation(firstTokenCharacter) {
            return false
        }
        // A straight quote directly after a word closes that word: `"hello` + `"` -> `"hello"`.
        if isStraightQuote(firstTokenCharacter), isWordCharacter(lastExistingCharacter) {
            return false
        }
        if isStraightQuote(lastExistingCharacter) {
            // An existing straight quote is opening at the start or after whitespace/opening punctuation,
            // and closing after a word or closing punctuation (`"hello"` + `world` -> `"hello" world`).
            return isClosingStraightQuote(at: existingText.index(before: existingText.endIndex), in: existingText)
        }
        if isOpeningPunctuation(lastExistingCharacter) {
            return false
        }
        return true
    }

    private static func isClosingStraightQuote(at index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return false }
        let previous = text[text.index(before: index)]
        if previous.isWhitespace || isOpeningPunctuation(previous) {
            return false
        }
        return isWordCharacter(previous) || isClosingPunctuation(previous)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func isStraightQuote(_ character: Character) -> Bool {
        character == "\"" || character == "'"
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        [".", ",", "!", "?", ":", ";", "%", ")", "]", "}", "…", "”", "’"].contains(character)
    }

    private static func isOpeningPunctuation(_ character: Character) -> Bool {
        ["(", "[", "{", "“", "‘", "\"", "'"].contains(character)
    }
}

private struct ElevenLabsWord: Decodable {
    let text: String
    let speakerID: String?
    let start: TimeInterval?
    let end: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case text
        case speakerID = "speaker_id"
        case start
        case end
    }
}

private struct SpeakerTurn {
    let label: String
    var text: String
}
