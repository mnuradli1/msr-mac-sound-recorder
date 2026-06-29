import SwiftUI
import MSRCore

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
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
                    Text(viewModel.credentialStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
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
