import Foundation
import MSRCore

public protocol AIService: AnyObject, Sendable {
    func transcribe(audioURL: URL, provider: AIProvider) async throws -> TranscribeResponse
    /// Transcribes with an optional ISO-639-1 language hint
    /// (`TranscriptionLanguage.languageCode`; `nil` = auto-detect). The default
    /// implementation ignores the hint and calls `transcribe(audioURL:provider:)`.
    func transcribe(audioURL: URL, provider: AIProvider, languageCode: String?) async throws -> TranscribeResponse
    func summarize(transcript: String) async throws -> SummarizeResponse
    /// A short, descriptive title for the transcript, already cleaned with
    /// `MeetingTitleGenerator.cleaned(_:fallback:)`. Throws when no title could
    /// be produced (for example a missing credential or an empty reply).
    func generateTitle(transcript: String) async throws -> String
}

extension AIService {
    public func transcribe(audioURL: URL, provider: AIProvider, languageCode: String?) async throws -> TranscribeResponse {
        try await transcribe(audioURL: audioURL, provider: provider)
    }
}

public enum LocalAPIError: Error, LocalizedError {
    case notFound
    case badRequest(String)
    case unauthorized
    case forbidden(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "Endpoint not found."
        case let .badRequest(message):
            return message
        case .unauthorized:
            return "A valid bearer token is required."
        case let .forbidden(message):
            return message
        }
    }
}

public struct LocalAPIHTTPResponse: Sendable {
    public var statusCode: Int
    public var body: Data
    public var contentType: String

    public init(statusCode: Int, body: Data, contentType: String = "application/json") {
        self.statusCode = statusCode
        self.body = body
        self.contentType = contentType
    }
}
