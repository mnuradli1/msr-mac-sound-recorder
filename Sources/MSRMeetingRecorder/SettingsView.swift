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

            Section("Transcription") {
                Picker("Provider", selection: $viewModel.settings.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .onChange(of: viewModel.settings.provider) { _, _ in
                    viewModel.saveSettings()
                }

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
    }
}
