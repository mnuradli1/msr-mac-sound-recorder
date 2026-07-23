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
