import Foundation
import MSRCore

public final class ElevenLabsTranscriptionClient {
    private static let transcriptionTimeout: TimeInterval = 30 * 60

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
        let audioData = try Data(contentsOf: audioURL)
        var multipart = MultipartFormData()
        multipart.appendField(name: "model_id", value: "scribe_v2")
        multipart.appendField(name: "diarize", value: "true")
        multipart.appendFile(
            name: "file",
            fileName: audioURL.lastPathComponent,
            mimeType: "audio/mp4",
            data: audioData
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.transcriptionTimeout
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.finalize()

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(ElevenLabsTranscriptionResponse.self, from: data)
        return TranscribeResponse(
            text: decoded.diarizedText ?? decoded.text,
            provider: .elevenLabs,
            languageCode: decoded.languageCode
        )
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "No response body"
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

    private static func formatSpeakerTurns(from words: [ElevenLabsWord]) -> String? {
        var speakerLabels: [String: String] = [:]
        var turns: [SpeakerTurn] = []

        for word in words {
            guard let speakerID = word.speakerID, !word.text.isEmpty else {
                continue
            }
            let label = speakerLabels[speakerID] ?? {
                let newLabel = "Speaker \(speakerLabels.count + 1)"
                speakerLabels[speakerID] = newLabel
                return newLabel
            }()

            if let lastIndex = turns.indices.last, turns[lastIndex].label == label {
                turns[lastIndex].text += word.text
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
}

private struct ElevenLabsWord: Decodable {
    let text: String
    let speakerID: String?

    enum CodingKeys: String, CodingKey {
        case text
        case speakerID = "speaker_id"
    }
}

private struct SpeakerTurn {
    let label: String
    var text: String
}
