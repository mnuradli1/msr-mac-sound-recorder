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
            text: decoded.text,
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

    enum CodingKeys: String, CodingKey {
        case text
        case languageCode = "language_code"
    }
}
