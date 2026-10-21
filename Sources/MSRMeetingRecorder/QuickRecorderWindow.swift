import AppKit
import Combine
import SwiftUI
import MSRCore

/// Menu-bar quick recorder: an `NSStatusItem` whose icon (and, optionally,
/// elapsed time) shows the recording state, and a borderless floating panel
/// with `QuickRecorderPanel` that opens under it.
///
/// A status item plus `NSPanel` is used instead of `MenuBarExtra(.window)`:
/// SwiftUI's menu-bar window cannot be opened or closed programmatically
/// (needed by the walkthrough and snapshots), and a `MenuBarExtra` label that
/// shows a ticking timer would re-evaluate the whole scene body on every tick.
/// Here the icon and title are set directly from Combine subscriptions, and
/// the panel's SwiftUI content exists only while it is open.
///
/// The item is present only while Settings → "Show menu bar control" is on.
/// All actions go through the shared `AppViewModel`, so the panel, the main
/// window's recording bar and the ⌃⌥R shortcut never diverge.
@MainActor
final class QuickRecorderController: NSObject {
    /// Window title of the panel (never shown; used to find it in AX and snapshots).
    static let panelTitle = "MSR Quick Recorder"

    private unowned let viewModel: AppViewModel
    /// Opens (or re-creates) the main window; set by the app scene, which owns
    /// SwiftUI's `openWindow` action. Falls back to `AppViewModel.showMainWindow()`.
    var openMainWindow: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var panel: QuickRecorderPanelWindow?
    private var hostingView: NSHostingView<QuickRecorderPanel>?
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitors: [Any] = []
    private var lastTitle = ""
    private var lastSymbol = ""
    /// `orderOut` makes the key panel resign key, which calls back into `hideQuickRecorder()`.
    private var isHiding = false

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        super.init()
        viewModel.$settings
            .map(\.showMenuBarControl)
            .removeDuplicates()
            .sink { [weak self] inserted in self?.setStatusItemInserted(inserted) }
            .store(in: &cancellables)
        // `sink` on `@Published` fires before the property is set (willSet);
        // hop to the next main-actor turn so the view model reads new values.
        Publishers.Merge3(
            viewModel.$workflowState.map { _ in () },
            viewModel.$settings.map { _ in () },
            viewModel.live.$recordingElapsed
                .map { formatClock($0) }
                .removeDuplicates()
                .map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.updateStatusItem() }
        .store(in: &cancellables)
        viewModel.$settings
            .map(\.theme)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyAppearance() }
            .store(in: &cancellables)
    }

    // MARK: Status item

    var isStatusItemInserted: Bool { statusItem != nil }

    /// The status-item button title: the elapsed time while a session is
    /// running or paused and the menu-bar timer is on, otherwise empty.
    nonisolated static func statusTitle(isSessionActive: Bool, showTimer: Bool, elapsed: TimeInterval) -> String {
        guard isSessionActive, showTimer else { return "" }
        return formatClock(elapsed)
    }

    nonisolated static func statusSymbol(isRecording: Bool, isPaused: Bool) -> String {
        if isRecording { return "record.circle.fill" }
        if isPaused { return "pause.circle.fill" }
        return "waveform.circle"
    }

    /// The text currently next to the menu-bar icon (walkthrough/tests).
    var statusItemTitle: String { statusItem?.button?.title ?? "" }

    private func setStatusItemInserted(_ inserted: Bool) {
        if inserted {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "MSRQuickRecorder"
            if let button = item.button {
                button.target = self
                button.action = #selector(statusItemClicked(_:))
                button.imagePosition = .imageLeading
                button.setAccessibilityIdentifier("msr.menuBar.item")
            }
            statusItem = item
            lastTitle = ""
            lastSymbol = ""
            updateStatusItem()
        } else {
            guard let item = statusItem else { return }
            hideQuickRecorder()
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol = Self.statusSymbol(isRecording: viewModel.isRecording, isPaused: viewModel.workflowState.isPaused)
        if symbol != lastSymbol {
            lastSymbol = symbol
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MSR")
            image?.isTemplate = true
            button.image = image
        }
        let title = Self.statusTitle(
            isSessionActive: viewModel.isRecordingSessionActive,
            showTimer: viewModel.settings.showMenuBarTimer,
            elapsed: viewModel.live.recordingElapsed
        )
        if title != lastTitle {
            lastTitle = title
            if title.isEmpty {
                button.title = ""
            } else {
                button.attributedTitle = NSAttributedString(
                    string: " " + title,
                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)]
                )
            }
        }
        button.toolTip = viewModel.isRecordingSessionActive
            ? viewModel.L(viewModel.statusChip.title) + (title.isEmpty ? "" : " · " + title)
            : "MSR Meeting Recorder"
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if isQuickRecorderShown {
            hideQuickRecorder()
        } else {
            showQuickRecorder()
        }
    }

    // MARK: Panel

    var isQuickRecorderShown: Bool { panel?.isVisible == true }

    /// The panel window while it is open (walkthrough/snapshots).
    var panelWindow: NSWindow? { isQuickRecorderShown ? panel : nil }

    /// Opens the panel under the menu-bar item (top-right of the main screen
    /// when the item is hidden). Does not activate the app.
    func showQuickRecorder() {
        let panel = panel ?? makePanel()
        self.panel = panel
        let content = NSHostingView(rootView: QuickRecorderPanel(
            viewModel: viewModel,
            onOpenMainWindow: { [weak self] in self?.openMainWindowFromPanel() },
            onQuit: { NSApp.terminate(nil) }
        ))
        hostingView = content
        let size = content.fittingSize
        let container = QuickRecorderContainerView(frame: NSRect(origin: .zero, size: size))
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        panel.contentView = container
        applyAppearance()
        panel.setFrame(NSRect(origin: origin(for: size), size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem?.button?.highlight(true)
        installEventMonitors()
    }

    func hideQuickRecorder() {
        guard !isHiding else { return }
        isHiding = true
        defer { isHiding = false }
        removeEventMonitors()
        statusItem?.button?.highlight(false)
        guard let panel else { return }
        panel.orderOut(nil)
        // Drop the SwiftUI content while closed: nothing observes the view
        // model or the live meters for a panel nobody can see.
        panel.contentView = nil
        hostingView = nil
    }

    private func makePanel() -> QuickRecorderPanelWindow {
        let panel = QuickRecorderPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: QuickRecorderPanel.width, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = Self.panelTitle
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.onCancel = { [weak self] in self?.hideQuickRecorder() }
        panel.onResignKey = { [weak self] in
            // Closing on focus loss, like a menu; the status-item click that
            // caused it toggles through `statusItemClicked` instead.
            guard let self, !self.isPointerOverStatusItem else { return }
            self.hideQuickRecorder()
        }
        return panel
    }

    private func applyAppearance() {
        guard let panel else { return }
        switch viewModel.settings.theme {
        case .system: panel.appearance = nil
        case .light: panel.appearance = NSAppearance(named: .aqua)
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func origin(for size: NSSize) -> NSPoint {
        if let buttonWindow = statusItem?.button?.window, buttonWindow.isVisible,
           let screen = buttonWindow.screen ?? NSScreen.main {
            let anchor = buttonWindow.frame
            let visible = screen.visibleFrame
            let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
            return NSPoint(x: x, y: anchor.minY - size.height - 6)
        }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        return NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 6)
    }

    private func openMainWindowFromPanel() {
        hideQuickRecorder()
        if let openMainWindow {
            NSApp.activate(ignoringOtherApps: true)
            openMainWindow()
        } else {
            viewModel.showMainWindow()
        }
    }

    private var isPointerOverStatusItem: Bool {
        guard let window = statusItem?.button?.window else { return false }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    // MARK: Click-away

    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }
        // Clicks in other apps close the panel.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hideQuickRecorder() }
        }) {
            eventMonitors.append(global)
        }
        // Clicks in this app's other windows close it too (the status-item
        // button toggles it through its own action).
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if event.window === panel || event.window === self.statusItem?.button?.window { return }
                self.hideQuickRecorder()
            }
            return event
        }) {
            eventMonitors.append(local)
        }
    }

    private func removeEventMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
    }
}

/// Borderless, non-activating floating panel that can still become key, so
/// its controls take clicks and Escape without bringing MSR to the front.
final class QuickRecorderPanelWindow: NSPanel {
    var onCancel: (() -> Void)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// Rounded, menu-material background of the quick-recorder panel.
final class QuickRecorderContainerView: NSVisualEffectView {
    static let cornerRadius: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
