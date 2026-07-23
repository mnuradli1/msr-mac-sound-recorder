import Foundation
import MSRCore

public final class ElevenLabsTranscriptionClient {
    private static let transcriptionTimeout: TimeInterval = 15 * 60
    private static let maximumResponseBytes = 64 * 1_024 * 1_024

    private let endpoint: URL
    private let urlSession: URLSession

    public init(
        endpoint: URL = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.urlSession = urlSession
    }

    public func transcribe(audioURL: URL, apiKey: String) async throws -> TranscribeResponse {
        let media = MultipartFileBody.neutralMediaDescriptor(for: audioURL)
        let multipart = try MultipartFileBody.create(
            fields: [("model_id", "scribe_v2"), ("diarize", "true")],
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

        let (data, response) = try await urlSession.upload(for: request, fromFile: multipart.url)
        guard data.count <= Self.maximumResponseBytes else { throw ProviderError.responseTooLarge }
        try Self.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(ElevenLabsTranscriptionResponse.self, from: data)
        return TranscribeResponse(
            text: decoded.diarizedText ?? decoded.text,
            provider: .elevenLabs,
            languageCode: decoded.languageCode,
            segments: decoded.segments
        )
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String((String(data: data, encoding: .utf8) ?? "No response body").prefix(500))
            throw ProviderError.providerRejected(http.statusCode, message)
        }
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
            guard !trimmedText.isEmpty else { continue }

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
        if isOpeningPunctuation(lastExistingCharacter) {
            return false
        }
        return true
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        [".", ",", "!", "?", ":", ";", "%", ")", "]", "}", "…"].contains(character)
    }

    private static func isOpeningPunctuation(_ character: Character) -> Bool {
        ["(", "[", "{", "“", "\"", "'"].contains(character)
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
