import SwiftUI
import MSRCore

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section("Setup Health") {
                ForEach(viewModel.setupHealthItems) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(item.severity.foregroundColor)
                            .frame(width: 18)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(item.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.secondary)
                                .lineLimit(2)
                        }
                    }
                }

                Button("Refresh Health") {
                    viewModel.refreshSetupHealth()
                }
            }

            Section("Storage") {
                HStack {
                    TextField("Recordings Folder", text: Binding(
                        get: { viewModel.recordingsFolderURL.path },
                        set: { viewModel.settings.recordingsFolderPath = $0 }
                    ))
                    Button {
                        viewModel.chooseRecordingsFolder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Choose recordings folder")
                    .accessibilityLabel("Choose recordings folder")
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
                HStack {
                    Text("Silence threshold")
                    Slider(value: $viewModel.settings.silenceThreshold, in: 0.001...0.05)
                    Text(viewModel.settings.silenceThreshold, format: .number.precision(.fractionLength(3)))
                        .monospacedDigit().frame(width: 48)
                }
            }

            Section("Transcription") {
                Picker("Provider", selection: $viewModel.settings.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(LocalizedStringKey(provider.displayName)).tag(provider)
                    }
                }
                .onChange(of: viewModel.settings.provider) { _, _ in
                    viewModel.saveSettings()
                }

                Toggle("Compress large/uncompressed uploads", isOn: $viewModel.settings.compressUploads)
                Toggle("Auto-title OpenAI transcripts", isOn: $viewModel.settings.autoTitle)
                Toggle("Remember credentials in Keychain", isOn: $viewModel.settings.rememberCredentials)

                SecureField("ElevenLabs API Key", text: $viewModel.elevenLabsKeyDraft)
                Button("Test ElevenLabs Key") {
                    Task { await viewModel.testCredential(provider: .elevenLabs) }
                }
                .disabled(viewModel.isTestingCredential)
            }

            Section("Summary") {
                SecureField("OpenAI API Key", text: $viewModel.openAIKeyDraft)
                Button("Test OpenAI Key") {
                    Task { await viewModel.testCredential(provider: .openAI) }
                }
                .disabled(viewModel.isTestingCredential)
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

            Section("Advanced") {
                Toggle("Show menu bar control", isOn: $viewModel.settings.showMenuBarControl)
                Toggle("Enable global Control–Option–R shortcut", isOn: $viewModel.settings.globalShortcutEnabled)
                Toggle("Enable local API", isOn: $viewModel.settings.localAPIEnabled)
                Text(viewModel.localAPIStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !viewModel.credentialStatusMessage.isEmpty {
                Section("Status") {
                    NoticeBanner(
                        message: viewModel.credentialStatusMessage,
                        severity: viewModel.credentialStatusSeverity,
                        horizontalPadding: 0
                    )
                    .textSelection(.enabled)
                }
            }

            HStack {
                Button("Forget Saved Keys", role: .destructive) {
                    viewModel.forgetAPIKeys()
                }
                Spacer()
                Button("Save") {
                    viewModel.saveAPIKeys()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520)
        .onChange(of: viewModel.settings) { _, _ in viewModel.saveSettings() }
    }
}
