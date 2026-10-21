import Foundation

public enum RecordingInteractionPolicy {
    public static func canSelectHistory(during state: RecordingWorkflowState) -> Bool {
        !state.isBusy && !state.isRecording && !state.isPaused
    }

    public static func canRecoverInterruptedRecordings(during state: RecordingWorkflowState) -> Bool {
        !state.isBusy && !state.isRecording && !state.isPaused
    }

    public static func canMutateRecordingLibrary(during state: RecordingWorkflowState) -> Bool {
        canSelectHistory(during: state)
    }

    public static func canPlayBack(during state: RecordingWorkflowState) -> Bool {
        !state.isBusy && !state.isRecording && !state.isPaused
    }

    public static func shouldApplyAsyncResult(targetID: UUID, selectedID: UUID?) -> Bool {
        targetID == selectedID
    }

    /// Whether a just-finished recording should be queued for transcription
    /// automatically.
    ///
    /// Returns `false` when the confidence report is shorter than
    /// `minimumDurationSeconds`, or has an `.error`-severity issue saying the
    /// audio is empty, silent or too short (`.emptyAudio`, `.silentAudio`,
    /// `.tooShort`). Warnings never block, so quiet but real meetings are still
    /// transcribed. Returns `true` when there is no report (analysis failed or
    /// was skipped): the user opted in, and a failed analysis is not evidence
    /// the audio is unusable.
    public static func shouldAutoTranscribe(
        report: RecordingConfidenceReport?,
        minimumDurationSeconds: TimeInterval = 3
    ) -> Bool {
        guard let report else { return true }
        guard report.durationSeconds >= minimumDurationSeconds else { return false }
        let blockingKinds: Set<RecordingConfidenceIssueKind> = [.emptyAudio, .silentAudio, .tooShort]
        return !report.issues.contains { $0.severity == .error && blockingKinds.contains($0.kind) }
    }
}
