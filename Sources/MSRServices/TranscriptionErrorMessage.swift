import Foundation

public enum TranscriptionErrorMessage {
    public static func message(for error: Error) -> String {
        if let providerError = error as? ProviderError {
            return message(for: providerError)
        }
        if let urlError = error as? URLError {
            return message(for: urlError)
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
        case let .providerRejected(status, message):
            return "Provider rejected the transcription request with HTTP \(status): \(message)"
        }
    }

    private static func message(for error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "Transcription upload timed out. Check the connection and retry the same recording."
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed:
            return "Network connection failed during transcription. Check the connection and retry."
        default:
            return "Network error during transcription: \(error.localizedDescription)"
        }
    }
}
