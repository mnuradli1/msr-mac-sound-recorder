import AppKit
import Foundation
import MSRCore

/// Presentation helpers for the redesigned UI. Computed properties and small
/// helpers only; all state and behavior stay in `AppViewModel`.
extension AppViewModel {
    // MARK: Recording bar

    /// Chip shown next to the timer in the recording bar.
    var statusChip: (title: String, tone: Tone) {
        if !workflowState.isRecording, !workflowState.isPaused, activeTranscriptionJob != nil {
            return ("Transcribing", .progress)
        }
        switch workflowState {
        case .ready: return ("Ready", .success)
        case .starting: return ("Starting", .progress)
        case .recording: return ("Recording", .recording)
        case .suspending: return ("Pausing", .warning)
        case let .paused(_, reason): return (reason.displayName, .warning)
        case .finalizing: return ("Saving", .progress)
        case .saved: return ("Saved", .success)
        case .recovering: return ("Recovering", .progress)
        case .transcribing: return ("Transcribing", .progress)
        case .summarizing: return ("Summarizing", .progress)
        case .failed: return ("Needs attention", .danger)
        }
    }

    /// Source that the meters describe: the locked source while recording.
    var meterSource: AudioSource {
        workflowState.lockedSource ?? selectedSource
    }

    var isRecordingSessionActive: Bool {
        isRecording || workflowState.isPaused
    }

    // MARK: Sidebar

    var recordingSections: [RecordingSection] {
        let calendar = Calendar.current
        let recordings = filteredRecordings
        // Name/duration sorts read better as one flat list.
        switch settings.sortOrder {
        case .newest, .oldest:
            break
        default:
            return recordings.isEmpty ? [] : [RecordingSection(title: "All Recordings", recordings: recordings)]
        }
        let today = recordings.filter { calendar.isDateInToday($0.startedAt) }
        let yesterday = recordings.filter { calendar.isDateInYesterday($0.startedAt) }
        let earlier = recordings.filter {
            !calendar.isDateInToday($0.startedAt) && !calendar.isDateInYesterday($0.startedAt)
        }
        return [
            RecordingSection(title: "Today", recordings: today),
            RecordingSection(title: "Yesterday", recordings: yesterday),
            RecordingSection(title: "Earlier", recordings: earlier)
        ].filter { !$0.recordings.isEmpty }
    }

    /// Badges for a sidebar row, from the facts precomputed at library load
    /// (`recordingRowFacts`); never touches the disk.
    func rowBadges(for recording: RecordingItem) -> [RecordingBadge] {
        recordingRowFacts[recording.id]?.badges
            ?? RecordingRowFacts(recording: recording, hasTranscript: false, hasSummary: false).badges
    }

    /// Transcription job chip for a sidebar row (single `jobStatusText` path).
    /// `isAutomatic` marks jobs queued by auto-transcribe; the row draws a
    /// separate "Auto" chip so each title stays one localizable key.
    /// In-memory only (`job(for:)`): evaluated for every row on every render.
    func jobChip(for recording: RecordingItem) -> (title: String, tone: Tone, isAutomatic: Bool)? {
        guard let text = transcriptionStatusText(for: recording) else { return nil }
        let status = job(for: recording.id)?.status
        return (text, status == .failed ? .warning : .progress, isAutomaticTranscription(for: recording))
    }

    func jobStatusText(for job: TranscriptionJob) -> String {
        switch job.status {
        case .queued: "Queued"
        case .running: "Transcribing"
        case .failed: job.errorMessage ?? "Failed"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        }
    }

    func sourceLabel(for recording: RecordingItem) -> String {
        recording.isImported ? "Imported" : recording.source.displayName
    }

    // MARK: Detail

    func recordingSubtitleParts(_ recording: RecordingItem) -> [String] {
        [
            sourceLabel(for: recording),
            formatClock(recording.durationSeconds),
            recording.startedAt.formatted(date: .abbreviated, time: .shortened)
        ]
    }

    /// True while the selected recording's primary action is running or waiting.
    var isPrimaryActionBusy: Bool {
        selectedRecordingIsTranscribing || selectedRecordingIsQueuedForTranscription || workflowState.isSummarizing
            || selectedRecordingIsSummarizing
    }

    /// What Read mode shows (`readModeTranscript`, cached in `AppViewModel`):
    /// the saved (timed) segments while they still match the transcript text,
    /// otherwise speaker blocks rebuilt from the edited text. The segments file
    /// is left alone; it keeps the SRT timestamps.
    var readModeSegments: [TranscriptSegment] {
        readModeTranscript.segments
    }

    var hasSummary: Bool {
        !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canRenameSelection: Bool {
        selectedRecording != nil && canMutateRecordingLibrary
    }

    /// Starts inline rename in the detail header (no sheet).
    func beginInlineRename() -> Bool {
        guard let selectedRecording, canMutateRecordingLibrary else { return false }
        renameDraft = selectedRecording.displayName
        return true
    }

    var confidenceTone: Tone {
        let issues = selectedRecordingConfidenceIssues
        if issues.contains(where: { $0.severity == .error }) { return .danger }
        if issues.contains(where: { $0.severity == .warning }) { return .warning }
        return .info
    }

    // MARK: Readiness & status

    /// Setup items that should block or worry the user (warnings and errors only).
    var setupItemsNeedingAttention: [SetupHealthItem] {
        setupHealthItems.filter { $0.severity == .warning || $0.severity == .error }
    }

    func setupHealthItem(id: String) -> SetupHealthItem? {
        setupHealthItems.first { $0.id == id }
    }

    /// Opens the macOS privacy pane (or MSR Settings) that fixes a setup item.
    func fixSetupItem(_ item: SetupHealthItem) {
        let privacy = "x-apple.systempreferences:com.apple.preference.security?"
        switch item.id {
        case "microphone":
            if let url = URL(string: privacy + "Privacy_Microphone") { NSWorkspace.shared.open(url) }
        case "screen":
            if let url = URL(string: privacy + "Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
        default:
            openSettingsWindow()
        }
    }

    func fixActionTitle(for item: SetupHealthItem) -> String {
        switch item.id {
        case "microphone", "screen": "Open Privacy Settings"
        default: "Open Settings"
        }
    }

    var queueSummary: QueueSummary? {
        let jobs = visibleTranscriptionJobs
        guard !jobs.isEmpty else { return nil }
        if let active = activeTranscriptionJob {
            return .active(name: active.recordingName, total: jobs.count)
        }
        let failed = jobs.filter { $0.status == .failed }.count
        if failed == jobs.count { return .needsRetry(count: failed) }
        return .queued(count: jobs.count)
    }

    /// Local API status for the status bar; only when the API is enabled, and
    /// without the bearer token (that stays in Settings).
    var localAPIStatusSummary: String? {
        guard settings.localAPIEnabled, !localAPIStatusMessage.isEmpty else { return nil }
        return localAPIStatusMessage.components(separatedBy: " · token").first
    }
}

/// Per-recording sidebar facts, computed once per library load (and when the
/// app writes a sidecar) instead of on every row render.
struct RecordingRowFacts: Equatable {
    let hasTranscript: Bool
    let hasSummary: Bool
    /// Single source of truth for row badges, so new artifacts (e.g. an
    /// auto-generated title) only need a new `RecordingBadge` case here.
    let badges: [RecordingBadge]

    init(recording: RecordingItem, hasTranscript: Bool, hasSummary: Bool) {
        self.hasTranscript = hasTranscript
        self.hasSummary = hasSummary
        var badges: [RecordingBadge] = []
        if recording.metadata.confidenceReport?.hasWarnings == true { badges.append(.warning) }
        if hasTranscript { badges.append(.transcript) }
        if hasSummary { badges.append(.summary) }
        if recording.isRecovered { badges.append(.recovered) }
        if recording.isImported { badges.append(.imported) }
        if recording.effectiveTitleSource == .generated { badges.append(.autoTitled) }
        self.badges = badges
    }
}
