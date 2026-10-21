import AppKit
import SwiftUI
import MSRCore
import MSRServices

@main
struct MSRMeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(MSRApplicationDelegate.self) private var applicationDelegate
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView(viewModel: viewModel)
                .background(QuickRecorderInstaller(viewModel: viewModel))
                .background(MainWindowTagger())
                .task {
                    applicationDelegate.viewModel = viewModel
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

                PlayPauseCommand(viewModel: viewModel, playback: viewModel.playback)

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

                Button("Copy Meeting Notes") { viewModel.copyMeetingNotes() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!viewModel.canCopyMeetingNotes)

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
                    Task { await viewModel.refreshLibrary() }
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

        // The menu-bar quick recorder is an AppKit status item + panel
        // (`QuickRecorderController`), installed by `QuickRecorderInstaller`.
    }

    static let mainWindowID = "main"

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

/// Installs the menu-bar quick recorder as soon as the main window's content
/// exists, and hands it the scene's `openWindow` so "Open MSR" can re-create
/// the main window after it was closed.
private struct QuickRecorderInstaller: View {
    let viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                let openWindow = openWindow
                viewModel.installQuickRecorder {
                    // An existing main window (visible, hidden or minimized) is
                    // brought forward; only when none exists is one re-created.
                    // The panel and Settings windows are never candidates.
                    if !MainWindowLocator.bringForward() {
                        openWindow(id: MSRMeetingRecorderApp.mainWindowID)
                    }
                }
            }
    }
}

/// Finds the main window (the `WindowGroup(id: "main")` window hosting
/// `ContentView`) without relying on titles: the window `MainWindowTagger`
/// recorded from inside `ContentView`, else a window whose SwiftUI identifier
/// is the scene id ("main-AppWindow-1"). Never the Settings windows or the
/// quick-recorder panel.
@MainActor
enum MainWindowLocator {
    /// Cleared when that window closes (see `MainWindowTaggerView`).
    fileprivate static weak var tagged: NSWindow?

    static func isMainWindow(_ window: NSWindow) -> Bool {
        if let tagged, window === tagged { return true }
        guard let identifier = window.identifier?.rawValue else { return false }
        let id = MSRMeetingRecorderApp.mainWindowID
        return identifier == id || identifier.hasPrefix(id + "-")
    }

    /// The open main window, whether visible, hidden (app hidden or ordered
    /// out) or minimized; `nil` once it was closed.
    static func existing() -> NSWindow? {
        if let tagged, NSApp.windows.contains(where: { $0 === tagged }) { return tagged }
        return NSApp.windows.first { window in
            window.sheetParent == nil && isMainWindow(window) && (window.isVisible || window.isMiniaturized)
        }
    }

    /// Unhides the app, then brings the existing main window forward.
    /// Returns `false` when there is none (the caller re-creates it).
    @discardableResult
    static func bringForward() -> Bool {
        NSApp.unhide(nil)
        guard let window = existing() else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

/// Zero-size background of `ContentView` that records its window for `MainWindowLocator`.
private struct MainWindowTagger: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowTaggerView { MainWindowTaggerView() }
    func updateNSView(_ nsView: MainWindowTaggerView, context: Context) {}
}

private final class MainWindowTaggerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        guard let window else { return }
        MainWindowLocator.tagged = window
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window
        )
    }

    @objc private func windowWillClose(_ notification: Notification) {
        if MainWindowLocator.tagged === notification.object as? NSWindow {
            MainWindowLocator.tagged = nil
        }
    }
}

/// Quit while a recording session is active or paused finalizes it first
/// (the same non-cancellable save as Stop), then lets the app terminate.
extension MSRApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, viewModel.needsFinalizeBeforeQuit else { return .terminateNow }
        // A second Quit while saving: the pending reply already ends the app.
        guard !isFinalizingBeforeQuit else { return .terminateCancel }
        isFinalizingBeforeQuit = true
        Task { @MainActor in
            await viewModel.finalizeBeforeQuit()
            self.isFinalizingBeforeQuit = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// `NSApp.terminate` from a run-loop callout, as a menu click does. Called
    /// from inside a main-actor job (a main-queue block, e.g. a `Task`), the
    /// `.terminateLater` wait would hold the main queue and the finalization
    /// task above could never run.
    static func requestTermination() {
        RunLoop.main.perform {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }
}

/// Recording → Play/Pause. Observes `PlaybackState` for the title, which the
/// scene itself (observing only `AppViewModel`) would not see change.
private struct PlayPauseCommand: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var playback: PlaybackState

    var body: some View {
        Button(playback.isPlaying ? "Pause" : "Play") {
            viewModel.togglePlayback()
        }
        .keyboardShortcut(.space, modifiers: [.option])
        .disabled(!viewModel.canPlaySelectedRecording)
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
