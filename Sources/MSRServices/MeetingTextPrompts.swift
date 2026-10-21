import Foundation
import MSRCore

/// Prompts, chunking and response checks shared by the text-model clients
/// (`OpenAIClient`, `DeepSeekClient`), so both providers produce summaries and
/// titles from exactly the same instructions.
enum MeetingTextPrompts {
    static let summaryChunkCharacters = 60_000
    static let titleTranscriptCharacters = 12_000
    static let maximumResponseBytes = 64 * 1_024 * 1_024

    static let titlePrompt = "You name meeting recordings. Write a specific, descriptive title of at most 8 words in the same language as the transcript. No quotes, no trailing period, no prefix like 'Title:'. Return only the title."

    static func titleInput(transcript: String) -> String {
        "\(titlePrompt)\n\nTranscript:\n\(String(transcript.prefix(titleTranscriptCharacters)))"
    }

    static func summaryPrompt(transcript: String) -> String {
        """
        Summarize this meeting transcript in Markdown with exactly these sections:
        ## Brief Summary
        ## Key Points
        ## Action Items

        Keep it concise. If there are no action items, write "- None".

        Transcript:
        \(transcript)
        """
    }

    static func chunkPrompt(index: Int, count: Int, chunk: String) -> String {
        "Summarize meeting transcript chunk \(index + 1) of \(count). Preserve decisions, owners, and action items.\n\n\(chunk)"
    }

    /// Summarizes `transcript` with `complete` (one model call per prompt):
    /// short transcripts in one call; longer ones chunk by chunk, then a final
    /// summary of the combined partial summaries.
    static func summarize(
        transcript: String,
        complete: (String) async throws -> String
    ) async throws -> String {
        let chunks = chunked(transcript, maximumCharacters: summaryChunkCharacters)
        if chunks.count == 1 {
            return try await complete(summaryPrompt(transcript: chunks[0]))
        }
        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            partials.append(try await complete(chunkPrompt(index: index, count: chunks.count, chunk: chunk)))
        }
        let combined = partials.enumerated().map { "Chunk \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n")
        return try await complete(summaryPrompt(transcript: combined))
    }

    /// Cleans a model's title reply with `MeetingTitleGenerator.cleaned(_:fallback:)`.
    /// - Throws: `ProviderError.invalidResponse` when nothing is left.
    static func cleanedTitle(_ reply: String) throws -> String {
        let title = MeetingTitleGenerator.cleaned(reply, fallback: "")
        guard !title.isEmpty else { throw ProviderError.invalidResponse }
        return title
    }

    /// Splits at the last newline before each `maximumCharacters` boundary.
    static func chunked(_ text: String, maximumCharacters: Int) -> [String] {
        guard text.count > maximumCharacters else { return [text] }
        var chunks: [String] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let proposed = text.index(cursor, offsetBy: maximumCharacters, limitedBy: text.endIndex) ?? text.endIndex
            var boundary = proposed
            if proposed < text.endIndex,
               let newline = text[cursor..<proposed].lastIndex(of: "\n") {
                boundary = text.index(after: newline)
            }
            chunks.append(String(text[cursor..<boundary]))
            cursor = boundary
        }
        return chunks
    }

    /// Throws `ProviderError.responseTooLarge`, `.invalidResponse` or
    /// `.providerRejected(status, first 500 bytes of the body)`.
    static func validate(response: URLResponse, data: Data) throws {
        guard data.count <= maximumResponseBytes else { throw ProviderError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String((String(data: data, encoding: .utf8) ?? "No response body").prefix(500))
            throw ProviderError.providerRejected(http.statusCode, message)
        }
    }
}
