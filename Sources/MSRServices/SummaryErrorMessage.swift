import Foundation

/// User-facing wording for a failed summary request (manual Summarize or
/// auto-summarize), parallel to `TranscriptionErrorMessage`.
public enum SummaryErrorMessage {
    public static func message(for error: Error) -> String {
        if error is CancellationError {
            return "Summary cancelled"
        }
        if let providerError = error as? ProviderError {
            return message(for: providerError)
        }
        if let urlError = error as? URLError {
            return message(for: urlError)
        }
        if error is DecodingError {
            return "The summary provider returned an unexpected response format. Retry once; if it keeps failing, the provider API may have changed."
        }
        if error is TranscriptPublisher.EmptySummaryError {
            return "The summary provider returned an empty summary. Press Summarize to try again."
        }
        return "Summary failed: \(error.localizedDescription)"
    }

    private static func message(for error: ProviderError) -> String {
        switch error {
        case .missingAPIKey:
            return "Summaries need an OpenAI or DeepSeek API key (\(ProviderError.textModelKeyNames)). Add one in Settings, then retry."
        case .audioFileMissing:
            return "Summary failed: \(error.localizedDescription)"
        case .invalidResponse:
            return "The summary provider returned an invalid response. Retry once, then check provider status if it keeps failing."
        case let .providerRejected(status, providerMessage):
            return rejectionMessage(status: status, providerMessage: providerMessage)
        case .responseTooLarge:
            return "The summary provider's response exceeded the 64 MB safety limit."
        }
    }

    private static func rejectionMessage(status: Int, providerMessage: String) -> String {
        switch status {
        case 401, 403:
            return "The summary provider rejected the API key (HTTP \(status)). Check or replace the OpenAI or DeepSeek key in Settings, then retry."
        case 402:
            return "The summary provider account is out of credits/quota (HTTP 402). Top up or upgrade the plan, then retry."
        case 413:
            return "The transcript is too long for the summary provider (HTTP 413). Trim the transcript, then retry."
        case 429:
            return "The summary provider rate limited the request (HTTP 429). Wait a minute, then retry."
        case 500...599:
            return "Summary provider outage (HTTP \(status)); try again later."
        default:
            return "The summary provider rejected the request with HTTP \(status): \(providerMessage)"
        }
    }

    private static func message(for error: URLError) -> String {
        switch error.code {
        case .cancelled:
            return "Summary cancelled"
        case .timedOut:
            return "The summary request timed out. Check the connection, then press Summarize to retry."
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "Network connection failed while summarizing. Check the connection and retry."
        default:
            return "Network error while summarizing: \(error.localizedDescription)"
        }
    }
}
