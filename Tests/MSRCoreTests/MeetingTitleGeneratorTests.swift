import Foundation
import Testing
@testable import MSRCore

@Suite("Meeting title generator")
struct MeetingTitleGeneratorTests {
    // MARK: isDefaultName

    @Test func recognisesDefaultNames() {
        #expect(MeetingTitleGenerator.isDefaultName("Meeting 2026-06-29 14.05"))
        #expect(MeetingTitleGenerator.isDefaultName("Meeting 2026-06-29 14.05 2"))
        #expect(MeetingTitleGenerator.isDefaultName("Recovered Meeting 2026-06-29 14.05"))
        #expect(MeetingTitleGenerator.isDefaultName("Untitled Meeting"))
        #expect(MeetingTitleGenerator.isDefaultName("Untitled Meeting 3"))
        #expect(MeetingTitleGenerator.isDefaultName("  Meeting 2026-06-29 14.05  "))
    }

    @Test func rejectsUserLookingNames() {
        #expect(!MeetingTitleGenerator.isDefaultName("Meeting with Bob"))
        #expect(!MeetingTitleGenerator.isDefaultName("Meeting 2026-06-29"))
        #expect(!MeetingTitleGenerator.isDefaultName("meeting 2026-06-29 14.05"))
        #expect(!MeetingTitleGenerator.isDefaultName("Meeting 2026-06-29 14.05 notes"))
        #expect(!MeetingTitleGenerator.isDefaultName("Untitled Meeting notes"))
        #expect(!MeetingTitleGenerator.isDefaultName("Weekly Sync"))
        #expect(!MeetingTitleGenerator.isDefaultName(""))
    }

    // MARK: cleaned

    @Test func cleanedStripsQuotesPrefixesAndTrailingPeriods() {
        #expect(MeetingTitleGenerator.cleaned("\"Q3 Budget Review.\"", fallback: "x") == "Q3 Budget Review")
        #expect(MeetingTitleGenerator.cleaned("Title: \u{201C}Roadmap Planning\u{201D}", fallback: "x") == "Roadmap Planning")
        #expect(MeetingTitleGenerator.cleaned("title :  'Hiring Plan'", fallback: "x") == "Hiring Plan")
        #expect(MeetingTitleGenerator.cleaned("\u{00AB}Revisi\u{00F3}n del presupuesto\u{00BB}", fallback: "x") == "Revisi\u{00F3}n del presupuesto")
        #expect(MeetingTitleGenerator.cleaned("Investors' Update", fallback: "x") == "Investors' Update")
    }

    @Test func cleanedStripsMarkdownAndIndonesianPrefix() {
        #expect(MeetingTitleGenerator.cleaned("**Judul:** Rapat Anggaran Pemasaran\u{3002}", fallback: "x") == "Rapat Anggaran Pemasaran")
        #expect(MeetingTitleGenerator.cleaned("# `Launch Plan`", fallback: "x") == "Launch Plan")
        #expect(MeetingTitleGenerator.cleaned("**\"Title: Vendor Contract Renewal\"**", fallback: "x") == "Vendor Contract Renewal")
        #expect(MeetingTitleGenerator.cleaned("\n\nTitle: Hiring Plan\nSecond line", fallback: "x") == "Hiring Plan")
    }

    @Test func cleanedCapsWordsAndCharactersOnWordBoundaries() {
        #expect(
            MeetingTitleGenerator.cleaned("One two three four five six seven eight nine ten", fallback: "x")
                == "One two three four five six seven eight"
        )
        #expect(MeetingTitleGenerator.cleaned("Alpha Bravo Charlie Delta", fallback: "x", maximumCharacters: 15) == "Alpha Bravo")
        #expect(MeetingTitleGenerator.cleaned("Alpha Bravo Charlie", fallback: "x", maximumWords: 2) == "Alpha Bravo")
        #expect(MeetingTitleGenerator.cleaned(String(repeating: "a", count: 100), fallback: "x") == String(repeating: "a", count: 80))
        let long = Array(repeating: "Planning", count: 8).joined(separator: " ")
        let capped = MeetingTitleGenerator.cleaned(long + " " + long, fallback: "x")
        #expect(capped.count <= 80)
        #expect(!capped.hasSuffix(" "))
    }

    @Test func cleanedSanitizesAndFallsBackWhenNothingIsLeft() {
        #expect(MeetingTitleGenerator.cleaned("Q3/Q4 Roadmap: Draft?", fallback: "x") == "Q3 Q4 Roadmap Draft")
        #expect(MeetingTitleGenerator.cleaned("\"???\"", fallback: "Meeting 2026-06-29 14.05") == "Meeting 2026-06-29 14.05")
        #expect(MeetingTitleGenerator.cleaned("**\"\"**", fallback: "Fallback") == "Fallback")
        #expect(MeetingTitleGenerator.cleaned("   \n  ", fallback: "Fallback") == "Fallback")
        #expect(MeetingTitleGenerator.cleaned("Title:", fallback: "") == "")
    }

    // MARK: localTitle

    @Test func localTitleFromEnglishTranscriptDropsFillerAndLeadIn() {
        let transcript = "Okay, so today we're going to discuss the Q3 marketing budget and hiring plan. Then we will talk about launch."
        #expect(MeetingTitleGenerator.localTitle(from: transcript) == "Q3 marketing budget and hiring plan")
    }

    @Test func localTitleFromIndonesianSpeakerTurns() {
        let transcript = """
        Speaker 1:
        Halo, halo. Oke, jadi hari ini kita akan membahas anggaran pemasaran kuartal tiga.

        Speaker 2:
        Baik.
        """
        #expect(MeetingTitleGenerator.localTitle(from: transcript) == "Anggaran pemasaran kuartal tiga")
    }

    @Test func localTitleStripsInlineSpeakerLabels() {
        let transcript = """
        Speaker 0: Hello everyone.
        Speaker 1: We need to finalize the vendor contract renewal before Friday.
        """
        #expect(MeetingTitleGenerator.localTitle(from: transcript) == "We need to finalize the vendor contract renewal")
    }

    @Test func localTitlePrefersSegments() {
        let segments = [
            TranscriptSegment(speaker: "Speaker 1", startTime: 0, text: "Um, yeah."),
            TranscriptSegment(speaker: "Speaker 2", startTime: 2, text: "Let's review the onboarding flow redesign for mobile.")
        ]
        #expect(
            MeetingTitleGenerator.localTitle(from: "Speaker 1: Ignored budget discussion text here.", segments: segments)
                == "Onboarding flow redesign for mobile"
        )
    }

    @Test func localTitleIgnoresTimestampsAndSoundTags() {
        let transcript = """
        [00:00] [music]
        [00:05] Speaker 1: (laughs) Welcome to the quarterly planning session for the design team.
        """
        #expect(MeetingTitleGenerator.localTitle(from: transcript) == "The quarterly planning session for the design team")

        let srt = "1\n00:00:01,000 --> 00:00:04,000\nThe new pricing tiers launch next month.\n"
        #expect(MeetingTitleGenerator.localTitle(from: srt) == "The new pricing tiers launch next month")
    }

    @Test func localTitleReturnsNilForFillerTagsAndEmptyInput() {
        #expect(MeetingTitleGenerator.localTitle(from: "") == nil)
        #expect(MeetingTitleGenerator.localTitle(from: "[outro jingle]") == nil)
        #expect(MeetingTitleGenerator.localTitle(from: "(music) [applause] \u{266A}") == nil)
        #expect(MeetingTitleGenerator.localTitle(from: "Okay. Um, yeah. Testing, testing, one two three. Hello? Hi!") == nil)
        #expect(MeetingTitleGenerator.localTitle(from: "Halo halo, satu dua tiga. Oke ya. Eh, hmm, jadi.") == nil)
        #expect(MeetingTitleGenerator.localTitle(from: "Speaker 0: Thanks for joining.\nSpeaker 1: Good morning everyone.") == nil)
        #expect(MeetingTitleGenerator.localTitle(from: "Budget review.") == nil)
    }

    @Test func localTitleCapsWordsAndTrimsDanglingWords() {
        let transcript = "We should finalize the budget for the next quarter today."
        #expect(MeetingTitleGenerator.localTitle(from: transcript, maximumWords: 5) == "We should finalize the budget")
        #expect(MeetingTitleGenerator.localTitle(from: transcript, maximumWords: 4) == "We should finalize")
        #expect(
            MeetingTitleGenerator.localTitle(from: "So we should, um, finalize the hiring plan, uh, this week.")
                == "We should finalize the hiring plan this week"
        )
    }

    @Test func localTitleKeepsMixedCaseAndNeverReturnsDefaultName() {
        #expect(
            MeetingTitleGenerator.localTitle(from: "iPhone launch timeline and pricing strategy for Europe.")
                == "iPhone launch timeline and pricing strategy for Europe"
        )
        let transcript = "Meeting 2026-06-29 14.05 notes about churn. Customer churn rose sharply in March."
        let title = MeetingTitleGenerator.localTitle(from: transcript, maximumWords: 3)
        #expect(title == "Customer churn rose")
        #expect(title.map(MeetingTitleGenerator.isDefaultName) == false)
    }

    @Test func localTitleIsDeterministic() {
        let transcript = "Speaker 1:\nOkay. Let's discuss the warehouse migration timeline and risks."
        let first = MeetingTitleGenerator.localTitle(from: transcript)
        #expect(first == "Warehouse migration timeline and risks")
        for _ in 0..<5 {
            #expect(MeetingTitleGenerator.localTitle(from: transcript) == first)
        }
    }
}

@Suite("Auto-transcribe contracts")
struct AutoTranscribeContractTests {
    @Test func settingsRoundTripAutoTranscribeAndAutoTitle() throws {
        var settings = AppSettings.default
        #expect(!settings.autoTranscribe)
        #expect(settings.autoTitle)
        settings.autoTranscribe = true
        settings.autoTitle = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.autoTranscribe)
        #expect(!decoded.autoTitle)
        #expect(AppSettings(provider: .openAI, recordingsFolderPath: nil).autoTranscribe == false)
    }

    @Test func legacyJobWithoutOriginDecodesAsManual() throws {
        let data = Data("""
        {
          "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
          "recordingID": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
          "recordingName": "Legacy",
          "audioFileName": "legacy.m4a",
          "provider": "elevenlabs",
          "status": "queued",
          "attemptCount": 1,
          "startedAt": "1970-01-01T00:00:01Z",
          "updatedAt": "1970-01-01T00:00:01Z"
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let job = try decoder.decode(TranscriptionJob.self, from: data)
        #expect(job.origin == .manual)
        #expect(!job.autoTitleRequested)
        #expect(!job.autoSummarizeRequested)
        #expect(TranscriptionJob.queue(recordingID: UUID(), recordingName: "M", audioFileName: "a.m4a", provider: .openAI).origin == .manual)
        let requested = TranscriptionJob.queue(
            recordingID: UUID(), recordingName: "M", audioFileName: "a.m4a", provider: .openAI, autoSummarizeRequested: true
        )
        #expect(requested.autoSummarizeRequested)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        #expect(try decoder.decode(TranscriptionJob.self, from: encoder.encode(requested)).autoSummarizeRequested)
    }

    @Test func jobRoundTripPreservesOriginAndAutoTitleRequest() throws {
        let folder = try ScratchFolder()
        let store = TranscriptionJobStore(folderURL: folder.url)
        var job = TranscriptionJob.queue(
            recordingID: UUID(),
            recordingName: "Meeting 2026-06-29 14.05",
            audioFileName: "recording.m4a",
            provider: .elevenLabs,
            origin: .automatic,
            autoTitleRequested: true,
            at: Date(timeIntervalSince1970: 10)
        )
        job.markRunning(at: Date(timeIntervalSince1970: 11))
        job.markInterruptedIfRunning(at: Date(timeIntervalSince1970: 12))
        try store.save(job)
        let loaded = try store.load(jobID: job.id)
        #expect(loaded == job)
        #expect(loaded.origin == .automatic)
        #expect(loaded.autoTitleRequested)
    }

    @Test func autoTranscribePolicySkipsEmptySilentAndShortAudio() {
        func report(duration: TimeInterval, _ issues: [RecordingConfidenceIssue] = []) -> RecordingConfidenceReport {
            RecordingConfidenceReport(checkedAt: Date(), durationSeconds: duration, peakLevel: 0.5, averageLevel: 0.1, issues: issues)
        }
        func issue(_ kind: RecordingConfidenceIssueKind, _ severity: RecordingConfidenceSeverity) -> RecordingConfidenceIssue {
            RecordingConfidenceIssue(kind: kind, severity: severity, message: kind.rawValue)
        }

        #expect(RecordingInteractionPolicy.shouldAutoTranscribe(report: nil))
        #expect(RecordingInteractionPolicy.shouldAutoTranscribe(report: report(duration: 60)))
        #expect(RecordingInteractionPolicy.shouldAutoTranscribe(report: report(duration: 3)))
        #expect(!RecordingInteractionPolicy.shouldAutoTranscribe(report: report(duration: 2.9)))
        #expect(!RecordingInteractionPolicy.shouldAutoTranscribe(report: report(duration: 0, [issue(.emptyAudio, .error)])))
        #expect(!RecordingInteractionPolicy.shouldAutoTranscribe(report: report(duration: 60, [issue(.emptyAudio, .error)])))
        #expect(!RecordingInteractionPolicy.shouldAutoTranscribe(report: report(duration: 60, [issue(.silentAudio, .error)])))
        #expect(!RecordingInteractionPolicy.shouldAutoTranscribe(report: report(duration: 60, [issue(.tooShort, .error)])))
        #expect(RecordingInteractionPolicy.shouldAutoTranscribe(report: report(duration: 60, [issue(.silentAudio, .warning)])))
        #expect(RecordingInteractionPolicy.shouldAutoTranscribe(report: report(duration: 60, [issue(.missingExpectedSource, .error)])))
        #expect(!RecordingInteractionPolicy.shouldAutoTranscribe(report: report(duration: 8), minimumDurationSeconds: 10))
    }
}

private final class ScratchFolder: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
