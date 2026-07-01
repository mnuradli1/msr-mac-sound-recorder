import SwiftUI
import MSRCore
import MSRServices

@main
struct MSRMeetingRecorderApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .task {
                    viewModel.startLocalAPI()
                    await viewModel.bootstrap()
                }
        }
        .defaultSize(width: 1280, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(viewModel.isRecording ? "Stop Recording" : "Start Recording") {
                    Task { await viewModel.toggleRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!viewModel.canToggleRecording)
            }

            CommandMenu("Recording") {
                Button("Search Recordings") {
                    NotificationCenter.default.post(name: .focusRecordingSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("Clear Search") {
                    NotificationCenter.default.post(name: .clearRecordingSearch, object: nil)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(!viewModel.isSearchingRecordings)

                Divider()

                Button("Import Recording...") {
                    viewModel.importRecording()
                }
                .keyboardShortcut("i", modifiers: [.command])
                .disabled(!viewModel.canMutateRecordingLibrary)

                Divider()

                Button(viewModel.isPlaying ? "Pause" : "Play") {
                    viewModel.togglePlayback()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!viewModel.canPlaySelectedRecording)

                Button("Rename") {
                    viewModel.startRename()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(viewModel.selectedRecording == nil || !viewModel.canMutateRecordingLibrary)

                Button("Transcribe") {
                    Task { await viewModel.transcribeSelected() }
                }
                .disabled(!viewModel.canRunPrimaryAction)

                Button("Re-transcribe") {
                    Task { await viewModel.retranscribeSelected() }
                }
                .disabled(!viewModel.hasTranscript || !viewModel.canRunPrimaryAction)

                Button("Summarize") {
                    Task { await viewModel.summarizeSelected() }
                }
                .disabled(viewModel.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !viewModel.canRunPrimaryAction)

                Menu("Save Transcript") {
                    Button("Save as .txt") {
                        viewModel.saveTranscript(format: .text)
                    }
                    Button("Save as .md") {
                        viewModel.saveTranscript(format: .markdown)
                    }
                }
                .disabled(!viewModel.hasTranscript)

                Divider()

                Button("Show in Finder") {
                    viewModel.showInFinder()
                }
                .disabled(viewModel.selectedRecording == nil)

                Button("Refresh History") {
                    viewModel.loadRecordings()
                }
            }
        }

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}
