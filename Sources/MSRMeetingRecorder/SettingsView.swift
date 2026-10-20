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
    @State private var lastTestedProvider: AIProvider?

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $viewModel.settings.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(LocalizedStringKey(provider.displayName)).tag(provider)
                    }
                }
                Toggle("Compress large/uncompressed uploads", isOn: $viewModel.settings.compressUploads)
                Toggle("Auto-title recordings from the transcript", isOn: $viewModel.settings.autoTitle)
                Toggle("Auto-transcribe new recordings", isOn: $viewModel.settings.autoTranscribe)
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
                        Text("With an OpenAI key saved, the beginning of each transcript is sent to OpenAI to name the recording; without one the title is generated on this Mac.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                credentialRow(
                    title: "ElevenLabs API Key",
                    provider: .elevenLabs,
                    healthID: "elevenlabs",
                    draft: $viewModel.elevenLabsKeyDraft,
                    testTitle: "Test ElevenLabs Key"
                )
                credentialRow(
                    title: "OpenAI API Key",
                    provider: .openAI,
                    healthID: "openai",
                    draft: $viewModel.openAIKeyDraft,
                    testTitle: "Test OpenAI Key"
                )
                Toggle("Remember credentials in Keychain", isOn: $viewModel.settings.rememberCredentials)
            } header: {
                Text("API Keys")
            } footer: {
                Text("ElevenLabs transcribes by default. OpenAI is used for summaries and optional transcription.")
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
                    .disabled(viewModel.elevenLabsKeyDraft.isEmpty && viewModel.openAIKeyDraft.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func credentialRow(
        title: LocalizedStringKey,
        provider: AIProvider,
        healthID: String,
        draft: Binding<String>,
        testTitle: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                Spacer()
                credentialStatus(healthID: healthID)
            }
            SecureField(title, text: draft, prompt: Text("Paste a key to save or replace it"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            HStack(spacing: 8) {
                Button(testTitle) {
                    lastTestedProvider = provider
                    Task { await viewModel.testCredential(provider: provider) }
                }
                .controlSize(.small)
                .disabled(viewModel.isTestingCredential)
                if viewModel.isTestingCredential, lastTestedProvider == provider {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            if lastTestedProvider == provider, !viewModel.credentialStatusMessage.isEmpty, !viewModel.isTestingCredential {
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

    @ViewBuilder
    private func credentialStatus(healthID: String) -> some View {
        if let item = viewModel.setupHealthItem(id: healthID) {
            let saved = item.severity == .success
            StatusChip(
                title: saved ? "Saved" : "Missing",
                tone: saved ? .success : (item.severity == .info ? .neutral : .warning),
                systemImage: saved ? "checkmark" : nil,
                compact: true
            )
            .help(Text.uiString(item.detail))
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section("Menu Bar & Shortcuts") {
                Toggle("Show menu bar control", isOn: $viewModel.settings.showMenuBarControl)
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
