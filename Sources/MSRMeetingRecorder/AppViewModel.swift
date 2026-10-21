import AppKit
import AVFoundation
import CoreGraphics
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import MSRCore
import MSRServices

enum AppNoticeSeverity {
    case info
    case success
    case warning
    case error
}

enum RecordingDetailTab: String, CaseIterable, Identifiable {
    case review = "Review"
    case notes = "Notes"
    case export = "Export"
    var id: String { rawValue }
}

struct SetupHealthItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let severity: AppNoticeSeverity
    let systemImage: String
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var recordings: [RecordingItem] = []
    /// What the sidebar rows draw for each recording (transcript/summary
    /// presence and badges). Rebuilt once per library load and updated when
    /// the app writes a sidecar, so rendering a row never touches the disk.
    @Published private(set) var recordingRowFacts: [UUID: RecordingRowFacts] = [:]
    @Published var selectedRecording: RecordingItem?
    @Published var selectedSource: AudioSource = .micAndSystem
    @Published var settings: AppSettings
    @Published var workflowState: RecordingWorkflowState = .ready {
        didSet { if libraryWatcherMissedEvents { resumeLibraryWatcherAfterBusy() } }
    }
    @Published var statusMessage = "Ready" {
        didSet {
            guard statusMessage != oldValue else { return }
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: statusMessage, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
            )
        }
    }
    @Published var transcriptText = "" {
        didSet { readModeCache = nil }
    }
    @Published var summaryText = ""
    @Published var recordingSearchQuery = ""
    @Published var renameDraft = ""
    @Published var showingRename = false
    @Published var elevenLabsKeyDraft = ""
    @Published var openAIKeyDraft = ""
    @Published var deepSeekKeyDraft = ""
    @Published var transcriptionStartedAt: Date?
    @Published var selectedTranscriptionJob: TranscriptionJob?
    /// The single in-memory source for job state in render paths (see `job(for:)`).
    @Published var transcriptionJobs: [TranscriptionJob] = [] {
        didSet {
            jobsByRecordingID = Self.latestJobByRecording(transcriptionJobs)
            transcriptionJobsGeneration &+= 1
        }
    }
    @Published var transcriptSegments: [TranscriptSegment] = [] {
        didSet { readModeCache = nil }
    }
    @Published var selectedDetailTab: RecordingDetailTab = .review
    /// Meter levels and elapsed time. Kept out of this object: they change
    /// many times a second while recording, and every `@Published` change here
    /// re-renders every view observing the model (sidebar, detail, commands).
    let live = RecordingLiveState()
    /// Playback position/duration, play state, review waveform and trim range;
    /// separate for the same reason (4 Hz while playing, continuous while a
    /// trim slider is dragged).
    let playback = PlaybackState()
    @Published var selectedExportFormat: TranscriptExportFormat = .markdown
    @Published var exportPreview = ""
    @Published var transcriptSaveMessage = ""
    @Published var lastExportURL: URL?
    @Published var setupHealthItems: [SetupHealthItem] = []
    @Published var microphoneDevices: [MicrophoneDevice] = []
    @Published var credentialStatusMessage = ""
    @Published var credentialStatusSeverity: AppNoticeSeverity = .info
    @Published var isTestingCredential = false
    @Published var localAPIStatusMessage = ""
    @Published var recoveryMessage = ""
    @Published var recoveryNoticeSeverity: AppNoticeSeverity = .info
    /// Set when auto-transcribe is on but could not run for the recording that
    /// just finished (for example no API key for the provider). Cleared when the
    /// next recording starts, when settings or keys change, or by
    /// `clearAutoTranscribeNotice()`.
    @Published var autoTranscribeNotice: String?
    /// Set when auto-title renamed a recording, e.g. `Titled “Launch date and onboarding owner”`.
    @Published var lastAutoTitleNotice: String?
    /// Set when auto-summarize finished for a recording: `Summary ready via DeepSeek`
    /// or `Auto-summary failed: …`. Dismissible, like `lastAutoTitleNotice`.
    @Published var lastAutoSummaryNotice: String?
    /// Whether `lastAutoSummaryNotice` reports a failure (warning) or a summary (success).
    @Published private(set) var lastAutoSummaryFailed = false
    /// Which text model wrote each summary produced in this run (not stored on
    /// disk), for the Summary panel's "via …" label.
    @Published private(set) var summaryProviderByRecording: [UUID: TextModelProvider] = [:]
    /// Credentials with a key available (session, environment or Keychain),
    /// cached by `refreshSetupHealth()` so views never query the Keychain while rendering.
    @Published private(set) var savedCredentials: Set<CredentialProvider> = []
    /// Outcome of the auto-summarize step per recording in this run (scenario diagnostics).
    private(set) var autoSummaryOutcomes: [UUID: AutoSummaryOutcome] = [:]
    /// Matches of the current query (`nil` when not searching), as streamed by
    /// `searchIndexer` for `searchGeneration`.
    @Published private var filteredRecordingIDs: [UUID]?
    /// Bumped per query; results of an older query are dropped.
    private var searchGeneration = 0
    /// The recording whose transcript is being published (auto-title runs
    /// after the job is marked completed; the summary runs afterwards, on its own).
    @Published private var publishingRecordingID: UUID?
    /// Recordings whose summary is being generated (auto-summarize after a
    /// transcription, or Summarize). Blocks only that recording's summary
    /// editing and summary/transcribe actions; the queue keeps running.
    @Published private(set) var summarizingRecordingIDs: Set<UUID> = []
    /// The text model each in-flight summary uses, for the Summary panel header.
    private var summarizingProviders: [UUID: TextModelProvider] = [:]
    /// In-flight auto-summary tasks, cancelled when the app quits.
    private var autoSummaryTasks: [UUID: Task<Void, Never>] = [:]

    private let settingsStore = UserDefaultsSettingsStore()
    private let keyStore = APIKeyStore()
    private let credentialValidator = CredentialValidator()
    private let recorder: AudioRecording
    private let aiService: ProviderAIService
    private let libraryFactory: (URL) -> any RecordingLibraryServing
    private let recordingsFolderOverride: URL?
    private var localServer: LocalHTTPServer?
    private var recordingSessionClock: RecordingSessionClock?
    private var temporaryAudioURL: URL?
    private var completedSegmentURLs: [URL] = []
    private var currentSessionManifest: RecordingSessionManifest?
    private var currentSessionSource: AudioSource?
    private var currentSessionName: String?
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var recordingTimer: Timer?
    private let recordingActions = RecordingActionCoordinator()
    private var recordingActionInFlight: Bool { recordingActions.actionInFlight }
    var sleepSafetyPending: Bool { recordingActions.sleepPending }
    private var systemSleepCoordinator: SystemSleepCoordinator?
    private var powerEventTask: Task<Void, Never>?
    private var transcriptionQueueTask: Task<Void, Never>?
    private var microphonePeakDuringRecording: Float = 0
    private var systemPeakDuringRecording: Float = 0
    private var powerObserverTokens: [NSObjectProtocol] = []
    private var sleepPreventionActivity: NSObjectProtocol?
    private var settingsWindow: NSWindow?
    private var securityScopedFolderURL: URL?
    private let waveformAnalyzer = WaveformAnalyzer(capacity: 64)
    private var waveformTask: Task<Void, Never>?
    private var transcriptAutosaveTask: Task<Void, Never>?
    private var summaryAutosaveTask: Task<Void, Never>?
    private var recordingSearchTask: Task<Void, Never>?
    private var windowSaveTask: Task<Void, Never>?
    private let globalHotkeyService = GlobalHotkeyService()
    private let folderWatcher = RecordingFolderWatcher()
    /// Full-text index (folded metadata always, transcript/summary text
    /// compressed within a byte budget); every query runs on it, off main.
    private let searchIndexer = RecordingSearchIndexer()
    private var searchIndexTask: Task<Void, Never>?
    private var watchedFolderPath: String?
    /// The library folder as of the last load, patched for the app's own
    /// writes since; folder-watcher events that leave it unchanged are ignored.
    private(set) var libraryFolderSnapshot: LibraryFolderSnapshot?
    /// `transcriptionJobs` indexed by recording (the first, i.e. most recently
    /// updated, job of each recording).
    private var jobsByRecordingID: [UUID: TranscriptionJob] = [:]
    /// Bumped on every change to `transcriptionJobs`; the jobs read by a
    /// background load are dropped when memory changed (a job was saved) since.
    private var transcriptionJobsGeneration = 0
    /// Library filesystem work done off the main actor (see `refreshLibrary`).
    private let libraryLoader = LibraryLoader()
    /// Bumped by every library load, sync or async; a background load whose
    /// generation is no longer current when it finishes is dropped.
    private var libraryLoadGeneration = 0
    /// The newest load generation that finished (applied, or dropped by
    /// `onlyWhenIdle`), and the superseded callers waiting for one at least as new.
    private var completedLibraryLoadGeneration = 0
    private var libraryLoadWaiters: [(generation: Int, continuation: CheckedContinuation<Void, Never>)] = []
    /// The newest generation started by a load that must be applied (not
    /// `onlyWhenIdle`). An idle-only load that supersedes it is applied even
    /// when busy, because the superseded caller waits for its result.
    private var newestRequiredLibraryLoadGeneration = 0
    /// Bumped by every in-memory patch of the library (`recordings`, row
    /// facts) made without a reload: rename, speaker rename, delete, sidecar
    /// writes. A background load that was reading while it changed would put
    /// the old state back, so its result is discarded and the load re-run.
    private var libraryMutationCounter = 0
    /// The folder watcher dropped an event while recording or busy; checked
    /// again (with a content re-index) once the workflow is idle.
    private var libraryWatcherMissedEvents = false
    /// Parsed Read-mode transcript; cleared whenever the transcript text or
    /// segments change (not published: it is derived state).
    private var readModeCache: ReadableTranscript?
    private var didBootstrap = false
    /// The settings whose side effects (hotkey, watcher, health, local API) were
    /// last applied; `saveSettings()` only re-runs a side effect when its inputs change.
    private var lastAppliedSettings: AppSettings
    private var settingsSaveTask: Task<Void, Never>?
    /// The folder the running local API server was started for.
    private var localAPIApprovedFolder: URL?
    /// Dev/scenario hook: when `true`, settings changes stay in memory and are
    /// never written to `UserDefaults`.
    var settingsPersistenceSuspended = false
    /// What `loadSelectedSidecars()` last loaded; `loadRecordings()` only reloads
    /// the selection's sidecars (and so resets trims and unsaved edits) when this changes.
    private var lastLoadedSidecarStamp: SidecarStamp?
    /// A capture failure reported while the session was still `.starting`;
    /// handled as soon as the session reaches `.recording`.
    private var pendingCaptureFailure: Error?
    /// `recoveryMessage` currently describes a capture failure (see `handleCaptureFailure`).
    private var recoveryMessageIsCaptureFailure = false

    /// - Parameter recorder: the capture engine. `nil` uses `MeetingAudioRecorder`,
    ///   or, for development, `FileReplayRecorder` when the environment variable
    ///   `MSR_FAKE_RECORDER_CLIP` names an existing audio file (each "recording"
    ///   then becomes a copy of that clip; no microphone or screen permission needed).
    init(
        recorder: AudioRecording? = nil,
        libraryFactory: @escaping (URL) -> any RecordingLibraryServing = { RecordingLibrary(folderURL: $0) },
        recordingsFolderOverride: URL? = nil
    ) {
        let loadedSettings = settingsStore.load()
        settings = loadedSettings
        lastAppliedSettings = loadedSettings
        self.recorder = recorder ?? Self.makeDefaultRecorder()
        self.libraryFactory = libraryFactory
        self.recordingsFolderOverride = recordingsFolderOverride
        aiService = ProviderAIService(keyStore: keyStore, textModelProvider: loadedSettings.summaryProvider)
        selectedSource = settings.preferredSource
        self.recorder.setMicrophoneDeviceUID(settings.microphoneDeviceID)
        if recordingsFolderOverride == nil, let bookmark = settings.recordingsFolderBookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                _ = url.startAccessingSecurityScopedResource()
                securityScopedFolderURL = url
                if stale,
                   let refreshed = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    settings.recordingsFolderBookmark = refreshed
                }
            }
        }
        // `onLevelUpdate` (the combined level) is not installed: no view reads
        // it, and each report would cost a main-actor hop and a model publish.
        self.recorder.onSourceLevelUpdate = { [weak self] channel, level in
            Task { @MainActor in
                self?.updateSourceLevel(channel, level)
            }
        }
        // `onCaptureFailure` is installed per capture segment (see `installCaptureFailureHandler`).
        lastAppliedSettings = settings
    }

    private static func makeDefaultRecorder() -> AudioRecording {
        if let path = ProcessInfo.processInfo.environment["MSR_FAKE_RECORDER_CLIP"], !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return FileReplayRecorder(clipURL: URL(fileURLWithPath: path))
        }
        return MeetingAudioRecorder()
    }

    /// Binds capture-failure reports to one session segment, so a late report from an
    /// earlier (paused) segment can never stop the capture that replaced it.
    private func installCaptureFailureHandler(sessionID: UUID, segmentFileName: String) {
        recorder.onCaptureFailure = { @Sendable [weak self] error in
            Task { @MainActor in
                await self?.handleCaptureFailure(error, sessionID: sessionID, segmentFileName: segmentFileName)
            }
        }
    }

    var isRecording: Bool {
        workflowState.isRecording
    }

    // Read/write forwarding to `live` and `playback` (source compatibility).
    // Views that draw these values observe `live`/`playback` directly.
    var microphoneLevel: Float { live.microphoneLevel }
    var systemLevel: Float { live.systemLevel }
    var recordingElapsed: TimeInterval { live.recordingElapsed }
    var isPlaying: Bool { playback.isPlaying }
    var playbackPosition: TimeInterval { playback.playbackPosition }
    var playbackDuration: TimeInterval { playback.playbackDuration }
    var reviewWaveform: [Float] { playback.reviewWaveform }
    var trimStartSeconds: TimeInterval {
        get { playback.trimStartSeconds }
        set { playback.trimStartSeconds = newValue }
    }
    var trimEndSeconds: TimeInterval {
        get { playback.trimEndSeconds }
        set { playback.trimEndSeconds = newValue }
    }

    var displayedSource: AudioSource {
        workflowState.lockedSource ?? selectedSource
    }

    var sourcePickerDisabled: Bool {
        workflowState.lockedSource != nil || workflowState.isBusy
    }

    var canToggleRecording: Bool {
        if recordingActionInFlight {
            return false
        }
        if isRecording || workflowState.isPaused {
            return true
        }
        return !workflowState.isBusy
    }

    var canPauseRecording: Bool {
        isRecording && !recordingActionInFlight
    }

    var canSavePausedRecording: Bool {
        workflowState.isPaused && !recordingActionInFlight && !completedSegmentURLs.isEmpty
    }

    var recordingButtonTitle: String {
        switch workflowState {
        case .starting:
            return "Starting..."
        case .recording:
            return "Stop Recording"
        case .suspending:
            return "Pausing..."
        case let .paused(_, reason):
            return reason == .systemSleep ? "Resume Recording" : "Resume"
        case .finalizing:
            return "Finalizing..."
        case .recovering:
            return "Recovering..."
        case .ready, .saved, .failed, .transcribing, .summarizing:
            return "Record"
        }
    }

    var recordingButtonSystemImage: String {
        if workflowState.isPaused {
            return "play.circle.fill"
        }
        return isRecording ? "stop.circle.fill" : "record.circle"
    }

    var secondaryRecordingButtonTitle: String? {
        if isRecording {
            return "Pause"
        }
        if workflowState.isPaused {
            return "Save"
        }
        return nil
    }

    var secondaryRecordingButtonSystemImage: String {
        workflowState.isPaused ? "checkmark.circle" : "pause.circle"
    }

    var canUseSecondaryRecordingAction: Bool {
        if isRecording {
            return canPauseRecording
        }
        if workflowState.isPaused {
            return canSavePausedRecording
        }
        return false
    }

    var primaryAction: RecordingPrimaryAction {
        RecordingPrimaryAction.next(transcript: transcriptText, summary: summaryText)
    }

    var primaryActionTitle: String {
        switch primaryAction {
        case .transcribe:
            if selectedTranscriptionJob?.status == .queued {
                return "Queued"
            }
            if selectedTranscriptionJob?.status == .running {
                return "Transcribing..."
            }
            if selectedTranscriptionJob?.status == .failed {
                return "Retry transcription"
            }
            return "Transcribe with \(settings.provider.displayName)"
        case .summarize:
            return "Summarize"
        case .copySummary:
            return "Copy Meeting Notes"
        }
    }

    var hasTranscript: Bool {
        !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canPlaySelectedRecording: Bool {
        selectedRecording != nil && RecordingInteractionPolicy.canPlayBack(during: workflowState)
    }

    var canSelectHistory: Bool {
        RecordingInteractionPolicy.canSelectHistory(during: workflowState)
    }

    var canMutateRecordingLibrary: Bool {
        RecordingInteractionPolicy.canMutateRecordingLibrary(during: workflowState)
    }

    var canRunPrimaryAction: Bool {
        guard let selectedRecording, canSelectHistory else { return false }
        // A summary in flight for this recording blocks Summarize and
        // (re-)transcribing it, which would make that summary stale.
        return !hasPendingTranscription(for: selectedRecording.id)
            && !summarizingRecordingIDs.contains(selectedRecording.id)
    }

    var activeTranscriptionJob: TranscriptionJob? {
        transcriptionJobs.first { $0.status == .running }
    }

    var visibleTranscriptionJobs: [TranscriptionJob] {
        transcriptionJobs.filter { job in
            switch job.status {
            case .queued, .running, .failed:
                return true
            case .completed, .cancelled:
                return false
            }
        }
    }

    var hasVisibleTranscriptionJobs: Bool {
        !visibleTranscriptionJobs.isEmpty
    }

    var recentTranscriptionHistory: [TranscriptionJob] {
        transcriptionJobs
            .filter { $0.status == .completed || $0.status == .cancelled }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(20)
            .map { $0 }
    }

    var selectedRecordingIsTranscribing: Bool {
        guard let selectedRecording else { return false }
        return publishingRecordingID == selectedRecording.id || job(for: selectedRecording.id)?.status == .running
    }

    var selectedRecordingIsQueuedForTranscription: Bool {
        guard let selectedRecording else { return false }
        return job(for: selectedRecording.id)?.status == .queued
    }

    var selectedRecordingConfidenceIssues: [RecordingConfidenceIssue] {
        selectedRecording?.metadata.confidenceReport?.issues ?? []
    }

    var miniRecordingIndicatorText: String? {
        switch workflowState {
        case let .recording(source):
            return "Recording \(source.displayName) \(formatDuration(recordingElapsed))"
        case let .paused(source, reason):
            return "\(reason.displayName) \(source.displayName) \(formatDuration(recordingElapsed))"
        default:
            return nil
        }
    }

    var isSearchingRecordings: Bool {
        !recordingSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var filteredRecordings: [RecordingItem] {
        let matches: [RecordingItem]
        if let filteredRecordingIDs {
            let lookup = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            matches = filteredRecordingIDs.compactMap { lookup[$0] }
        } else {
            matches = recordings
        }
        switch settings.sortOrder {
        case .newest: return matches.sorted { $0.startedAt > $1.startedAt }
        case .oldest: return matches.sorted { $0.startedAt < $1.startedAt }
        case .nameAscending: return matches.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .nameDescending: return matches.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedDescending }
        case .durationLongest: return matches.sorted { $0.durationSeconds > $1.durationSeconds }
        case .durationShortest: return matches.sorted { $0.durationSeconds < $1.durationSeconds }
        }
    }

    var recordingSearchResultCount: Int {
        filteredRecordings.count
    }

    var workflowErrorMessage: String? {
        if case let .failed(message) = workflowState {
            return message
        }
        return nil
    }

    var recordingsFolderURL: URL {
        if let recordingsFolderOverride { return recordingsFolderOverride }
        // Developer override so snapshot/UI runs can use a fixture library
        // instead of the user's real recordings.
        if let override = ProcessInfo.processInfo.environment["MSR_RECORDINGS_FOLDER"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let securityScopedFolderURL { return securityScopedFolderURL }
        if let path = settings.recordingsFolderPath, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        return (music ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("MSR Recordings", isDirectory: true)
    }

    var selectedProviderName: String {
        settings.provider.displayName
    }

    // MARK: - Auto-transcribe / auto-title state for the UI

    /// Who chose the selected recording's title (`nil` when nothing is selected).
    var selectedRecordingTitleSource: RecordingTitleSource? {
        selectedRecording?.effectiveTitleSource
    }

    /// Whether the recording's latest transcription job was queued by auto-transcribe.
    func isAutomaticTranscription(for recording: RecordingItem) -> Bool {
        // In-memory only: this is evaluated per row while rendering.
        job(for: recording.id)?.origin == .automatic
    }

    /// Auto-transcribe is switched on AND the current provider has an API key.
    var autoTranscribeIsEffective: Bool {
        settings.autoTranscribe && credentialAvailable(for: settings.provider)
    }

    func clearAutoTranscribeNotice() {
        autoTranscribeNotice = nil
    }

    func clearAutoTitleNotice() {
        lastAutoTitleNotice = nil
    }

    func clearAutoSummaryNotice() {
        lastAutoSummaryNotice = nil
    }

    // MARK: - Summaries (OpenAI or DeepSeek)

    /// Whether a summary can be requested: an OpenAI or DeepSeek key is
    /// available. Read from `savedCredentials`, so views never query the
    /// Keychain while rendering; actions re-check through `aiService`.
    var canSummarize: Bool {
        resolvedSummaryProvider != nil
    }

    /// The text model summaries would use right now (the selected provider when
    /// it has a key, otherwise the other one), or `nil` without either key.
    /// Derived from the cached `savedCredentials` and `settings.summaryProvider`.
    var resolvedSummaryProvider: TextModelProvider? {
        [settings.summaryProvider, settings.summaryProvider.alternative]
            .first { savedCredentials.contains($0.credentialProvider) }
    }

    /// Whether the selected recording's summary is being generated.
    var selectedRecordingIsSummarizing: Bool {
        guard let id = selectedRecording?.id else { return false }
        return summarizingRecordingIDs.contains(id)
    }

    /// The text model writing the selected recording's in-flight summary.
    var selectedSummarizingProvider: TextModelProvider? {
        guard let id = selectedRecording?.id, summarizingRecordingIDs.contains(id) else { return nil }
        return summarizingProviders[id]
    }

    /// `key` from Localizable.strings in the app language chosen in Settings
    /// (the system language for "System"); `key` itself when no table has it
    /// (for example under `swift run`, whose main bundle has no tables).
    func L(_ key: String) -> String {
        let code: String?
        switch settings.language {
        case .system: code = nil
        case .english: code = "en"
        case .indonesian: code = "id"
        }
        let bundle = code
            .flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
            .flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// `L(format)` with `arguments` substituted (`%@`).
    func L(_ format: String, _ arguments: CVarArg...) -> String {
        String(format: L(format), arguments: arguments)
    }

    /// Auto-summarize is switched on AND an OpenAI or DeepSeek key is available.
    var autoSummarizeIsEffective: Bool {
        settings.autoSummarize && canSummarize
    }

    /// The provider that wrote the selected recording's summary, when known (this run only).
    var selectedSummaryProvider: TextModelProvider? {
        guard hasSummaryText, let id = selectedRecording?.id else { return nil }
        return summaryProviderByRecording[id]
    }

    private var hasSummaryText: Bool {
        !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether `aiService` can summarize right now (reads the key store; for
    /// actions, not for rendering).
    private var summaryKeyAvailableNow: Bool {
        syncTextModelProvider()
        return aiService.canSummarize
    }

    /// `settings` can change (through a binding) before the debounced
    /// `saveSettings()` runs; summaries always follow the current setting.
    private func syncTextModelProvider() {
        if aiService.textModelProvider != settings.summaryProvider {
            aiService.textModelProvider = settings.summaryProvider
        }
    }

    /// Whether a key for `credential` was available at the last `refreshSetupHealth()`.
    func hasSavedCredential(_ credential: CredentialProvider) -> Bool {
        savedCredentials.contains(credential)
    }

    /// Whether an API key for `provider` is available (session, Keychain or environment).
    func credentialAvailable(for provider: AIProvider) -> Bool {
        keyStore.apiKey(for: provider) != nil
    }

    func startLocalAPI() {
        guard settings.localAPIEnabled else {
            localAPIStatusMessage = "Local API disabled"
            return
        }
        guard localServer == nil else { return }
        let approvedFolder = recordingsFolderURL.standardizedFileURL
        let securedProxy = LocalAPIProxy(aiService: aiService) { url in
            StoragePath.isContained(url, in: approvedFolder)
        }
        let server = LocalHTTPServer(proxy: securedProxy)
        do {
            try server.start()
            localServer = server
            localAPIApprovedFolder = approvedFolder
            localAPIStatusMessage = "Local API running on 127.0.0.1:\(server.port) · token \(server.bearerToken)"
            if statusMessage.hasPrefix("Local API") {
                statusMessage = "Ready"
            }
        } catch {
            localAPIStatusMessage = "Local API could not start: \(error.localizedDescription)"
            statusMessage = localAPIStatusMessage
        }
    }

    func stopLocalAPI() {
        localServer?.stop()
        localServer = nil
        localAPIApprovedFolder = nil
        localAPIStatusMessage = "Local API disabled"
    }

    /// The local API only serves files inside the folder it was started for;
    /// restart a running server when the recordings folder changes.
    private func restartLocalAPIIfFolderChanged() {
        guard localServer != nil,
              localAPIApprovedFolder != recordingsFolderURL.standardizedFileURL else { return }
        stopLocalAPI()
        startLocalAPI()
    }

    /// Runs once per process: recreating the window re-runs the view's `.task`,
    /// which must not re-mark running jobs as interrupted or re-run recovery.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        installPowerObservers()
        microphoneDevices = AudioDeviceCatalog.microphones()
        globalHotkeyService.configure(enabled: settings.globalShortcutEnabled) { [weak self] in
            Task { await self?.toggleRecording() }
        }
        startLibraryWatcher()
        // Off the main actor: the window stays responsive while a large library loads.
        await refreshLibrary()
        markInterruptedTranscriptionJobs()
        refreshSetupHealth()
        processTranscriptionQueueIfNeeded()
        await recoverInterruptedRecordings()
    }

    /// Loads the library synchronously on the main actor, for actions that
    /// need the result at once (scenario checks, tests). Everything else uses
    /// `refreshLibrary()`, which does the filesystem work off the main actor.
    /// Supersedes any background load still in flight.
    /// - Parameter folderSnapshot: the folder listing to treat as "before the
    ///   load"; `nil` takes one.
    func loadRecordings(folderSnapshot: LibraryFolderSnapshot? = nil) {
        libraryLoadGeneration += 1
        let generation = libraryLoadGeneration
        let jobsGeneration = transcriptionJobsGeneration
        applyLibraryLoad(
            LibraryLoader.performLoad(library: library(), jobsFolder: recordingsFolderURL, folderSnapshot: folderSnapshot),
            jobsGeneration: jobsGeneration
        )
        completeLibraryLoad(generation)
    }

    /// Reloads the library (recordings, row facts, jobs, folder snapshot) with
    /// the filesystem work off the main actor, then publishes it on the main
    /// actor. When this is still the newest load, the caller continues in the
    /// same main-actor turn as the publish (no frame shows the new list with a
    /// stale workflow state). A newer load (sync or async) started meanwhile
    /// wins: this one's result is dropped, and the call returns once that newer
    /// load has finished, so callers always see a library at least as new as the call.
    /// - Parameters:
    ///   - folderSnapshot: the folder listing to treat as "before the load"
    ///     (the folder watcher passes the one it just took); `nil` takes one.
    ///   - onlyWhenIdle: drop the result when a recording session started or
    ///     the workflow became busy meanwhile (background refreshes).
    ///   - beforeLoad: file work to do first, on the loader (e.g. deleting job files).
    ///
    /// When the in-memory library was patched (rename, delete, …) while the
    /// load was reading, its result predates the patch: it is discarded and
    /// the load re-run once, with a fresh folder snapshot.
    func refreshLibrary(
        folderSnapshot: LibraryFolderSnapshot? = nil,
        onlyWhenIdle: Bool = false,
        beforeLoad: (@Sendable () -> Void)? = nil
    ) async {
        var folderSnapshot = folderSnapshot
        var beforeLoad = beforeLoad
        var mayRetry = true
        while true {
            libraryLoadGeneration += 1
            let generation = libraryLoadGeneration
            if !onlyWhenIdle { newestRequiredLibraryLoadGeneration = generation }
            let jobsGeneration = transcriptionJobsGeneration
            let mutations = libraryMutationCounter
            let result = await libraryLoader.load(
                library: library(),
                jobsFolder: recordingsFolderURL,
                folderSnapshot: folderSnapshot,
                beforeLoad: beforeLoad
            )
            guard generation == libraryLoadGeneration else {
                // Superseded: wait for the newer load instead.
                if completedLibraryLoadGeneration < generation {
                    await withCheckedContinuation { libraryLoadWaiters.append((generation, $0)) }
                }
                return
            }
            if mayRetry, mutations != libraryMutationCounter {
                mayRetry = false
                folderSnapshot = nil
                beforeLoad = nil
                continue
            }
            // An idle-only result is dropped while busy, unless a load that
            // must apply was superseded by this one and waits for it.
            let required = newestRequiredLibraryLoadGeneration > completedLibraryLoadGeneration
            if required || !(onlyWhenIdle && (workflowState.isRecording || workflowState.isBusy)) {
                applyLibraryLoad(result, jobsGeneration: jobsGeneration)
            }
            completeLibraryLoad(generation)
            return
        }
    }

    /// Records that load `generation` finished and resumes the superseded
    /// callers it satisfies.
    private func completeLibraryLoad(_ generation: Int) {
        completedLibraryLoadGeneration = max(completedLibraryLoadGeneration, generation)
        let ready = libraryLoadWaiters.filter { $0.generation <= completedLibraryLoadGeneration }
        libraryLoadWaiters.removeAll { $0.generation <= completedLibraryLoadGeneration }
        for waiter in ready { waiter.continuation.resume() }
    }

    /// Publishes a finished load: recordings, row facts, search documents,
    /// selection, jobs (unless a job changed in memory since the load began,
    /// `jobsGeneration`), the selection's sidecars when they changed, health.
    private func applyLibraryLoad(_ result: LibraryLoadResult, jobsGeneration: Int) {
        let loaded: [RecordingItem]
        switch result.recordings {
        case let .success(items):
            loaded = items
        case let .failure(error):
            statusMessage = error.localizedDescription
            // Never knock a live or paused recording session out of its state.
            if !isRecording, !workflowState.isPaused, !workflowState.isBusy {
                workflowState = .failed(error.localizedDescription)
            }
            return
        }
        libraryFolderSnapshot = result.folderSnapshot
        recordingRowFacts = result.rowFacts
        recordings = loaded
        startSearchIndexing()
        if let selectedRecording,
           let refreshed = recordings.first(where: { $0.id == selectedRecording.id }) {
            self.selectedRecording = refreshed
        } else {
            selectedRecording = recordings.first
        }
        if jobsGeneration == transcriptionJobsGeneration {
            switch result.jobs {
            case let .success(jobs): setTranscriptionJobs(jobs)
            case let .failure(error): statusMessage = error.localizedDescription
            }
        } else {
            // A job was saved while the load ran: memory is newer than what it read.
            setTranscriptionJobs(transcriptionJobs)
        }
        // A background refresh (folder watcher, finished job) must not stop
        // playback or drop trims/unsaved edits of an unchanged selection.
        let sidecarsUnchanged = selectedRecording.map { sidecarStamp(for: $0) == lastLoadedSidecarStamp } ?? false
        if !sidecarsUnchanged {
            loadSelectedSidecars()
        }
        refreshSetupHealth()
    }

    /// Mirrors `recordings` into the search index (metadata only, cheap), re-runs
    /// an active query, then reads the transcripts and summaries that are new
    /// or changed on disk, at utility priority. A query never waits for that
    /// pass: documents not read yet are read by the query itself.
    private func startSearchIndexing() {
        searchIndexTask?.cancel()
        let snapshot = recordings
        let indexer = searchIndexer
        searchIndexTask = Task(priority: .utility) { [weak self] in
            await indexer.update(snapshot)
            guard !Task.isCancelled else { return }
            if let self, self.isSearchingRecordings { self.scheduleRecordingSearch() }
            await indexer.indexContent()
        }
    }

    /// Puts an updated recording (renamed, speakers renamed) into the
    /// in-memory library without a full reload: list, row facts, search
    /// document, selection; `ownWrites` are recorded as the app's own so the
    /// folder watcher does not reload for them.
    private func applyUpdatedRecording(_ updated: RecordingItem, ownWrites: [URL]) {
        libraryMutationCounter += 1
        if let index = recordings.firstIndex(where: { $0.id == updated.id }) {
            recordings[index] = updated
        }
        let facts = recordingRowFacts[updated.id]
        recordingRowFacts[updated.id] = facts.map {
            RecordingRowFacts(recording: updated, hasTranscript: $0.hasTranscript, hasSummary: $0.hasSummary)
        } ?? LibraryLoader.rowFacts(for: updated, listing: nil)
        refreshSearchDocument(for: updated)
        if selectedRecording?.id == updated.id {
            selectedRecording = updated
        }
        noteOwnLibraryWrites(ownWrites)
    }

    func clearRecordingSearch() {
        recordingSearchQuery = ""
        scheduleRecordingSearch()
    }

    /// Runs the current query after a short debounce. Results stream in:
    /// matches decided from memory first, then those whose text had to be read
    /// from disk. A newer query (generation) or a cleared field drops them.
    func scheduleRecordingSearch() {
        recordingSearchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let query = recordingSearchQuery
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filteredRecordingIDs = nil
            return
        }
        let indexer = searchIndexer
        recordingSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let (updates, continuation) = AsyncStream.makeStream(of: RecordingSearchIndexer.Progress.self)
            let producer = Task.detached(priority: .userInitiated) {
                await indexer.search(query) { continuation.yield($0) }
                continuation.finish()
            }
            await withTaskCancellationHandler {
                for await update in updates {
                    guard let self, generation == self.searchGeneration else { break }
                    // An empty partial result would flash "no results" before
                    // the disk-backed matches arrive.
                    if update.isComplete || !update.matches.isEmpty {
                        self.filteredRecordingIDs = update.matches
                    }
                }
            } onCancel: {
                producer.cancel()
            }
        }
    }

    func select(_ recording: RecordingItem) {
        guard RecordingInteractionPolicy.canSelectHistory(during: workflowState) else {
            statusMessage = workflowState.isPaused
                ? "Save or resume the paused recording first."
                : "Finish the current task first."
            return
        }
        flushTranscriptEdits()
        selectedRecording = recording
        loadSelectedSidecars()
        preparePlayback(for: recording)
        if !workflowState.isBusy, !isRecording {
            workflowState = .saved
            statusMessage = "Recording selected"
        }
    }

    func showInFinder(_ recording: RecordingItem? = nil) {
        let target = recording ?? selectedRecording
        guard let target else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target.audioURL])
        statusMessage = "Showing \(target.displayName) in Finder"
    }

    func selectAdjacentRecording(offset: Int) {
        let items = filteredRecordings
        guard !items.isEmpty else { return }
        let current = selectedRecording.flatMap { selected in items.firstIndex(where: { $0.id == selected.id }) } ?? 0
        select(items[min(max(0, current + offset), items.count - 1)])
    }

    func checkForUpdates() {
        if let url = URL(string: "https://github.com/mnuradli1/msr-mac-sound-recorder/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    func persistWindowSize(_ size: CGSize) {
        guard size.width >= 980, size.height >= 640 else { return }
        guard abs(settings.windowWidth - size.width) > 0.5 || abs(settings.windowHeight - size.height) > 0.5 else { return }
        settings.windowWidth = size.width
        settings.windowHeight = size.height
        windowSaveTask?.cancel()
        windowSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.persistSettings()
        }
    }

    private func persistSettings() {
        guard !settingsPersistenceSuspended else { return }
        settingsStore.save(settings)
    }

    func openSettingsWindow() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MSR Settings"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(viewModel: self))
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = recordingsFolderURL
        if panel.runModal() == .OK, let url = panel.url {
            let gainedScope = url.startAccessingSecurityScopedResource()
            do {
                try preflightRecordingsFolder(url)
                let bookmark = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                securityScopedFolderURL?.stopAccessingSecurityScopedResource()
                securityScopedFolderURL = url
                settings.recordingsFolderPath = url.path
                settings.recordingsFolderBookmark = bookmark
                saveSettings()
                restartLocalAPIIfFolderChanged()
                Task { await refreshLibrary() }
            } catch {
                if gainedScope { url.stopAccessingSecurityScopedResource() }
                statusMessage = "The recordings folder was not changed: \(error.localizedDescription)"
            }
        }
    }

    private func preflightRecordingsFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        let probe = url.appendingPathComponent(".msr-write-probe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data("MSR".utf8)) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        do {
            let handle = try FileHandle(forWritingTo: probe)
            try handle.synchronize()
            try handle.close()
            try FileManager.default.removeItem(at: probe)
        } catch {
            try? FileManager.default.removeItem(at: probe)
            throw error
        }
    }

    func importRecording() {
        guard RecordingInteractionPolicy.canMutateRecordingLibrary(during: workflowState) else {
            statusMessage = "Finish the current recording task first."
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio]
        panel.directoryURL = recordingsFolderURL
        panel.message = "Choose an audio or video file to import for transcription."

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        Task { await importRecordings(from: panel.urls) }
    }

    /// Imports `urls` in order, each copied into the library off the main
    /// actor, then reloads the library once (not once per file) and selects
    /// the last file imported. A failing file is reported like a single import
    /// would be; the files before and after it are still imported.
    func importRecordings(from urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard RecordingInteractionPolicy.canMutateRecordingLibrary(during: workflowState) else {
            statusMessage = "Finish the current recording task first."
            return
        }
        var lastImported: RecordingItem?
        var lastError: Error?
        var stoppedByPolicy = false
        for url in urls {
            // Re-checked per file, as before batching: a recording started meanwhile stops the import.
            guard RecordingInteractionPolicy.canMutateRecordingLibrary(during: workflowState) else {
                stoppedByPolicy = true
                break
            }
            statusMessage = "Importing \(url.lastPathComponent)"
            do {
                let duration = try await audioDuration(for: url)
                let (confidenceReport, reviewWaveform) = await confidenceReportForImportedRecording(url: url, duration: duration)
                let recordingLibrary = library()
                let requestedName = url.deletingPathExtension().lastPathComponent
                let now = Date()
                lastImported = try await libraryLoader.run {
                    let imported = try recordingLibrary.importRecording(
                        sourceURL: url,
                        requestedName: requestedName,
                        source: .microphone,
                        startedAt: now,
                        durationSeconds: duration,
                        importedAt: now,
                        confidenceReport: confidenceReport
                    )
                    // The level check decoded the file once; keep its waveform.
                    if let reviewWaveform { try? recordingLibrary.storeWaveformCache(reviewWaveform, for: imported) }
                    return imported
                }
                lastError = nil
            } catch {
                lastError = error
            }
        }
        if lastImported != nil {
            await refreshLibrary()
        }
        if stoppedByPolicy {
            // A recording task owns the window state now; only report.
            statusMessage = "Finish the current recording task first."
            return
        }
        if let imported = lastImported {
            selectedRecording = recordings.first(where: { $0.id == imported.id }) ?? imported
            loadSelectedSidecars()
            preparePlayback(for: imported)
        }
        if let lastError {
            workflowState = .failed(lastError.localizedDescription)
            statusMessage = lastError.localizedDescription
        } else if let imported = lastImported {
            workflowState = .saved
            statusMessage = "Imported \(imported.displayName)"
        }
    }

    func importRecording(from url: URL) async {
        await importRecordings(from: [url])
    }

    func toggleRecording() async {
        await performRecordingAction {
            if self.isRecording {
                await self.runNonCancellableFinalization()
            } else if self.workflowState.isPaused {
                await self.resumeRecordingSession()
            } else {
                await self.startNewRecordingSession()
            }
        }
    }

    func startRecording() async {
        await performRecordingAction {
            await self.startNewRecordingSession()
        }
    }

    /// The capture pipeline reported that it stopped on its own (stream ended,
    /// encoder error). Save whatever was captured instead of showing a live
    /// "Recording" state that is no longer true.
    private func handleCaptureFailure(_ error: Error, sessionID: UUID, segmentFileName: String) async {
        // Let an in-flight start/pause/stop (or sleep save) settle first; it may own the segment.
        await recordingActions.waitUntilIdle()
        guard currentSessionManifest?.id == sessionID,
              currentSessionManifest?.activeSegment?.fileName == segmentFileName else { return }
        if case .starting = workflowState {
            // `startNewRecordingSession`/`resumeRecordingSession` re-deliver it
            // once the session is `.recording`, so the failure is not dropped.
            pendingCaptureFailure = error
            return
        }
        guard isRecording else { return }
        recoveryMessage = "\(error.localizedDescription) The audio captured so far is being saved."
        recoveryNoticeSeverity = .error
        recoveryMessageIsCaptureFailure = true
        await stopRecording()
    }

    /// Hands a capture failure that arrived during `.starting` to
    /// `handleCaptureFailure` now that the session is `.recording`. Runs once
    /// the start action has returned, so its `stopRecording()` is not
    /// swallowed by `performRecordingAction`'s in-flight guard.
    private func deliverPendingCaptureFailure() {
        guard let error = pendingCaptureFailure,
              let sessionID = currentSessionManifest?.id,
              let segmentFileName = currentSessionManifest?.activeSegment?.fileName else { return }
        pendingCaptureFailure = nil
        Task { @MainActor [weak self] in
            await self?.handleCaptureFailure(error, sessionID: sessionID, segmentFileName: segmentFileName)
        }
    }

    func stopRecording() async {
        await performRecordingAction {
            await self.runNonCancellableFinalization()
        }
    }

    func pauseRecording(reason: RecordingPauseReason = .manual) async {
        await performRecordingAction {
            await self.pauseCurrentRecording(reason: reason)
        }
    }

    func useSecondaryRecordingAction() async {
        await performRecordingAction {
            if self.isRecording {
                await self.pauseCurrentRecording(reason: .manual)
            } else if self.workflowState.isPaused {
                await self.runNonCancellableFinalization()
            }
        }
    }

    func recoverInterruptedRecordings() async {
        guard !recordingActionInFlight,
              RecordingInteractionPolicy.canRecoverInterruptedRecordings(during: workflowState) else { return }
        let previousState = workflowState
        workflowState = .recovering
        statusMessage = "Checking interrupted recordings"
        do {
            let results = try await RecordingRecoveryService(folderURL: recordingsFolderURL).recoverInterruptedRecordings()
            // Nothing recovered and the folder is as last loaded (the usual
            // launch): the library `bootstrap` just loaded is still current.
            let folder = library().folderURL
            let current = results.isEmpty && libraryFolderSnapshot != nil
                ? await libraryLoader.run { LibraryFolderSnapshot.capture(folderURL: folder) }
                : nil
            let folderUnchanged = current != nil && current == libraryFolderSnapshot
            if !folderUnchanged {
                await refreshLibrary()
            }
            let recovered = results.compactMap(\.recording)
            let failedCount = results.filter { if case .failed = $0.status { return true }; return false }.count
            let hasWarnings = results.contains { !$0.warnings.isEmpty || !$0.failedFiles.isEmpty }
            if let firstRecovered = recovered.first {
                selectedRecording = recordings.first(where: { $0.id == firstRecovered.id }) ?? firstRecovered
                loadSelectedSidecars()
                recoveryMessage = "\(recovered.count) interrupted recording\(recovered.count == 1 ? "" : "s") recovered."
                if failedCount > 0 { recoveryMessage += " \(failedCount) could not be recovered; original files were preserved." }
                else if hasWarnings { recoveryMessage += " Some source audio was missing or unreadable; recovery is partial." }
                recoveryNoticeSeverity = failedCount > 0 || hasWarnings ? .warning : .success
                statusMessage = recoveryMessage
                workflowState = .saved
            } else if results.contains(where: {
                if case .failed = $0.status { return true }
                return false
            }) {
                recoveryMessage = "Some interrupted recording files could not be recovered."
                recoveryNoticeSeverity = .warning
                statusMessage = recoveryMessage
                workflowState = selectedRecording == nil ? .ready : .saved
            } else {
                recoveryMessage = ""
                recoveryNoticeSeverity = .info
                workflowState = previousState == .recovering ? (selectedRecording == nil ? .ready : .saved) : previousState
                if statusMessage == "Checking interrupted recordings" {
                    statusMessage = selectedRecording == nil ? "Ready" : "Recording selected"
                }
            }
        } catch {
            workflowState = .failed(error.localizedDescription)
            recoveryMessage = "Recovery failed: \(error.localizedDescription)"
            recoveryNoticeSeverity = .error
            statusMessage = recoveryMessage
        }
    }

    func suspendForSystemSleep() async {
        await recordingActions.prepareForSleep {
            guard self.recordingSessionClock != nil else { return }
            // A failed resume can contain a new partial active segment alongside
            // older paused segments. Preserve the whole manifest for recovery,
            // rather than publishing only older segments and deleting its index.
            if case .failed = self.workflowState { return }
            await self.runNonCancellableFinalization()
        }
    }

    func resumeAfterSystemWake() async {
        recordingActions.didWake()
        await recordingActions.waitForSleepCompletion()
        await recordingActions.waitUntilIdle()
        guard !recordingActions.sleepPending else { return }
        await recoverInterruptedRecordings()
    }

    private func startNewRecordingSession() async {
        guard !isRecording, !workflowState.isPaused, !workflowState.isBusy else { return }
        let source = selectedSource
        workflowState = .starting(source: source)
        statusMessage = "Starting \(source.displayName)"
        recoveryMessage = ""
        recoveryNoticeSeverity = .info
        recoveryMessageIsCaptureFailure = false
        pendingCaptureFailure = nil
        autoTranscribeNotice = nil
        resetSignalLevels()
        microphonePeakDuringRecording = 0
        systemPeakDuringRecording = 0
        stopPlayback()

        do {
            try ensureMinimumRecordingSpace()
            let startedAt = Date()
            let temporaryURL = try makeTemporaryAudioURL(source: source)
            let requestedName = defaultMeetingName(for: startedAt)
            var manifest = RecordingSessionManifest(
                state: .starting,
                finalRecordingID: UUID(),
                source: source,
                requestedName: requestedName,
                startedAt: startedAt,
                updatedAt: startedAt,
                activeSegment: RecordingSessionSegment(
                    fileName: temporaryURL.lastPathComponent,
                    startedAt: startedAt
                )
            )
            manifest.microphoneFileName = source == .system ? nil : DurableCaptureFiles.rawURL(for: temporaryURL, channel: .microphone).lastPathComponent
            manifest.systemFileName = source == .microphone ? nil : DurableCaptureFiles.rawURL(for: temporaryURL, channel: .system).lastPathComponent
            try manifestStore().save(manifest)
            currentSessionManifest = manifest
            temporaryAudioURL = temporaryURL
            installCaptureFailureHandler(sessionID: manifest.id, segmentFileName: temporaryURL.lastPathComponent)
            try await recorder.start(source: source, outputURL: temporaryURL)
            var capturingManifest = manifest
            capturingManifest.state = .capturing
            capturingManifest.microphoneFileName = recorder.captureArtifacts?.microphoneFileName
            capturingManifest.systemFileName = recorder.captureArtifacts?.systemFileName
            capturingManifest.updatedAt = Date()
            try manifestStore().save(capturingManifest)
            recordingSessionClock = RecordingSessionClock(startedAt: startedAt)
            completedSegmentURLs = []
            currentSessionSource = source
            currentSessionName = requestedName
            currentSessionManifest = capturingManifest
            workflowState = .recording(source: source)
            live.setElapsed(0)
            startRecordingTimer()
            beginSleepPrevention()
            statusMessage = "Recording \(source.displayName)"
            deliverPendingCaptureFailure()
        } catch {
            pendingCaptureFailure = nil
            if recorder.isRecording {
                try? await recorder.stop()
            }
            if var interrupted = currentSessionManifest {
                interrupted.state = .failed
                interrupted.recoveryNote = error.localizedDescription
                interrupted.updatedAt = Date()
                try? manifestStore().save(interrupted)
            }
            workflowState = .failed(error.localizedDescription)
            temporaryAudioURL = nil
            recordingSessionClock = nil
            completedSegmentURLs = []
            currentSessionManifest = nil
            currentSessionSource = nil
            currentSessionName = nil
            resetSignalLevels()
            endSleepPrevention()
            statusMessage = error.localizedDescription
        }
    }

    private func resumeRecordingSession() async {
        guard workflowState.isPaused,
              let source = workflowState.lockedSource,
              var clock = recordingSessionClock else { return }

        workflowState = .starting(source: source)
        statusMessage = "Resuming \(source.displayName)"
        pendingCaptureFailure = nil
        resetSignalLevels()

        do {
            try ensureMinimumRecordingSpace()
            let temporaryURL = try makeTemporaryAudioURL(source: source)
            var manifest = try currentManifestFallback(source: source, clock: clock)
            let resumedAt = Date()
            manifest.startActiveSegment(
                fileName: temporaryURL.lastPathComponent,
                startedAt: resumedAt,
                updatedAt: resumedAt
            )
            manifest.microphoneFileName = source == .system ? nil : DurableCaptureFiles.rawURL(for: temporaryURL, channel: .microphone).lastPathComponent
            manifest.systemFileName = source == .microphone ? nil : DurableCaptureFiles.rawURL(for: temporaryURL, channel: .system).lastPathComponent
            try manifestStore().save(manifest)
            currentSessionManifest = manifest
            temporaryAudioURL = temporaryURL
            installCaptureFailureHandler(sessionID: manifest.id, segmentFileName: temporaryURL.lastPathComponent)
            try await recorder.start(source: source, outputURL: temporaryURL)
            manifest.state = .capturing
            manifest.microphoneFileName = recorder.captureArtifacts?.microphoneFileName
            manifest.systemFileName = recorder.captureArtifacts?.systemFileName
            manifest.updatedAt = Date()
            try manifestStore().save(manifest)
            clock.resume(at: resumedAt)
            recordingSessionClock = clock
            currentSessionManifest = manifest
            workflowState = .recording(source: source)
            startRecordingTimer()
            beginSleepPrevention()
            statusMessage = "Recording \(source.displayName)"
            deliverPendingCaptureFailure()
        } catch {
            pendingCaptureFailure = nil
            if recorder.isRecording {
                try? await recorder.stop()
            }
            if var interrupted = currentSessionManifest {
                interrupted.state = .failed
                interrupted.recoveryNote = error.localizedDescription
                interrupted.updatedAt = Date()
                try? manifestStore().save(interrupted)
            }
            workflowState = .failed(error.localizedDescription)
            temporaryAudioURL = nil
            resetSignalLevels()
            recoveryMessage = "The interrupted segment was preserved for recovery."
            recoveryNoticeSeverity = .warning
            statusMessage = error.localizedDescription
        }
    }

    private func pauseCurrentRecording(reason: RecordingPauseReason) async {
        guard isRecording,
              let source = workflowState.lockedSource,
              let temporaryAudioURL,
              var clock = recordingSessionClock else { return }

        workflowState = .suspending(source: source)
        statusMessage = reason.displayName
        stopRecordingTimer()

        do {
            try await recorder.stop()
            endSleepPrevention()
            let pausedAt = Date()
            clock.pause(at: pausedAt, reason: reason)
            var manifest = try currentManifestFallback(source: source, clock: clock)
            manifest.finishActiveSegment(
                endedAt: pausedAt,
                accumulatedActiveDuration: clock.activeDuration(at: pausedAt),
                reason: reason,
                updatedAt: pausedAt
            )
            try manifestStore().save(manifest)
            completedSegmentURLs.append(temporaryAudioURL)
            self.temporaryAudioURL = nil
            recordingSessionClock = clock
            currentSessionManifest = manifest
            live.setElapsed(clock.activeDuration(at: pausedAt))
            resetSignalLevels()
            workflowState = .paused(source: source, reason: reason)
            statusMessage = reason == .systemSleep
                ? "Recording paused before sleep. Resume after wake."
                : "Recording paused"
        } catch {
            endSleepPrevention()
            workflowState = .failed(error.localizedDescription)
            recoveryMessage = "Could not pause cleanly. Recovery will retry on next launch."
            recoveryNoticeSeverity = .error
            statusMessage = error.localizedDescription
            resetSignalLevels()
        }
    }

    private func finalizeRecordingSession() async {
        guard let source = workflowState.lockedSource ?? currentSessionSource,
              let clock = recordingSessionClock else { return }

        let wasRecording = isRecording
        let activeTemporaryAudioURL = temporaryAudioURL
        workflowState = .finalizing(source: source)
        statusMessage = "Finalizing recording"
        stopRecordingTimer()

        do {
            var finalizedClock = clock
            var finalizingManifest = try currentManifestFallback(source: source, clock: finalizedClock)
            finalizingManifest.state = .finalizing
            finalizingManifest.finalRecordingID = finalizingManifest.finalRecordingID ?? UUID()
            finalizingManifest.finalizationProgress = 0.1
            finalizingManifest.updatedAt = Date()
            try manifestStore().save(finalizingManifest)
            currentSessionManifest = finalizingManifest
            if wasRecording, let temporaryAudioURL = activeTemporaryAudioURL {
                do {
                    try await recorder.stop()
                } catch where recoveryMessageIsCaptureFailure
                    && FileManager.default.fileExists(atPath: temporaryAudioURL.path) {
                    // The capture already stopped on its own; closing it again can
                    // fail, but the audio written so far is still saved (and checked
                    // and auto-transcribed) like any other recording.
                }
                let stoppedAt = Date()
                finalizedClock.pause(at: stoppedAt, reason: .manual)
                var manifest = try currentManifestFallback(source: source, clock: finalizedClock)
                manifest.finishActiveSegment(
                    endedAt: stoppedAt,
                    accumulatedActiveDuration: finalizedClock.activeDuration(at: stoppedAt),
                    reason: .manual,
                    updatedAt: stoppedAt
                )
                manifest.state = .finalizing
                manifest.finalRecordingID = finalizingManifest.finalRecordingID
                manifest.finalizationProgress = 0.3
                try manifestStore().save(manifest)
                currentSessionManifest = manifest
                completedSegmentURLs.append(temporaryAudioURL)
                self.temporaryAudioURL = nil
            }
            endSleepPrevention()
            let segmentURLs = try finalizedSegmentURLs()
            guard !segmentURLs.isEmpty else {
                throw RecordingSessionError.noCapturedSegments
            }
            try validateCapturedSegmentsExist(segmentURLs)
            let endedAt = Date()
            let finalTemporaryURL: URL
            if segmentURLs.count == 1, let onlySegment = segmentURLs.first {
                finalTemporaryURL = onlySegment
            } else {
                finalTemporaryURL = try makeFinalTemporaryAudioURL()
                try await AudioTrackMixer.concatenateToSingleM4A(inputs: segmentURLs, outputURL: finalTemporaryURL)
            }
            // The same decode yields the review waveform, cached next to the
            // recording below so its first selection needs no analysis.
            let (confidenceReport, reviewWaveform) = try await RecordingConfidenceAnalyzer.analyzeWithWaveform(
                audioURL: finalTemporaryURL,
                source: source,
                expectedChannels: [
                    .microphone: microphonePeakDuringRecording,
                    .system: systemPeakDuringRecording
                ],
                minimumDuration: 3,
                silenceThreshold: Float(settings.silenceThreshold),
                waveformBuckets: WaveformAnalyzer.defaultBucketCount
            )
            if var manifest = currentSessionManifest {
                manifest.state = .finalizing
                manifest.finalizationProgress = 0.75
                manifest.updatedAt = Date()
                try manifestStore().save(manifest)
                currentSessionManifest = manifest
            }
            // Publishing (library listing, audio move, durable metadata write)
            // and removing the capture files run off the main actor while the
            // UI shows "Saving"; the workflow stays `.finalizing` throughout.
            let recordingLibrary = library()
            let requestedName = currentSessionName ?? defaultMeetingName(for: finalizedClock.startedAt)
            let startedAt = finalizedClock.startedAt
            let activeDuration = finalizedClock.activeDuration(at: endedAt)
            let finalRecordingID = currentSessionManifest?.finalRecordingID
            let recording = try await libraryLoader.run {
                let recording = try recordingLibrary.finishRecording(
                    temporaryAudioURL: finalTemporaryURL,
                    requestedName: requestedName,
                    source: source,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    durationSecondsOverride: activeDuration,
                    recoveredAt: nil,
                    recoveryNote: nil,
                    segmentCount: max(1, segmentURLs.count),
                    confidenceReport: confidenceReport,
                    recordingID: finalRecordingID
                )
                for segment in segmentURLs { DurableCaptureFiles.removeRawFiles(for: segment, source: source) }
                if segmentURLs.count > 1 {
                    for url in segmentURLs {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                // Best effort: without it the first selection analyzes the audio.
                try? recordingLibrary.storeWaveformCache(reviewWaveform, for: recording)
                return recording
            }
            if let currentSessionManifest {
                var completed = currentSessionManifest
                completed.state = .completed
                completed.finalizationProgress = 1
                completed.updatedAt = Date()
                try? manifestStore().save(completed)
                try? manifestStore().delete(completed)
            }
            clearRecordingSession()
            resetSignalLevels()
            // Published before auto-transcribe queues the job (below).
            await refreshLibrary()
            selectedRecording = recordings.first(where: { $0.id == recording.id }) ?? recording
            loadSelectedSidecars()
            preparePlayback(for: recording)
            workflowState = .saved
            statusMessage = segmentURLs.count > 1 ? "Recording saved from \(segmentURLs.count) segments" : "Recording saved"
            if recoveryMessageIsCaptureFailure {
                // The "…is being saved" banner is no longer true; cleared when the next recording starts.
                recoveryMessage = "Saved after the capture stopped unexpectedly."
                recoveryNoticeSeverity = .warning
                recoveryMessageIsCaptureFailure = false
            }
            autoTranscribeIfEnabled(recording: selectedRecording ?? recording, confidenceReport: confidenceReport)
        } catch {
            // A failed checkpoint (for example disk full) must not leave capture
            // running while we acknowledge sleep or report finalization failure.
            if recorder.isRecording { try? await recorder.stop() }
            endSleepPrevention()
            if var manifest = currentSessionManifest {
                manifest.state = .failed
                manifest.recoveryNote = error.localizedDescription
                manifest.updatedAt = Date()
                try? manifestStore().save(manifest)
                currentSessionManifest = manifest
            }
            workflowState = .failed(error.localizedDescription)
            recoveryMessage = "Could not finalize cleanly. Recovery will retry on next launch."
            recoveryNoticeSeverity = .error
            recoveryMessageIsCaptureFailure = false
            resetSignalLevels()
            statusMessage = error.localizedDescription
        }
    }

    /// Queues a transcription for a recording that was just captured (never for
    /// recovered or imported recordings) when auto-transcribe is on.
    private func autoTranscribeIfEnabled(recording: RecordingItem, confidenceReport: RecordingConfidenceReport?) {
        guard settings.autoTranscribe else { return }
        let provider = settings.provider
        guard credentialAvailable(for: provider) else {
            let notice = "Recording saved · auto-transcribe skipped: add a \(provider.displayName) API key in Settings"
            autoTranscribeNotice = notice
            statusMessage = notice
            return
        }
        guard RecordingInteractionPolicy.shouldAutoTranscribe(report: confidenceReport) else {
            statusMessage = "Recording saved · auto-transcribe skipped (audio too short or empty)"
            return
        }
        if enqueueTranscription(
            recording: recording,
            replacingExistingTranscript: false,
            origin: .automatic,
            autoTitleRequested: settings.autoTitle
        ) {
            statusMessage = "Recording saved · transcription queued"
        }
    }

    private func runNonCancellableFinalization() async {
        // An unstructured task does not inherit cancellation from a closing view,
        // command, or menu action. Await it so callers cannot start another state
        // transition before the durable finalization checkpoint completes.
        await Task { @MainActor [self] in
            await finalizeRecordingSession()
        }.value
    }

    func startRename(_ recording: RecordingItem? = nil) {
        guard RecordingInteractionPolicy.canMutateRecordingLibrary(during: workflowState) else {
            statusMessage = "Finish the current recording task first."
            return
        }
        let target = recording ?? selectedRecording
        guard let target else { return }
        selectedRecording = target
        renameDraft = target.displayName
        showingRename = true
    }

    func applyRename() {
        guard canMutateRecordingLibrary else {
            statusMessage = "Finish the current recording task first."
            showingRename = false
            return
        }
        guard let selectedRecording else { return }
        do {
            let renamed = try library().rename(selectedRecording, to: renameDraft)
            showingRename = false
            // Reflected at once, without a full reload: a rename rewrites only
            // the metadata file (a legacy recording also moves to immutable
            // storage; reload for that, off the main actor).
            applyUpdatedRecording(renamed, ownWrites: [renamed.metadataURL])
            if !selectedRecording.usesImmutableStorage {
                Task { await refreshLibrary() }
            }
            self.selectedRecording = renamed
            loadSelectedSidecars()
            preparePlayback(for: renamed)
            switch workflowState {
            case .ready, .saved, .failed:
                workflowState = .saved
            default:
                break
            }
            statusMessage = "Renamed to \(renamed.displayName)"
        } catch {
            workflowState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    func delete(_ recording: RecordingItem? = nil) {
        guard RecordingInteractionPolicy.canMutateRecordingLibrary(during: workflowState) else {
            statusMessage = "Finish the current recording task first."
            return
        }
        let target = recording ?? selectedRecording
        guard let target else { return }
        // A transcription or summary still writing to the recording would
        // otherwise leave orphan files behind (or fail late).
        if hasPendingTranscriptionReadingDiskIfNeeded(for: target.id) {
            statusMessage = L("Wait for the transcription to finish (or cancel it) before deleting this recording.")
            return
        }
        if summarizingRecordingIDs.contains(target.id) {
            statusMessage = L("Wait for the summary to finish before deleting this recording.")
            return
        }
        do {
            if target.id == selectedRecording?.id {
                stopPlayback()
            }
            try library().delete(target)
            let targetID = target.id
            if transcriptionJobs.contains(where: { $0.recordingID == targetID }) {
                setTranscriptionJobs(transcriptionJobs.filter { $0.recordingID != targetID })
            }
            if target.id == selectedRecording?.id {
                selectedRecording = nil
                transcriptText = ""
                transcriptSegments = []
                summaryText = ""
                selectedTranscriptionJob = nil
            }
            // Gone from the list at once; the job files and the full reload
            // follow off the main actor.
            libraryMutationCounter += 1
            recordings.removeAll { $0.id == targetID }
            recordingRowFacts[targetID] = nil
            let indexer = searchIndexer
            Task { await indexer.remove(targetID) }
            if isSearchingRecordings { scheduleRecordingSearch() }
            if selectedRecording == nil, let first = recordings.first {
                selectedRecording = first
                loadSelectedSidecars()
            }
            let jobsFolder = recordingsFolderURL
            Task {
                await refreshLibrary(beforeLoad: {
                    try? TranscriptionJobStore(folderURL: jobsFolder).delete(recordingID: targetID)
                })
            }
            workflowState = selectedRecording == nil ? .ready : .saved
            statusMessage = "Recording deleted"
        } catch {
            workflowState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    func runPrimaryAction() async {
        switch primaryAction {
        case .transcribe:
            await transcribeSelected(replacingExistingTranscript: false)
        case .summarize:
            await summarizeSelected()
        case .copySummary:
            // The case keeps its Core name; with a summary the next step is sharing the notes.
            copyMeetingNotes()
        }
    }

    func transcribeSelected(replacingExistingTranscript: Bool = false) async {
        guard let selectedRecording, RecordingInteractionPolicy.canSelectHistory(during: workflowState) else { return }
        enqueueTranscription(recording: selectedRecording, replacingExistingTranscript: replacingExistingTranscript)
    }

    func transcribeSelectedRange() {
        guard let selectedRecording else { return }
        let fullRange = trimStartSeconds <= 0.01 && trimEndSeconds >= selectedRecording.durationSeconds - 0.1
        enqueueTranscription(
            recording: selectedRecording,
            replacingExistingTranscript: hasTranscript,
            trimRange: fullRange ? nil : AudioTrimRange(startSeconds: trimStartSeconds, endSeconds: trimEndSeconds)
        )
    }

    func retranscribeSelected() async {
        await transcribeSelected(replacingExistingTranscript: true)
    }

    func retryTranscription(recordingID: UUID) {
        guard let recording = recordings.first(where: { $0.id == recordingID }) else { return }
        let hasExistingTranscript = !readTextIfExists(at: recording.transcriptURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        enqueueTranscription(recording: recording, replacingExistingTranscript: hasExistingTranscript)
    }

    func cancelTranscription(recordingID: UUID) {
        guard var job = jobReadingDiskIfNeeded(for: recordingID),
              job.status == .queued || job.status == .running else { return }
        if job.status == .running {
            transcriptionQueueTask?.cancel()
        }
        job.markCancelled()
        do {
            try transcriptionJobStore().save(job)
            noteOwnJobWrite(job)
            upsertTranscriptionJob(job)
            statusMessage = "Transcription cancelled"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func transcriptionStatusText(for recording: RecordingItem) -> String? {
        guard let job = job(for: recording.id) else { return nil }
        switch job.status {
        case .queued:
            return "Queued"
        case .running:
            return "Transcribing"
        case .failed:
            return "Needs retry"
        case .completed:
            return nil
        case .cancelled:
            return nil
        }
    }

    func jumpToTranscriptSegment(_ segment: TranscriptSegment) {
        guard let startTime = segment.startTime else { return }
        if let selectedRecording, audioPlayer?.url != selectedRecording.audioURL {
            preparePlayback(for: selectedRecording)
        }
        guard let audioPlayer else { return }
        audioPlayer.currentTime = min(max(0, startTime), audioPlayer.duration)
        playback.playbackPosition = audioPlayer.currentTime
        if !audioPlayer.isPlaying {
            audioPlayer.play()
            playback.isPlaying = true
            startPlaybackTimer()
        }
        statusMessage = "Jumped to \(formatDuration(startTime))"
    }

    func saveTranscript(format: TranscriptExportFormat) {
        guard let selectedRecording else { return }
        let transcript = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            statusMessage = "Transcript is empty."
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = "\(selectedRecording.displayName).transcript.\(format.fileExtension)"
        panel.directoryURL = recordingsFolderURL

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let content = TranscriptExporter.content(
                transcript: transcriptText,
                recordingName: selectedRecording.displayName,
                format: format
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Transcript saved as .\(format.fileExtension)"
        } catch {
            workflowState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    func summarizeSelected() async {
        guard let selectedRecording, RecordingInteractionPolicy.canSelectHistory(during: workflowState) else { return }
        let targetID = selectedRecording.id
        let transcript = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            statusMessage = "Transcript is empty."
            return
        }
        guard !summarizingRecordingIDs.contains(targetID) else {
            statusMessage = L("Summarizing")
            return
        }
        // Action time: the Keychain/environment, not the cached flags, decide.
        syncTextModelProvider()
        guard let provider = aiService.resolvedTextModelProvider else {
            statusMessage = L("Add an OpenAI or DeepSeek API key in Settings to summarize.")
            return
        }
        workflowState = .summarizing
        statusMessage = L("Summarizing with %@", provider.displayName)
        summarizingRecordingIDs.insert(targetID)
        summarizingProviders[targetID] = provider
        defer {
            summarizingRecordingIDs.remove(targetID)
            summarizingProviders[targetID] = nil
        }
        do {
            let decoded = try await aiService.summarize(transcript: transcript)
            let written = try library().writeSummary(decoded.markdown, for: selectedRecording)
            summaryProviderByRecording[targetID] = provider
            noteSidecarsChanged(for: written, written: [written.summaryURL])
            if RecordingInteractionPolicy.shouldApplyAsyncResult(targetID: targetID, selectedID: self.selectedRecording?.id) {
                summaryText = decoded.markdown
                // Our own write: the next library refresh must not reload over it.
                if lastLoadedSidecarStamp?.recordingID == targetID, let current = self.selectedRecording {
                    lastLoadedSidecarStamp = sidecarStamp(for: current)
                }
                updateExportPreview()
            }
            workflowState = .saved
            statusMessage = L("Summary ready via %@", provider.displayName)
        } catch {
            let message = SummaryErrorMessage.message(for: error)
            workflowState = .failed(message)
            statusMessage = message
        }
    }

    func copyTranscript() {
        copy(transcriptText)
    }

    func copySummary() {
        copy(summaryText)
    }

    var canCopyMeetingNotes: Bool {
        selectedRecording != nil && (hasTranscript || hasSummaryText)
    }

    /// Shareable Markdown meeting notes (title, details, summary, action
    /// items, transcript) for the selected recording, from what is on screen.
    func meetingNotesMarkdown() -> String? {
        guard let recording = selectedRecording else { return nil }
        return TranscriptExporter.meetingNotesMarkdown(MeetingNotesExportInput(
            recording: recording,
            transcript: transcriptText,
            segments: transcriptSegments,
            summary: summaryText
        ))
    }

    func copyMeetingNotes() {
        guard canCopyMeetingNotes, let markdown = meetingNotesMarkdown() else {
            statusMessage = "Transcribe or summarize this recording first."
            return
        }
        copy(markdown)
        statusMessage = "Meeting notes copied"
    }

    func exportMeetingNotes() {
        guard let recording = selectedRecording, canCopyMeetingNotes else {
            statusMessage = "Transcribe or summarize this recording first."
            return
        }
        flushTranscriptEdits()
        flushSummaryEdits()
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(recording.displayName).meeting-notes.md"
        panel.directoryURL = recordingsFolderURL
        guard panel.runModal() == .OK, let url = panel.url, let markdown = meetingNotesMarkdown() else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            lastExportURL = url
            statusMessage = "Exported \(url.lastPathComponent)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Speaker names

    /// Speaker chips can be renamed: a transcript exists and no transcription
    /// for this recording is waiting or running (it would overwrite the names).
    var canRenameSpeakers: Bool {
        guard let selectedRecording, canMutateRecordingLibrary else { return false }
        return hasTranscript && !hasPendingTranscription(for: selectedRecording.id)
    }

    var selectedRecordingHasSpeakerNames: Bool {
        !(selectedRecording?.speakerNames.isEmpty ?? true)
    }

    /// The provider's label for a speaker now shown as `displayName`, when it was renamed.
    func originalSpeakerLabel(for displayName: String) -> String? {
        selectedRecording?.speakerNames.first { $0.value == displayName }?.key
    }

    /// Names the diarized speaker `label` (its original label or current name)
    /// `name` in the transcript, segments and metadata. An empty name reverts
    /// it to the original label.
    func renameSpeaker(label: String, to name: String) {
        guard let recording = selectedRecording else { return }
        guard canRenameSpeakers else {
            statusMessage = hasPendingTranscription(for: recording.id)
                ? "Wait for the transcription to finish before renaming speakers."
                : "Finish the current recording task first."
            return
        }
        // Unsaved transcript and summary edits would otherwise be overwritten by the reload.
        flushTranscriptEdits()
        flushSummaryEdits()
        do {
            let updated = try library().renameSpeaker(selectedRecording ?? recording, label: label, to: name)
            reloadAfterSpeakerChange(updated)
            let cleaned = SpeakerNames.sanitized(name)
            if !cleaned.isEmpty, updated.speakerNames.values.contains(cleaned) {
                statusMessage = L("Speaker renamed to %@", cleaned)
            } else {
                statusMessage = L("Speaker name reset")
            }
            noteSummaryUsesOldSpeakerLabels()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Reverts every renamed speaker of the selected recording to its original
    /// label (transcript, segments and metadata).
    func resetSpeakerNames() {
        guard let recording = selectedRecording else { return }
        guard canRenameSpeakers else {
            statusMessage = "Finish the current recording task first."
            return
        }
        flushTranscriptEdits()
        flushSummaryEdits()
        do {
            // Renaming back to the original label rewrites the transcript too
            // (`resetSpeakerNames` alone would only drop the mapping); one
            // library read for all speakers.
            let current = try library().resetAllSpeakerNames(for: recording)
            reloadAfterSpeakerChange(current)
            statusMessage = L("Speaker names reset")
            noteSummaryUsesOldSpeakerLabels()
        } catch {
            Task { await refreshLibrary() }
            statusMessage = error.localizedDescription
        }
    }

    /// A summary is never rewritten by a speaker rename; say so once.
    private func noteSummaryUsesOldSpeakerLabels() {
        guard hasSummaryText else { return }
        lastAutoSummaryNotice = L("The summary still uses the old speaker label. Summarize again to update it.")
        lastAutoSummaryFailed = false
    }

    /// A speaker rename rewrote the transcript, segments and metadata of
    /// `updated`: patch it into memory (no full reload) and reload the panes.
    private func reloadAfterSpeakerChange(_ updated: RecordingItem) {
        applyUpdatedRecording(
            updated,
            ownWrites: [updated.metadataURL, updated.transcriptURL, updated.transcriptSegmentsURL]
        )
        selectedRecording = updated
        loadSelectedSidecars()
    }

    func copyAllNotes() {
        let sections = [
            transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "Transcript\n\n\(transcriptText)",
            summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "Summary\n\n\(summaryText)"
        ].compactMap { $0 }
        copy(sections.joined(separator: "\n\n---\n\n"))
    }

    func togglePlayback() {
        guard RecordingInteractionPolicy.canPlayBack(during: workflowState) else {
            statusMessage = "Playback is disabled during the current recording task."
            return
        }
        guard let selectedRecording else { return }
        if audioPlayer?.url != selectedRecording.audioURL {
            preparePlayback(for: selectedRecording)
        }
        guard let audioPlayer else { return }
        if audioPlayer.isPlaying {
            audioPlayer.pause()
            playback.isPlaying = false
            statusMessage = "Playback paused"
        } else {
            audioPlayer.play()
            playback.isPlaying = true
            statusMessage = "Playing \(selectedRecording.displayName)"
            startPlaybackTimer()
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        playback.isPlaying = false
        playback.playbackPosition = 0
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    func skipPlayback(by seconds: TimeInterval) {
        guard let audioPlayer else { return }
        audioPlayer.currentTime = min(max(0, audioPlayer.currentTime + seconds), audioPlayer.duration)
        playback.playbackPosition = audioPlayer.currentTime
    }

    func seekPlayback(to seconds: TimeInterval) {
        guard let audioPlayer else { return }
        audioPlayer.currentTime = min(max(0, seconds), audioPlayer.duration)
        playback.playbackPosition = audioPlayer.currentTime
    }

    func setPlaybackSpeed(_ speed: Double) {
        settings.playbackSpeed = [0.75, 1, 1.25, 1.5, 2].min(by: { abs($0 - speed) < abs($1 - speed) }) ?? 1
        audioPlayer?.enableRate = true
        audioPlayer?.rate = Float(settings.playbackSpeed)
        saveSettings()
    }

    func resetTrim() {
        playback.trimStartSeconds = 0
        playback.trimEndSeconds = selectedRecording?.durationSeconds ?? playbackDuration
        updateExportPreview()
    }

    func saveTrimmedCopy() async {
        guard let recording = selectedRecording else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = "\(recording.displayName).trimmed.m4a"
        panel.directoryURL = recordingsFolderURL
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try await TranscriptionAudioPreparer.saveTrimmedCopy(
                sourceURL: recording.audioURL,
                destinationURL: destination,
                range: AudioTrimRange(startSeconds: trimStartSeconds, endSeconds: trimEndSeconds)
            )
            lastExportURL = destination
            statusMessage = "Trimmed copy saved"
        } catch { statusMessage = error.localizedDescription }
    }

    func scheduleTranscriptAutosave() {
        transcriptAutosaveTask?.cancel()
        if let recording = selectedRecording,
           ((try? String(contentsOf: recording.transcriptURL, encoding: .utf8)) ?? "") == transcriptText {
            transcriptSaveMessage = ""
            return
        }
        transcriptSaveMessage = "Unsaved changes"
        transcriptAutosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.flushTranscriptEdits() }
        }
        updateExportPreview()
    }

    func flushTranscriptEdits() {
        transcriptAutosaveTask?.cancel()
        transcriptAutosaveTask = nil
        guard let recording = selectedRecording else { return }
        if transcriptText.isEmpty, !FileManager.default.fileExists(atPath: recording.transcriptURL.path) { return }
        if (try? String(contentsOf: recording.transcriptURL, encoding: .utf8)) == transcriptText {
            transcriptSaveMessage = ""
            return
        }
        do {
            let updated = try library().writeTranscript(transcriptText, for: recording)
            selectedRecording = updated
            noteSidecarsChanged(for: updated, written: [updated.transcriptURL])
            // Our own write: the next library refresh must not reload over it.
            if lastLoadedSidecarStamp?.recordingID == updated.id {
                lastLoadedSidecarStamp = sidecarStamp(for: updated)
            }
            transcriptSaveMessage = "Saved"
        } catch {
            transcriptSaveMessage = "Save failed"
            statusMessage = error.localizedDescription
        }
    }

    func scheduleSummaryAutosave() {
        summaryAutosaveTask?.cancel()
        if let recording = selectedRecording,
           ((try? String(contentsOf: recording.summaryURL, encoding: .utf8)) ?? "") == summaryText {
            return
        }
        summaryAutosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.flushSummaryEdits() }
        }
        updateExportPreview()
    }

    func flushSummaryEdits() {
        summaryAutosaveTask?.cancel()
        summaryAutosaveTask = nil
        guard let recording = selectedRecording else { return }
        if summaryText.isEmpty, !FileManager.default.fileExists(atPath: recording.summaryURL.path) { return }
        if (try? String(contentsOf: recording.summaryURL, encoding: .utf8)) == summaryText { return }
        do {
            let updated = try library().writeSummary(summaryText, for: recording)
            noteSidecarsChanged(for: updated, written: [updated.summaryURL])
            if lastLoadedSidecarStamp?.recordingID == recording.id {
                lastLoadedSidecarStamp = sidecarStamp(for: recording)
            }
        } catch { statusMessage = error.localizedDescription }
    }

    func updateExportPreview() {
        guard let recording = selectedRecording else { exportPreview = ""; return }
        exportPreview = (try? TranscriptExporter.preview(
            MeetingNotesExportInput(recording: recording, transcript: transcriptText, segments: transcriptSegments, summary: summaryText),
            format: selectedExportFormat
        )) ?? "This format is unavailable for the current transcript."
    }

    func exportSelected() {
        guard let recording = selectedRecording else { return }
        flushTranscriptEdits()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(recording.displayName).export.\(selectedExportFormat.fileExtension)"
        panel.directoryURL = recordingsFolderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TranscriptExporter.export(
                MeetingNotesExportInput(recording: recording, transcript: transcriptText, segments: transcriptSegments, summary: summaryText),
                format: selectedExportFormat,
                to: url
            )
            lastExportURL = url
            statusMessage = "Exported \(url.lastPathComponent)"
        } catch { statusMessage = error.localizedDescription }
    }

    func revealLastExport() {
        guard let lastExportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExportURL])
    }

    /// Debounced `saveSettings()` (600 ms) for controls that change continuously
    /// (sliders, text fields, toggles bound directly to `settings`).
    func scheduleSettingsSave() {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveSettings()
        }
    }

    /// Persists `settings` and applies side effects. Expensive side effects
    /// (hotkey registration, folder watcher, setup health, local API restart)
    /// only run when the settings they depend on changed since the last apply.
    func saveSettings() {
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        persistSettings()
        let previous = lastAppliedSettings
        lastAppliedSettings = settings

        if previous.preferredSource != settings.preferredSource {
            selectedSource = settings.preferredSource
        }
        if previous.microphoneDeviceID != settings.microphoneDeviceID {
            recorder.setMicrophoneDeviceUID(settings.microphoneDeviceID)
        }
        audioPlayer?.rate = Float(settings.playbackSpeed)

        let folderChanged = previous.recordingsFolderPath != settings.recordingsFolderPath
            || previous.recordingsFolderBookmark != settings.recordingsFolderBookmark
        if settings.localAPIEnabled {
            startLocalAPI()
            if folderChanged { restartLocalAPIIfFolderChanged() }
        } else if localServer != nil {
            stopLocalAPI()
        }
        if previous.globalShortcutEnabled != settings.globalShortcutEnabled {
            globalHotkeyService.configure(enabled: settings.globalShortcutEnabled) { [weak self] in
                Task { await self?.toggleRecording() }
            }
        }
        if previous.summaryProvider != settings.summaryProvider {
            aiService.textModelProvider = settings.summaryProvider
        }
        if folderChanged || previous.summaryProvider != settings.summaryProvider {
            if folderChanged { startLibraryWatcher() }
            refreshSetupHealth()
        }
        if Self.userFacingSettingsDiffer(previous, settings) {
            autoTranscribeNotice = nil
        }
        // A provider switch can make queued jobs runnable.
        processTranscriptionQueueIfNeeded()
    }

    /// Ignores window geometry, which is saved on its own as the window resizes.
    private static func userFacingSettingsDiffer(_ lhs: AppSettings, _ rhs: AppSettings) -> Bool {
        var lhs = lhs
        lhs.windowWidth = rhs.windowWidth
        lhs.windowHeight = rhs.windowHeight
        return lhs != rhs
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }

    private func startLibraryWatcher() {
        let folder = recordingsFolderURL
        guard watchedFolderPath != folder.path else { return }
        watchedFolderPath = folder.path
        try? folderWatcher.start(folderURL: folder) { [weak self] in
            // Listed on the watcher queue, off the main thread.
            let snapshot = LibraryFolderSnapshot.capture(folderURL: folder)
            Task { @MainActor in
                guard let self else { return }
                guard !self.workflowState.isRecording, !self.workflowState.isBusy else {
                    self.libraryWatcherMissedEvents = true
                    return
                }
                // Only the app's own writes since the last load: nothing to reload.
                if let snapshot, snapshot == self.libraryFolderSnapshot { return }
                await self.refreshLibrary(folderSnapshot: snapshot, onlyWhenIdle: true)
            }
        }
    }

    /// The workflow became idle after the watcher dropped events while
    /// recording or busy: compares the folder again (reloading when it
    /// changed), then re-reads changed transcripts and summaries for search
    /// in any case, so outside edits made meanwhile become searchable.
    private func resumeLibraryWatcherAfterBusy() {
        guard libraryWatcherMissedEvents, !workflowState.isRecording, !workflowState.isBusy else { return }
        libraryWatcherMissedEvents = false
        let folder = recordingsFolderURL
        let indexer = searchIndexer
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.libraryLoader.run { LibraryFolderSnapshot.capture(folderURL: folder) }
            if snapshot == nil || snapshot != self.libraryFolderSnapshot {
                await self.refreshLibrary(folderSnapshot: snapshot, onlyWhenIdle: true)
            }
            await Task.detached(priority: .utility) { await indexer.indexContent() }.value
            if self.isSearchingRecordings { self.scheduleRecordingSearch() }
        }
    }

    func saveAPIKeys() {
        do {
            if !elevenLabsKeyDraft.isEmpty {
                if settings.rememberCredentials {
                    try keyStore.save(apiKey: elevenLabsKeyDraft, for: .elevenLabs)
                } else {
                    try keyStore.setSession(apiKey: elevenLabsKeyDraft, for: .elevenLabs)
                }
                elevenLabsKeyDraft = ""
            }
            if !openAIKeyDraft.isEmpty {
                if settings.rememberCredentials {
                    try keyStore.save(apiKey: openAIKeyDraft, for: .openAI)
                } else {
                    try keyStore.setSession(apiKey: openAIKeyDraft, for: .openAI)
                }
                openAIKeyDraft = ""
            }
            if !deepSeekKeyDraft.isEmpty {
                if settings.rememberCredentials {
                    try keyStore.save(apiKey: deepSeekKeyDraft, for: CredentialProvider.deepSeek)
                } else {
                    try keyStore.setSession(apiKey: deepSeekKeyDraft, for: CredentialProvider.deepSeek)
                }
                deepSeekKeyDraft = ""
            }
            autoTranscribeNotice = nil
            saveSettings()
            refreshSetupHealth()
            // A newly added key can make waiting jobs runnable.
            processTranscriptionQueueIfNeeded()
            statusMessage = "Settings saved"
        } catch {
            workflowState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    func forgetAPIKeys() {
        do {
            try keyStore.forget(.elevenLabs)
            try keyStore.forget(.openAI)
            try keyStore.forget(CredentialProvider.deepSeek)
            refreshSetupHealth()
            statusMessage = "Saved API keys forgotten"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Transcription-provider entry point (kept for existing callers).
    func testCredential(provider: AIProvider) async {
        await testCredential(credential: provider.credentialProvider)
    }

    /// Tests the drafted key for `credential`, or the stored one when the draft is empty.
    func testCredential(credential: CredentialProvider) async {
        guard !isTestingCredential else { return }
        isTestingCredential = true
        defer { isTestingCredential = false }

        let draft: String
        switch credential {
        case .elevenLabs:
            draft = elevenLabsKeyDraft
        case .openAI:
            draft = openAIKeyDraft
        case .deepSeek:
            draft = deepSeekKeyDraft
        }
        let key = APIKeyNormalizer.normalized(draft) ?? keyStore.apiKey(for: credential) ?? ""
        credentialStatusMessage = "Testing \(credential.displayName) key..."
        credentialStatusSeverity = .info
        let result = await credentialValidator.validate(credential: credential, apiKey: key)
        credentialStatusMessage = result.message
        credentialStatusSeverity = result.isValid ? .success : .error
        statusMessage = result.message
        refreshSetupHealth()
    }

    /// Re-reads which credentials have a key (session, environment or
    /// Keychain) into `savedCredentials`, which `canSummarize`,
    /// `resolvedSummaryProvider` and Settings read while rendering.
    func refreshCredentialCache() {
        // Isolated lifecycle tests must never prompt for the user's Keychain.
        guard recordingsFolderOverride == nil else { return }
        savedCredentials = Set(CredentialProvider.allCases.filter { keyStore.apiKey(for: $0) != nil })
    }

    func refreshSetupHealth() {
        // Isolated lifecycle tests must never prompt for the user's Keychain.
        guard recordingsFolderOverride == nil else { return }
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let microphoneItem: SetupHealthItem
        switch microphoneStatus {
        case .authorized:
            microphoneItem = SetupHealthItem(
                id: "microphone",
                title: "Microphone Permission",
                detail: "Allowed",
                severity: .success,
                systemImage: "mic.fill"
            )
        case .notDetermined:
            microphoneItem = SetupHealthItem(
                id: "microphone",
                title: "Microphone Permission",
                detail: "Not requested yet",
                severity: .warning,
                systemImage: "mic"
            )
        case .denied, .restricted:
            microphoneItem = SetupHealthItem(
                id: "microphone",
                title: "Microphone Permission",
                detail: "Open macOS Privacy settings to allow microphone access.",
                severity: .error,
                systemImage: "mic.slash.fill"
            )
        @unknown default:
            microphoneItem = SetupHealthItem(
                id: "microphone",
                title: "Microphone Permission",
                detail: "Unknown status",
                severity: .warning,
                systemImage: "questionmark.circle"
            )
        }

        let screenAllowed = CGPreflightScreenCaptureAccess()
        let screenItem = SetupHealthItem(
            id: "screen",
            title: "System Audio Permission",
            detail: screenAllowed ? "Screen capture permission looks allowed" : "Allow Screen Recording for system audio capture.",
            severity: screenAllowed ? .success : .warning,
            systemImage: screenAllowed ? "speaker.wave.2.fill" : "speaker.slash.fill"
        )

        let elevenLabsItem = SetupHealthItem(
            id: "elevenlabs",
            title: "ElevenLabs Key",
            detail: keyStore.apiKey(for: .elevenLabs) == nil ? "Missing" : "Saved",
            severity: keyStore.apiKey(for: .elevenLabs) == nil ? .warning : .success,
            systemImage: "text.quote"
        )

        refreshCredentialCache()
        // Summaries use the selected text model, else the other one with a key.
        let summaryProvider = resolvedSummaryProvider
        let summaryItem = SetupHealthItem(
            id: "summary",
            title: "Summary key",
            detail: summaryProvider.map { "\($0.displayName) saved" } ?? "Missing: add an OpenAI or DeepSeek key for summaries",
            severity: summaryProvider == nil ? .info : .success,
            systemImage: "sparkles"
        )

        let folderItem: SetupHealthItem
        do {
            try FileManager.default.createDirectory(at: recordingsFolderURL, withIntermediateDirectories: true)
            let writable = FileManager.default.isWritableFile(atPath: recordingsFolderURL.path)
            folderItem = SetupHealthItem(
                id: "folder",
                title: "Recordings Folder",
                detail: writable ? recordingsFolderURL.path : "Folder is not writable.",
                severity: writable ? .success : .error,
                systemImage: writable ? "folder.fill" : "folder.badge.questionmark"
            )
        } catch {
            folderItem = SetupHealthItem(
                id: "folder",
                title: "Recordings Folder",
                detail: error.localizedDescription,
                severity: .error,
                systemImage: "folder.badge.questionmark"
            )
        }

        setupHealthItems = [microphoneItem, screenItem, elevenLabsItem, summaryItem, folderItem]
    }

    /// Queues a transcription with the current provider. Refuses (and says why
    /// in `statusMessage`) when a job is already pending or the provider has no
    /// API key, so the queue never holds jobs it cannot run.
    /// - Parameter autoTitleRequested: defaults to `settings.autoTitle`.
    /// - Returns: whether a job was queued.
    @discardableResult
    private func enqueueTranscription(
        recording: RecordingItem,
        replacingExistingTranscript: Bool,
        trimRange: AudioTrimRange? = nil,
        origin: TranscriptionJobOrigin = .manual,
        autoTitleRequested: Bool? = nil
    ) -> Bool {
        guard RecordingInteractionPolicy.canSelectHistory(during: workflowState) else { return false }
        guard !hasPendingTranscriptionReadingDiskIfNeeded(for: recording.id) else {
            statusMessage = "Transcription already queued"
            return false
        }
        let provider = settings.provider
        guard credentialAvailable(for: provider) else {
            statusMessage = "Add a \(provider.displayName) API key in Settings to transcribe."
            return false
        }

        let store = transcriptionJobStore()
        let previousAttemptCount = jobReadingDiskIfNeeded(for: recording.id)?.attemptCount ?? 0
        let job = TranscriptionJob.queue(
            recordingID: recording.id,
            recordingName: recording.displayName,
            audioFileName: recording.audioURL.lastPathComponent,
            provider: provider,
            replacingExistingTranscript: replacingExistingTranscript,
            previousAttemptCount: previousAttemptCount,
            trimStartSeconds: trimRange?.startSeconds,
            trimEndSeconds: trimRange?.endSeconds,
            origin: origin,
            autoTitleRequested: autoTitleRequested ?? settings.autoTitle,
            // Captured now: only when the switch is on and a summary key exists.
            autoSummarizeRequested: settings.autoSummarize && summaryKeyAvailableNow,
            languageCode: settings.transcriptionLanguage.languageCode
        )

        do {
            try store.save(job)
            noteOwnJobWrite(job)
            upsertTranscriptionJob(job)
            statusMessage = replacingExistingTranscript ? "Re-transcription queued" : "Transcription queued"
            processTranscriptionQueueIfNeeded()
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    /// The oldest queued job whose provider currently has an API key.
    private func nextRunnableQueuedJob() -> TranscriptionJob? {
        transcriptionJobs
            .filter { $0.status == .queued && credentialAvailable(for: $0.provider) }
            .min { $0.queuedAt < $1.queuedAt }
    }

    /// Starts the queue worker when a runnable job exists. Jobs whose provider
    /// has no key stay queued until a key is added (`saveAPIKeys`/`saveSettings`
    /// call this again).
    private func processTranscriptionQueueIfNeeded() {
        guard transcriptionQueueTask == nil else { return }
        guard nextRunnableQueuedJob() != nil else { return }
        transcriptionQueueTask = Task { [weak self] in
            await self?.runTranscriptionQueue()
        }
    }

    private func runTranscriptionQueue() async {
        defer {
            transcriptionQueueTask = nil
            transcriptionStartedAt = nil
            // Re-arm only for jobs that can actually run; re-arming for a job
            // without a credential would spin forever.
            if nextRunnableQueuedJob() != nil {
                processTranscriptionQueueIfNeeded()
            }
        }

        while !Task.isCancelled {
            await refreshTranscriptionJobs()
            guard var job = nextRunnableQueuedJob() else { break }

            if await recoverPublishedJobIfPossible(&job) {
                saveTranscriptionJob(job)
                continue
            }

            job.markRunning()
            saveTranscriptionJob(job)
            transcriptionStartedAt = job.startedAt
            statusMessage = "Transcribing \(job.recordingName)"
            await performTranscriptionJob(job)
        }
    }

    private func performTranscriptionJob(_ job: TranscriptionJob) async {
        guard let recording = await recording(for: job) else {
            var failed = job
            failed.markFailed("Recording file is missing.")
            saveTranscriptionJob(failed)
            return
        }

        var running = job
        do {
            let recordingLibrary = library()
            let stableRecording = try await libraryLoader.run { try recordingLibrary.migrateIfNeeded(recording) }
            let trimRange: AudioTrimRange? = {
                guard let end = job.trimEndSeconds else { return nil }
                return AudioTrimRange(startSeconds: job.trimStartSeconds ?? 0, endSeconds: end)
            }()
            let prepared = try await TranscriptionAudioPreparer.prepare(
                sourceURL: stableRecording.audioURL,
                durationSeconds: stableRecording.durationSeconds,
                trimRange: trimRange,
                compressionEnabled: settings.compressUploads
            )
            defer { prepared.cleanUp() }
            running.usedUncompressedAudioFallback = prepared.usedUncompressedFallback
            running.audioPreparationWarning = prepared.warning
            saveTranscriptionJob(running)

            let decoded = try await aiService.transcribe(
                audioURL: prepared.url,
                provider: job.provider,
                // Captured at queue time (nil: auto-detect, also for jobs saved before 1.2).
                languageCode: job.languageCode
            )
            try Task.checkCancellation()

            syncTextModelProvider()
            let service = aiService
            var titleGenerator: TranscriptPublisher.TitleGenerator?
            if service.canGenerateTitlesRemotely {
                titleGenerator = { transcript -> String? in try await service.generateTitle(transcript: transcript) }
            }
            // The title runs inside `publish` after the job is checkpointed as
            // completed; until it returns the recording still counts as busy.
            // The summary is NOT generated here (no summarizer): it starts on
            // its own below, so the transcript shows and the queue moves on.
            publishingRecordingID = recording.id
            defer { publishingRecordingID = nil }
            let result = try await TranscriptPublisher.publish(
                job: running,
                recording: stableRecording,
                decoded: decoded,
                autoTitleRequested: job.autoTitleRequested,
                library: recordingLibrary,
                titleGenerator: titleGenerator,
                summarizer: nil,
                checkpoint: { [weak self] checkpointed in
                    running = checkpointed
                    self?.saveTranscriptionJob(checkpointed)
                }
            )
            publishingRecordingID = nil
            await applyPublishedTranscript(result, transcript: decoded.text, replacedExisting: job.replacingExistingTranscript)
            statusMessage = job.replacingExistingTranscript ? "Transcript refreshed" : "Transcript ready"
            if let title = result.generatedTitle {
                statusMessage += " · titled \u{201C}\(title)\u{201D}"
            }
            if job.autoSummarizeRequested {
                startAutoSummary(for: result.recording, transcript: decoded.text)
            }
        } catch let error where error is CancellationError || (error as? URLError)?.code == .cancelled {
            // A cancelled task surfaces from URLSession as `URLError(.cancelled)`.
            var cancelled = job
            cancelled.markCancelled()
            saveTranscriptionJob(cancelled)
            statusMessage = "Transcription cancelled"
        } catch {
            // A failure after the job was checkpointed as completed (e.g. a
            // summary-clear error) must not flip it back to failed.
            if running.status == .completed {
                await refreshLibrary()
                statusMessage = error.localizedDescription
                return
            }
            let message = TranscriptionErrorMessage.message(for: error)
            var failed = job
            failed.markFailed(message)
            saveTranscriptionJob(failed)
            if RecordingInteractionPolicy.shouldApplyAsyncResult(targetID: recording.id, selectedID: selectedRecording?.id) {
                selectedTranscriptionJob = failed
            }
            statusMessage = message
        }
    }

    /// Refreshes the library and, when the published recording is still
    /// selected, the transcript pane, after `TranscriptPublisher` finished.
    private func applyPublishedTranscript(_ result: TranscriptPublishResult, transcript: String, replacedExisting: Bool) async {
        let finalRecording = result.recording
        await refreshLibrary()
        refreshSearchDocument(for: finalRecording)
        if let title = result.generatedTitle {
            lastAutoTitleNotice = "Titled \u{201C}\(title)\u{201D}"
        }
        if RecordingInteractionPolicy.shouldApplyAsyncResult(targetID: finalRecording.id, selectedID: selectedRecording?.id) {
            selectedRecording = recordings.first(where: { $0.id == finalRecording.id }) ?? finalRecording
            transcriptText = transcript
            transcriptSegments = result.segments
            selectedTranscriptionJob = job(for: finalRecording.id) ?? result.job
            if replacedExisting {
                summaryText = ""
                summaryProviderByRecording[finalRecording.id] = nil
            }
            updateExportPreview()
        }
    }

    /// Generates the summary of a just-published transcript on its own task
    /// (`TranscriptPublisher.summarize`, which never overwrites an existing
    /// summary), tracked in `summarizingRecordingIDs` until it finishes.
    private func startAutoSummary(for recording: RecordingItem, transcript: String) {
        let recordingID = recording.id
        guard !summarizingRecordingIDs.contains(recordingID) else { return }
        // Action time: the key store, not the cached flags, decides.
        syncTextModelProvider()
        let service = aiService
        guard let provider = service.resolvedTextModelProvider else {
            // The key was removed after the job was queued.
            applyAutoSummary(
                TranscriptSummaryOutcome(recording: recording, error: ProviderError.missingAPIKey(ProviderError.textModelKeyNames)),
                recordingID: recordingID,
                provider: nil
            )
            return
        }
        // Typed-but-unsaved summary text reaches disk first, so it is kept.
        if selectedRecording?.id == recordingID { flushSummaryEdits() }
        summarizingRecordingIDs.insert(recordingID)
        summarizingProviders[recordingID] = provider
        let recordingLibrary = library()
        autoSummaryTasks[recordingID] = Task { [weak self] in
            defer {
                self?.summarizingRecordingIDs.remove(recordingID)
                self?.summarizingProviders[recordingID] = nil
                self?.autoSummaryTasks[recordingID] = nil
            }
            let outcome = await TranscriptPublisher.summarize(
                recording: recording,
                transcript: transcript,
                library: recordingLibrary,
                summarizer: { text in try await service.summarize(transcript: text) }
            )
            self?.applyAutoSummary(outcome, recordingID: recordingID, provider: provider)
        }
    }

    /// Cancels in-flight auto-summaries (app quit); their tasks clear
    /// `summarizingRecordingIDs` as they unwind, and so does this.
    private func cancelAutoSummaries() {
        for task in autoSummaryTasks.values { task.cancel() }
        autoSummaryTasks = [:]
        summarizingRecordingIDs = []
        summarizingProviders = [:]
    }

    /// Shows the auto-summary (or why there is none) after
    /// `TranscriptPublisher.summarize` finished. A failure never fails the job.
    private func applyAutoSummary(_ outcome: TranscriptSummaryOutcome, recordingID: UUID, provider: TextModelProvider?) {
        if let markdown = outcome.markdown {
            if let provider { summaryProviderByRecording[recordingID] = provider }
            noteSidecarsChanged(for: outcome.recording, written: [outcome.recording.summaryURL])
            if RecordingInteractionPolicy.shouldApplyAsyncResult(targetID: recordingID, selectedID: selectedRecording?.id) {
                let editor = summaryText
                if editor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editor == outcome.previousSummary {
                    summaryText = markdown
                    // Our own write: the next library refresh must not reload over it.
                    if lastLoadedSidecarStamp?.recordingID == recordingID, let selectedRecording {
                        lastLoadedSidecarStamp = sidecarStamp(for: selectedRecording)
                    }
                    updateExportPreview()
                } else {
                    // The editor holds text the user typed: it wins over the generated summary.
                    flushSummaryEdits()
                    summaryProviderByRecording[recordingID] = nil
                    lastAutoSummaryNotice = L(TranscriptPublisher.existingSummaryKept)
                    lastAutoSummaryFailed = false
                    autoSummaryOutcomes[recordingID] = AutoSummaryOutcome(provider: provider, characters: 0, error: nil)
                    return
                }
            }
            lastAutoSummaryNotice = provider.map { L("Summary ready via %@", $0.displayName) } ?? L("Summary ready")
            lastAutoSummaryFailed = false
            statusMessage = lastAutoSummaryNotice ?? statusMessage
            autoSummaryOutcomes[recordingID] = AutoSummaryOutcome(provider: provider, characters: markdown.count, error: nil)
        } else if let error = outcome.error {
            let message = SummaryErrorMessage.message(for: error)
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !cancelled {
                lastAutoSummaryNotice = L("Auto-summary failed: %@", message)
                lastAutoSummaryFailed = true
                statusMessage = message
            }
            autoSummaryOutcomes[recordingID] = AutoSummaryOutcome(provider: provider, characters: 0, error: message)
        } else if outcome.skippedReason == TranscriptPublisher.existingSummaryKept {
            lastAutoSummaryNotice = L(TranscriptPublisher.existingSummaryKept)
            lastAutoSummaryFailed = false
            autoSummaryOutcomes[recordingID] = AutoSummaryOutcome(provider: provider, characters: 0, error: nil)
        } else {
            // Skipped: an empty transcript, or the recording was deleted meanwhile.
            autoSummaryOutcomes[recordingID] = AutoSummaryOutcome(provider: provider, characters: 0, error: nil)
        }
    }

    /// Reads every job file synchronously (a fallback; loads and saves keep
    /// `transcriptionJobs` current without it).
    private func loadTranscriptionJobs() {
        do {
            setTranscriptionJobs(try transcriptionJobStore().loadAll())
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Re-reads the job files off the main actor (the queue does this before
    /// picking the next job). Dropped when a job changed in memory meanwhile.
    private func refreshTranscriptionJobs() async {
        let generation = transcriptionJobsGeneration
        let folder = recordingsFolderURL
        let result = await libraryLoader.run { Result { try TranscriptionJobStore(folderURL: folder).loadAll() } }
        guard generation == transcriptionJobsGeneration else { return }
        switch result {
        case let .success(jobs): setTranscriptionJobs(jobs)
        case let .failure(error): statusMessage = error.localizedDescription
        }
    }

    /// `jobs` newest first (`TranscriptionJobStore.loadAll` order), plus the selection's job.
    private func setTranscriptionJobs(_ jobs: [TranscriptionJob]) {
        transcriptionJobs = jobs
        if let selectedRecording {
            selectedTranscriptionJob = jobs.first { $0.recordingID == selectedRecording.id }
        } else {
            selectedTranscriptionJob = nil
        }
    }

    /// Launch: jobs left `.running` by a previous run are marked interrupted
    /// (in memory and on disk). `transcriptionJobs` was just loaded.
    private func markInterruptedTranscriptionJobs() {
        var jobs = transcriptionJobs
        var changed = false
        for index in jobs.indices where jobs[index].status == .running {
            jobs[index].markInterruptedIfRunning()
            try? transcriptionJobStore().save(jobs[index])
            noteOwnJobWrite(jobs[index])
            changed = true
        }
        if changed { setTranscriptionJobs(jobs) }
    }

    /// Saves `job` and puts it into `transcriptionJobs` in memory, instead of
    /// re-reading every job file after each checkpoint.
    private func saveTranscriptionJob(_ job: TranscriptionJob) {
        do {
            try transcriptionJobStore().save(job)
            noteOwnJobWrite(job)
            upsertTranscriptionJob(job)
        } catch {
            // As before: show what is on disk.
            loadTranscriptionJobs()
        }
    }

    /// Puts a just-saved job into memory as stored (read back from its own
    /// file: dates round-trip through the store's encoding), keeping
    /// `loadAll`'s newest-first order; no folder listing.
    private func upsertTranscriptionJob(_ saved: TranscriptionJob) {
        let job = (try? transcriptionJobStore().load(jobID: saved.id)) ?? saved
        var jobs = transcriptionJobs.filter { $0.id != job.id }
        let index = jobs.firstIndex { $0.updatedAt <= job.updatedAt } ?? jobs.endIndex
        jobs.insert(job, at: index)
        setTranscriptionJobs(jobs)
    }

    /// Completes a job whose transcript was already written before the app
    /// stopped (SHA-256 checkpoint), including the skipped side effects.
    private func recoverPublishedJobIfPossible(_ job: inout TranscriptionJob) async -> Bool {
        guard job.transcriptContentSHA256 != nil,
              let recording = await recording(for: job),
              let result = TranscriptPublisher.recoverIfPublished(job: job, recording: recording, library: library())
        else { return false }
        job = result.job
        let transcript = readTextIfExists(at: result.recording.transcriptURL)
        await applyPublishedTranscript(result, transcript: transcript, replacedExisting: job.replacingExistingTranscript)
        if job.autoSummarizeRequested,
           readTextIfExists(at: result.recording.summaryURL).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Recovery never calls the provider; say how to get the summary.
            lastAutoSummaryNotice = L("Transcript recovered; summary was not generated. Press Summarize to create one.")
            lastAutoSummaryFailed = true
        }
        return true
    }

    /// The recording's latest job, from memory only (`transcriptionJobs`).
    /// Evaluated by views while rendering, so it never reads the disk.
    func job(for recordingID: UUID) -> TranscriptionJob? {
        jobsByRecordingID[recordingID]
    }

    /// Like `job(for:)`, but falls back to the job files on disk. Only for
    /// actions (queueing, cancelling, deleting), never while rendering.
    private func jobReadingDiskIfNeeded(for recordingID: UUID) -> TranscriptionJob? {
        job(for: recordingID) ?? transcriptionJobStore().loadIfExists(recordingID: recordingID)
    }

    /// In-memory; safe to evaluate while rendering.
    private func hasPendingTranscription(for recordingID: UUID) -> Bool {
        if publishingRecordingID == recordingID { return true }
        guard let job = job(for: recordingID) else { return false }
        return job.status == .queued || job.status == .running
    }

    /// `hasPendingTranscription(for:)` with the disk fallback, for actions.
    private func hasPendingTranscriptionReadingDiskIfNeeded(for recordingID: UUID) -> Bool {
        if publishingRecordingID == recordingID { return true }
        guard let job = jobReadingDiskIfNeeded(for: recordingID) else { return false }
        return job.status == .queued || job.status == .running
    }

    private static func latestJobByRecording(_ jobs: [TranscriptionJob]) -> [UUID: TranscriptionJob] {
        // `jobs` is newest first (`TranscriptionJobStore.loadAll`); keep the first.
        Dictionary(jobs.map { ($0.recordingID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Row facts, Read mode and own-write bookkeeping

    /// Parsed once per transcript/segments change instead of on every render.
    var readModeTranscript: ReadableTranscript {
        if let readModeCache { return readModeCache }
        let parsed = TranscriptParser.readableTranscript(saved: transcriptSegments, transcript: transcriptText)
        readModeCache = parsed
        return parsed
    }

    /// After the app wrote (or cleared) some of a recording's sidecars
    /// (`written`: exactly the files it wrote): refreshes its search document
    /// and sidebar facts, and records those files as the app's own so the
    /// folder watcher does not reload for them.
    private func noteSidecarsChanged(for recording: RecordingItem, written: [URL]) {
        libraryMutationCounter += 1
        refreshSearchDocument(for: recording)
        if isSearchingRecordings { scheduleRecordingSearch() }
        recordingRowFacts[recording.id] = LibraryLoader.rowFacts(for: recording, listing: nil)
        noteOwnLibraryWrites(written)
    }

    /// Patches `libraryFolderSnapshot` for files the app itself just wrote or
    /// removed (each with its `DurableFile` backup), with the stamps those
    /// writes recorded under `LibraryIO` (`OwnFileWrites`). The files are never
    /// re-read here: that would also absorb an outside change made since. A
    /// file without a recorded stamp keeps its old entry (the watcher then
    /// reloads, which is always safe).
    private func noteOwnLibraryWrites(_ urls: [URL]) {
        let folder = library().folderURL.standardizedFileURL.path
        let files = urls
            .filter { $0.deletingLastPathComponent().standardizedFileURL.path == folder }
            .flatMap { [$0, DurableFile.backupURL(for: $0)] }
        guard !files.isEmpty else { return }
        let recorded = OwnFileWrites.take(files)
        guard var snapshot = libraryFolderSnapshot else { return }
        for (url, status) in zip(files, recorded) {
            if let status { snapshot.patch(url.lastPathComponent, with: status) }
        }
        libraryFolderSnapshot = snapshot
    }

    private func noteOwnJobWrite(_ job: TranscriptionJob) {
        noteOwnLibraryWrites([transcriptionJobStore().url(for: job.id)])
    }

    /// The job's recording from memory, else from a library read off the main actor.
    private func recording(for job: TranscriptionJob) async -> RecordingItem? {
        if let recording = recordings.first(where: { $0.id == job.recordingID }) {
            return recording
        }
        let recordingLibrary = library()
        let recordingID = job.recordingID
        return await libraryLoader.run { (try? recordingLibrary.loadRecordings())?.first { $0.id == recordingID } }
    }

    private func performRecordingAction(_ operation: () async -> Void) async {
        await recordingActions.perform(operation)
    }

    private func makeTemporaryAudioURL(source: AudioSource) throws -> URL {
        let folder = recordingsFolderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(".in-progress-\(source.rawValue)-\(UUID().uuidString).m4a")
    }

    private func ensureMinimumRecordingSpace() throws {
        let folder = recordingsFolderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage,
           available < 256 * 1_024 * 1_024 {
            throw RecordingSessionError.insufficientDiskSpace(availableBytes: available)
        }
    }

    private func makeFinalTemporaryAudioURL() throws -> URL {
        let folder = recordingsFolderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(".final-\(UUID().uuidString).m4a")
    }

    private func manifestStore() -> RecordingSessionManifestStore {
        RecordingSessionManifestStore(folderURL: recordingsFolderURL)
    }

    private func transcriptionJobStore() -> TranscriptionJobStore {
        TranscriptionJobStore(folderURL: recordingsFolderURL)
    }

    private func library() -> any RecordingLibraryServing {
        libraryFactory(recordingsFolderURL)
    }

    private func currentManifestFallback(source: AudioSource, clock: RecordingSessionClock) throws -> RecordingSessionManifest {
        if let currentSessionManifest {
            return currentSessionManifest
        }
        let requestedName = currentSessionName ?? defaultMeetingName(for: clock.startedAt)
        var manifest = RecordingSessionManifest(
            source: source,
            requestedName: requestedName,
            startedAt: clock.startedAt,
            updatedAt: Date(),
            accumulatedActiveDuration: clock.accumulatedActiveDuration,
            completedSegments: completedSegmentURLs.map {
                RecordingSessionSegment(fileName: $0.lastPathComponent, startedAt: clock.startedAt)
            },
            pauseReason: clock.pauseReason
        )
        if let temporaryAudioURL, let segmentStartedAt = clock.currentSegmentStartedAt {
            manifest.startActiveSegment(
                fileName: temporaryAudioURL.lastPathComponent,
                startedAt: segmentStartedAt
            )
        }
        return manifest
    }

    private func finalizedSegmentURLs() throws -> [URL] {
        if let currentSessionManifest, !currentSessionManifest.completedSegments.isEmpty {
            return currentSessionManifest.completedSegments.map {
                recordingsFolderURL.appendingPathComponent($0.fileName)
            }
        }
        return completedSegmentURLs
    }

    private func validateCapturedSegmentsExist(_ urls: [URL]) throws {
        for url in urls where !FileManager.default.fileExists(atPath: url.path) {
            throw RecordingSessionError.missingCapturedSegment(url.lastPathComponent)
        }
    }

    private func loadSelectedSidecars() {
        guard let selectedRecording else {
            transcriptText = ""
            transcriptSegments = []
            summaryText = ""
            selectedTranscriptionJob = nil
            playback.reviewWaveform = []
            exportPreview = ""
            lastLoadedSidecarStamp = nil
            return
        }
        let recordingLibrary = library()
        // One consistent read, never between the steps of an off-main durable write.
        let (transcript, savedSegments, summary) = LibraryIO.serialized {
            (
                (try? String(contentsOf: selectedRecording.transcriptURL, encoding: .utf8)) ?? "",
                recordingLibrary.loadTranscriptSegments(for: selectedRecording),
                (try? String(contentsOf: selectedRecording.summaryURL, encoding: .utf8)) ?? ""
            )
        }
        transcriptText = transcript
        transcriptSegments = savedSegments.isEmpty ? TranscriptParser.segments(from: transcriptText) : savedSegments
        summaryText = summary
        playback.trimStartSeconds = 0
        playback.trimEndSeconds = selectedRecording.durationSeconds
        transcriptSaveMessage = ""
        updateExportPreview()
        waveformTask?.cancel()
        let targetID = selectedRecording.id
        let waveformRecording = selectedRecording
        let analyzer = waveformAnalyzer
        waveformTask = Task { [weak self] in
            guard let result = await Self.reviewWaveform(for: waveformRecording, library: recordingLibrary, analyzer: analyzer),
                  let self else { return }
            if result.stored { self.noteOwnLibraryWrites([waveformRecording.waveformURL]) }
            if !Task.isCancelled, self.selectedRecording?.id == targetID {
                self.playback.reviewWaveform = result.samples
            }
        }
        selectedTranscriptionJob = loadTranscriptionJobForSelection(selectedRecording)
        // Keep an already-loaded player (and its position) for the same file.
        if audioPlayer?.url != selectedRecording.audioURL {
            preparePlayback(for: selectedRecording)
        }
        lastLoadedSidecarStamp = sidecarStamp(for: selectedRecording)
    }

    /// The review waveform of `recording`, off the main actor: the library's
    /// sidecar cache when it matches the audio file, else an analysis
    /// (cancellable), which is then stored (`stored`) for next time.
    nonisolated private static func reviewWaveform(
        for recording: RecordingItem,
        library: any RecordingLibraryServing,
        analyzer: WaveformAnalyzer
    ) async -> (samples: [Float], stored: Bool)? {
        let buckets = WaveformAnalyzer.defaultBucketCount
        if let cached = library.loadWaveformCache(for: recording, bucketCount: buckets) {
            return (cached, false)
        }
        // Stamped before the scan: a file replaced or edited while it is
        // scanned is not cached under its new stamp.
        let scannedAudio = WaveformCacheFile.AudioStamp(audioURL: recording.audioURL)
        guard let samples = try? await analyzer.samples(for: recording.audioURL, bucketCount: buckets) else { return nil }
        guard let scannedAudio else { return (samples, false) }
        let stored = (try? library.storeWaveformCache(samples, for: recording, scannedAudio: scannedAudio)) ?? false
        return (samples, stored)
    }

    /// Identity plus sidecar modification dates of a recording, so a library
    /// refresh can tell whether the selection's transcript/summary/segments changed.
    private struct SidecarStamp: Equatable {
        let recordingID: UUID
        let audioURL: URL
        let transcriptModified: Date?
        let summaryModified: Date?
        let segmentsModified: Date?
    }

    private func sidecarStamp(for recording: RecordingItem) -> SidecarStamp {
        func modified(_ url: URL) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        return SidecarStamp(
            recordingID: recording.id,
            audioURL: recording.audioURL,
            transcriptModified: modified(recording.transcriptURL),
            summaryModified: modified(recording.summaryURL),
            segmentsModified: modified(recording.transcriptSegmentsURL)
        )
    }

    /// Re-indexes `recording` (metadata, and its transcript and summary read
    /// again) off the main actor, then re-runs an active query.
    private func refreshSearchDocument(for recording: RecordingItem) {
        let indexer = searchIndexer
        Task { [weak self] in
            await indexer.refresh(recording)
            if let self, self.isSearchingRecordings { self.scheduleRecordingSearch() }
        }
    }

    private func readTextIfExists(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func loadTranscriptionJobForSelection(_ recording: RecordingItem) -> TranscriptionJob? {
        // `transcriptionJobs` already holds every job file (`loadAll`).
        job(for: recording.id)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        statusMessage = "Copied"
    }

    private func defaultMeetingName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Meeting \(formatter.string(from: date))"
    }

    private func audioDuration(for url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw ImportedRecordingError.unreadableDuration
        }
        return duration
    }

    /// The imported file's level report and, from the same decode, its review
    /// waveform (`nil` when the file could not be decoded).
    private func confidenceReportForImportedRecording(url: URL, duration: TimeInterval) async -> (RecordingConfidenceReport, [Float]?) {
        do {
            let analysis = try await RecordingConfidenceAnalyzer.analyzeWithWaveform(
                audioURL: url,
                source: .microphone,
                expectedChannels: [.microphone: 1],
                minimumDuration: 1,
                silenceThreshold: 0.01,
                waveformBuckets: WaveformAnalyzer.defaultBucketCount
            )
            var report = analysis.report
            report.issues.append(importedSourceIssue)
            return (report, analysis.waveform)
        } catch {
            return (RecordingConfidenceReport(
                checkedAt: Date(),
                durationSeconds: duration,
                peakLevel: 0,
                averageLevel: 0,
                issues: [
                    importedSourceIssue,
                    RecordingConfidenceIssue(
                        kind: .silentAudio,
                        severity: .warning,
                        message: "Audio level could not be checked for this file format."
                    )
                ]
            ), nil)
        }
    }

    private var importedSourceIssue: RecordingConfidenceIssue {
        RecordingConfidenceIssue(
            kind: .missingExpectedSource,
            severity: .info,
            message: "Imported file source is external. Confirm it contains the meeting audio you expect."
        )
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func preparePlayback(for recording: RecordingItem) {
        stopPlayback()
        do {
            let player = try AVAudioPlayer(contentsOf: recording.audioURL)
            player.enableRate = true
            player.rate = Float(settings.playbackSpeed)
            player.prepareToPlay()
            audioPlayer = player
            playback.playbackDuration = player.duration
            playback.playbackPosition = 0
        } catch {
            audioPlayer = nil
            playback.playbackDuration = 0
            playback.playbackPosition = 0
            statusMessage = "Could not load audio: \(error.localizedDescription)"
        }
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let audioPlayer = self.audioPlayer else { return }
                // Only real changes publish (the duration rarely changes).
                if self.playback.playbackPosition != audioPlayer.currentTime {
                    self.playback.playbackPosition = audioPlayer.currentTime
                }
                if self.playback.playbackDuration != audioPlayer.duration {
                    self.playback.playbackDuration = audioPlayer.duration
                }
                if !audioPlayer.isPlaying {
                    self.playback.isPlaying = false
                    self.playbackTimer?.invalidate()
                    self.playbackTimer = nil
                }
            }
        }
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recordingSessionClock = self.recordingSessionClock else { return }
                self.live.setElapsed(recordingSessionClock.activeDuration(at: Date()))
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func updateSourceLevel(_ channel: AudioSignalChannel, _ level: Float) {
        let clamped = min(1, max(0, level))
        switch channel {
        case .microphone:
            microphonePeakDuringRecording = max(microphonePeakDuringRecording, clamped)
        case .system:
            systemPeakDuringRecording = max(systemPeakDuringRecording, clamped)
        }
        live.setLevel(clamped, for: channel)
    }

    private func resetSignalLevels() {
        live.resetLevels()
    }

    private func clearRecordingSession() {
        pendingCaptureFailure = nil
        recordingSessionClock = nil
        temporaryAudioURL = nil
        completedSegmentURLs = []
        currentSessionManifest = nil
        currentSessionSource = nil
        currentSessionName = nil
        microphonePeakDuringRecording = 0
        systemPeakDuringRecording = 0
        live.setElapsed(0)
        endSleepPrevention()
    }

    private func installPowerObservers() {
        guard powerObserverTokens.isEmpty else { return }
        let coordinator = SystemSleepCoordinator(onSleep: { [weak self] acknowledgement in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { acknowledgement.complete(); return }
                    let previous = self.powerEventTask
                    self.powerEventTask = Task { @MainActor in
                        await previous?.value
                        await self.suspendForSystemSleep()
                        acknowledgement.complete()
                    }
                }
            }
        }, onWake: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let previous = self.powerEventTask
                    self.powerEventTask = Task { @MainActor in
                        await previous?.value
                        await self.resumeAfterSystemWake()
                    }
                }
            }
        }, onRegistrationFailure: { [weak self] in
            Task { @MainActor in
                self?.recoveryMessage = "Sleep protection could not register. Stop and save before closing the lid; PCM recovery remains available."
                self?.recoveryNoticeSeverity = .warning
            }
        })
        systemSleepCoordinator = coordinator
        coordinator.start()
        let willTerminate = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushTranscriptEdits()
                self?.flushSummaryEdits()
                self?.cancelAutoSummaries()
            }
        }
        powerObserverTokens = [willTerminate]
    }

    private func beginSleepPrevention() {
        guard sleepPreventionActivity == nil else { return }
        sleepPreventionActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "MSR is recording meeting audio"
        )
    }

    private func endSleepPrevention() {
        guard let sleepPreventionActivity else { return }
        ProcessInfo.processInfo.endActivity(sleepPreventionActivity)
        self.sleepPreventionActivity = nil
    }
}

/// What the auto-summarize step produced for one recording.
struct AutoSummaryOutcome: Equatable {
    var provider: TextModelProvider?
    var characters: Int
    var error: String?
}

private enum RecordingSessionError: LocalizedError {
    case noCapturedSegments
    case missingCapturedSegment(String)
    case insufficientDiskSpace(availableBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .noCapturedSegments:
            return "No captured audio segments were available to save."
        case let .missingCapturedSegment(fileName):
            return "A recorded audio segment is missing: \(fileName). Recovery will retry on next launch."
        case let .insufficientDiskSpace(availableBytes):
            let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            return "Recording needs at least 256 MB of free space. \(available) is available."
        }
    }
}

private enum ImportedRecordingError: LocalizedError {
    case unreadableDuration

    var errorDescription: String? {
        switch self {
        case .unreadableDuration:
            return "Could not read the selected file duration."
        }
    }
}

private final class UserDefaultsSettingsStore {
    private let key = "app.msr.settings"

    func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
