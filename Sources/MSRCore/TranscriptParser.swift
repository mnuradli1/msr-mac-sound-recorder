import Foundation

public struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var speaker: String
    public var startTime: TimeInterval?
    public var endTime: TimeInterval?
    public var text: String

    public init(
        id: UUID = UUID(),
        speaker: String,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        text: String
    ) {
        self.id = id
        self.speaker = speaker
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public enum TranscriptParser {
    public static func segments(from transcript: String) -> [TranscriptSegment] {
        let normalized = transcript.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return blocks.compactMap(parseBlock)
    }

    private static func parseBlock(_ block: String) -> TranscriptSegment? {
        var lines = block.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }

        var firstLine = lines.removeFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        let startTime = consumeTimestamp(from: &firstLine)
        guard firstLine.hasSuffix(":") else {
            return nil
        }

        let speaker = String(firstLine.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speaker.isEmpty, !text.isEmpty else { return nil }

        return TranscriptSegment(speaker: speaker, startTime: startTime, text: text)
    }

    private static func consumeTimestamp(from value: inout String) -> TimeInterval? {
        guard value.hasPrefix("["),
              let endIndex = value.firstIndex(of: "]") else {
            return nil
        }

        let timestamp = String(value[value.index(after: value.startIndex)..<endIndex])
        value = String(value[value.index(after: endIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return seconds(from: timestamp)
    }

    private static func seconds(from timestamp: String) -> TimeInterval? {
        let parts = timestamp.split(separator: ":").compactMap { TimeInterval($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        if parts.count == 2 {
            return parts[0] * 60 + parts[1]
        }
        return parts[0] * 3_600 + parts[1] * 60 + parts[2]
    }
}

/// What the Notes tab's Read mode shows for a transcript whose saved segments
/// (with timestamps) may be older than the transcript text the user edited.
public struct ReadableTranscript: Equatable, Sendable {
    public var segments: [TranscriptSegment]
    /// `true` when `segments` were rebuilt from edited text and carry no times.
    public var isEdited: Bool

    public init(segments: [TranscriptSegment], isEdited: Bool) {
        self.segments = segments
        self.isEdited = isEdited
    }
}

extension TranscriptParser {
    /// The saved segments when they still describe `transcript`; otherwise
    /// speaker blocks rebuilt from the text (no times), or one unlabelled
    /// segment of the plain text when it has no speaker blocks.
    ///
    /// The saved segments are never rewritten: they hold the timestamps SRT
    /// export needs.
    public static func readableTranscript(saved: [TranscriptSegment], transcript: String) -> ReadableTranscript {
        if saved.isEmpty || segments(saved, match: transcript) {
            return ReadableTranscript(segments: saved, isEdited: false)
        }
        return ReadableTranscript(segments: untimedSegments(from: transcript), isEdited: true)
    }

    /// Whether `segments` still describe `transcript`: the texts are equal after
    /// collapsing whitespace and dropping speaker-label lines (`Speaker 1:`,
    /// `[00:01:02] Adli:`), and, when the text has labels, the speaker order matches.
    public static func segments(_ segments: [TranscriptSegment], match transcript: String) -> Bool {
        var labels: [String] = []
        var bodyLines: [String] = []
        for block in blocks(in: transcript) {
            var lines = block.components(separatedBy: "\n")
            if let label = speakerLabel(lines[0]) {
                labels.append(label)
                lines.removeFirst()
            }
            bodyLines.append(contentsOf: lines)
        }
        let transcriptBody = collapsedWhitespace(bodyLines.joined(separator: " "))
        let segmentBody = collapsedWhitespace(segments.map(\.text).joined(separator: " "))
        guard transcriptBody == segmentBody else { return false }
        if labels.isEmpty { return true }
        return dedupedRuns(labels) == dedupedRuns(segments.map(\.speaker))
    }

    /// Speaker blocks without times. A block without a label line joins the
    /// previous block (or starts an unlabelled one) so no edited text is dropped.
    static func untimedSegments(from transcript: String) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for block in blocks(in: transcript) {
            var lines = block.components(separatedBy: "\n")
            let label = speakerLabel(lines[0])
            if label != nil { lines.removeFirst() }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let label {
                guard !text.isEmpty else { continue }
                result.append(TranscriptSegment(speaker: label, text: text))
            } else if let last = result.indices.last {
                result[last].text += "\n\n" + text
            } else {
                result.append(TranscriptSegment(speaker: "", text: text))
            }
        }
        return result
    }

    private static func blocks(in transcript: String) -> [String] {
        transcript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The label of a block's first line when it is `Label:` (optionally after a
    /// `[hh:mm:ss]` timestamp) and the label looks like a name: at most four
    /// words, at most 40 characters, no sentence punctuation.
    private static func speakerLabel(_ line: String) -> String? {
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = consumeTimestamp(from: &value)
        guard value.hasSuffix(":") else { return nil }
        let label = String(value.dropLast()).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty,
              label.count <= 40,
              label.split(whereSeparator: \.isWhitespace).count <= 4,
              !label.contains(where: { ".!?,;:".contains($0) }) else { return nil }
        return label
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func dedupedRuns(_ values: [String]) -> [String] {
        values.reduce(into: []) { result, value in
            if result.last != value { result.append(value) }
        }
    }
}
