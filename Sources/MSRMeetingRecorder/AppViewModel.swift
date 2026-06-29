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
    @Published var credentialStatusMessage = ""
    @Published var isTestingCredential = false
    @Published var localAPIStatusMessage = ""

    private let settingsStore = UserDefaultsSettingsStore()
    private let keyStore = APIKeyStore()
    private let credentialValidator = CredentialValidator()
    private let recorder: AudioRecording
    private let aiService: ProviderAIService
    private let proxy: LocalAPIProxy
    private var localServer: LocalHTTPServer?
    private var recordingStartedAt: Date?
    private var temporaryAudioURL: URL?
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var recordingTimer: Timer?

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
        if isRecording {
            return true
        }
        return !workflowState.isBusy
    }

    var recordingButtonTitle: String {
        switch workflowState {
        case .starting:
            return "Starting..."
        case .recording:
            return "Stop Recording"
        case .finalizing:
            return "Finalizing..."
        case .ready, .saved, .failed, .transcribing, .summarizing:
            return "Record"
        }
    }

    var recordingButtonSystemImage: String {
        isRecording ? "stop.circle.fill" : "record.circle"
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
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func startRecording() async {
        guard canToggleRecording, !isRecording else { return }
        let source = selectedSource
        workflowState = .starting(source: source)
        statusMessage = "Starting \(source.displayName)"
        resetSignalLevels()
        stopPlayback()

        do {
            let folder = recordingsFolderURL
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temporaryURL = folder.appendingPathComponent(".in-progress-\(UUID().uuidString).m4a")
            temporaryAudioURL = temporaryURL
            try await recorder.start(source: source, outputURL: temporaryURL)
            recordingStartedAt = Date()
            workflowState = .recording(source: source)
            recordingElapsed = 0
            startRecordingTimer()
            statusMessage = "Recording \(source.displayName)"
        } catch {
            workflowState = .failed(error.localizedDescription)
            recordingStartedAt = nil
            temporaryAudioURL = nil
            resetSignalLevels()
            statusMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard isRecording,
              let startedAt = recordingStartedAt,
              let temporaryAudioURL,
              let source = workflowState.lockedSource else {
            return
        }

        workflowState = .finalizing(source: source)
        statusMessage = "Finalizing recording"
        stopRecordingTimer()

        do {
            try await recorder.stop()
            let recording = try library().finishRecording(
                temporaryAudioURL: temporaryAudioURL,
                requestedName: defaultMeetingName(for: startedAt),
                source: source,
                startedAt: startedAt,
                endedAt: Date()
            )
            recordingStartedAt = nil
            self.temporaryAudioURL = nil
            resetSignalLevels()
            loadRecordings()
            selectedRecording = recording
            loadSelectedSidecars()
            preparePlayback(for: recording)
            workflowState = .saved
            statusMessage = "Recording saved"
        } catch {
            workflowState = .failed(error.localizedDescription)
            recordingStartedAt = nil
            self.temporaryAudioURL = nil
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
            workflowState = .saved
            statusMessage = replacingExistingTranscript ? "Transcript refreshed" : "Transcript ready"
        } catch {
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
                guard let self, let recordingStartedAt = self.recordingStartedAt else { return }
                self.recordingElapsed = Date().timeIntervalSince(recordingStartedAt)
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
