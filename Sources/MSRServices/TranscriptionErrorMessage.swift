import Foundation

public enum TranscriptionErrorMessage {
    public static func message(for error: Error) -> String {
        if error is CancellationError {
            return "Transcription cancelled"
        }
        if let providerError = error as? ProviderError {
            return message(for: providerError)
        }
        if let urlError = error as? URLError {
            return message(for: urlError)
        }
        if error is DecodingError {
            return "Provider returned an unexpected response format. Retry once; if it keeps failing, the provider API may have changed."
        }
        return "Transcription failed: \(error.localizedDescription)"
    }

    private static func message(for error: ProviderError) -> String {
        switch error {
        case .missingAPIKey:
            return "Transcription needs an API key. Add it in Settings, then retry."
        case let .audioFileMissing(path):
            return "Audio file was not found: \(path). Show the recording in Finder and confirm it still exists."
        case .invalidResponse:
            return "Provider returned an invalid transcription response. Retry once, then check provider status if it keeps failing."
        case let .providerRejected(status, providerMessage):
            return rejectionMessage(status: status, providerMessage: providerMessage)
        case .responseTooLarge:
            return "Provider response exceeded the 64 MB safety limit."
        }
    }

    private static func rejectionMessage(status: Int, providerMessage: String) -> String {
        switch status {
        case 401, 403:
            return "API key was rejected by the provider (HTTP \(status)). Check or replace the key in Settings, then retry."
        case 402:
            return "Provider account is out of credits/quota (HTTP 402). Top up or upgrade the plan, then retry."
        case 413:
            return "Provider rejected the upload because the audio file is too large (HTTP 413). Trim the recording or turn on upload compression, then retry."
        case 429:
            return "Provider rate limited the transcription request (HTTP 429); it was retried automatically but is still limited. Wait a minute, then retry."
        case 500...599:
            return "Transcription provider outage (HTTP \(status)); try again later."
        default:
            return "Provider rejected the transcription request with HTTP \(status): \(providerMessage)"
        }
    }

    private static func message(for error: URLError) -> String {
        switch error.code {
        case .cancelled:
            return "Transcription cancelled"
        case .timedOut:
            return "Transcription upload timed out. Check the connection and retry the same recording."
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "Network connection failed during transcription. Check the connection and retry."
        default:
            return "Network error during transcription: \(error.localizedDescription)"
        }
    }
}
