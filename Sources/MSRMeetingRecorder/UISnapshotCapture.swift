import AppKit
import Foundation

/// Developer hook for visual verification without screen-recording permission.
///
/// When `MSR_UI_SNAPSHOT_PATH` is set, the app waits for layout, renders a
/// window's content view into a PNG at that path, and then quits.
///
/// Optional environment variables:
/// - `MSR_UI_SNAPSHOT_DELAY`: seconds to wait before capturing (default 1.5).
/// - `MSR_UI_SNAPSHOT_APPEARANCE`: `light` or `dark` to force an appearance.
/// - `MSR_UI_SNAPSHOT_SIZE`: main window size as `WIDTHxHEIGHT` (default `1180x760`).
/// - `MSR_UI_SNAPSHOT_SELECT`: index into the visible recording list, or `none`
///   to show the empty "Ready to record" state.
/// - `MSR_UI_SNAPSHOT_TAB`: `review`, `notes` or `export`.
/// - `MSR_UI_SNAPSHOT_SEARCH`: a recording search query to type before capture.
/// - `MSR_UI_SNAPSHOT_TRANSCRIPT_MODE`: `read` or `edit` for the Notes tab.
/// - `MSR_UI_SNAPSHOT_WINDOW`: `main` (default) or `settings`.
/// - `MSR_UI_SNAPSHOT_SETTINGS_TAB`: `general`, `transcription`, `advanced` or `health`.
/// - `MSR_UI_SNAPSHOT_KEEP_RUNNING`: when set, the app stays open after capturing.
///
/// Pair it with `MSR_RECORDINGS_FOLDER` to point the app at a fixture library so
/// snapshots never touch the user's real recordings (see `scripts/make_ui_fixture.sh`
/// and `scripts/ui_snapshots.sh`).
@MainActor
enum UISnapshotCapture {
    nonisolated private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    nonisolated static var isRequested: Bool {
        guard let path = environment["MSR_UI_SNAPSHOT_PATH"] else { return false }
        return !path.isEmpty
    }

    /// Settings tab to open first while snapshotting; `nil` outside snapshot runs.
    nonisolated static var requestedSettingsTab: String? {
        guard isRequested else { return nil }
        return environment["MSR_UI_SNAPSHOT_SETTINGS_TAB"]?.lowercased()
    }

    /// Transcript mode for the Notes tab while snapshotting; `nil` outside snapshot runs.
    nonisolated static var requestedTranscriptMode: String? {
        guard isRequested else { return nil }
        return environment["MSR_UI_SNAPSHOT_TRANSCRIPT_MODE"]?.lowercased()
    }

    /// Runs before `bootstrap()` in snapshot runs only.
    ///
    /// A `swift run` build is unsigned, so reading the real app's Keychain items
    /// would block on a macOS access prompt. Snapshot runs therefore get
    /// in-memory placeholder session keys (never written to the Keychain:
    /// `rememberCredentials` is forced off first) so setup health never queries
    /// the Keychain.
    static func prepareIfRequested(viewModel: AppViewModel) {
        guard isRequested else { return }
        viewModel.settings.rememberCredentials = false
        viewModel.settings.localAPIEnabled = false
        viewModel.elevenLabsKeyDraft = "snapshot-placeholder-key"
        viewModel.openAIKeyDraft = "snapshot-placeholder-key"
        viewModel.saveAPIKeys()
        viewModel.statusMessage = "Ready"
    }

    static func runIfRequested(viewModel: AppViewModel) async {
        let environment = environment
        guard let path = environment["MSR_UI_SNAPSHOT_PATH"], !path.isEmpty else { return }

        if let appearance = environment["MSR_UI_SNAPSHOT_APPEARANCE"] {
            switch appearance.lowercased() {
            case "dark":
                NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light":
                NSApp.appearance = NSAppearance(named: .aqua)
            default:
                break
            }
        }

        if let mainWindow = mainWindow() {
            let size = parseSize(environment["MSR_UI_SNAPSHOT_SIZE"]) ?? NSSize(width: 1_180, height: 760)
            var frame = mainWindow.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            mainWindow.setFrame(frame, display: true)
        }

        applyState(to: viewModel, environment: environment)

        let delay = Double(environment["MSR_UI_SNAPSHOT_DELAY"] ?? "") ?? 1.5
        try? await Task.sleep(for: .seconds(max(0, delay)))

        defer {
            if environment["MSR_UI_SNAPSHOT_KEEP_RUNNING"] == nil {
                NSApp.terminate(nil)
            }
        }

        let window: NSWindow?
        if environment["MSR_UI_SNAPSHOT_WINDOW"]?.lowercased() == "settings" {
            viewModel.openSettingsWindow()
            try? await Task.sleep(for: .seconds(1))
            window = NSApp.windows.first { $0.title == "MSR Settings" && $0.isVisible }
        } else {
            window = mainWindow()
        }

        // Capture the theme frame so the title bar (traffic lights, title) is included.
        guard let window, let view = window.contentView?.superview ?? window.contentView else {
            FileHandle.standardError.write(Data("MSR snapshot: no window found\n".utf8))
            return
        }
        capture(view: view, window: window, to: path)
    }

    private static func applyState(to viewModel: AppViewModel, environment: [String: String]) {
        if let query = environment["MSR_UI_SNAPSHOT_SEARCH"], !query.isEmpty {
            viewModel.recordingSearchQuery = query
            viewModel.scheduleRecordingSearch()
        }

        if let selection = environment["MSR_UI_SNAPSHOT_SELECT"]?.lowercased() {
            if selection == "none" {
                viewModel.stopPlayback()
                viewModel.selectedRecording = nil
                viewModel.transcriptText = ""
                viewModel.summaryText = ""
                viewModel.transcriptSegments = []
            } else if let index = Int(selection) {
                let items = viewModel.filteredRecordings
                if items.indices.contains(index) {
                    viewModel.select(items[index])
                }
            }
        }

        if let tabName = environment["MSR_UI_SNAPSHOT_TAB"]?.lowercased(),
           let tab = RecordingDetailTab.allCases.first(where: { $0.rawValue.lowercased() == tabName }) {
            viewModel.selectedDetailTab = tab
        }
    }

    private static func mainWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter { $0.canBecomeMain && $0.title != "MSR Settings" }
        return candidates.first(where: { $0.isVisible }) ?? candidates.first
    }

    private static func parseSize(_ value: String?) -> NSSize? {
        guard let value else { return nil }
        let parts = value.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return NSSize(width: parts[0], height: parts[1])
    }

    private static func capture(view: NSView, window: NSWindow, to path: String) {
        window.displayIfNeeded()
        let bounds = view.bounds
        guard let representation = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            FileHandle.standardError.write(Data("MSR snapshot: could not create bitmap\n".utf8))
            return
        }
        view.cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("MSR snapshot: could not encode PNG\n".utf8))
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("MSR snapshot: wrote \(path) (\(Int(bounds.width))x\(Int(bounds.height)))\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("MSR snapshot: write failed: \(error.localizedDescription)\n".utf8))
        }
    }
}
