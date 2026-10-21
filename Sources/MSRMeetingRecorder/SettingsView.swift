import AppKit
import SwiftUI
import MSRCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case transcription
    case advanced
    case health

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .transcription: "Transcription & AI"
        case .advanced: "Advanced"
        case .health: "Setup Health"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .transcription: "text.quote"
        case .advanced: "slider.horizontal.3"
        case .health: "checkmark.shield"
        }
    }

    static var initial: SettingsTab {
        UISnapshotCapture.requestedSettingsTab.flatMap(SettingsTab.init(rawValue:)) ?? .general
    }
}

/// Settings window (hosted in a fixed ~560×560 window created by
/// `AppViewModel.openSettingsWindow()`), organized in tabs. Every binding and
/// action from the previous flat form is preserved.
struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var selection = SettingsTab.initial

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $selection) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("msr.settings.tabs")
            .padding(.top, 14)
            .padding(.bottom, 2)

            Group {
                switch selection {
                case .general: GeneralSettingsTab(viewModel: viewModel)
                case .transcription: TranscriptionSettingsTab(viewModel: viewModel)
                case .advanced: AdvancedSettingsTab(viewModel: viewModel)
                case .health: SetupHealthSettingsTab(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 560)
        .environment(\.locale, preferredLocale)
        .background(SettingsWindowAppearance(theme: viewModel.settings.theme))
        .onChange(of: viewModel.settings) { _, _ in viewModel.scheduleSettingsSave() }
    }

    private var preferredLocale: Locale {
        switch viewModel.settings.language {
        case .system: .current
        case .english: Locale(identifier: "en")
        case .indonesian: Locale(identifier: "id")
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Recordings Folder") {
                    HStack(spacing: 6) {
                        TextField("Recordings Folder", text: Binding(
                            get: { viewModel.recordingsFolderURL.path },
                            set: { viewModel.settings.recordingsFolderPath = $0 }
                        ))
                        .labelsHidden()
                        .truncationMode(.middle)
                        Button {
                            viewModel.chooseRecordingsFolder()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Choose recordings folder")
                        .accessibilityLabel("Choose recordings folder")
                    }
                }
            }

            Section("Capture") {
                Picker("Default source", selection: $viewModel.settings.preferredSource) {
                    ForEach(AudioSource.allCases) { source in Text(LocalizedStringKey(source.displayName)).tag(source) }
                }
                Picker("Microphone", selection: Binding(
                    get: { viewModel.settings.microphoneDeviceID ?? "" },
                    set: { viewModel.settings.microphoneDeviceID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("System Default").tag("")
                    ForEach(viewModel.microphoneDevices) { device in
                        Text(device.isDefault ? "\(device.name) (Default)" : device.name).tag(device.id)
                    }
                }
                LabeledContent("System audio") {
                    Text("All Mac system audio via ScreenCaptureKit")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Silence threshold") {
                    HStack {
                        Slider(value: $viewModel.settings.silenceThreshold, in: 0.001...0.05)
                            .labelsHidden()
                            .accessibilityLabel("Silence threshold")
                        Text(viewModel.settings.silenceThreshold, format: .number.precision(.fractionLength(3)))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Library & Playback") {
                Picker("Default sort", selection: $viewModel.settings.sortOrder) {
                    ForEach(RecordingSortOrder.allCases) { order in Text(LocalizedStringKey(order.displayName)).tag(order) }
                }
                Picker("Playback speed", selection: $viewModel.settings.playbackSpeed) {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                        Text("\(speed, specifier: "%g")×").tag(speed)
                    }
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $viewModel.settings.theme) {
                    ForEach(AppTheme.allCases) { theme in Text(LocalizedStringKey(theme.displayName)).tag(theme) }
                }
                Picker("Language", selection: $viewModel.settings.language) {
                    ForEach(AppLanguage.allCases) { language in Text(LocalizedStringKey(language.displayName)).tag(language) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Transcription & AI

private struct TranscriptionSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var lastTestedCredential: CredentialProvider?

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $viewModel.settings.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(LocalizedStringKey(provider.displayName)).tag(provider)
                    }
                }
                Picker("Transcription language", selection: $viewModel.settings.transcriptionLanguage) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.displayName)).tag(language)
                    }
                }
                .help("The spoken language of your meetings. Automatic lets the provider detect it.")
                .accessibilityIdentifier("msr.settings.transcriptionLanguage")
                Toggle("Compress large/uncompressed uploads", isOn: $viewModel.settings.compressUploads)
                    .accessibilityIdentifier("msr.settings.compressUploads")
                Toggle("Auto-title recordings from the transcript", isOn: $viewModel.settings.autoTitle)
                    .accessibilityIdentifier("msr.settings.autoTitle")
                Toggle("Auto-transcribe new recordings", isOn: $viewModel.settings.autoTranscribe)
                    .accessibilityIdentifier("msr.settings.autoTranscribe")
            } header: {
                Text("Transcription")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.settings.autoTranscribe
                        ? (viewModel.autoTranscribeIsEffective
                            ? "Each finished recording is queued for transcription right away. With auto-title on, the recording is renamed from its transcript unless you rename it yourself."
                            : "Auto-transcribe is on, but no API key is saved for the selected provider. Add one below.")
                        : "Transcription starts when you press Transcribe. Turn this on to queue every finished recording automatically.")
                    if viewModel.settings.autoTitle {
                        Text("With an OpenAI or DeepSeek key saved, the beginning of each transcript is sent to that provider to name the recording; without one the title is generated on this Mac.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Summary provider", selection: $viewModel.settings.summaryProvider) {
                    ForEach(TextModelProvider.allCases) { provider in
                        Text(LocalizedStringKey(provider.displayName)).tag(provider)
                    }
                }
                .accessibilityIdentifier("msr.settings.summaryProvider")
                Toggle("Auto-summarize after transcription", isOn: Binding(
                    // Reads as off while no summary key exists; the setting itself is kept.
                    get: { viewModel.settings.autoSummarize && viewModel.canSummarize },
                    set: { viewModel.settings.autoSummarize = $0 }
                ))
                .disabled(!viewModel.canSummarize)
                .accessibilityIdentifier("msr.settings.autoSummarize")
            } header: {
                Text("Summary")
            } footer: {
                summaryFooter
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                credentialRow(
                    title: "ElevenLabs API Key",
                    credential: .elevenLabs,
                    draft: $viewModel.elevenLabsKeyDraft,
                    testTitle: "Test ElevenLabs Key"
                )
                credentialRow(
                    title: "OpenAI API Key",
                    credential: .openAI,
                    draft: $viewModel.openAIKeyDraft,
                    testTitle: "Test OpenAI Key"
                )
                credentialRow(
                    title: "DeepSeek API Key",
                    credential: .deepSeek,
                    draft: $viewModel.deepSeekKeyDraft,
                    testTitle: "Test DeepSeek Key",
                    fieldIdentifier: "msr.settings.deepSeekKey",
                    testIdentifier: "msr.settings.testDeepSeek"
                )
                Toggle("Remember credentials in Keychain", isOn: $viewModel.settings.rememberCredentials)
            } header: {
                Text("API Keys")
            } footer: {
                Text("ElevenLabs transcribes by default. OpenAI or DeepSeek writes summaries and titles; OpenAI can also transcribe.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Forget Saved Keys", role: .destructive) {
                        viewModel.forgetAPIKeys()
                    }
                    Spacer()
                    Button("Save Keys") {
                        viewModel.saveAPIKeys()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.elevenLabsKeyDraft.isEmpty && viewModel.openAIKeyDraft.isEmpty
                        && viewModel.deepSeekKeyDraft.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var summaryFooter: some View {
        if let provider = viewModel.resolvedSummaryProvider {
            VStack(alignment: .leading, spacing: 4) {
                if viewModel.settings.autoSummarize {
                    Text("After each transcription, the transcript is sent to \(provider.displayName) for a summary.")
                } else {
                    Text("Summaries use \(provider.displayName). Turn this on to summarize every new transcript automatically.")
                }
                if provider != viewModel.settings.summaryProvider {
                    Text("No \(viewModel.settings.summaryProvider.displayName) key is saved, so \(provider.displayName) is used.")
                }
            }
        } else {
            Text("Requires an OpenAI or DeepSeek API key.")
        }
    }

    @ViewBuilder
    private func credentialRow(
        title: LocalizedStringKey,
        credential: CredentialProvider,
        draft: Binding<String>,
        testTitle: LocalizedStringKey,
        fieldIdentifier: String? = nil,
        testIdentifier: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                Spacer()
                credentialStatus(credential)
            }
            SecureField(title, text: draft, prompt: Text("Paste a key to save or replace it"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityIdentifier(fieldIdentifier ?? "msr.settings.\(credential.rawValue)Key")
            HStack(spacing: 8) {
                Button(testTitle) {
                    lastTestedCredential = credential
                    Task { await viewModel.testCredential(credential: credential) }
                }
                .controlSize(.small)
                .disabled(viewModel.isTestingCredential)
                .accessibilityIdentifier(testIdentifier ?? "msr.settings.test\(credential.displayName)")
                if viewModel.isTestingCredential, lastTestedCredential == credential {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            if lastTestedCredential == credential, !viewModel.credentialStatusMessage.isEmpty, !viewModel.isTestingCredential {
                Label {
                    Text.uiString(viewModel.credentialStatusMessage)
                        .textSelection(.enabled)
                        .lineLimit(3)
                } icon: {
                    Image(systemName: viewModel.credentialStatusSeverity.iconName)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(viewModel.credentialStatusSeverity.foregroundColor)
            }
        }
        .padding(.vertical, 2)
    }

    /// Saved/Missing chip. A missing ElevenLabs key is a warning (it is the
    /// default transcription provider); OpenAI and DeepSeek are optional.
    private func credentialStatus(_ credential: CredentialProvider) -> some View {
        let saved = viewModel.hasSavedCredential(credential)
        return StatusChip(
            title: saved ? "Saved" : "Missing",
            tone: saved ? .success : (credential == .elevenLabs ? .warning : .neutral),
            systemImage: saved ? "checkmark" : nil,
            compact: true
        )
    }
}

// MARK: - Advanced

private struct AdvancedSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section("Menu Bar & Shortcuts") {
                Toggle("Show menu bar control", isOn: $viewModel.settings.showMenuBarControl)
                Toggle("Show timer in menu bar", isOn: $viewModel.settings.showMenuBarTimer)
                    .disabled(!viewModel.settings.showMenuBarControl)
                Toggle("Enable global Control–Option–R shortcut", isOn: $viewModel.settings.globalShortcutEnabled)
            }
            Section {
                Toggle("Enable local API", isOn: $viewModel.settings.localAPIEnabled)
                if !viewModel.localAPIStatusMessage.isEmpty {
                    Text(verbatim: viewModel.localAPIStatusMessage)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Local API")
            } footer: {
                Text("Lets local automation on this Mac request transcriptions with a per-run token. Off by default.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Setup Health

private struct SetupHealthSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section {
                ForEach(viewModel.setupHealthItems) { item in
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(item.severity.tone.accent)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(item.title))
                                .font(.system(size: 13, weight: .semibold))
                            Text.uiString(item.detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        if item.severity == .warning || item.severity == .error {
                            Button(LocalizedStringKey(viewModel.fixActionTitle(for: item))) {
                                viewModel.fixSetupItem(item)
                            }
                            .controlSize(.small)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            } header: {
                Text("Setup Health")
            } footer: {
                HStack {
                    Spacer()
                    Button("Refresh Health") {
                        viewModel.refreshSetupHealth()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Applies the in-app theme to the AppKit-hosted settings window.
private struct SettingsWindowAppearance: NSViewRepresentable {
    let theme: AppTheme

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let appearance: NSAppearance? = switch theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        DispatchQueue.main.async {
            if nsView.window?.appearance != appearance {
                nsView.window?.appearance = appearance
            }
        }
    }
}
