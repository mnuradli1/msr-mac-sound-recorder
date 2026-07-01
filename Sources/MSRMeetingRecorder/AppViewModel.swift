import AppKit
import AVFoundation
import CoreGraphics
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
    @Published var selectedRecording: RecordingItem?
    @Published var selectedSource: AudioSource = .micAndSystem
    @Published var settings: AppSettings
    @Published var workflowState: RecordingWorkflowState = .ready
    @Published var statusMessage = "Ready"
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
    @Published var setupHealthItems: [SetupHealthItem] = []
    @Published var credentialStatusMessage = ""
    @Published var credentialStatusSeverity: AppNoticeSeverity = .info
    @Published var isTestingCredential = false
    @Published var localAPIStatusMessage = ""
    @Published var recoveryMessage = ""
    @Published var recoveryNoticeSeverity: AppNoticeSeverity = .info
    @Published private var recordingSearchDocuments: [RecordingSearchDocument] = []

    private let settingsStore = UserDefaultsSettingsStore()
    private let keyStore = APIKeyStore()
    private let credentialValidator = CredentialValidator()
    private let recorder: AudioRecording
    private let aiService: ProviderAIService
    private let proxy: LocalAPIProxy
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

    init(recorder: AudioRecording = MeetingAudioRecorder()) {
        settings = settingsStore.load()
        self.recorder = recorder
        aiService = ProviderAIService(keyStore: keyStore)
        proxy = LocalAPIProxy(aiService: aiService)
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
        RecordingSearch.filter(recordingSearchDocuments, query: recordingSearchQuery).map(\.recording)
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

    func startLocalAPI() {
        guard localServer == nil else { return }
        let server = LocalHTTPServer(proxy: proxy)
        do {
            try server.start()
            localServer = server
            localAPIStatusMessage = "Local API running on 127.0.0.1:\(server.port)"
            if statusMessage.hasPrefix("Local API") {
                statusMessage = "Ready"
            }
        } catch {
            localAPIStatusMessage = "Local API could not start: \(error.localizedDescription)"
            statusMessage = localAPIStatusMessage
        }
    }

    func bootstrap() async {
        installPowerObservers()
        loadRecordings()
        loadTranscriptionJobs(markInterruptedRunning: true)
        refreshSetupHealth()
        processTranscriptionQueueIfNeeded()
        await recoverInterruptedRecordings()
    }

    func loadRecordings() {
        do {
            recordings = try library().loadRecordings()
            recordingSearchDocuments = makeSearchDocuments(for: recordings)
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
    }

    func select(_ recording: RecordingItem) {
        guard RecordingInteractionPolicy.canSelectHistory(during: workflowState) else {
            statusMessage = workflowState.isPaused
                ? "Save or resume the paused recording first."
                : "Finish the current task first."
            return
        }
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
            settings.recordingsFolderPath = url.path
            saveSettings()
            loadRecordings()
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
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .movie]
        panel.directoryURL = recordingsFolderURL
        panel.message = "Choose an audio or video file to import for transcription."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importRecording(from: url) }
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
                await self.finalizeRecordingSession()
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
            await self.finalizeRecordingSession()
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
                await self.finalizeRecordingSession()
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
        resetSignalLevels()
        microphonePeakDuringRecording = 0
        systemPeakDuringRecording = 0
        stopPlayback()

        do {
            let startedAt = Date()
            let temporaryURL = try makeTemporaryAudioURL(source: source)
            let requestedName = defaultMeetingName(for: startedAt)
            let manifest = RecordingSessionManifest(
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
            recordingSessionClock = RecordingSessionClock(startedAt: startedAt)
            completedSegmentURLs = []
            currentSessionSource = source
            currentSessionName = requestedName
            workflowState = .recording(source: source)
            recordingElapsed = 0
            startRecordingTimer()
            beginSleepPrevention()
            statusMessage = "Recording \(source.displayName)"
        } catch {
            if let currentSessionManifest {
                try? manifestStore().delete(currentSessionManifest)
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
            clock.resume(at: resumedAt)
            recordingSessionClock = clock
            currentSessionManifest = manifest
            workflowState = .recording(source: source)
            startRecordingTimer()
            beginSleepPrevention()
            statusMessage = "Recording \(source.displayName)"
        } catch {
            if let currentSessionManifest {
                try? manifestStore().save(currentSessionManifest)
            }
            workflowState = .paused(source: source, reason: clock.pauseReason ?? .manual)
            temporaryAudioURL = nil
            resetSignalLevels()
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
                silenceThreshold: 0.01
            )
            let recording = try library().finishRecording(
                temporaryAudioURL: finalTemporaryURL,
                requestedName: currentSessionName ?? defaultMeetingName(for: finalizedClock.startedAt),
                source: source,
                startedAt: finalizedClock.startedAt,
                endedAt: endedAt,
                durationSecondsOverride: finalizedClock.activeDuration(at: endedAt),
                segmentCount: max(1, segmentURLs.count),
                confidenceReport: confidenceReport
            )
            if segmentURLs.count > 1 {
                for url in segmentURLs {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            if let currentSessionManifest {
                try? manifestStore().delete(currentSessionManifest)
            }
            clearRecordingSession()
            resetSignalLevels()
            loadRecordings()
            selectedRecording = recordings.first(where: { $0.id == recording.id }) ?? recording
            loadSelectedSidecars()
            preparePlayback(for: recording)
            workflowState = .saved
            statusMessage = segmentURLs.count > 1 ? "Recording saved from \(segmentURLs.count) segments" : "Recording saved"
        } catch {
            endSleepPrevention()
            workflowState = .failed(error.localizedDescription)
            recoveryMessage = "Could not finalize cleanly. Recovery will retry on next launch."
            recoveryNoticeSeverity = .error
            resetSignalLevels()
            statusMessage = error.localizedDescription
        }
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
            let response = try await proxy.handle(
                method: "POST",
                path: "/summarize",
                body: JSONEncoder().encode(SummarizeRequest(transcript: transcript))
            )
            let decoded = try JSONDecoder().decode(SummarizeResponse.self, from: response.body)
            try library().writeSummary(decoded.markdown, for: selectedRecording)
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

    func saveSettings() {
        settingsStore.save(settings)
        refreshSetupHealth()
    }

    func saveAPIKeys() {
        do {
            if !elevenLabsKeyDraft.isEmpty {
                try keyStore.save(apiKey: elevenLabsKeyDraft, for: .elevenLabs)
                elevenLabsKeyDraft = ""
            }
            if !openAIKeyDraft.isEmpty {
                try keyStore.save(apiKey: openAIKeyDraft, for: .openAI)
                openAIKeyDraft = ""
            }
            saveSettings()
            statusMessage = "Settings saved"
        } catch {
            workflowState = .failed(error.localizedDescription)
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

    private func enqueueTranscription(recording: RecordingItem, replacingExistingTranscript: Bool) {
        guard RecordingInteractionPolicy.canSelectHistory(during: workflowState) else { return }
        guard !hasPendingTranscription(for: recording.id) else {
            statusMessage = "Transcription already queued"
            return
        }

        let store = transcriptionJobStore()
        let previousAttemptCount = store.loadIfExists(recordingID: recording.id)?.attemptCount ?? 0
        let job = TranscriptionJob.queue(
            recordingID: recording.id,
            recordingName: recording.displayName,
            audioFileName: recording.audioURL.lastPathComponent,
            provider: settings.provider,
            replacingExistingTranscript: replacingExistingTranscript,
            previousAttemptCount: previousAttemptCount
        )

        do {
            try store.save(job)
            loadTranscriptionJobs()
            statusMessage = replacingExistingTranscript ? "Re-transcription queued" : "Transcription queued"
            processTranscriptionQueueIfNeeded()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func processTranscriptionQueueIfNeeded() {
        guard transcriptionQueueTask == nil else { return }
        guard transcriptionJobs.contains(where: { $0.status == .queued }) else { return }
        transcriptionQueueTask = Task { [weak self] in
            await self?.runTranscriptionQueue()
        }
    }

    private func runTranscriptionQueue() async {
        defer {
            transcriptionQueueTask = nil
            transcriptionStartedAt = nil
            if transcriptionJobs.contains(where: { $0.status == .queued }) {
                processTranscriptionQueueIfNeeded()
            }
        }

        while !Task.isCancelled {
            loadTranscriptionJobs()
            guard var job = transcriptionJobs
                .filter({ $0.status == .queued })
                .sorted(by: { $0.updatedAt < $1.updatedAt })
                .first else {
                break
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

        do {
            let request = TranscribeRequest(
                audioPath: recording.audioURL.path,
                provider: job.provider
            )
            let response = try await proxy.handle(
                method: "POST",
                path: "/transcribe",
                body: JSONEncoder().encode(request)
            )
            try Task.checkCancellation()
            let decoded = try JSONDecoder().decode(TranscribeResponse.self, from: response.body)
            let segments = decoded.segments.isEmpty
                ? TranscriptParser.segments(from: decoded.text)
                : decoded.segments
            try library().writeTranscript(decoded.text, for: recording)
            try library().writeTranscriptSegments(segments, for: recording)
            if job.replacingExistingTranscript {
                try library().clearSummary(for: recording)
            }
            refreshSearchDocument(for: recording)

            var completed = job
            completed.markCompleted(transcriptFileName: recording.transcriptURL.lastPathComponent)
            saveTranscriptionJob(completed)
            if RecordingInteractionPolicy.shouldApplyAsyncResult(targetID: recording.id, selectedID: selectedRecording?.id) {
                transcriptText = decoded.text
                transcriptSegments = segments
                selectedTranscriptionJob = completed
                if job.replacingExistingTranscript {
                    summaryText = ""
                }
            }
            statusMessage = job.replacingExistingTranscript ? "Transcript refreshed" : "Transcript ready"
        } catch is CancellationError {
            var cancelled = job
            cancelled.markCancelled()
            saveTranscriptionJob(cancelled)
            statusMessage = "Transcription cancelled"
        } catch {
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

    private func library() -> RecordingLibrary {
        RecordingLibrary(folderURL: recordingsFolderURL)
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
            return
        }
        let recordingLibrary = library()
        transcriptText = (try? String(contentsOf: selectedRecording.transcriptURL, encoding: .utf8)) ?? ""
        let savedSegments = recordingLibrary.loadTranscriptSegments(for: selectedRecording)
        transcriptSegments = savedSegments.isEmpty ? TranscriptParser.segments(from: transcriptText) : savedSegments
        summaryText = (try? String(contentsOf: selectedRecording.summaryURL, encoding: .utf8)) ?? ""
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
        powerObserverTokens = [willSleep, didWake]
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

    var errorDescription: String? {
        switch self {
        case .noCapturedSegments:
            return "No captured audio segments were available to save."
        case let .missingCapturedSegment(fileName):
            return "A recorded audio segment is missing: \(fileName). Recovery will retry on next launch."
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
