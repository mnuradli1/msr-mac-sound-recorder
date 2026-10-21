import Foundation

/// Rules for user-chosen speaker display names and for rewriting speaker
/// headers in transcript text (see `RecordingLibrary.renameSpeaker`).
public enum SpeakerNames {
    public static let maximumLength = 40
    public static let maximumWords = 4

    /// `name` reduced to something every transcript reader accepts as a speaker
    /// label (`Label:` header line): newlines, control characters and
    /// `. ! ? , ; : [ ]` become spaces, whitespace is collapsed, and the result
    /// is capped at four words and 40 characters. Returns `""` when nothing is
    /// left, which callers treat as "revert to the original label".
    public static func sanitized(_ name: String) -> String {
        let disallowed = CharacterSet(charactersIn: ".!?,;:[]")
            .union(.controlCharacters)
            .union(.newlines)
        let replaced = String(String.UnicodeScalarView(name.unicodeScalars.map {
            disallowed.contains($0) ? " " : $0
        }))
        let words = replaced.split(whereSeparator: \.isWhitespace).prefix(maximumWords)
        var result = words.joined(separator: " ")
        if result.count > maximumLength {
            result = String(result.prefix(maximumLength)).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// Speaker labels used by `Label:` header lines in `transcript`, in first-use order.
    public static func labels(in transcript: String) -> [String] {
        var seen = Set<String>()
        return TranscriptParser.segments(from: transcript).map(\.speaker).filter { seen.insert($0).inserted }
    }

    /// Rewrites the speaker label of every block whose first line is a header
    /// for one of `labels` — `Label:` on its own line (the ElevenLabs format),
    /// `[00:01:02] Label:`, or an inline `Label: text` — to `newLabel`. Only the
    /// first line of a block (start of text or after a blank line) is
    /// considered, so a colon inside spoken text is never touched. Everything
    /// else, including line endings and timestamps, is kept byte-for-byte.
    public static func renaming(_ labels: Set<String>, to newLabel: String, in transcript: String) -> String {
        guard !labels.isEmpty, !transcript.isEmpty else { return transcript }
        var lines = transcript.components(separatedBy: "\n")
        var atBlockStart = true
        for index in lines.indices {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                atBlockStart = true
                continue
            }
            if atBlockStart, let rewritten = rewrittenHeader(line, labels: labels, newLabel: newLabel) {
                lines[index] = rewritten
            }
            atBlockStart = false
        }
        return lines.joined(separator: "\n")
    }

    private static func rewrittenHeader(_ line: String, labels: Set<String>, newLabel: String) -> String? {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        var rest = line[leading.endIndex...]
        var prefix = String(leading)
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let afterClose = rest.index(after: close)
            let spacing = rest[afterClose...].prefix(while: { $0 == " " || $0 == "\t" })
            prefix += rest[..<spacing.endIndex]
            rest = rest[spacing.endIndex...]
        }
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let label = rest[..<colon].trimmingCharacters(in: .whitespaces)
        guard labels.contains(label) else { return nil }
        return prefix + newLabel + rest[colon...]
    }
}
