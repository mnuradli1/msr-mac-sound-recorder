import Foundation
import ZIPFoundation

public enum TranscriptExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case text, markdown, srt, docx

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .text: "Plain Text"
        case .markdown: "Markdown"
        case .srt: "SubRip Captions"
        case .docx: "Word Document"
        }
    }
    public var fileExtension: String {
        switch self {
        case .text: "txt"
        case .markdown: "md"
        case .srt: "srt"
        case .docx: "docx"
        }
    }
}

public struct MeetingNotesExportInput: Sendable {
    public var recording: RecordingItem
    public var transcript: String
    public var segments: [TranscriptSegment]
    public var summary: String

    public init(recording: RecordingItem, transcript: String, segments: [TranscriptSegment], summary: String) {
        self.recording = recording
        self.transcript = transcript
        self.segments = segments
        self.summary = summary
    }
}

public enum TranscriptExportError: Error, LocalizedError {
    case timestampsRequired
    public var errorDescription: String? { "SRT export requires timestamped transcript segments." }
}

public enum TranscriptExporter {
    public static func content(
        transcript: String,
        recordingName: String,
        format: TranscriptExportFormat
    ) -> String {
        switch format {
        case .text, .srt, .docx: transcript
        case .markdown:
            "# \(recordingName)\n\n## Transcript\n\n\(transcript)"
        }
    }

    public static func preview(_ input: MeetingNotesExportInput, format: TranscriptExportFormat) throws -> String {
        switch format {
        case .text: plainText(input)
        case .markdown: markdown(input)
        case .srt: try srt(input.segments)
        case .docx: markdown(input)
        }
    }

    public static func export(_ input: MeetingNotesExportInput, format: TranscriptExportFormat, to url: URL) throws {
        switch format {
        case .docx:
            try writeDOCX(input, to: url)
        default:
            try DurableFile.write(Data(try preview(input, format: format).utf8), to: url)
        }
    }

    public static func canExportSRT(_ segments: [TranscriptSegment]) -> Bool {
        segments.contains { $0.startTime != nil }
    }

    private static func plainText(_ input: MeetingNotesExportInput) -> String {
        let name = input.recording.displayName
        return "\(name)\n\(String(repeating: "=", count: name.count))\n\n\(input.transcript.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    private static func markdown(_ input: MeetingNotesExportInput) -> String {
        let recording = input.recording
        let date = recording.startedAt.formatted(date: .numeric, time: .shortened)
        let duration = timestamp(recording.durationSeconds)
        let summary = input.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        # \(recording.displayName)

        - Source: \(recording.source.displayName)
        - Recorded: \(date)
        - Duration: \(duration)

        ## Summary

        \(summary.isEmpty ? "No summary available." : summary)

        ## Transcript

        \(input.transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    /// Shareable meeting notes:
    ///
    /// ```
    /// # <title>
    ///
    /// <date> · <duration> · <source>
    ///
    /// ## Summary
    /// <summary markdown, minus its Action Items section; "_No summary yet._" when empty>
    ///
    /// ## Action Items            (only when the summary has an "Action Items" section)
    /// <that section's body>
    ///
    /// ## Transcript
    /// **[00:01:05] Sarah:** text  (timestamps when the segments have them)
    /// ```
    ///
    /// The transcript uses the saved segments while they still match the text
    /// (`TranscriptParser.readableTranscript`); after edits it falls back to
    /// the speaker blocks of the edited text (no times), or the plain text.
    public static func meetingNotesMarkdown(_ input: MeetingNotesExportInput) -> String {
        let recording = input.recording
        let metadataLine = [
            recording.startedAt.formatted(date: .abbreviated, time: .shortened),
            timestamp(recording.durationSeconds),
            recording.source.displayName
        ].joined(separator: " · ")

        let summary = input.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let split = splitActionItems(from: summary)
        let summaryBody: String
        if summary.isEmpty {
            summaryBody = "_No summary yet._"
        } else if split.summary.isEmpty, split.actionItems != nil {
            // Only action items: they are listed once, in their own section.
            summaryBody = "_No summary beyond the action items below._"
        } else {
            summaryBody = demotingHeadings(split.summary.isEmpty ? summary : split.summary, toAtLeast: 3)
        }
        var sections = [
            "# \(recording.displayName)",
            metadataLine,
            "## Summary",
            summaryBody
        ]
        if let actionItems = split.actionItems {
            sections.append("## Action Items")
            sections.append(demotingHeadings(actionItems, toAtLeast: 3))
        }
        sections.append("## Transcript")
        let transcript = notesTranscript(input)
        sections.append(transcript.isEmpty ? "_No transcript yet._" : transcript)
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// The summary without its `Action Items` heading section, and that
    /// section's body (`nil` when absent or empty). Matches any heading level,
    /// case-insensitively; the section ends at the next heading of the same or a
    /// higher level.
    static func splitActionItems(from summary: String) -> (summary: String, actionItems: String?) {
        let lines = summary.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { headingLevel($0).map { $0.title.lowercased() == "action items" } ?? false }),
              let level = headingLevel(lines[start])?.level else {
            return (summary, nil)
        }
        let end = lines[(start + 1)...].firstIndex { line in
            guard let heading = headingLevel(line) else { return false }
            return heading.level <= level
        } ?? lines.endIndex
        let body = lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return (summary, nil) }
        let remaining = (Array(lines[..<start]) + Array(lines[end...]))
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (remaining, body)
    }

    /// Shifts every Markdown heading in `markdown` down by the same number of
    /// levels so the highest one is at least `minimumLevel` (capped at `######`),
    /// keeping the summary's own structure under the notes' `##` sections.
    static func demotingHeadings(_ markdown: String, toAtLeast minimumLevel: Int) -> String {
        let lines = markdown.components(separatedBy: "\n")
        guard let highest = lines.compactMap({ headingLevel($0)?.level }).min(), highest < minimumLevel else {
            return markdown
        }
        let shift = minimumLevel - highest
        return lines.map { line in
            guard let level = headingLevel(line)?.level else { return line }
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let newLevel = min(6, level + shift)
            return String(repeating: "#", count: newLevel) + trimmed.dropFirst(level)
        }.joined(separator: "\n")
    }

    private static func headingLevel(_ line: String) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let title = rest
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":*_ "))
        return (hashes, title)
    }

    private static func notesTranscript(_ input: MeetingNotesExportInput) -> String {
        let text = input.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let readable = TranscriptParser.readableTranscript(saved: input.segments, transcript: text)
        let segments = readable.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard segments.contains(where: { !$0.speaker.isEmpty }) else { return text }
        return segments.map { segment in
            let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let time = segment.startTime.map { "[\(timestamp($0))] " } ?? ""
            guard !segment.speaker.isEmpty else { return time.isEmpty ? body : "**\(time.trimmingCharacters(in: .whitespaces))** \(body)" }
            return "**\(time)\(segment.speaker):** \(body)"
        }.joined(separator: "\n\n")
    }

    private static func srt(_ segments: [TranscriptSegment]) throws -> String {
        let timestamped = segments.filter { $0.startTime != nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !timestamped.isEmpty else { throw TranscriptExportError.timestampsRequired }
        return timestamped.enumerated().map { index, segment in
            let start = max(0, segment.startTime ?? 0)
            let end = max(start + 1, segment.endTime ?? start + 3)
            return "\(index + 1)\n\(srtTimestamp(start)) --> \(srtTimestamp(end))\n\(segment.speaker): \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }.joined(separator: "\n")
    }

    private static func writeDOCX(_ input: MeetingNotesExportInput, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        try add("[Content_Types].xml", content: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """, to: archive)
        try add("_rels/.rels", content: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """, to: archive)
        let lines = try preview(input, format: .markdown).components(separatedBy: .newlines)
        let body = lines.map { line in
            let bold = line.hasPrefix("#")
            let text = line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            return paragraph(text, bold: bold)
        }.joined(separator: "\n")
        try add("word/document.xml", content: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        \(body)
        <w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:body></w:document>
        """, to: archive)
    }

    private static func add(_ path: String, content: String, to archive: Archive) throws {
        let data = Data(content.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<min(start + size, data.count))
        }
    }

    private static func paragraph(_ text: String, bold: Bool) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let properties = bold ? "<w:rPr><w:b/></w:rPr>" : ""
        return "<w:p><w:r>\(properties)<w:t xml:space=\"preserve\">\(escaped)</w:t></w:r></w:p>"
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", value / 3_600, value / 60 % 60, value % 60)
    }

    private static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let milliseconds = max(0, Int((seconds * 1_000).rounded()))
        return String(
            format: "%02d:%02d:%02d,%03d",
            milliseconds / 3_600_000,
            milliseconds / 60_000 % 60,
            milliseconds / 1_000 % 60,
            milliseconds % 1_000
        )
    }
}
