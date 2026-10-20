import AppKit
import AVFoundation
import CoreGraphics
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import MSRCore
import MSRPresentation
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
    let presentation: PresentationCoordinator
    @Published var recordings: [RecordingItem] = []
    @Published var selectedRecording: RecordingItem?
    @Published var selectedSource: AudioSource = .micAndSystem
    @Published var settings: AppSettings
    @Published var workflowState: RecordingWorkflowState = .ready
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
    @Published var transcriptText = ""
    @Published var summaryText = ""
    @Published var recordingSearchQuery = ""
    @Published var renameDraft = ""
    @Published var showingRename = false
    @Published var elevenLabsKeyDraft = ""
    @Published var openAIKeyDraft = ""
    @Published var inputLevel: Float = 0
    @Published var microphoneLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var waveform = WaveformBuffer(capacity: 36)
    @Published var isPlaying = false
    @Published var playbackPosition: TimeInterval = 0
    @Published var playbackDuration: TimeInterval = 0
    @Published var recordingElapsed: TimeInterval = 0
    @Published var transcriptionStartedAt: Date?
    @Published var selectedTranscriptionJob: TranscriptionJob?
    @Published var transcriptionJobs: [TranscriptionJob] = []
    @Published var transcriptSegments: [TranscriptSegment] = []
    @Published var reviewWaveform: [Float] = []
    @Published var trimStartSeconds: TimeInterval = 0
    @Published var trimEndSeconds: TimeInterval = 0
    @Published var selectedDetailTab: RecordingDetailTab = .review
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
    @Published private var recordingSearchDocuments: [RecordingSearchDocument] = []
    @Published private var filteredRecordingIDs: [UUID]?

    private let settingsStore = UserDefaultsSettingsStore()
    private let keyStore = APIKeyStore()
    private let credentialValidator = CredentialValidator()
    private let recorder: AudioRecording
    private let aiService: ProviderAIService
    private let libraryFactory: (URL) -> any RecordingLibraryServing
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
    private var recordingActionInFlight = false
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
    private let searchIndexer = RecordingSearchIndexer(capacity: 64)
    private var searchIndexTask: Task<Void, Never>?
    private var watchedFolderPath: String?
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

    /// - Parameter recorder: the capture engine. `nil` uses `MeetingAudioRecorder`,
    ///   or, for development, `FileReplayRecorder` when the environment variable
    ///   `MSR_FAKE_RECORDER_CLIP` names an existing audio file (each "recording"
    ///   then becomes a copy of that clip; no microphone or screen permission needed).
    init(
        recorder: AudioRecording? = nil,
        libraryFactory: @escaping (URL) -> any RecordingLibraryServing = { RecordingLibrary(folderURL: $0) }
    ) {
        let loadedSettings = settingsStore.load()
        settings = loadedSettings
        lastAppliedSettings = loadedSettings
        presentation = PresentationCoordinator(settings: loadedSettings)
        self.recorder = recorder ?? Self.makeDefaultRecorder()
        self.libraryFactory = libraryFactory
        aiService = ProviderAIService(keyStore: keyStore)
        selectedSource = settings.preferredSource
        self.recorder.setMicrophoneDeviceUID(settings.microphoneDeviceID)
        if let bookmark = settings.recordingsFolderBookmark {
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
        self.recorder.onLevelUpdate = { [weak self] level in
            Task { @MainActor in
                self?.updateFallbackInputLevel(level)
            }
        }
        self.recorder.onSourceLevelUpdate = { [weak self] channel, level in
            Task { @MainActor in
                self?.updateSourceLevel(channel, level)
            }
        }
        lastAppliedSettings = settings
        bindPresentationModels()
    }

    private static func makeDefaultRecorder() -> AudioRecording {
        if let path = ProcessInfo.processInfo.environment["MSR_FAKE_RECORDER_CLIP"], !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return FileReplayRecorder(clipURL: URL(fileURLWithPath: path))
        }
        return MeetingAudioRecorder()
    }

    private func bindPresentationModels() {
        $recordings.assign(to: &presentation.library.$recordings)
        $selectedRecording.assign(to: &presentation.library.$selectedRecording)
        $recordingSearchQuery.assign(to: &presentation.library.$searchQuery)
        $renameDraft.assign(to: &presentation.library.$renameDraft)
        $showingRename.assign(to: &presentation.library.$showingRename)

        $selectedSource.assign(to: &presentation.recordingSession.$selectedSource)
        $workflowState.assign(to: &presentation.recordingSession.$workflowState)
        $inputLevel.assign(to: &presentation.recordingSession.$inputLevel)
        $microphoneLevel.assign(to: &presentation.recordingSession.$microphoneLevel)
        $systemLevel.assign(to: &presentation.recordingSession.$systemLevel)
        $waveform.assign(to: &presentation.recordingSession.$waveform)
        $recordingElapsed.assign(to: &presentation.recordingSession.$elapsed)

        $isPlaying.assign(to: &presentation.playback.$isPlaying)
        $playbackPosition.assign(to: &presentation.playback.$position)
        $playbackDuration.assign(to: &presentation.playback.$duration)
        $reviewWaveform.assign(to: &presentation.playback.$waveform)
        $trimStartSeconds.assign(to: &presentation.playback.$trimStart)
        $trimEndSeconds.assign(to: &presentation.playback.$trimEnd)

        $transcriptionJobs.assign(to: &presentation.queue.$jobs)
        $selectedTranscriptionJob.assign(to: &presentation.queue.$selectedJob)
        $transcriptionStartedAt.assign(to: &presentation.queue.$startedAt)

        $transcriptText.assign(to: &presentation.notes.$transcript)
        $summaryText.assign(to: &presentation.notes.$summary)
        $transcriptSegments.assign(to: &presentation.notes.$segments)
        $selectedExportFormat.assign(to: &presentation.notes.$exportFormat)
        $exportPreview.assign(to: &presentation.notes.$exportPreview)
        $transcriptSaveMessage.assign(to: &presentation.notes.$saveMessage)
        $lastExportURL.assign(to: &presentation.notes.$lastExportURL)
        $settings.assign(to: &presentation.settings.$settings)
    }

    var isRecording: Bool {
        workflowState.isRecording
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
            return "Copy Summary"
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
        return !hasPendingTranscription(for: selectedRecording.id)
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
        return job(for: selectedRecording.id)?.status == .running
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
            let lookup = Dictionary(uniqueKeysWithValues: recordingSearchDocuments.map { ($0.recording.id, $0.recording) })
            matches = filteredRecordingIDs.compactMap { lookup[$0] }
        } else {
            matches = recordingSearchDocuments.map(\.recording)
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

    /// "Auto" when the recording's latest transcription job was queued by
    /// auto-transcribe; `nil` otherwise.
    func transcriptionOriginLabel(for recording: RecordingItem) -> String? {
        // In-memory only: this is evaluated per row while rendering.
        transcriptionJobs.first { $0.recordingID == recording.id }?.origin == .automatic ? "Auto" : nil
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
        loadRecordings()
        loadTranscriptionJobs(markInterruptedRunning: true)
        refreshSetupHealth()
        processTranscriptionQueueIfNeeded()
        await recoverInterruptedRecordings()
    }

    func loadRecordings() {
        do {
            recordings = try library().loadRecordings()
            recordingSearchDocuments = recordings.map { RecordingSearchDocument(recording: $0) }
            searchIndexTask?.cancel()
            let snapshot = recordings
            searchIndexTask = Task { [weak self] in
                guard let self else { return }
                let documents = await searchIndexer.documents(for: snapshot)
                guard !Task.isCancelled, self.recordings.map(\.id) == snapshot.map(\.id) else { return }
                self.recordingSearchDocuments = documents
                self.scheduleRecordingSearch()
            }
            if let selectedRecording,
               let refreshed = recordings.first(where: { $0.id == selectedRecording.id }) {
                self.selectedRecording = refreshed
            } else {
                selectedRecording = recordings.first
            }
            loadTranscriptionJobs()
            loadSelectedSidecars()
            refreshSetupHealth()
        } catch {
            statusMessage = error.localizedDescription
            workflowState = .failed(error.localizedDescription)
        }
    }

    func clearRecordingSearch() {
        recordingSearchQuery = ""
        scheduleRecordingSearch()
    }

    func scheduleRecordingSearch() {
        recordingSearchTask?.cancel()
        let documents = recordingSearchDocuments
        let query = recordingSearchQuery
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filteredRecordingIDs = nil
            return
        }
        recordingSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let ids = await Task.detached(priority: .userInitiated) {
                RecordingSearch.filter(documents, query: query).map { $0.recording.id }
            }.value
            guard !Task.isCancelled else { return }
            self?.filteredRecordingIDs = ids
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
                loadRecordings()
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

    func importRecordings(from urls: [URL]) async {
        for url in urls { await importRecording(from: url) }
    }

    func importRecording(from url: URL) async {
        guard RecordingInteractionPolicy.canMutateRecordingLibrary(during: workflowState) else {
            statusMessage = "Finish the current recording task first."
            return
        }

        statusMessage = "Importing \(url.lastPathComponent)"
        do {
            let duration = try await audioDuration(for: url)
            let confidenceReport = await confidenceReportForImportedRecording(url: url, duration: duration)
            let imported = try library().importRecording(
                sourceURL: url,
                requestedName: url.deletingPathExtension().lastPathComponent,
                source: .microphone,
                startedAt: Date(),
                durationSeconds: duration,
                importedAt: Date(),
                confidenceReport: confidenceReport
            )
            loadRecordings()
            selectedRecording = recordings.first(where: { $0.id == imported.id }) ?? imported
            loadSelectedSidecars()
            preparePlayback(for: imported)
            workflowState = .saved
            statusMessage = "Imported \(imported.displayName)"
        } catch {
            workflowState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
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
            loadRecordings()
            let recovered = results.compactMap(\.recording)
            if let firstRecovered = recovered.first {
                selectedRecording = recordings.first(where: { $0.id == firstRecovered.id }) ?? firstRecovered
                loadSelectedSidecars()
                recoveryMessage = "\(recovered.count) interrupted recording\(recovered.count == 1 ? "" : "s") recovered."
                recoveryNoticeSeverity = .success
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
        await performRecordingAction {
            guard self.isRecording else { return }
            await self.pauseCurrentRecording(reason: .systemSleep)
        }
    }

    private func startNewRecordingSession() async {
        guard !isRecording, !workflowState.isPaused, !workflowState.isBusy else { return }
        let source = selectedSource
        workflowState = .starting(source: source)
        statusMessage = "Starting \(source.displayName)"
        recoveryMessage = ""
        recoveryNoticeSeverity = .info
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
            let manifest = RecordingSessionManifest(
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
            try manifestStore().save(manifest)
            currentSessionManifest = manifest
            temporaryAudioURL = temporaryURL
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
            recordingElapsed = 0
            startRecordingTimer()
            beginSleepPrevention()
            statusMessage = "Recording \(source.displayName)"
        } catch {
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
            try manifestStore().save(manifest)
            temporaryAudioURL = temporaryURL
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
        } catch {
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
            recordingElapsed = clock.activeDuration(at: pausedAt)
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
                try await recorder.stop()
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
            let confidenceReport = try await RecordingConfidenceAnalyzer.analyze(
                audioURL: finalTemporaryURL,
                source: source,
                expectedChannels: [
                    .microphone: microphonePeakDuringRecording,
                    .system: systemPeakDuringRecording
                ],
                minimumDuration: 3,
                silenceThreshold: Float(settings.silenceThreshold)
            )
            if var manifest = currentSessionManifest {
                manifest.state = .finalizing
                manifest.finalizationProgress = 0.75
                manifest.updatedAt = Date()
                try manifestStore().save(manifest)
                currentSessionManifest = manifest
            }
            let recording = try library().finishRecording(
                temporaryAudioURL: finalTemporaryURL,
                requestedName: currentSessionName ?? defaultMeetingName(for: finalizedClock.startedAt),
                source: source,
                startedAt: finalizedClock.startedAt,
                endedAt: endedAt,
                durationSecondsOverride: finalizedClock.activeDuration(at: endedAt),
                recoveredAt: nil,
                recoveryNote: nil,
                segmentCount: max(1, segmentURLs.count),
                confidenceReport: confidenceReport,
                recordingID: currentSessionManifest?.finalRecordingID
            )
            if segmentURLs.count > 1 {
                for url in segmentURLs {
                    try? FileManager.default.removeItem(at: url)
                }
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
            loadRecordings()
            selectedRecording = recordings.first(where: { $0.id == recording.id }) ?? recording
            loadSelectedSidecars()
            preparePlayback(for: recording)
            workflowState = .saved
            statusMessage = segmentURLs.count > 1 ? "Recording saved from \(segmentURLs.count) segments" : "Recording saved"
            autoTranscribeIfEnabled(recording: selectedRecording ?? recording, confidenceReport: confidenceReport)
        } catch {
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
        guard let selectedRecording else { return }
        do {
            let renamed = try library().rename(selectedRecording, to: renameDraft)
            showingRename = false
            loadRecordings()
            self.selectedRecording = renamed
            loadSelectedSidecars()
            preparePlayback(for: renamed)
            workflowState = .saved
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
        do {
            if target.id == selectedRecording?.id {
                stopPlayback()
            }
            try library().delete(target)
            try? transcriptionJobStore().delete(recordingID: target.id)
            if target.id == selectedRecording?.id {
                selectedRecording = nil
                transcriptText = ""
                transcriptSegments = []
                summaryText = ""
                selectedTranscriptionJob = nil
            }
            loadRecordings()
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
            copySummary()
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
        guard var job = job(for: recordingID),
              job.status == .queued || job.status == .running else { return }
        if job.status == .running {
            transcriptionQueueTask?.cancel()
        }
        job.markCancelled()
        do {
            try transcriptionJobStore().save(job)
            loadTranscriptionJobs()
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
        playbackPosition = audioPlayer.currentTime
        if !audioPlayer.isPlaying {
            audioPlayer.play()
            isPlaying = true
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
        workflowState = .summarizing
        statusMessage = "Summarizing"
        do {
            let decoded = try await aiService.summarize(transcript: transcript)
            _ = try library().writeSummary(decoded.markdown, for: selectedRecording)
            refreshSearchDocument(for: selectedRecording)
            if RecordingInteractionPolicy.shouldApplyAsyncResult(targetID: targetID, selectedID: self.selectedRecording?.id) {
                summaryText = decoded.markdown
            }
            workflowState = .saved
            statusMessage = "Summary ready"
        } catch {
            workflowState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    func copyTranscript() {
        copy(transcriptText)
    }

    func copySummary() {
        copy(summaryText)
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
            isPlaying = false
            statusMessage = "Playback paused"
        } else {
            audioPlayer.play()
            isPlaying = true
            statusMessage = "Playing \(selectedRecording.displayName)"
            startPlaybackTimer()
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        isPlaying = false
        playbackPosition = 0
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    func skipPlayback(by seconds: TimeInterval) {
        guard let audioPlayer else { return }
        audioPlayer.currentTime = min(max(0, audioPlayer.currentTime + seconds), audioPlayer.duration)
        playbackPosition = audioPlayer.currentTime
    }

    func seekPlayback(to seconds: TimeInterval) {
        guard let audioPlayer else { return }
        audioPlayer.currentTime = min(max(0, seconds), audioPlayer.duration)
        playbackPosition = audioPlayer.currentTime
    }

    func setPlaybackSpeed(_ speed: Double) {
        settings.playbackSpeed = [0.75, 1, 1.25, 1.5, 2].min(by: { abs($0 - speed) < abs($1 - speed) }) ?? 1
        audioPlayer?.enableRate = true
        audioPlayer?.rate = Float(settings.playbackSpeed)
        saveSettings()
    }

    func resetTrim() {
        trimStartSeconds = 0
        trimEndSeconds = selectedRecording?.durationSeconds ?? playbackDuration
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
        do { _ = try library().writeSummary(summaryText, for: recording) }
        catch { statusMessage = error.localizedDescription }
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
        if folderChanged {
            startLibraryWatcher()
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
            Task { @MainActor in
                guard let self, !self.workflowState.isRecording, !self.workflowState.isBusy else { return }
                self.loadRecordings()
            }
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
            refreshSetupHealth()
            statusMessage = "Saved API keys forgotten"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func testCredential(provider: AIProvider) async {
        guard !isTestingCredential else { return }
        isTestingCredential = true
        defer { isTestingCredential = false }

        let draft: String
        switch provider {
        case .elevenLabs:
            draft = elevenLabsKeyDraft
        case .openAI:
            draft = openAIKeyDraft
        }
        let key = APIKeyNormalizer.normalized(draft) ?? keyStore.apiKey(for: provider) ?? ""
        credentialStatusMessage = "Testing \(provider.displayName) key..."
        credentialStatusSeverity = .info
        let result = await credentialValidator.validate(provider: provider, apiKey: key)
        credentialStatusMessage = result.message
        credentialStatusSeverity = result.isValid ? .success : .error
        statusMessage = result.message
        refreshSetupHealth()
    }

    func refreshSetupHealth() {
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

        let openAIItem = SetupHealthItem(
            id: "openai",
            title: "OpenAI Key",
            detail: keyStore.apiKey(for: .openAI) == nil ? "Missing for summaries" : "Saved",
            severity: keyStore.apiKey(for: .openAI) == nil ? .info : .success,
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

        setupHealthItems = [microphoneItem, screenItem, elevenLabsItem, openAIItem, folderItem]
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
        guard !hasPendingTranscription(for: recording.id) else {
            statusMessage = "Transcription already queued"
            return false
        }
        let provider = settings.provider
        guard credentialAvailable(for: provider) else {
            statusMessage = "Add a \(provider.displayName) API key in Settings to transcribe."
            return false
        }

        let store = transcriptionJobStore()
        let previousAttemptCount = store.loadIfExists(recordingID: recording.id)?.attemptCount ?? 0
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
            autoTitleRequested: autoTitleRequested ?? settings.autoTitle
        )

        do {
            try store.save(job)
            loadTranscriptionJobs()
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
            loadTranscriptionJobs()
            guard var job = nextRunnableQueuedJob() else { break }

            if recoverPublishedJobIfPossible(&job) {
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
        guard let recording = recording(for: job) else {
            var failed = job
            failed.markFailed("Recording file is missing.")
            saveTranscriptionJob(failed)
            return
        }

        var running = job
        do {
            let recordingLibrary = library()
            let stableRecording = try recordingLibrary.migrateIfNeeded(recording)
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

            let decoded = try await aiService.transcribe(audioURL: prepared.url, provider: job.provider)
            try Task.checkCancellation()

            let service = aiService
            var titleGenerator: TranscriptPublisher.TitleGenerator?
            if service.canGenerateTitlesRemotely {
                titleGenerator = { transcript -> String? in try await service.generateTitle(transcript: transcript) }
            }
            let result = try await TranscriptPublisher.publish(
                job: running,
                recording: stableRecording,
                decoded: decoded,
                autoTitleRequested: job.autoTitleRequested,
                library: recordingLibrary,
                titleGenerator: titleGenerator,
                checkpoint: { [weak self] checkpointed in
                    running = checkpointed
                    self?.saveTranscriptionJob(checkpointed)
                }
            )
            applyPublishedTranscript(result, transcript: decoded.text, replacedExisting: job.replacingExistingTranscript)
            statusMessage = job.replacingExistingTranscript ? "Transcript refreshed" : "Transcript ready"
            if let title = result.generatedTitle {
                statusMessage += " · titled \u{201C}\(title)\u{201D}"
            }
        } catch is CancellationError {
            var cancelled = job
            cancelled.markCancelled()
            saveTranscriptionJob(cancelled)
            statusMessage = "Transcription cancelled"
        } catch {
            // A failure after the job was checkpointed as completed (e.g. a
            // summary-clear error) must not flip it back to failed.
            if running.status == .completed {
                loadRecordings()
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
    private func applyPublishedTranscript(_ result: TranscriptPublishResult, transcript: String, replacedExisting: Bool) {
        let finalRecording = result.recording
        loadRecordings()
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
            }
            updateExportPreview()
        }
    }

    private func loadTranscriptionJobs(markInterruptedRunning: Bool = false) {
        do {
            var jobs = try transcriptionJobStore().loadAll()
            if markInterruptedRunning {
                for index in jobs.indices where jobs[index].status == .running {
                    jobs[index].markInterruptedIfRunning()
                    try? transcriptionJobStore().save(jobs[index])
                }
            }
            transcriptionJobs = jobs
            if let selectedRecording {
                selectedTranscriptionJob = jobs.first { $0.recordingID == selectedRecording.id }
            } else {
                selectedTranscriptionJob = nil
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func saveTranscriptionJob(_ job: TranscriptionJob) {
        try? transcriptionJobStore().save(job)
        loadTranscriptionJobs()
    }

    /// Completes a job whose transcript was already written before the app
    /// stopped (SHA-256 checkpoint), including the skipped side effects.
    private func recoverPublishedJobIfPossible(_ job: inout TranscriptionJob) -> Bool {
        guard job.transcriptContentSHA256 != nil,
              let recording = recording(for: job),
              let result = TranscriptPublisher.recoverIfPublished(job: job, recording: recording, library: library())
        else { return false }
        job = result.job
        let transcript = readTextIfExists(at: result.recording.transcriptURL)
        applyPublishedTranscript(result, transcript: transcript, replacedExisting: job.replacingExistingTranscript)
        return true
    }

    private func job(for recordingID: UUID) -> TranscriptionJob? {
        transcriptionJobs.first { $0.recordingID == recordingID }
            ?? transcriptionJobStore().loadIfExists(recordingID: recordingID)
    }

    private func hasPendingTranscription(for recordingID: UUID) -> Bool {
        guard let job = job(for: recordingID) else { return false }
        return job.status == .queued || job.status == .running
    }

    private func recording(for job: TranscriptionJob) -> RecordingItem? {
        if let recording = recordings.first(where: { $0.id == job.recordingID }) {
            return recording
        }
        return (try? library().loadRecordings())?.first { $0.id == job.recordingID }
    }

    private func performRecordingAction(_ operation: () async -> Void) async {
        guard !recordingActionInFlight else { return }
        recordingActionInFlight = true
        defer { recordingActionInFlight = false }
        await operation()
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
            reviewWaveform = []
            exportPreview = ""
            return
        }
        let recordingLibrary = library()
        transcriptText = (try? String(contentsOf: selectedRecording.transcriptURL, encoding: .utf8)) ?? ""
        let savedSegments = recordingLibrary.loadTranscriptSegments(for: selectedRecording)
        transcriptSegments = savedSegments.isEmpty ? TranscriptParser.segments(from: transcriptText) : savedSegments
        summaryText = (try? String(contentsOf: selectedRecording.summaryURL, encoding: .utf8)) ?? ""
        trimStartSeconds = 0
        trimEndSeconds = selectedRecording.durationSeconds
        transcriptSaveMessage = ""
        updateExportPreview()
        waveformTask?.cancel()
        let targetID = selectedRecording.id
        let audioURL = selectedRecording.audioURL
        waveformTask = Task { [weak self] in
            guard let self else { return }
            if let samples = try? await waveformAnalyzer.samples(for: audioURL, bucketCount: 96), !Task.isCancelled {
                await MainActor.run {
                    if self.selectedRecording?.id == targetID { self.reviewWaveform = samples }
                }
            }
        }
        selectedTranscriptionJob = loadTranscriptionJobForSelection(selectedRecording)
        preparePlayback(for: selectedRecording)
    }

    private func makeSearchDocuments(for recordings: [RecordingItem]) -> [RecordingSearchDocument] {
        recordings.map(makeSearchDocument)
    }

    private func makeSearchDocument(for recording: RecordingItem) -> RecordingSearchDocument {
        RecordingSearchDocument(
            recording: recording,
            transcriptText: readTextIfExists(at: recording.transcriptURL),
            summaryText: readTextIfExists(at: recording.summaryURL)
        )
    }

    private func refreshSearchDocument(for recording: RecordingItem) {
        let document = makeSearchDocument(for: recording)
        if let index = recordingSearchDocuments.firstIndex(where: { $0.recording.id == recording.id }) {
            recordingSearchDocuments[index] = document
        } else {
            recordingSearchDocuments.insert(document, at: 0)
        }
    }

    private func readTextIfExists(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func loadTranscriptionJobForSelection(_ recording: RecordingItem) -> TranscriptionJob? {
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

    private func confidenceReportForImportedRecording(url: URL, duration: TimeInterval) async -> RecordingConfidenceReport {
        do {
            var report = try await RecordingConfidenceAnalyzer.analyze(
                audioURL: url,
                source: .microphone,
                expectedChannels: [.microphone: 1],
                minimumDuration: 1,
                silenceThreshold: 0.01
            )
            report.issues.append(importedSourceIssue)
            return report
        } catch {
            return RecordingConfidenceReport(
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
            )
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
            playbackDuration = player.duration
            playbackPosition = 0
        } catch {
            audioPlayer = nil
            playbackDuration = 0
            playbackPosition = 0
            statusMessage = "Could not load audio: \(error.localizedDescription)"
        }
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let audioPlayer = self.audioPlayer else { return }
                self.playbackPosition = audioPlayer.currentTime
                self.playbackDuration = audioPlayer.duration
                if !audioPlayer.isPlaying {
                    self.isPlaying = false
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
                self.recordingElapsed = recordingSessionClock.activeDuration(at: Date())
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func updateFallbackInputLevel(_ level: Float) {
        let clamped = min(1, max(0, level))
        inputLevel = clamped
        waveform.append(clamped)
    }

    private func updateSourceLevel(_ channel: AudioSignalChannel, _ level: Float) {
        let clamped = min(1, max(0, level))
        switch channel {
        case .microphone:
            microphoneLevel = clamped
            microphonePeakDuringRecording = max(microphonePeakDuringRecording, clamped)
        case .system:
            systemLevel = clamped
            systemPeakDuringRecording = max(systemPeakDuringRecording, clamped)
        }
        inputLevel = max(microphoneLevel, systemLevel)
        waveform.append(inputLevel)
    }

    private func resetSignalLevels() {
        microphoneLevel = 0
        systemLevel = 0
        inputLevel = 0
        waveform.reset()
    }

    private func clearRecordingSession() {
        recordingSessionClock = nil
        temporaryAudioURL = nil
        completedSegmentURLs = []
        currentSessionManifest = nil
        currentSessionSource = nil
        currentSessionName = nil
        microphonePeakDuringRecording = 0
        systemPeakDuringRecording = 0
        recordingElapsed = 0
        endSleepPrevention()
    }

    private func installPowerObservers() {
        guard powerObserverTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let willSleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.suspendForSystemSleep()
            }
        }
        let didWake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.recoverInterruptedRecordings()
            }
        }
        let willTerminate = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushTranscriptEdits()
                self?.flushSummaryEdits()
            }
        }
        powerObserverTokens = [willSleep, didWake, willTerminate]
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
