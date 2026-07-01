import Foundation

public struct RecordingSearchDocument: Equatable, Sendable {
    public var recording: RecordingItem
    public var transcriptText: String
    public var summaryText: String

    public init(
        recording: RecordingItem,
        transcriptText: String = "",
        summaryText: String = ""
    ) {
        self.recording = recording
        self.transcriptText = transcriptText
        self.summaryText = summaryText
    }
}

public enum RecordingSearch {
    public static func filter(
        _ documents: [RecordingSearchDocument],
        query: String,
        calendar: Calendar = .current
    ) -> [RecordingSearchDocument] {
        let tokens = searchTokens(for: query)
        guard !tokens.isEmpty else { return documents }

        return documents.filter { document in
            let searchableText = normalized(searchText(for: document, calendar: calendar))
            return tokens.allSatisfy { searchableText.contains($0) }
        }
    }

    private static func searchTokens(for query: String) -> [String] {
        normalized(query)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func searchText(for document: RecordingSearchDocument, calendar: Calendar) -> String {
        [
            document.recording.displayName,
            document.recording.source.displayName,
            sourceAliases(for: document.recording.source),
            dateSearchText(for: document.recording.startedAt, calendar: calendar),
            durationText(for: document.recording.durationSeconds),
            document.transcriptText,
            document.summaryText
        ].joined(separator: " ")
    }

    private static func sourceAliases(for source: AudioSource) -> String {
        switch source {
        case .microphone:
            return "microphone mic"
        case .system:
            return "system audio"
        case .micAndSystem:
            return "both mic microphone system audio mic and system"
        }
    }

    private static func dateSearchText(for date: Date, calendar: Calendar) -> String {
        let dateTimeFormatter = DateFormatter()
        dateTimeFormatter.calendar = calendar
        dateTimeFormatter.locale = Locale(identifier: "en_US_POSIX")

        let formats = [
            "yyyy-MM-dd",
            "yyyy-MM-dd HH.mm",
            "yyyy-MM-dd HH:mm",
            "MMM d yyyy",
            "MMMM d yyyy"
        ]

        return formats.map { format in
            dateTimeFormatter.dateFormat = format
            return dateTimeFormatter.string(from: date)
        }.joined(separator: " ")
    }

    private static func durationText(for seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
