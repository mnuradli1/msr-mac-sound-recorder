import Foundation

public enum TranscriptExportFormat: String, CaseIterable, Identifiable, Sendable {
    case text
    case markdown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .text:
            return "Plain Text"
        case .markdown:
            return "Markdown"
        }
    }

    public var fileExtension: String {
        switch self {
        case .text:
            return "txt"
        case .markdown:
            return "md"
        }
    }
}

public enum TranscriptExporter {
    public static func content(
        transcript: String,
        recordingName: String,
        format: TranscriptExportFormat
    ) -> String {
        switch format {
        case .text:
            return transcript
        case .markdown:
            return """
            # \(recordingName)

            ## Transcript

            \(transcript)
            """
        }
    }
}
