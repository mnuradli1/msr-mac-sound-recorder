import Foundation

/// Pure, deterministic helpers for naming recordings from their transcript.
///
/// Nothing here touches the network, the clock, the locale, or randomness: the
/// same input always yields the same output, so results are safe to unit test
/// and to recompute.
///
/// - `isDefaultName(_:)` recognises machine-generated placeholder titles.
/// - `cleaned(_:fallback:maximumWords:maximumCharacters:)` normalises a title
///   candidate (for example an LLM reply) into a short, file-name-safe title.
/// - `localTitle(from:segments:maximumWords:)` derives a title from the
///   transcript text alone, for use when no remote title service is available.
public enum MeetingTitleGenerator {
    // MARK: - Default names

    /// Returns `true` for machine-generated placeholder titles, which auto-title
    /// is allowed to replace:
    /// - `Meeting yyyy-MM-dd HH.mm`, optionally followed by a ` N` de-duplication
    ///   suffix (for example `Meeting 2026-06-29 14.05 2`);
    /// - `Recovered Meeting yyyy-MM-dd HH.mm` (the crash-recovery name), same suffix rule;
    /// - `Untitled Meeting`, optionally followed by ` N` (the sanitizer fallback).
    ///
    /// Matching is case-sensitive and ignores surrounding whitespace.
    /// `"Meeting with Bob"` is `false`.
    public static func isDefaultName(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return defaultNamePatterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: - Cleaning title candidates

    /// Normalises a title candidate into a short title that is safe to store.
    ///
    /// Rules, applied to the first line that is non-empty after cleaning:
    /// 1. strips Markdown emphasis (`**`, `__`), backticks, a leading `#` heading
    ///    marker and a leading list marker (`-`, `*`, `•`, `>`, `1.`);
    /// 2. strips a leading `Title:` / `Judul:` prefix (case-insensitive, also
    ///    `Meeting title:`, `Judul rapat:` and a full-width colon);
    /// 3. strips surrounding straight or curly quotes, `«»`, `‹›` and corner brackets;
    /// 4. drops trailing `.`, `。`, `,`, `;`, `:`, `…` and dashes (`?` and `!` are kept);
    /// 5. collapses runs of whitespace into single spaces;
    /// 6. keeps at most `maximumWords` words, then at most `maximumCharacters`
    ///    characters, cutting on a word boundary (a single over-long word is truncated);
    /// 7. passes the result through `FileNameSanitizer.sanitizedBaseName(_:fallback:)`.
    ///
    /// Steps 1–5 repeat until nothing changes, so nested wrappers such as
    /// `**"Title: Budget"**` are fully removed. Returns `fallback` when nothing is left.
    public static func cleaned(
        _ candidate: String,
        fallback: String,
        maximumWords: Int = 8,
        maximumCharacters: Int = 80
    ) -> String {
        let wordLimit = max(1, maximumWords)
        let characterLimit = max(1, maximumCharacters)
        for line in candidate.components(separatedBy: .newlines) {
            let value = cleanedLine(line, maximumWords: wordLimit, maximumCharacters: characterLimit)
            if !value.isEmpty { return value }
        }
        return fallback
    }

    // MARK: - Local (offline) titles

    /// Derives a title from the transcript without any network access.
    ///
    /// Rules:
    /// 1. Text comes from `segments` (in order) when any are given, then from
    ///    `transcript`, one line at a time.
    /// 2. Each line loses SRT timing lines (`-->`), a leading timestamp
    ///    (`00:12`, `[00:12]`, `(1:02:03)`), bracketed tags anywhere (`[music]`,
    ///    `(laughs)`, `{noise}`, `<inaudible>`, `*sighs*`, `♪`) and a leading
    ///    speaker label of at most three words (`Speaker 0:`, `Adli:`).
    /// 3. Lines are split into sentences at `.`, `!`, `?`, `…` followed by
    ///    whitespace, and at `。！？`.
    /// 4. A sentence is skipped when it has fewer than three content words, or
    ///    more filler words than content words. Filler words are greetings and
    ///    hesitations in English and Indonesian ("ok", "okay", "yeah", "um", "uh",
    ///    "hello", "hi", "halo", "oke", "ya", "jadi", "eh", "hmm", "testing",
    ///    "test", …) and phrases such as "one two three", "satu dua tiga",
    ///    "good morning", "terima kasih", "thanks for joining". Common function
    ///    words ("the", "we", "is", "yang", "kita", …) count as neither.
    /// 5. From the first sentence that qualifies: leading filler and connectors
    ///    ("so", "and", "nah", …) are dropped, then a lead-in such as "today we're
    ///    going to discuss" / "hari ini kita akan membahas" when at least two
    ///    words remain after it; hesitations ("um", "eh") are dropped anywhere.
    /// 6. The first `maximumWords` words are kept (dangling function words are
    ///    trimmed from the end of a cut title), the first character is
    ///    capitalised unless the first word already has an uppercase letter, and
    ///    trailing punctuation is dropped. The result goes through
    ///    `cleaned(_:fallback:maximumWords:maximumCharacters:)`.
    /// 7. A result that `isDefaultName(_:)` would accept is never returned; the
    ///    next sentence is tried instead.
    ///
    /// Returns `nil` when no sentence qualifies (empty transcript, only tags such
    /// as `[outro jingle]`, or only filler).
    public static func localTitle(
        from transcript: String,
        segments: [TranscriptSegment] = [],
        maximumWords: Int = 8
    ) -> String? {
        let wordLimit = max(1, maximumWords)
        let sources: [[String]] = [
            segments.flatMap { $0.text.components(separatedBy: .newlines) },
            transcript.components(separatedBy: .newlines)
        ]
        for lines in sources {
            for line in lines {
                for sentence in sentences(in: strippedTranscriptLine(line)) {
                    if let title = title(fromSentence: sentence, maximumWords: wordLimit) {
                        return title
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Cleaning implementation

    private static let defaultNamePatterns = [
        #"^(Recovered )?Meeting [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}\.[0-9]{2}( [0-9]+)?$"#,
        #"^Untitled Meeting( [0-9]+)?$"#
    ]

    private static let quoteCharacters: Set<Character> = [
        "\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "\u{201E}", "\u{201A}",
        "\u{00AB}", "\u{00BB}", "\u{2039}", "\u{203A}", "\u{300C}", "\u{300D}", "\u{300E}", "\u{300F}"
    ]

    /// Quote marks that are never meaningful at the edge of a title (unlike `'`).
    private static let edgeQuoteCharacters: Set<Character> = [
        "\"", "\u{201C}", "\u{201D}", "\u{201E}", "\u{00AB}", "\u{00BB}", "\u{2039}", "\u{203A}",
        "\u{300C}", "\u{300D}", "\u{300E}", "\u{300F}"
    ]

    private static let trailingPunctuation: Set<Character> = [
        ".", "\u{3002}", ",", "\u{FF0C}", ";", "\u{FF1B}", ":", "\u{FF1A}", "\u{2026}",
        "-", "\u{2013}", "\u{2014}", "\u{00B7}", "*", "_"
    ]

    private static let leadingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "\u{FF1A}", "-", "\u{2013}", "\u{2014}", "\u{00B7}", "*", "_"
    ]

    private static func cleanedLine(_ line: String, maximumWords: Int, maximumCharacters: Int) -> String {
        var value = collapsedWhitespace(line)
        while true {
            let previous = value
            value = strippingMarkdown(value)
            value = strippingTitlePrefix(value)
            value = strippingQuotes(value)
            value = trimmingEdgePunctuation(value)
            value = collapsedWhitespace(value)
            if value == previous { break }
        }
        // Sanitize before capping so characters the sanitizer turns into spaces
        // (for example "Q3/Q4") cannot push the result past the word limit.
        value = FileNameSanitizer.sanitizedBaseName(value, fallback: "")
        value = trimmingEdgePunctuation(capped(value, maximumWords: maximumWords, maximumCharacters: maximumCharacters))
        return FileNameSanitizer.sanitizedBaseName(value, fallback: "")
    }

    private static func strippingMarkdown(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        result = result.replacingOccurrences(of: #"^\s*#{1,6}\s*"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"^\s*(?:[-*•>]|[0-9]{1,2}[.)])\s+"#,
            with: "",
            options: .regularExpression
        )
        return result
    }

    private static func strippingTitlePrefix(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"^\s*(?:(?:suggested|meeting|recording)\s+)?(?:title|judul)(?:\s+(?:rapat|pertemuan|rekaman))?\s*[:：]\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func strippingQuotes(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespaces)
        while result.count >= 2,
              let first = result.first, let last = result.last,
              quoteCharacters.contains(first), quoteCharacters.contains(last) {
            let inner = result.dropFirst().dropLast()
            // Leave `'Budget' and 'Plan'` alone: the edges are not one pair.
            guard !inner.contains(first), !inner.contains(last) else { break }
            result = String(inner).trimmingCharacters(in: .whitespaces)
        }
        while let first = result.first, edgeQuoteCharacters.contains(first) { result.removeFirst() }
        while let last = result.last, edgeQuoteCharacters.contains(last) { result.removeLast() }
        return result
    }

    private static func trimmingEdgePunctuation(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, trailingPunctuation.contains(last) || last.isWhitespace {
            result.removeLast()
        }
        while let first = result.first, leadingPunctuation.contains(first) || first.isWhitespace {
            result.removeFirst()
        }
        return result
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func capped(_ value: String, maximumWords: Int, maximumCharacters: Int) -> String {
        var result = ""
        for word in value.split(whereSeparator: \.isWhitespace).prefix(maximumWords) {
            let next = result.isEmpty ? String(word) : "\(result) \(word)"
            if next.count > maximumCharacters {
                if result.isEmpty { result = String(word.prefix(maximumCharacters)) }
                break
            }
            result = next
        }
        return result
    }

    // MARK: - Local title implementation

    private static let tagPatterns = [
        #"\[[^\]]*\]"#,
        #"\{[^}]*\}"#,
        #"<[^>]*>"#,
        #"\([^)]{0,60}\)"#,
        #"\*[^*\s][^*]{0,40}\*"#,
        #"[♪♫♬]+"#
    ]

    private static let leadingTimestampPattern =
        #"^[\[(]?[0-9]{1,2}(?::[0-9]{2}){1,2}(?:[.,][0-9]{1,3})?[\])]?\s*[-–—]?\s*"#

    /// Removes timestamps, sound tags and a leading speaker label from one line.
    private static func strippedTranscriptLine(_ line: String) -> String {
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains("-->") else { return "" }
        value = value.replacingOccurrences(of: leadingTimestampPattern, with: "", options: .regularExpression)
        for pattern in tagPatterns {
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: leadingTimestampPattern, with: "", options: .regularExpression)
        value = strippingSpeakerLabel(value)
        return collapsedWhitespace(value)
    }

    /// Drops `Label:` at the start of a line when the label is at most three
    /// words, at most 40 characters, contains no sentence punctuation, and the
    /// colon ends the line or is followed by whitespace (so `10:30` is kept).
    private static func strippingSpeakerLabel(_ value: String) -> String {
        guard let colon = value.firstIndex(where: { $0 == ":" || $0 == "\u{FF1A}" }) else { return value }
        let label = value[..<colon].trimmingCharacters(in: .whitespaces)
        let afterColon = value.index(after: colon)
        guard !label.isEmpty,
              label.count <= 40,
              label.split(whereSeparator: \.isWhitespace).count <= 3,
              !label.contains(where: { ".!?,;".contains($0) }),
              afterColon == value.endIndex || value[afterColon].isWhitespace else {
            return value
        }
        return String(value[afterColon...]).trimmingCharacters(in: .whitespaces)
    }

    private static func sentences(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let marked = text
            .replacingOccurrences(of: #"([.!?…])\s+"#, with: "$1\n", options: .regularExpression)
            .replacingOccurrences(of: #"([。！？])"#, with: "$1\n", options: .regularExpression)
        return marked
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func title(fromSentence sentence: String, maximumWords: Int) -> String? {
        let tokens = sentence
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        guard !tokens.isEmpty else { return nil }
        let words = tokens.map(normalizedWord)

        var isFiller = words.map { fillerWords.contains($0) }
        for phrase in fillerPhrases where phrase.count <= words.count {
            for start in 0...(words.count - phrase.count) where Array(words[start..<(start + phrase.count)]) == phrase {
                for index in start..<(start + phrase.count) { isFiller[index] = true }
            }
        }
        let fillerCount = isFiller.filter { $0 }.count
        let contentCount = words.indices.filter { !isFiller[$0] && !functionWords.contains(words[$0]) }.count
        guard contentCount >= 3, fillerCount <= contentCount else { return nil }

        var start = 0
        while start < words.count, isFiller[start] || leadingConnectors.contains(words[start]) {
            start += 1
        }
        let leadIn = leadInLength(Array(words[start...]))
        if leadIn > 0, words.count - (start + leadIn) >= 2 {
            start += leadIn
            while start < words.count, isFiller[start] { start += 1 }
        }

        var kept: [(token: String, word: String)] = []
        for (token, word) in zip(tokens[start...], words[start...]) {
            guard hesitationWords.contains(word) else {
                kept.append((token, word))
                continue
            }
            // "should, um, finalize" -> "should finalize": the comma belonged to the pause.
            if let last = kept.last, last.token.hasSuffix(",") {
                kept[kept.count - 1].token = String(last.token.dropLast())
            }
        }
        guard !kept.isEmpty else { return nil }
        if kept.count > maximumWords {
            kept = Array(kept.prefix(maximumWords))
            while kept.count > 1, let last = kept.last, danglingWords.contains(last.1) {
                kept.removeLast()
            }
        }

        var candidate = kept.map(\.0).joined(separator: " ")
        while let last = candidate.last, last.isPunctuation || last.isSymbol || last.isWhitespace {
            candidate.removeLast()
        }

        var title = cleaned(candidate, fallback: "", maximumWords: maximumWords)
        while let last = title.last, last.isPunctuation || last.isSymbol || last.isWhitespace {
            title.removeLast()
        }
        if let firstWord = title.split(separator: " ").first,
           !firstWord.contains(where: \.isUppercase),
           let first = title.first {
            title = first.uppercased() + title.dropFirst()
        }
        guard title.contains(where: \.isLetter), !isDefaultName(title) else { return nil }
        return title
    }

    private static func normalizedWord(_ token: String) -> String {
        token
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }

    /// Number of leading words in `words` that form a lead-in such as
    /// "today we're going to discuss" or "hari ini kita akan membahas".
    private static func leadInLength(_ words: [String]) -> Int {
        guard !words.isEmpty else { return 0 }
        let joined = words.joined(separator: " ") + " "
        for pattern in leadInPatterns {
            if let range = joined.range(of: pattern, options: .regularExpression), range.lowerBound == joined.startIndex {
                return joined[range].split(separator: " ").count
            }
        }
        return 0
    }

    private static let leadInPatterns = [
        // English
        #"^(?:(?:so )?(?:today|now) )?(?:(?:we're|we are|we will|we'll|i'm|i am|i will|i'll|i want to|we want to|we need to|i'd like to|we'd like to)(?: going to| gonna)? |let's |lets |let us )(?:quickly |briefly )?(?:talk about|discuss|review|go over|go through|cover|look at|walk through|start with|kick off with)(?: the| our)? "#,
        #"^(?:we're|we are) (?:here|meeting) (?:today )?to (?:talk about|discuss|review|go over|cover)(?: the| our)? "#,
        #"^(?:this|today's|the) (?:meeting|call|session) is (?:about|on|for)(?: the| our)? "#,
        #"^(?:the |our )?agenda (?:for today |today )?is(?: the| our)? "#,
        // Indonesian
        #"^(?:(?:hari ini|sekarang|pada rapat ini|di rapat ini) )?(?:(?:kita|kami|saya) )?(?:(?:akan|mau|ingin|perlu) )?(?:membahas|bahas|mendiskusikan|diskusikan|membicarakan|bicarakan|ngobrolin|meninjau)(?: (?:tentang|soal|mengenai))? "#,
        #"^mari (?:kita )?(?:bahas|membahas|diskusikan|mendiskusikan)(?: (?:tentang|soal|mengenai))? "#,
        #"^(?:rapat|pertemuan) (?:ini|kita|hari ini) (?:membahas|tentang|soal|mengenai) "#,
        #"^agenda (?:kita )?(?:hari ini|rapat ini|pertemuan ini)(?: (?:adalah|yaitu|ialah))? "#
    ]

    /// Greetings, hesitations and acknowledgements (English and Indonesian).
    private static let fillerWords: Set<String> = [
        "ok", "okay", "okey", "okeh", "oke", "okei", "k", "yeah", "yes", "yep", "yup", "ya", "iya", "yah",
        "um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "ahh", "eh", "ehm", "em", "hmm", "hmmm", "hm", "mm", "mhm",
        "oh", "wow", "hello", "hi", "hey", "halo", "hallo", "hai", "so", "well", "alright", "jadi", "nah", "baik",
        "testing", "test", "tes", "thanks", "makasih", "welcome", "everyone", "everybody", "guys", "folks",
        "semuanya", "anyway", "sip"
    ]

    /// Pure hesitations, dropped anywhere in a local title.
    private static let hesitationWords: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "ahh", "eh", "ehm", "em", "hmm", "hmmm", "hm", "mm", "mhm"
    ]

    /// Multi-word greetings and microphone checks; every word in a match counts as filler.
    private static let fillerPhrases: [[String]] = [
        ["one", "two", "three"], ["satu", "dua", "tiga"],
        ["good", "morning"], ["good", "afternoon"], ["good", "evening"],
        ["selamat", "pagi"], ["selamat", "siang"], ["selamat", "sore"], ["selamat", "malam"],
        ["thank", "you"], ["terima", "kasih"], ["thanks", "for", "joining"], ["for", "joining"],
        ["can", "you", "hear", "me"], ["can", "everyone", "hear", "me"], ["bisa", "dengar"],
        ["mic", "check"], ["sound", "check"], ["check", "check"], ["welcome", "to"],
        ["let's", "get", "started"], ["let's", "start"], ["kita", "mulai"], ["mari", "kita", "mulai"],
        ["how", "are", "you"], ["apa", "kabar"]
    ]

    /// Connectors dropped from the start of a local title.
    private static let leadingConnectors: Set<String> = [
        "and", "but", "or", "right", "now", "then", "dan", "tapi", "terus", "lalu", "kemudian"
    ]

    /// Function words: neither content nor filler when scoring a sentence.
    private static let functionWords: Set<String> = [
        // English
        "a", "an", "the", "and", "or", "but", "nor", "of", "to", "in", "on", "at", "for", "with", "from", "by",
        "about", "as", "into", "over", "up", "out", "off", "is", "are", "was", "were", "be", "been", "being", "am",
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them", "my", "your", "his", "its",
        "our", "their", "this", "that", "these", "those", "there", "here", "do", "does", "did", "done", "have",
        "has", "had", "will", "would", "can", "could", "should", "shall", "may", "might", "must", "just", "not",
        "no", "if", "then", "than", "what", "which", "who", "whom", "how", "when", "where", "why", "let's", "lets",
        "let", "i'm", "we're", "you're", "they're", "it's", "that's", "there's", "here's", "what's", "don't",
        "doesn't", "didn't", "can't", "won't", "isn't", "aren't", "i'll", "we'll", "you'll", "i've", "we've",
        "i'd", "we'd", "very", "really", "also", "too", "some", "any", "all", "get", "got", "go", "going", "gonna",
        "wanna", "gotta", "want", "like", "know", "think", "mean", "see", "say", "said", "now", "thing", "things",
        "stuff", "kind", "sort", "lot", "bit", "little", "right",
        // Indonesian
        "yang", "dan", "di", "ke", "dari", "itu", "ini", "untuk", "dengan", "akan", "ada", "tidak", "nggak",
        "ngga", "gak", "ga", "enggak", "juga", "kita", "kami", "saya", "aku", "gue", "gua", "kamu", "anda", "dia",
        "mereka", "sudah", "udah", "belum", "bisa", "mau", "ingin", "apa", "adalah", "ialah", "yaitu", "pada",
        "dalam", "oleh", "atau", "tapi", "tetapi", "namun", "karena", "kalau", "kalo", "jika", "agar", "supaya",
        "sebagai", "seperti", "lagi", "masih", "saja", "aja", "sih", "deh", "dong", "kan", "kok", "lho", "loh",
        "nya", "pun", "para", "sama", "buat", "biar", "terus", "lalu", "kemudian", "nanti", "sekarang", "begitu",
        "gitu", "gini", "begini", "sangat", "banget", "lebih", "paling", "semua", "setiap", "tiap", "harus",
        "perlu", "boleh", "bahwa", "sini", "situ", "sana", "mana", "siapa", "kapan", "bagaimana", "gimana",
        "kenapa", "mengapa", "punya"
    ]

    /// Words that should not end a title that was cut at the word limit.
    private static let danglingWords: Set<String> = functionWords.union(leadingConnectors)
}
