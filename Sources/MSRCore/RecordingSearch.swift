import Foundation

/// Text normalization shared by the search index and queries: lowercased,
/// diacritics folded (`String.folding(options: [.caseInsensitive,
/// .diacriticInsensitive], locale: .current)`), every whitespace run collapsed
/// to one space and trimmed, as NFC UTF-8 bytes. Query tokens never contain
/// whitespace, so matching a token against folded text is a byte substring
/// search.
///
/// ASCII is folded byte by byte (A–Z lowered); each run of non-ASCII
/// characters goes through Foundation's folding. The one difference from
/// folding the whole string is that ASCII `I` always becomes `i` (Foundation
/// gives a dotless `ı` in a Turkish or Azeri locale); queries are folded the
/// same way, so matching stays consistent.
public enum SearchFolding {
    public static func fold(_ text: String) -> [UInt8] {
        var text = text
        return text.withUTF8 { fold(utf8: $0) }
    }

    public static func fold(utf8 input: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        guard !input.isEmpty else { return [] }
        let buffer = FoldBuffer(capacity: input.count + 16)
        buffer.appendFolded(utf8: input)
        return Array(buffer.bytes)
    }

    /// Whether `token` occurs in `text` (byte substring).
    public static func contains(_ text: UnsafeBufferPointer<UInt8>, _ token: [UInt8]) -> Bool {
        guard !token.isEmpty else { return true }
        guard text.count >= token.count, let base = text.baseAddress else { return false }
        return token.withUnsafeBufferPointer { needle in
            memmem(base, text.count, needle.baseAddress, needle.count) != nil
        }
    }

    public static func contains(_ text: [UInt8], _ token: [UInt8]) -> Bool {
        text.withUnsafeBufferPointer { contains($0, token) }
    }
}

/// A growable byte buffer that folded text is appended to
/// (`SearchFolding`), reusable across documents so that indexing does not
/// allocate per file. Not thread-safe: one per task.
public final class FoldBuffer {
    public private(set) var count = 0
    private var pointer: UnsafeMutablePointer<UInt8>
    private var capacity: Int

    public init(capacity: Int = 64 * 1_024) {
        self.capacity = max(16, capacity)
        pointer = .allocate(capacity: self.capacity)
    }

    deinit { pointer.deallocate() }

    public var bytes: UnsafeBufferPointer<UInt8> { UnsafeBufferPointer(start: pointer, count: count) }

    public func removeAll() { count = 0 }

    /// Room for `extra` more bytes.
    public func reserve(_ extra: Int) {
        let needed = count + extra
        guard needed > capacity else { return }
        let grown = UnsafeMutablePointer<UInt8>.allocate(capacity: max(needed, capacity * 2))
        grown.update(from: pointer, count: count)
        pointer.deallocate()
        pointer = grown
        capacity = max(needed, capacity * 2)
    }

    /// Appends the folded form of `input`, separated from earlier text by one
    /// space (when both are non-empty).
    public func appendFolded(utf8 input: UnsafeBufferPointer<UInt8>) {
        let total = input.count
        guard total > 0 else { return }
        // ASCII never folds longer than its input; a non-ASCII run can (a few
        // characters case-fold to several), so room is re-checked after each run.
        reserve(total + 16)
        let start = count
        var length = count
        var pendingSpace = length > 0
        var index = 0
        while index < total {
            let byte = input[index]
            if byte < 0x80 {
                index += 1
                if byte == 0x20 || (byte >= 0x09 && byte <= 0x0D) {
                    pendingSpace = length > 0
                    continue
                }
                if pendingSpace {
                    pointer[length] = 0x20
                    length += 1
                    pendingSpace = false
                }
                pointer[length] = byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
                length += 1
                continue
            }
            var end = index + 1
            while end < total, input[end] >= 0x80 { end += 1 }
            // The run may start with combining marks (decomposed "e\u{301}"):
            // fold it together with the ASCII character before it.
            var runStart = index
            if index > 0, !pendingSpace, length > start, input[index - 1] < 0x80 {
                length -= 1
                runStart = index - 1
            }
            let run = String(decoding: UnsafeBufferPointer(rebasing: input[runStart..<end]), as: UTF8.self)
            index = end
            let folded = run
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .precomposedStringWithCanonicalMapping
            for scalar in folded.unicodeScalars {
                if scalar.properties.isWhitespace {
                    pendingSpace = length > 0
                    continue
                }
                guard let encoded = UTF8.encode(scalar) else { continue }
                count = length
                reserve(encoded.count + 1)
                if pendingSpace {
                    pointer[length] = 0x20
                    length += 1
                    pendingSpace = false
                }
                for unit in encoded {
                    pointer[length] = unit
                    length += 1
                }
            }
            // Room for the rest of the input: each remaining byte adds at most
            // one output byte (an emitted space stands for a consumed one).
            count = length
            reserve(total - index + 16)
        }
        count = length
    }
}

/// A parsed query: its folded, whitespace-separated tokens. A recording
/// matches when every token occurs in its name, source, date, duration,
/// transcript or summary text.
public struct RecordingSearchQuery: Equatable, Sendable {
    public let tokens: [[UInt8]]

    public init(_ query: String) {
        tokens = SearchFolding.fold(query)
            .split(separator: 0x20)
            .map(Array.init)
    }

    public var isEmpty: Bool { tokens.isEmpty }

    /// The tokens of `tokens` (default: all) that do not occur in `text`.
    public func missingTokens(in text: [UInt8], from tokens: [[UInt8]]? = nil) -> [[UInt8]] {
        text.withUnsafeBufferPointer { buffer in
            (tokens ?? self.tokens).filter { !SearchFolding.contains(buffer, $0) }
        }
    }
}

/// The searchable text of one recording, folded once: `metadataText` (name,
/// source and its aliases, date and duration) and `contentText` (transcript
/// and summary).
public struct RecordingSearchDocument: Equatable, Sendable {
    public var recording: RecordingItem
    public var metadataText: [UInt8]
    public var contentText: [UInt8]

    public init(
        recording: RecordingItem,
        transcriptText: String = "",
        summaryText: String = "",
        calendar: Calendar = .current
    ) {
        self.recording = recording
        metadataText = RecordingSearch.metadataText(for: recording, dates: SearchDateText(calendar: calendar))
        contentText = RecordingSearch.contentText(transcript: transcriptText, summary: summaryText)
    }

    public init(recording: RecordingItem, metadataText: [UInt8], contentText: [UInt8]) {
        self.recording = recording
        self.metadataText = metadataText
        self.contentText = contentText
    }

    public func matches(_ query: RecordingSearchQuery) -> Bool {
        let missing = query.missingTokens(in: metadataText)
        return missing.isEmpty || query.missingTokens(in: contentText, from: missing).isEmpty
    }
}

/// Date strings a recording can be found by, with the formatters made once
/// (not once per document). Not thread-safe: one per actor or call.
public final class SearchDateText {
    private let formatters: [DateFormatter]
    /// The zone the dates are written in (`calendar.timeZone`).
    public let timeZone: TimeZone

    public init(calendar: Calendar = .current) {
        timeZone = calendar.timeZone
        formatters = ["yyyy-MM-dd", "yyyy-MM-dd HH.mm", "yyyy-MM-dd HH:mm", "MMM d yyyy", "MMMM d yyyy"].map { format in
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }

    public func text(for date: Date) -> String {
        formatters.map { $0.string(from: date) }.joined(separator: " ")
    }
}

public enum RecordingSearch {
    /// The documents whose text contains every token of `query` (all of them
    /// when the query is blank), in order.
    public static func filter(_ documents: [RecordingSearchDocument], query: String) -> [RecordingSearchDocument] {
        let parsed = RecordingSearchQuery(query)
        guard !parsed.isEmpty else { return documents }
        return documents.filter { $0.matches(parsed) }
    }

    /// Folded name, source (and aliases), date and duration text.
    public static func metadataText(for recording: RecordingItem, dates: SearchDateText) -> [UInt8] {
        SearchFolding.fold([
            recording.displayName,
            recording.source.displayName,
            sourceAliases(for: recording.source),
            dates.text(for: recording.startedAt),
            durationText(for: recording.durationSeconds)
        ].joined(separator: " "))
    }

    /// Folded transcript and summary, separated by a space (tokens never span it).
    public static func contentText(transcript: String, summary: String) -> [UInt8] {
        let transcript = SearchFolding.fold(transcript)
        let summary = SearchFolding.fold(summary)
        if transcript.isEmpty { return summary }
        if summary.isEmpty { return transcript }
        return transcript + [0x20] + summary
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
}

/// A fixed-size summary of a folded text that can prove a token is absent:
/// an exact set of the bytes present, plus a one-hash Bloom filter of every
/// 2- and 3-byte sequence. `mayContain` is `false` only when the token
/// cannot occur; `true` must be confirmed against the text. 160 bytes for a
/// short text, up to about 2 KB (16,384 bits) for long transcripts: the
/// filter is folded in half while the result stays at most 30 % full.
public struct SearchSketch: Equatable, Sendable {
    private var bytesPresent: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    private var bloom: [UInt64]

    static let maximumBits = 16_384
    static let minimumBits = 1_024

    public init(_ text: [UInt8]) {
        self = text.withUnsafeBufferPointer { SearchSketch($0) }
    }

    public init(_ bytes: UnsafeBufferPointer<UInt8>) {
        var bloom = [UInt64](repeating: 0, count: Self.maximumBits / 64)
        var present: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        do {
            bloom.withUnsafeMutableBufferPointer { bits in
                let mask = UInt64(Self.maximumBits - 1)
                for index in 0..<bytes.count {
                    Self.insert(bytes[index], into: &present)
                    if index + 1 < bytes.count {
                        let slot = Self.slot(Self.gram2(bytes[index], bytes[index + 1])) & mask
                        bits[Int(slot >> 6)] |= 1 << (slot & 63)
                    }
                    if index + 2 < bytes.count {
                        let slot = Self.slot(Self.gram3(bytes[index], bytes[index + 1], bytes[index + 2])) & mask
                        bits[Int(slot >> 6)] |= 1 << (slot & 63)
                    }
                }
            }
        }
        // Fold in half (slot & (m/2 - 1)) while the result stays under ~30 % full.
        var words = bloom.count
        while words * 64 > Self.minimumBits {
            let half = words / 2
            var setBits = 0
            for index in 0..<half { setBits += (bloom[index] | bloom[index + half]).nonzeroBitCount }
            guard Double(setBits) <= 0.3 * Double(half * 64) else { break }
            for index in 0..<half { bloom[index] |= bloom[index + half] }
            words = half
        }
        self.bloom = Array(bloom.prefix(words))
        bytesPresent = present
    }

    /// Resident size in bytes.
    public var byteCount: Int { bloom.count * 8 + 32 }

    public func mayContain(_ token: [UInt8]) -> Bool {
        guard !token.isEmpty else { return true }
        let mask = UInt64(bloom.count * 64 - 1)
        return token.withUnsafeBufferPointer { bytes in
            for index in 0..<bytes.count {
                guard Self.contains(bytes[index], in: bytesPresent) else { return false }
                if index + 1 < bytes.count {
                    let slot = Self.slot(Self.gram2(bytes[index], bytes[index + 1])) & mask
                    guard bloom[Int(slot >> 6)] & (1 << (slot & 63)) != 0 else { return false }
                }
                if index + 2 < bytes.count {
                    let slot = Self.slot(Self.gram3(bytes[index], bytes[index + 1], bytes[index + 2])) & mask
                    guard bloom[Int(slot >> 6)] & (1 << (slot & 63)) != 0 else { return false }
                }
            }
            return true
        }
    }

    public func mayContainAll(_ tokens: [[UInt8]]) -> Bool {
        tokens.allSatisfy(mayContain)
    }

    public static func == (lhs: SearchSketch, rhs: SearchSketch) -> Bool {
        lhs.bloom == rhs.bloom
            && lhs.bytesPresent.0 == rhs.bytesPresent.0 && lhs.bytesPresent.1 == rhs.bytesPresent.1
            && lhs.bytesPresent.2 == rhs.bytesPresent.2 && lhs.bytesPresent.3 == rhs.bytesPresent.3
    }

    @inline(__always) private static func gram2(_ a: UInt8, _ b: UInt8) -> UInt64 {
        0x2_0000_0000 | UInt64(a) << 8 | UInt64(b)
    }

    @inline(__always) private static func gram3(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt64 {
        0x3_0000_0000 | UInt64(a) << 16 | UInt64(b) << 8 | UInt64(c)
    }

    /// The top 14 bits of a multiplicative hash; folding keeps the low bits of it.
    @inline(__always) private static func slot(_ gram: UInt64) -> UInt64 {
        (gram &* 0x9E37_79B9_7F4A_7C15) >> 50
    }

    @inline(__always) private static func insert(_ byte: UInt8, into set: inout (UInt64, UInt64, UInt64, UInt64)) {
        let bit = UInt64(1) << UInt64(byte & 63)
        switch byte >> 6 {
        case 0: set.0 |= bit
        case 1: set.1 |= bit
        case 2: set.2 |= bit
        default: set.3 |= bit
        }
    }

    @inline(__always) private static func contains(_ byte: UInt8, in set: (UInt64, UInt64, UInt64, UInt64)) -> Bool {
        let bit = UInt64(1) << UInt64(byte & 63)
        switch byte >> 6 {
        case 0: return set.0 & bit != 0
        case 1: return set.1 & bit != 0
        case 2: return set.2 & bit != 0
        default: return set.3 & bit != 0
        }
    }
}
