import SwiftUI
import MSRCore
import MSRServices

@main
struct MSRMeetingRecorderApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(width: 1280, height: 780)
                .task {
                    viewModel.startLocalAPI()
                    viewModel.loadRecordings()
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
                Button(viewModel.isPlaying ? "Pause" : "Play") {
                    viewModel.togglePlayback()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(viewModel.selectedRecording == nil)

                Button("Rename") {
                    viewModel.startRename()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(viewModel.selectedRecording == nil)

                Button("Transcribe") {
                    Task { await viewModel.transcribeSelected() }
                }
                .disabled(viewModel.selectedRecording == nil || viewModel.workflowState.isBusy || viewModel.isRecording)

                Button("Re-transcribe") {
                    Task { await viewModel.retranscribeSelected() }
                }
                .disabled(!viewModel.hasTranscript || viewModel.workflowState.isBusy || viewModel.isRecording)

                Button("Summarize") {
                    Task { await viewModel.summarizeSelected() }
                }
                .disabled(viewModel.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.workflowState.isBusy || viewModel.isRecording)

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
