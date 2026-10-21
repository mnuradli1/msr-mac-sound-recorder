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

    public init(
        recording: RecordingItem,
        segments: [TranscriptSegment],
        generatedTitle: String?,
        titleSource: RecordingTitleSource,
        job: TranscriptionJob,
        titleNote: String? = nil
    ) {
        self.recording = recording
        self.segments = segments
        self.generatedTitle = generatedTitle
        self.titleSource = titleSource
        self.job = job
        self.titleNote = titleNote
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
/// 5. auto-title runs last and is best-effort.
@MainActor
public enum TranscriptPublisher {
    /// Remote title generator. Returning `nil` (or throwing) falls back to the
    /// local heuristic `MeetingTitleGenerator.localTitle(from:segments:)`.
    public typealias TitleGenerator = @MainActor (String) async throws -> String?

    public static func publish(
        job: TranscriptionJob,
        recording: RecordingItem,
        decoded: TranscribeResponse,
        autoTitleRequested: Bool,
        library: any RecordingLibraryServing,
        titleGenerator: TitleGenerator? = nil,
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
        }

        current.markCompleted(transcriptFileName: published.transcriptURL.lastPathComponent)
        checkpoint(current)
        // The caller's snapshot may predate a rename made while the job ran.
        published = onDisk(published, library: library)

        guard autoTitleRequested else {
            return TranscriptPublishResult(
                recording: published,
                segments: segments,
                generatedTitle: nil,
                titleSource: published.effectiveTitleSource,
                job: current
            )
        }

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
        }
        let finalRecording = outcome.renamed ?? published
        return TranscriptPublishResult(
            recording: finalRecording,
            segments: segments,
            generatedTitle: outcome.renamed?.displayName,
            titleSource: finalRecording.effectiveTitleSource,
            job: current,
            titleNote: outcome.note
        )
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
