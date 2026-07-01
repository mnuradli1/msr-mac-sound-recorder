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
}
