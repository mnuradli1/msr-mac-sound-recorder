import AppKit
import Foundation

/// Developer hook for visual verification without screen-recording permission.
///
/// When `MSR_UI_SNAPSHOT_PATH` is set, the app waits for layout, renders its
/// main window's content view into a PNG at that path, and then quits.
///
/// Optional environment variables:
/// - `MSR_UI_SNAPSHOT_DELAY`: seconds to wait before capturing (default 1.5).
/// - `MSR_UI_SNAPSHOT_APPEARANCE`: `light` or `dark` to force an appearance.
/// - `MSR_UI_SNAPSHOT_KEEP_RUNNING`: when set, the app stays open after capturing.
///
/// Pair it with `MSR_RECORDINGS_FOLDER` to point the app at a fixture library so
/// snapshots never touch the user's real recordings.
@MainActor
enum UISnapshotCapture {
    static var isRequested: Bool {
        guard let path = ProcessInfo.processInfo.environment["MSR_UI_SNAPSHOT_PATH"] else { return false }
        return !path.isEmpty
    }

    static func runIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
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

        let delay = Double(environment["MSR_UI_SNAPSHOT_DELAY"] ?? "") ?? 1.5
        try? await Task.sleep(for: .seconds(max(0, delay)))

        defer {
            if environment["MSR_UI_SNAPSHOT_KEEP_RUNNING"] == nil {
                NSApp.terminate(nil)
            }
        }

        let candidates = NSApp.windows.filter { $0.canBecomeMain }
        guard let window = candidates.first(where: { $0.isVisible }) ?? candidates.first,
              let view = window.contentView else {
            FileHandle.standardError.write(Data("MSR snapshot: no main window found\n".utf8))
            return
        }

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
