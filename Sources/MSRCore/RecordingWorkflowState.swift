import Foundation

public enum RecordingWorkflowState: Equatable, Sendable {
    case ready
    case starting(source: AudioSource)
    case recording(source: AudioSource)
    case finalizing(source: AudioSource)
    case saved
    case transcribing
    case summarizing
    case failed(String)

    public var lockedSource: AudioSource? {
        switch self {
        case let .starting(source), let .recording(source), let .finalizing(source):
            return source
        case .ready, .saved, .transcribing, .summarizing, .failed:
            return nil
        }
    }

    public var isBusy: Bool {
        switch self {
        case .starting, .finalizing, .transcribing, .summarizing:
            return true
        case .ready, .recording, .saved, .failed:
            return false
        }
    }

    public var isRecording: Bool {
        if case .recording = self {
            return true
        }
        return false
    }

    public var isFinalizing: Bool {
        if case .finalizing = self {
            return true
        }
        return false
    }

    public var isTranscribing: Bool {
        if case .transcribing = self {
            return true
        }
        return false
    }

    public var isSummarizing: Bool {
        if case .summarizing = self {
            return true
        }
        return false
    }
}

public enum RecordingPrimaryAction: Equatable, Sendable {
    case transcribe
    case summarize
    case copySummary

    public static func next(transcript: String, summary: String) -> RecordingPrimaryAction {
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .transcribe
        }
        if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .summarize
        }
        return .copySummary
    }

    public var title: String {
        switch self {
        case .transcribe:
            return "Transcribe with ElevenLabs"
        case .summarize:
            return "Summarize"
        case .copySummary:
            return "Copy Summary"
        }
    }

    public var systemImage: String {
        switch self {
        case .transcribe:
            return "text.quote"
        case .summarize:
            return "sparkles"
        case .copySummary:
            return "doc.on.doc.fill"
        }
    }
}
