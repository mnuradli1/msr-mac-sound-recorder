import AppKit
import AVFoundation
import Foundation
import SwiftUI
import MSRCore
import MSRServices

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
    @Published var credentialStatusMessage = ""
    @Published var isTestingCredential = false
    @Published var localAPIStatusMessage = ""
    @Published var recoveryMessage = ""

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
    private var currentSessionSource: AudioSource?
    private var currentSessionName: String?
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var recordingTimer: Timer?
    private var recordingActionInFlight = false
    private var powerObserverTokens: [NSObjectProtocol] = []
    private var sleepPreventionActivity: NSObjectProtocol?

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
        await recoverInterruptedRecordings()
    }

    func loadRecordings() {
        do {
            recordings = try library().loadRecordings()
            if let selectedRecording,
               let refreshed = recordings.first(where: { $0.id == selectedRecording.id }) {
                self.selectedRecording = refreshed
            } else {
                selectedRecording = recordings.first
            }
            loadSelectedSidecars()
        } catch {
            statusMessage = error.localizedDescription
            workflowState = .failed(error.localizedDescription)
        }
    }

    func select(_ recording: RecordingItem) {
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
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
        guard !recordingActionInFlight, !isRecording, !workflowState.isBusy else { return }
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
                statusMessage = recoveryMessage
                workflowState = .saved
            } else if results.contains(where: {
                if case .failed = $0.status { return true }
                return false
            }) {
                recoveryMessage = "Some interrupted recording files could not be recovered."
                statusMessage = recoveryMessage
                workflowState = selectedRecording == nil ? .ready : .saved
            } else {
                recoveryMessage = ""
                workflowState = previousState == .recovering ? (selectedRecording == nil ? .ready : .saved) : previousState
                if statusMessage == "Checking interrupted recordings" {
                    statusMessage = selectedRecording == nil ? "Ready" : "Recording selected"
                }
            }
        } catch {
            workflowState = .failed(error.localizedDescription)
            recoveryMessage = "Recovery failed: \(error.localizedDescription)"
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
        resetSignalLevels()
        stopPlayback()

        do {
            let startedAt = Date()
            let temporaryURL = try makeTemporaryAudioURL()
            temporaryAudioURL = temporaryURL
            try await recorder.start(source: source, outputURL: temporaryURL)
            recordingSessionClock = RecordingSessionClock(startedAt: startedAt)
            completedSegmentURLs = []
            currentSessionSource = source
            currentSessionName = defaultMeetingName(for: startedAt)
            workflowState = .recording(source: source)
            recordingElapsed = 0
            startRecordingTimer()
            beginSleepPrevention()
            statusMessage = "Recording \(source.displayName)"
        } catch {
            workflowState = .failed(error.localizedDescription)
            temporaryAudioURL = nil
            recordingSessionClock = nil
            completedSegmentURLs = []
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
            let temporaryURL = try makeTemporaryAudioURL()
            temporaryAudioURL = temporaryURL
            try await recorder.start(source: source, outputURL: temporaryURL)
            let resumedAt = Date()
            clock.resume(at: resumedAt)
            recordingSessionClock = clock
            workflowState = .recording(source: source)
            startRecordingTimer()
            beginSleepPrevention()
            statusMessage = "Recording \(source.displayName)"
        } catch {
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
            completedSegmentURLs.append(temporaryAudioURL)
            self.temporaryAudioURL = nil
            let pausedAt = Date()
            clock.pause(at: pausedAt, reason: reason)
            recordingSessionClock = clock
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
                completedSegmentURLs.append(temporaryAudioURL)
                self.temporaryAudioURL = nil
                finalizedClock.pause(at: Date(), reason: .manual)
            }
            endSleepPrevention()
            let segmentURLs = completedSegmentURLs
            guard !segmentURLs.isEmpty else {
                throw RecordingSessionError.noCapturedSegments
            }
            let endedAt = Date()
            let finalTemporaryURL: URL
            if segmentURLs.count == 1, let onlySegment = segmentURLs.first {
                finalTemporaryURL = onlySegment
            } else {
                finalTemporaryURL = try makeFinalTemporaryAudioURL()
                try await AudioTrackMixer.concatenateToSingleM4A(inputs: segmentURLs, outputURL: finalTemporaryURL)
            }
            let recording = try library().finishRecording(
                temporaryAudioURL: finalTemporaryURL,
                requestedName: currentSessionName ?? defaultMeetingName(for: finalizedClock.startedAt),
                source: source,
                startedAt: finalizedClock.startedAt,
                endedAt: endedAt,
                durationSecondsOverride: finalizedClock.activeDuration(at: endedAt),
                segmentCount: max(1, segmentURLs.count)
            )
            if segmentURLs.count > 1 {
                for url in segmentURLs {
                    try? FileManager.default.removeItem(at: url)
                }
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
            resetSignalLevels()
            statusMessage = error.localizedDescription
        }
    }

    func startRename(_ recording: RecordingItem? = nil) {
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
        let target = recording ?? selectedRecording
        guard let target else { return }
        do {
            if target.id == selectedRecording?.id {
                stopPlayback()
            }
            try library().delete(target)
            if target.id == selectedRecording?.id {
                selectedRecording = nil
                transcriptText = ""
                summaryText = ""
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
        guard let selectedRecording, !workflowState.isBusy, !isRecording else { return }
        transcriptionStartedAt = Date()
        workflowState = .transcribing
        statusMessage = replacingExistingTranscript
            ? "Re-transcribing with \(settings.provider.displayName)"
            : "Transcribing with \(settings.provider.displayName)"
        do {
            let request = TranscribeRequest(
                audioPath: selectedRecording.audioURL.path,
                provider: settings.provider
            )
            let response = try await proxy.handle(
                method: "POST",
                path: "/transcribe",
                body: JSONEncoder().encode(request)
            )
            let decoded = try JSONDecoder().decode(TranscribeResponse.self, from: response.body)
            transcriptText = decoded.text
            try library().writeTranscript(decoded.text, for: selectedRecording)
            if replacingExistingTranscript {
                try library().clearSummary(for: selectedRecording)
                summaryText = ""
            }
            transcriptionStartedAt = nil
            workflowState = .saved
            statusMessage = replacingExistingTranscript ? "Transcript refreshed" : "Transcript ready"
        } catch {
            transcriptionStartedAt = nil
            workflowState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    func retranscribeSelected() async {
        await transcribeSelected(replacingExistingTranscript: true)
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
        guard let selectedRecording, !workflowState.isBusy, !isRecording else { return }
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
            summaryText = decoded.markdown
            try library().writeSummary(decoded.markdown, for: selectedRecording)
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
        let result = await credentialValidator.validate(provider: provider, apiKey: key)
        credentialStatusMessage = result.message
        statusMessage = result.message
    }

    private func performRecordingAction(_ operation: () async -> Void) async {
        guard !recordingActionInFlight else { return }
        recordingActionInFlight = true
        defer { recordingActionInFlight = false }
        await operation()
    }

    private func makeTemporaryAudioURL() throws -> URL {
        let folder = recordingsFolderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(".in-progress-\(UUID().uuidString).m4a")
    }

    private func makeFinalTemporaryAudioURL() throws -> URL {
        let folder = recordingsFolderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(".final-\(UUID().uuidString).m4a")
    }

    private func library() -> RecordingLibrary {
        RecordingLibrary(folderURL: recordingsFolderURL)
    }

    private func loadSelectedSidecars() {
        guard let selectedRecording else {
            transcriptText = ""
            summaryText = ""
            return
        }
        transcriptText = (try? String(contentsOf: selectedRecording.transcriptURL, encoding: .utf8)) ?? ""
        summaryText = (try? String(contentsOf: selectedRecording.summaryURL, encoding: .utf8)) ?? ""
        preparePlayback(for: selectedRecording)
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
        case .system:
            systemLevel = clamped
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
        currentSessionSource = nil
        currentSessionName = nil
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

    var errorDescription: String? {
        switch self {
        case .noCapturedSegments:
            return "No captured audio segments were available to save."
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
