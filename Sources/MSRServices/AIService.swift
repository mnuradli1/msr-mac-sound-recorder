import Foundation
import MSRCore

public protocol AIService: AnyObject, Sendable {
    func transcribe(audioURL: URL, provider: AIProvider) async throws -> TranscribeResponse
    func summarize(transcript: String) async throws -> SummarizeResponse
    /// A short, descriptive title for the transcript, already cleaned with
    /// `MeetingTitleGenerator.cleaned(_:fallback:)`. Throws when no title could
    /// be produced (for example a missing credential or an empty reply).
    func generateTitle(transcript: String) async throws -> String
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
