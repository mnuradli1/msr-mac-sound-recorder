import AppKit
import SwiftUI
import MSRCore
import MSRServices

@main
struct MSRMeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(MSRApplicationDelegate.self) private var applicationDelegate
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .task {
                    UISnapshotCapture.prepareIfRequested(viewModel: viewModel)
                    viewModel.startLocalAPI()
                    await viewModel.bootstrap()
                    await UIScenarioRunner.runIfRequested(viewModel: viewModel)
                    await UISnapshotCapture.runIfRequested(viewModel: viewModel)
                }
        }
        .defaultSize(width: viewModel.settings.windowWidth, height: viewModel.settings.windowHeight)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
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
                .keyboardShortcut(.space, modifiers: [.option])
                .disabled(!viewModel.canPlaySelectedRecording)

                Button("Rename") {
                    viewModel.startRename()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(viewModel.selectedRecording == nil || !viewModel.canMutateRecordingLibrary)

                Button("Transcribe") {
                    Task { await viewModel.transcribeSelected() }
                }
                .keyboardShortcut("t", modifiers: [.command])
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

                Button("Copy Transcript") { viewModel.copyTranscript() }
                    .disabled(!viewModel.hasTranscript)

                Button("Copy Summary") { viewModel.copySummary() }
                    .disabled(!viewModel.hasSummary)

                Button("Save Notes") { viewModel.flushTranscriptEdits() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(viewModel.selectedRecording == nil)

                Button("Export…") {
                    viewModel.selectedDetailTab = .export
                    viewModel.exportSelected()
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(viewModel.selectedRecording == nil)

                Divider()

                Button("Previous Recording") { viewModel.selectAdjacentRecording(offset: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                Button("Next Recording") { viewModel.selectAdjacentRecording(offset: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command])

                Button("Review Tab") { viewModel.selectedDetailTab = .review }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Notes Tab") { viewModel.selectedDetailTab = .notes }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Export Tab") { viewModel.selectedDetailTab = .export }
                    .keyboardShortcut("3", modifiers: [.command])

                Divider()

                Button("Show in Finder") {
                    viewModel.showInFinder()
                }
                .disabled(viewModel.selectedRecording == nil)

                Button("Refresh History") {
                    viewModel.loadRecordings()
                }

                Divider()

                Button("Delete Recording…") {
                    // ⌘⌫ means "delete to line start" while editing text; keep
                    // that behavior for the keystroke instead of deleting the
                    // recording. Choosing the item from the menu bar always asks.
                    if let textView = DeleteRecordingCommand.textViewToEdit(for: NSApp.currentEvent) {
                        textView.deleteToBeginningOfLine(nil)
                        return
                    }
                    // ContentView confirms, then calls `viewModel.delete(_:)`.
                    NotificationCenter.default.post(name: .requestDeleteRecording, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(viewModel.selectedRecording == nil || !viewModel.canMutateRecordingLibrary)
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { viewModel.checkForUpdates() }
            }
        }

        Settings {
            SettingsView(viewModel: viewModel)
                .preferredColorScheme(preferredColorScheme)
                .environment(\.locale, preferredLocale)
        }

        MenuBarExtra(isInserted: .constant(viewModel.settings.showMenuBarControl)) {
            Button("Show MSR") { viewModel.showMainWindow() }
            Button(viewModel.isRecording ? "Stop Recording" : "Start Recording") {
                Task { await viewModel.toggleRecording() }
            }
            .disabled(!viewModel.canToggleRecording)
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: viewModel.isRecording ? "record.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.menu)
    }

    private var preferredColorScheme: ColorScheme? {
        switch viewModel.settings.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var preferredLocale: Locale {
        switch viewModel.settings.language {
        case .system: .current
        case .english: Locale(identifier: "en")
        case .indonesian: Locale(identifier: "id")
        }
    }
}

/// Routing for Recording → Delete Recording… (⌘⌫).
enum DeleteRecordingCommand {
    /// The editable text view that should get "delete to line start" instead
    /// of the recording being deleted: only when the command came from a
    /// keystroke typed into a text view. A menu-bar click (a mouse event, or
    /// no key event) always asks to delete the recording, even while a text
    /// field such as the search field still has focus.
    @MainActor
    static func textViewToEdit(for event: NSEvent?) -> NSTextView? {
        guard let event, event.type == .keyDown else { return nil }
        let window = event.window ?? NSApp.keyWindow
        guard let textView = window?.firstResponder as? NSTextView, textView.isEditable else { return nil }
        return textView
    }
}
