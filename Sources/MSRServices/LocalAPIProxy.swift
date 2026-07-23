import Foundation
import MSRCore

public final class LocalAPIProxy: @unchecked Sendable {
    private let aiService: AIService
    private let pathAuthorization: (@Sendable (URL) -> Bool)?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(aiService: AIService, pathAuthorization: (@Sendable (URL) -> Bool)? = nil) {
        self.aiService = aiService
        self.pathAuthorization = pathAuthorization
    }

    public func handle(method: String, path: String, body: Data) async throws -> LocalAPIHTTPResponse {
        switch (method.uppercased(), path) {
        case ("GET", "/health"):
            return try json(["status": "ok"])
        case ("POST", "/transcribe"):
            let request = try decoder.decode(TranscribeRequest.self, from: body)
            guard !request.audioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalAPIError.badRequest("audioPath is required.")
            }
            let audioURL = URL(fileURLWithPath: request.audioPath).standardizedFileURL
            if let pathAuthorization, !pathAuthorization(audioURL) {
                throw LocalAPIError.forbidden("The requested audio file is outside the approved recordings library.")
            }
            let response = try await aiService.transcribe(
                audioURL: audioURL,
                provider: request.provider
            )
            return try json(response)
        case ("POST", "/summarize"):
            let request = try decoder.decode(SummarizeRequest.self, from: body)
            guard !request.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalAPIError.badRequest("transcript is required.")
            }
            let response = try await aiService.summarize(transcript: request.transcript)
            return try json(response)
        default:
            throw LocalAPIError.notFound
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> LocalAPIHTTPResponse {
        LocalAPIHTTPResponse(statusCode: 200, body: try encoder.encode(value))
    }
}
