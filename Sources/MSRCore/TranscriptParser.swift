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
