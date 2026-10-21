import CryptoKit
import Foundation
import MSRCore

/// The outcome of publishing a transcript (and, optionally, auto-titling the recording).
public struct TranscriptPublishResult: Sendable {
    /// The recording as stored after publishing (renamed when auto-title applied).
    public var recording: RecordingItem
    /// The segments written next to the transcript.
    public var segments: [TranscriptSegment]
    /// The title applied by auto-title, or `nil` when the recording was not renamed.
    public var generatedTitle: String?
    /// `recording.effectiveTitleSource` after publishing.
    public var titleSource: RecordingTitleSource
    /// The job, marked `.completed` (and with `recordingName` updated after a rename).
    public var job: TranscriptionJob
    /// Why auto-title fell back or was skipped, for diagnostics only. Never fatal.
    public var titleNote: String?
    /// The summary written by the auto-summarize step, or `nil` when it did not
    /// run or failed.
    public var summaryMarkdown: String?
    /// Why the auto-summarize step failed. Never fatal: the job is already
    /// completed and the transcript published when this is set.
    public var summaryError: Error?
    /// Why the auto-summarize step wrote nothing although it ran (for example
    /// `TranscriptPublisher.existingSummaryKept`), or `nil`.
    public var summarySkippedReason: String?

    public init(
        recording: RecordingItem,
        segments: [TranscriptSegment],
        generatedTitle: String?,
        titleSource: RecordingTitleSource,
        job: TranscriptionJob,
        titleNote: String? = nil,
        summaryMarkdown: String? = nil,
        summaryError: Error? = nil,
        summarySkippedReason: String? = nil
    ) {
        self.recording = recording
        self.segments = segments
        self.generatedTitle = generatedTitle
        self.titleSource = titleSource
        self.job = job
        self.titleNote = titleNote
        self.summaryMarkdown = summaryMarkdown
        self.summaryError = summaryError
        self.summarySkippedReason = summarySkippedReason
    }
}

/// The outcome of `TranscriptPublisher.summarize`: at most one of `markdown`,
/// `error` and `skippedReason` is set (none when the transcript was empty).
public struct TranscriptSummaryOutcome: Sendable {
    /// The recording as stored after the step (re-read from disk when a summary was written).
    public var recording: RecordingItem
    /// The summary written to `summary.md`, or `nil` when nothing was written.
    public var markdown: String?
    /// What `summary.md` held immediately before the write (`""` when absent).
    public var previousSummary: String
    /// Why nothing was written although the step ran (no error).
    public var skippedReason: String?
    /// Why the summarizer failed. Never fatal for the transcription job.
    public var error: Error?

    public init(
        recording: RecordingItem,
        markdown: String? = nil,
        previousSummary: String = "",
        skippedReason: String? = nil,
        error: Error? = nil
    ) {
        self.recording = recording
        self.markdown = markdown
        self.previousSummary = previousSummary
        self.skippedReason = skippedReason
        self.error = error
    }
}

/// Publishes a finished transcription into the recording library and applies
/// auto-title, independent of the app's view model so the rules are testable.
///
/// Ordering guarantees (see `publish`):
/// 1. the recording is migrated to immutable storage;
/// 2. the job is checkpointed as "publishing" with the transcript's SHA-256, so
///    an interrupted publish can be recovered without re-billing the provider
///    (`recoverIfPublished`);
/// 3. the transcript bundle is written, and the summary cleared when replacing;
/// 4. the job is marked completed and checkpointed BEFORE any title work, so a
///    title failure can never fail or re-bill the job;
/// 5. auto-title runs next and is best-effort;
/// 6. auto-summarize (when the job requested it and a summarizer is supplied)
///    runs last, on the final (possibly renamed) recording, and is best-effort:
///    a failure is returned in `summaryError`, never thrown. It never replaces
///    a summary the user already has (see `summarize`). The app passes no
///    summarizer and calls `summarize` itself afterwards, so the transcript is
///    shown (and the queue moves on) while the summary is generated.
@MainActor
public enum TranscriptPublisher {
    /// Remote title generator. Returning `nil` (or throwing) falls back to the
    /// local heuristic `MeetingTitleGenerator.localTitle(from:segments:)`.
    public typealias TitleGenerator = @MainActor (String) async throws -> String?
    /// Remote summarizer (e.g. `ProviderAIService.summarize(transcript:)`).
    public typealias Summarizer = @MainActor (String) async throws -> SummarizeResponse

    public static func publish(
        job: TranscriptionJob,
        recording: RecordingItem,
        decoded: TranscribeResponse,
        autoTitleRequested: Bool,
        library: any RecordingLibraryServing,
        titleGenerator: TitleGenerator? = nil,
        summarizer: Summarizer? = nil,
        checkpoint: (TranscriptionJob) -> Void = { _ in }
    ) async throws -> TranscriptPublishResult {
        let stable = try library.migrateIfNeeded(recording)
        let segments = decoded.segments.isEmpty
            ? TranscriptParser.segments(from: decoded.text)
            : decoded.segments

        var current = job
        current.markPublishing(
            transcriptFileName: stable.transcriptURL.lastPathComponent,
            contentSHA256: sha256(decoded.text)
        )
        checkpoint(current)

        var published = try library.writeTranscriptBundle(decoded.text, segments: segments, for: stable)
        if job.replacingExistingTranscript {
            published = try library.clearSummary(for: published)
            // Diarized labels of a new transcript need not match the old ones.
            if let reset = try? library.resetSpeakerNames(for: published) {
                published = reset
            }
        }

        current.markCompleted(transcriptFileName: published.transcriptURL.lastPathComponent)
        checkpoint(current)
        // The caller's snapshot may predate a rename made while the job ran.
        published = onDisk(published, library: library)

        var finalRecording = published
        var generatedTitle: String?
        var titleNote: String?
        if autoTitleRequested {
            let outcome = await applyAutoTitle(
                to: published,
                transcript: decoded.text,
                segments: segments,
                library: library,
                titleGenerator: titleGenerator
            )
            if let renamed = outcome.renamed {
                current.recordingName = renamed.displayName
                checkpoint(current)
                finalRecording = renamed
                generatedTitle = renamed.displayName
            }
            titleNote = outcome.note
        }

        var summaryMarkdown: String?
        var summaryError: Error?
        var summarySkippedReason: String?
        if job.autoSummarizeRequested, let summarizer {
            // A replaced transcript's summary was cleared above, so only a
            // summary the user kept (or typed meanwhile) blocks the write.
            let outcome = await summarize(
                recording: finalRecording,
                transcript: decoded.text,
                library: library,
                summarizer: summarizer
            )
            if outcome.markdown != nil { finalRecording = outcome.recording }
            summaryMarkdown = outcome.markdown
            summaryError = outcome.error
            summarySkippedReason = outcome.skippedReason
        }

        return TranscriptPublishResult(
            recording: finalRecording,
            segments: segments,
            generatedTitle: generatedTitle,
            titleSource: finalRecording.effectiveTitleSource,
            job: current,
            titleNote: titleNote,
            summaryMarkdown: summaryMarkdown,
            summaryError: summaryError,
            summarySkippedReason: summarySkippedReason
        )
    }

    /// Error used when a summarizer returns only whitespace.
    public struct EmptySummaryError: Error, LocalizedError {
        public init() {}
        public var errorDescription: String? { "The summary provider returned an empty summary." }
    }

    /// `summarySkippedReason` when the recording already has a summary.
    public static let existingSummaryKept = "Existing summary kept"
    /// `summarySkippedReason` when the recording was deleted while summarizing.
    public static let recordingDeleted = "Recording was deleted"

    /// Summarizes `transcript` into the recording's `summary.md`, best-effort.
    ///
    /// Never overwrites a summary: when `summary.md` already has text, before
    /// the remote call or immediately before the write (the user typed while
    /// the summary ran), nothing is written and `skippedReason` is
    /// `existingSummaryKept`. The recording is re-read right before the write
    /// and nothing is written when it was deleted meanwhile (`recordingDeleted`).
    /// An empty transcript is skipped without calling the summarizer.
    public static func summarize(
        recording: RecordingItem,
        transcript: String,
        library: any RecordingLibraryServing,
        summarizer: Summarizer
    ) async -> TranscriptSummaryOutcome {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return TranscriptSummaryOutcome(recording: recording) }
        let initial = onDisk(recording, library: library)
        guard !hasSummaryText(storedSummary(of: initial)) else {
            return TranscriptSummaryOutcome(recording: initial, skippedReason: existingSummaryKept)
        }
        do {
            let response = try await summarizer(trimmed)
            let markdown = response.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markdown.isEmpty else {
                return TranscriptSummaryOutcome(recording: initial, error: EmptySummaryError())
            }
            // Re-read: the recording may have been renamed or deleted while the summary ran.
            guard let latest = try library.loadRecordings().first(where: { $0.id == recording.id }) else {
                return TranscriptSummaryOutcome(recording: initial, skippedReason: recordingDeleted)
            }
            let before = storedSummary(of: latest)
            guard !hasSummaryText(before) else {
                return TranscriptSummaryOutcome(recording: latest, previousSummary: before, skippedReason: existingSummaryKept)
            }
            let written = try library.writeSummary(markdown, for: latest)
            return TranscriptSummaryOutcome(
                recording: onDisk(written, library: library),
                markdown: markdown,
                previousSummary: before
            )
        } catch {
            return TranscriptSummaryOutcome(recording: initial, error: error)
        }
    }

    private static func storedSummary(of recording: RecordingItem) -> String {
        (try? String(contentsOf: recording.summaryURL, encoding: .utf8)) ?? ""
    }

    private static func hasSummaryText(_ summary: String) -> Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Completes a job whose transcript was already written (the app stopped
    /// between writing the transcript and marking the job completed), detected by
    /// the SHA-256 checkpoint. Performs the side effects that were skipped:
    /// clears the summary when the job replaced a transcript, and auto-titles
    /// with the local heuristic when requested and the title is still default.
    /// Returns `nil` when the on-disk transcript does not match the checkpoint.
    public static func recoverIfPublished(
        job: TranscriptionJob,
        recording: RecordingItem,
        library: any RecordingLibraryServing
    ) -> TranscriptPublishResult? {
        guard let expected = job.transcriptContentSHA256,
              let transcript = try? String(contentsOf: recording.transcriptURL, encoding: .utf8),
              sha256(transcript) == expected else { return nil }

        var current = job
        var recovered = onDisk(recording, library: library)
        if job.replacingExistingTranscript, let cleared = try? library.clearSummary(for: recovered) {
            recovered = cleared
            if let reset = try? library.resetSpeakerNames(for: recovered) {
                recovered = reset
            }
        }
        current.markCompleted(transcriptFileName: recovered.transcriptURL.lastPathComponent)

        let savedSegments = library.loadTranscriptSegments(for: recovered)
        let segments = savedSegments.isEmpty ? TranscriptParser.segments(from: transcript) : savedSegments
        var generatedTitle: String?
        if job.autoTitleRequested,
           recovered.effectiveTitleSource == .default,
           let local = MeetingTitleGenerator.localTitle(from: transcript, segments: segments),
           let renamed = try? library.renameIfTitleIsDefault(recovered, to: local) {
            recovered = renamed
            generatedTitle = renamed.displayName
            current.recordingName = renamed.displayName
        }
        return TranscriptPublishResult(
            recording: recovered,
            segments: segments,
            generatedTitle: generatedTitle,
            titleSource: recovered.effectiveTitleSource,
            job: current
        )
    }

    /// The stored state of `recording` (falls back to the snapshot when it cannot be read).
    private static func onDisk(_ recording: RecordingItem, library: any RecordingLibraryServing) -> RecordingItem {
        (try? library.loadRecordings())?.first { $0.id == recording.id } ?? recording
    }

    public nonisolated static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func applyAutoTitle(
        to recording: RecordingItem,
        transcript: String,
        segments: [TranscriptSegment],
        library: any RecordingLibraryServing,
        titleGenerator: TitleGenerator?
    ) async -> (renamed: RecordingItem?, note: String?) {
        // Cheap pre-check so a user-chosen title never costs a remote call.
        // `renameIfTitleIsDefault` re-checks on disk right before renaming.
        guard recording.effectiveTitleSource == .default else {
            return (nil, "title already chosen")
        }
        var note: String?
        var candidate: String?
        if let titleGenerator {
            do {
                if let remote = try await titleGenerator(transcript) {
                    let cleaned = MeetingTitleGenerator.cleaned(remote, fallback: "")
                    if cleaned.isEmpty || MeetingTitleGenerator.isDefaultName(cleaned) {
                        note = "remote title was empty"
                    } else {
                        candidate = cleaned
                    }
                } else {
                    note = "remote title unavailable"
                }
            } catch {
                note = "remote title failed: \(error.localizedDescription)"
            }
        }
        if candidate == nil {
            candidate = MeetingTitleGenerator.localTitle(from: transcript, segments: segments)
                .map { MeetingTitleGenerator.cleaned($0, fallback: "") }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let candidate else {
            return (nil, note ?? "no title could be derived from the transcript")
        }
        do {
            guard let renamed = try library.renameIfTitleIsDefault(recording, to: candidate) else {
                return (nil, "title already chosen")
            }
            return (renamed, note)
        } catch {
            return (nil, "rename failed: \(error.localizedDescription)")
        }
    }
}
