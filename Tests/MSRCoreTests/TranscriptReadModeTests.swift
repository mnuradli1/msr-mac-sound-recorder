import Foundation
import Testing
@testable import MSRCore

/// Read mode keeps the timed segments while they match the transcript text and
/// falls back to the edited text (without times) once they no longer do.
@Suite("Transcript read mode")
struct TranscriptReadModeTests {
    private static let saved = [
        TranscriptSegment(speaker: "Speaker 1", startTime: 0, endTime: 2.5, text: "Okay, hello everyone."),
        TranscriptSegment(speaker: "Speaker 2", startTime: 2.5, endTime: 9, text: "Today we discuss the launch date.")
    ]

    @Test func untouchedTranscriptKeepsTimedSegments() {
        let transcript = "Speaker 1:\nOkay, hello everyone.\n\nSpeaker 2:\nToday we discuss the launch date."
        let readable = TranscriptParser.readableTranscript(saved: Self.saved, transcript: transcript)
        #expect(!readable.isEdited)
        #expect(readable.segments == Self.saved)
    }

    @Test func whitespaceAndTimestampsDoNotCountAsEdits() {
        let transcript = "[00:00] Speaker 1:\n  Okay,   hello\neveryone.\r\n\r\n\n[00:02] Speaker 2:\nToday we discuss the launch date.\n"
        #expect(TranscriptParser.segments(Self.saved, match: transcript))
    }

    @Test func plainTextWithoutLabelsMatchesWhenTheWordsAreTheSame() {
        let transcript = "Okay, hello everyone. Today we discuss the launch date."
        #expect(TranscriptParser.segments(Self.saved, match: transcript))
    }

    @Test func editedWordsFallBackToUntimedSpeakerBlocks() {
        let transcript = "Speaker 1:\nOkay, hello team.\n\nSpeaker 2:\nToday we discuss the launch date.\n\nA paragraph without a label."
        let readable = TranscriptParser.readableTranscript(saved: Self.saved, transcript: transcript)
        #expect(readable.isEdited)
        #expect(readable.segments.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(readable.segments.map(\.text) == [
            "Okay, hello team.",
            "Today we discuss the launch date.\n\nA paragraph without a label."
        ])
        #expect(readable.segments.allSatisfy { $0.startTime == nil && $0.endTime == nil })
    }

    @Test func renamedSpeakerCountsAsAnEdit() {
        let transcript = "Adli:\nOkay, hello everyone.\n\nSpeaker 2:\nToday we discuss the launch date."
        let readable = TranscriptParser.readableTranscript(saved: Self.saved, transcript: transcript)
        #expect(readable.isEdited)
        #expect(readable.segments.first?.speaker == "Adli")
    }

    @Test func editedPlainTextBecomesOneUnlabelledSegment() {
        let readable = TranscriptParser.readableTranscript(saved: Self.saved, transcript: "Completely rewritten notes.")
        #expect(readable.isEdited)
        #expect(readable.segments.count == 1)
        #expect(readable.segments.first?.speaker == "")
        #expect(readable.segments.first?.text == "Completely rewritten notes.")
    }

    @Test func clearedTextShowsNothing() {
        let readable = TranscriptParser.readableTranscript(saved: Self.saved, transcript: "  \n")
        #expect(readable.isEdited)
        #expect(readable.segments.isEmpty)
    }
}
