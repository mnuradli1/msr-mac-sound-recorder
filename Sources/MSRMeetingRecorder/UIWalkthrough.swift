import AppKit
import ApplicationServices
import Combine
import Foundation
import MSRCore

// MARK: - AXDriver

/// One element of an accessibility snapshot.
struct AXNode: @unchecked Sendable {
    let element: AXUIElement
    let role: String
    let subrole: String
    let identifier: String
    let title: String
    /// `AXDescription`: where SwiftUI puts a control's label.
    let label: String
    /// String (or numeric) `AXValue`, when there is one.
    let value: String?
    let depth: Int
    /// Index of the parent node in the same snapshot.
    let parent: Int?

    var texts: [String] {
        [title, label, value ?? ""].filter { !$0.isEmpty }
    }

    var summary: String {
        var parts = [role]
        if !subrole.isEmpty { parts.append("subrole=\(subrole)") }
        if !identifier.isEmpty { parts.append("id=\(identifier)") }
        if !title.isEmpty { parts.append("title=\(title.prefix(50))") }
        if !label.isEmpty { parts.append("label=\(label.prefix(50))") }
        if let value, !value.isEmpty { parts.append("value=\(value.prefix(50))") }
        return parts.joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

/// Drives this app's own accessibility tree, the way VoiceOver does.
///
/// It uses the AX C API (`AXUIElementCreateApplication(getpid())`) against its
/// own process. That needs no Accessibility (TCC) grant, so it works from a
/// plain `swift build` binary launched from a shell. The in-process
/// `NSAccessibility` protocol tree is not enough: SwiftUI only vends its own
/// elements (buttons, text, list rows) through the AX request path, while
/// `accessibilityChildren()` on a hosting view only reaches AppKit-backed
/// controls. AX requests to the own process are answered synchronously on the
/// calling thread, so every call here runs on the main actor (SwiftUI and the
/// view model are main-thread only); waits suspend with `Task.sleep` so the
/// run loop keeps processing the resulting UI updates.
///
/// Key presses are synthesized as `NSEvent`s and routed through
/// `NSApp.sendEvent` (key equivalents + responder chain), which also needs no
/// permission. Main-menu items are invoked through `NSMenu`.
@MainActor
final class AXDriver {
    struct Query: CustomStringConvertible {
        var role: String?
        /// Exact accessibility identifier.
        var identifier: String?
        /// Case-insensitive substring of the title, label or string value.
        var text: String?
        /// Case-insensitive exact title, label or string value.
        var exactText: String?

        var description: String {
            [role.map { "role=\($0)" }, identifier.map { "id=\($0)" },
             text.map { "text~\($0)" }, exactText.map { "text=\($0)" }]
                .compactMap { $0 }.joined(separator: " ")
        }

        func matches(_ node: AXNode) -> Bool {
            if let role, node.role != role { return false }
            if let identifier, node.identifier != identifier { return false }
            if let text, !node.texts.contains(where: { $0.localizedCaseInsensitiveContains(text) }) { return false }
            if let exactText,
               !node.texts.contains(where: { $0.compare(exactText, options: .caseInsensitive) == .orderedSame }) {
                return false
            }
            return true
        }
    }

    private let pid = ProcessInfo.processInfo.processIdentifier

    // MARK: Snapshots

    /// Every element of the app's windows (optionally only the window titled
    /// `window`), plus open menus. Depth-first, each element once.
    func snapshot(window: String? = nil) async -> [AXNode] {
        Self.collect(pid: pid, windowTitle: window)
    }

    func find(_ query: Query, window: String? = nil) async -> AXNode? {
        await snapshot(window: window).first(where: query.matches)
    }

    func findAll(_ query: Query, window: String? = nil) async -> [AXNode] {
        await snapshot(window: window).filter(query.matches)
    }

    /// Polls (50 ms steps) until `query` matches or `timeout` passes.
    func waitFor(_ query: Query, window: String? = nil, timeout: TimeInterval = 5) async -> AXNode? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let node = await find(query, window: window) { return node }
            if Date() >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Polls (50 ms steps) until `query` no longer matches.
    func waitForAbsence(_ query: Query, window: String? = nil, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if await find(query, window: window) == nil { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Direct children of `node` within `nodes` (a snapshot containing it).
    func children(of node: AXNode, in nodes: [AXNode]) -> [AXNode] {
        guard let index = nodes.firstIndex(where: { CFEqual($0.element, node.element) }) else { return [] }
        return nodes.filter { $0.parent == index }
    }

    /// Descendants of `node` within `nodes`.
    func descendants(of node: AXNode, in nodes: [AXNode]) -> [AXNode] {
        guard let start = nodes.firstIndex(where: { CFEqual($0.element, node.element) }) else { return [] }
        var result: [AXNode] = []
        var index = start + 1
        while index < nodes.count, nodes[index].depth > nodes[start].depth {
            result.append(nodes[index])
            index += 1
        }
        return result
    }

    func ancestor(of node: AXNode, in nodes: [AXNode], where predicate: (AXNode) -> Bool) -> AXNode? {
        guard var index = nodes.firstIndex(where: { CFEqual($0.element, node.element) }) else { return nil }
        while let parent = nodes[index].parent {
            if predicate(nodes[parent]) { return nodes[parent] }
            index = parent
        }
        return nil
    }

    func dump(_ nodes: [AXNode]) {
        let lines = nodes.map { String(repeating: "  ", count: $0.depth) + $0.summary }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    // MARK: Actions

    /// AXPress. SwiftUI rebuilds the pressed control while it handles the
    /// action and then often reports `kAXErrorFailure` (-25200) although the
    /// action ran, so only errors meaning "not dispatched" count as failure;
    /// callers assert the effect on the view model or disk.
    @discardableResult
    func press(_ node: AXNode) async -> Bool {
        lastPressResult = await perform(node, kAXPressAction)
        return ![.actionUnsupported, .invalidUIElement, .illegalArgument, .apiDisabled, .notImplemented]
            .contains(lastPressResult)
    }

    private(set) var lastPressResult = AXError.success

    @MainActor
    final class MenuOutcome {
        var opened = false
        var chosen = false
        var items: [String] = []
    }

    /// Opens a menu button the way VoiceOver does (AXShowMenu, else AXPress)
    /// and presses the item titled `itemTitle` in the open menu. AXPress on a
    /// pop-up button runs NSMenu tracking inside the (synchronous, in-process)
    /// AX call, so the item is picked from a common-modes run-loop timer that
    /// fires during tracking. If the item never shows up, Escape closes the menu.
    func choose(_ itemTitle: String, fromMenuButton node: AXNode, timeout: TimeInterval = 3) async -> (MenuOutcome, String) {
        let outcome = MenuOutcome()
        let deadline = Date().addingTimeInterval(timeout)
        let pid = pid
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !outcome.chosen else { return }
                let menuItems = Self.collect(pid: pid, windowTitle: nil).filter { $0.role == kAXMenuItemRole }
                guard !menuItems.isEmpty else {
                    if Date() > deadline { Self.postEscape() }
                    return
                }
                outcome.opened = true
                outcome.items = menuItems.map(\.title).filter { !$0.isEmpty }
                if let item = menuItems.first(where: { $0.title == itemTitle }) {
                    outcome.chosen = AXUIElementPerformAction(item.element, kAXPressAction as CFString) != .actionUnsupported
                } else if Date() > deadline {
                    Self.postEscape()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        var method = "AXShowMenu"
        if AXUIElementPerformAction(node.element, kAXShowMenuAction as CFString) == .actionUnsupported {
            method = "AXPress (AXShowMenu unsupported)"
            _ = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
        }
        _ = await waitUntil(timeout: max(0.2, deadline.timeIntervalSinceNow + 0.5)) { outcome.chosen }
        return (outcome, method)
    }

    private static func postEscape() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ) else { return }
        NSApp.postEvent(event, atStart: true)
    }

    @discardableResult
    func perform(_ node: AXNode, _ action: String) async -> AXError {
        let result = AXUIElementPerformAction(node.element, action as CFString)
        await Task.yield()
        return result
    }

    @discardableResult
    func set(_ node: AXNode, _ attribute: String, to value: AnyObject) async -> AXError {
        let result = AXUIElementSetAttributeValue(node.element, attribute as CFString, value as CFTypeRef)
        await Task.yield()
        return result
    }

    /// Selects the list row holding `node`, the way VoiceOver does: AXPress
    /// on the row content, then `AXSelected` on the row, then `AXSelectedRows`
    /// on the outline. Returns the method that satisfied `isSelected`.
    func selectRow(containing node: AXNode, isSelected: () -> Bool) async -> String? {
        if await press(node), await waitUntil(timeout: 1, isSelected) { return "AXPress" }
        let nodes = await snapshot()
        let row = node.role == kAXRowRole ? node : ancestor(of: node, in: nodes) { $0.role == kAXRowRole }
        guard let row else { return nil }
        if await set(row, kAXSelectedAttribute, to: kCFBooleanTrue) == .success,
           await waitUntil(timeout: 1, isSelected) {
            return "AXSelected on the AXRow"
        }
        if let outline = ancestor(of: row, in: nodes, where: { $0.role == kAXOutlineRole || $0.role == kAXTableRole }) {
            if await set(outline, kAXSelectedRowsAttribute, to: [row.element] as CFArray) == .success,
               await waitUntil(timeout: 1, isSelected) {
                return "AXSelectedRows on the AXOutline"
            }
        }
        return nil
    }

    /// Sets a text field's value: `AXValue` first; when the SwiftUI binding
    /// does not pick that up, focuses the field (`AXFocused`) and inserts the
    /// text through the window's field editor, which is what typing does.
    func setText(_ text: String, on node: AXNode, in window: NSWindow, applied: () -> Bool) async -> String? {
        let valueResult = await set(node, kAXValueAttribute, to: text as NSString)
        if await waitUntil(timeout: 0.8, applied) { return "AXValue" }
        let focusResult = await set(node, kAXFocusedAttribute, to: kCFBooleanTrue)
        _ = await waitUntil(timeout: 1) { window.firstResponder is NSTextView }
        if let editor = window.firstResponder as? NSTextView {
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
            if await waitUntil(timeout: 1, applied) { return "AXFocused + field editor insertText (AXValue alone did not reach the binding)" }
        }
        lastTextFailure = "AXValue=\(valueResult.rawValue) AXFocused=\(focusResult.rawValue) firstResponder=\(window.firstResponder.map { "\(type(of: $0))" } ?? "nil") key=\(window.isKeyWindow) active=\(NSApp.isActive)"
        return nil
    }

    /// A string attribute read synchronously (AX requests to the own process are answered inline).
    func string(_ node: AXNode, _ attribute: String = kAXValueAttribute) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node.element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    func bool(_ node: AXNode, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node.element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// Diagnostics for the last `setText` that did not apply.
    private(set) var lastTextFailure = ""

    struct Key {
        let keyCode: UInt16
        let characters: String
        var modifiers: NSEvent.ModifierFlags = []

        static let returnKey = Key(keyCode: 36, characters: "\r")
        static let escape = Key(keyCode: 53, characters: "\u{1b}")
        static let commandDelete = Key(keyCode: 51, characters: "\u{7f}", modifiers: .command)
    }

    /// Synthesizes a key press and posts it to the app's event queue, so it is
    /// fetched and dispatched like a real keystroke (`NSApp.currentEvent`, key
    /// equivalents, then the key window's responder chain).
    func sendKey(_ key: Key, to window: NSWindow) async {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: key.modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: key.characters,
                charactersIgnoringModifiers: key.characters,
                isARepeat: false,
                keyCode: key.keyCode
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
        try? await Task.sleep(for: .milliseconds(100))
    }

    enum MenuResult: Equatable, CustomStringConvertible {
        case performed
        case missing(String)
        case disabled(String)

        var description: String {
            switch self {
            case .performed: "performed"
            case let .missing(detail): "missing \(detail)"
            case let .disabled(title): "disabled \(title)"
            }
        }
    }

    /// Invokes a main-menu item by its title path, e.g. ["Recording", "Copy Transcript"].
    func performMainMenuItem(_ path: [String]) -> MenuResult {
        guard var menu = NSApp.mainMenu else { return .missing("no main menu") }
        for (depth, title) in path.enumerated() {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
                return .missing("\(title) (have: \(menu.items.map(\.title).filter { !$0.isEmpty }.joined(separator: ", ")))")
            }
            let item = menu.items[index]
            if depth == path.count - 1 {
                guard item.isEnabled else { return .disabled(title) }
                menu.performActionForItem(at: index)
                return .performed
            }
            guard let submenu = item.submenu else { return .missing("\(title) has no submenu") }
            menu = submenu
        }
        return .missing("empty path")
    }

    // MARK: Collection

    private static let attributeNames = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXValueAttribute, kAXChildrenAttribute
    ]

    private static func collect(pid: pid_t, windowTitle: String?) -> [AXNode] {
        let attributes = attributeNames as CFArray
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3)
        var nodes: [AXNode] = []

        // The AX hierarchy is a tree; the depth and size caps bound a bad one.
        func visit(_ element: AXUIElement, depth: Int, parent: Int?) {
            guard depth < 60, nodes.count < 6_000 else { return }
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let values = raw as? [AnyObject], values.count == 7 else { return }
            func string(_ index: Int) -> String {
                values[index] as? String ?? ""
            }
            var value: String?
            if let text = values[5] as? String {
                value = text
            } else if let attributed = values[5] as? NSAttributedString {
                value = attributed.string
            } else if let number = values[5] as? NSNumber, CFGetTypeID(number) != AXValueGetTypeID() {
                value = number.stringValue
            }
            let node = AXNode(
                element: element,
                role: string(0),
                subrole: string(1),
                identifier: string(2),
                title: string(3),
                label: string(4),
                value: value,
                depth: depth,
                parent: parent
            )
            nodes.append(node)
            let index = nodes.count - 1
            let children = (values[6] as? [AnyObject] ?? []).filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
            for child in children {
                // swiftlint:disable:next force_cast
                visit(child as! AXUIElement, depth: depth + 1, parent: index)
            }
        }

        var windowsValue: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue)
        for window in windowsValue as? [AXUIElement] ?? [] {
            if let windowTitle {
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                guard (title as? String) == windowTitle else { continue }
            }
            visit(window, depth: 0, parent: nil)
        }
        if windowTitle == nil {
            // Open pop-up/context menus hang off the application element.
            var childrenValue: CFTypeRef?
            AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &childrenValue)
            for child in childrenValue as? [AXUIElement] ?? [] {
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
                if (role as? String) == kAXMenuRole { visit(child, depth: 0, parent: nil) }
            }
        }
        return nodes
    }
}

// MARK: - Walkthrough

/// `MSR_UI_SCENARIO=ui-walkthrough`: exercises the redesigned controls through
/// the accessibility tree (press, select, set value, show menu, key events) and
/// asserts each step against the view model or the files on disk. Prints one
/// JSON line per step to stderr plus a final summary line and exits 1 when any
/// step failed (unless `MSR_UI_SNAPSHOT_PATH` is set). `ui-walkthrough-empty`
/// is the small empty-library readiness check. See `scripts/ui_walkthrough.sh`.
///
/// Development aids: `MSR_UI_WALKTHROUGH_ONLY=1,2,5` runs only those step
/// numbers; `MSR_UI_WALKTHROUGH_DUMP=1` prints the AX tree after a failed step.
@MainActor
final class UIWalkthrough {
    private struct StepFailure: Error {
        let detail: String
    }

    private static let settingsTitle = "MSR Settings"

    private let viewModel: AppViewModel
    private let ax = AXDriver()
    private var passed = 0
    private var failed = 0
    private var walkthroughRecordingID: UUID?
    private var observedStates: [RecordingWorkflowState] = []
    private var cancellables = Set<AnyCancellable>()
    private let environment = ProcessInfo.processInfo.environment

    private init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    static func run(viewModel: AppViewModel) async {
        let walkthrough = UIWalkthrough(viewModel: viewModel)
        await walkthrough.runFull()
        walkthrough.finish()
    }

    static func runEmpty(viewModel: AppViewModel) async {
        let walkthrough = UIWalkthrough(viewModel: viewModel)
        await walkthrough.runEmptyLibrary()
        walkthrough.finish()
    }

    // MARK: Setup

    private func prepare() async -> NSWindow? {
        viewModel.settingsPersistenceSuspended = true
        // Labels are matched in English; keep the run deterministic.
        viewModel.settings.language = .english
        viewModel.settings.sortOrder = .newest
        viewModel.settings.autoTranscribe = false
        // The first-run sheet would cover the window; step 13 opens it on purpose.
        if !UISnapshotCapture.requestsOnboarding {
            viewModel.settings.hasCompletedOnboarding = true
        }
        if !viewModel.credentialAvailable(for: viewModel.settings.provider),
           viewModel.credentialAvailable(for: .elevenLabs) {
            viewModel.settings.provider = .elevenLabs
        }
        // No NSApp.activate: the run must not take keyboard focus from the
        // user; every driver path below works for an inactive app.
        var window: NSWindow?
        _ = await ax.waitUntil(timeout: 5) {
            window = self.mainWindow()
            return window != nil
        }
        window?.makeKeyAndOrderFront(nil)
        _ = await ax.waitUntil(timeout: 2) { window?.isKeyWindow == true }
        // The first AX request switches SwiftUI's accessibility on; wait for the tree.
        _ = await ax.waitFor(AXDriver.Query(identifier: "msr.recordingBar.record"), timeout: 5)
        return window
    }

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.title != Self.settingsTitle }
    }

    private func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.title == Self.settingsTitle }
    }

    // MARK: Full walkthrough

    private func runFull() async {
        guard let window = await prepare() else {
            record("setup", ok: false, detail: "main window did not appear")
            return
        }
        viewModel.$workflowState
            .sink { [weak self] state in self?.observedStates.append(state) }
            .store(in: &cancellables)

        await step("1-sidebar-selection") { try await self.sidebarSelection() }
        await step("2-tabs") { try await self.tabs() }
        await step("3-read-edit-toggle") { try await self.readEditToggle() }
        await step("4-search") { try await self.search() }
        await step("5a-inline-rename-commit") { try await self.inlineRenameCommit(window: window) }
        await step("5b-inline-rename-cancel") { try await self.inlineRenameCancel(window: window) }
        await step("6-settings-window") { try await self.settingsWindowToggles() }
        await step("6b-transcription-language") { try await self.transcriptionLanguagePicker() }
        await step("6c-auto-summarize") { try await self.autoSummarizeToggle() }
        await step("7-record-button") { try await self.recordViaButton() }
        await step("8a-overflow-menu-copy") { try await self.overflowMenuCopy() }
        await step("8b-menu-copy-transcript") { try await self.menuCopyTranscript() }
        await step("8c-menu-export-tab") { try await self.menuExportTab() }
        await step("8d-speaker-rename") { try await self.speakerRename(window: window) }
        await step("8e-menu-copy-meeting-notes") { try await self.menuCopyMeetingNotes() }
        await step("9a-command-delete-in-text-field") { try await self.commandDeleteInTextField(window: window) }
        await step("9b-menu-delete-with-confirmation") { try await self.deleteWithConfirmation(window: window) }
        await step("10-status-bar") { try await self.statusBar() }
        await step("12-quick-recorder") { try await self.quickRecorder(window: window) }
        await step("13-onboarding") { try await self.onboarding() }
        await step("13b-onboarding-escape") { try await self.onboardingEscape() }
    }

    private func sidebarSelection() async throws -> String {
        let visible = viewModel.filteredRecordings
        try check(visible.count >= 2, "need at least 2 recordings, have \(visible.count)")
        let target = visible[1].id == viewModel.selectedRecording?.id ? visible[0] : visible[1]
        let before = viewModel.selectedRecording?.displayName ?? "none"
        let method = try await select(target)
        return "'\(before.prefix(30))' → second row '\(target.displayName.prefix(30))' via \(method)"
    }

    private func tabs() async throws -> String {
        var log: [String] = []
        for tab in [RecordingDetailTab.notes, .export, .review] {
            let segment = try await segment(in: "msr.detail.tabs", label: tab.rawValue)
            try check(await ax.press(segment), "AXPress on the \(tab.rawValue) segment failed")
            try check(await ax.waitUntil(timeout: 2) { self.viewModel.selectedDetailTab == tab },
                      "selectedDetailTab is \(viewModel.selectedDetailTab.rawValue), expected \(tab.rawValue)")
            log.append(tab.rawValue)
        }
        return "selectedDetailTab followed " + log.joined(separator: " → ")
    }

    private func readEditToggle() async throws -> String {
        // The Read/Edit switch only exists for recordings with timed segments.
        let recording = try require(
            viewModel.filteredRecordings.first { FileManager.default.fileExists(atPath: $0.transcriptSegmentsURL.path) },
            "no fixture recording has transcript segments"
        )
        if viewModel.selectedRecording?.id != recording.id {
            _ = try await select(recording)
        }
        let notes = try await segment(in: "msr.detail.tabs", label: RecordingDetailTab.notes.rawValue)
        await ax.press(notes)
        try check(await ax.waitUntil(timeout: 2) { self.viewModel.selectedDetailTab == .notes }, "Notes tab did not open")
        try check(!viewModel.transcriptSegments.isEmpty, "selected recording has no segments loaded")

        let probe = String(viewModel.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        try check(!probe.isEmpty, "transcript text is empty")
        let editorQuery = AXDriver.Query(role: kAXTextAreaRole, text: probe)
        try check(await ax.find(editorQuery) == nil, "transcript TextEditor visible before pressing Edit text")

        let edit = try await segment(in: "msr.notes.transcriptMode", label: TranscriptMode.edit.rawValue)
        try check(await ax.press(edit), "AXPress on Edit text failed")
        let editor = await ax.waitFor(editorQuery, timeout: 3)
        try check(editor != nil, "no AX text area containing the transcript appeared after Edit text")

        let read = try await segment(in: "msr.notes.transcriptMode", label: TranscriptMode.read.rawValue)
        try check(await ax.press(read), "AXPress on Read failed")
        try check(await ax.waitForAbsence(editorQuery, timeout: 3), "transcript TextEditor still visible after Read")
        let identifier = editor?.identifier.isEmpty == false ? editor!.identifier : "no id"
        return "Edit text → AXTextArea (\(identifier)) holding the transcript; Read → gone"
    }

    private func search() async throws -> String {
        let total = viewModel.filteredRecordings.count
        let query = "Northwind"
        let field = try require(await ax.waitFor(AXDriver.Query(identifier: "msr.sidebar.search")),
                                "search field (msr.sidebar.search) not in AX tree")
        let method = try require(
            await ax.setText(query, on: field, in: try require(mainWindow(), "no main window")) { self.viewModel.recordingSearchQuery == query },
            "could not set the search field value (query is '\(viewModel.recordingSearchQuery)'; \(ax.lastTextFailure))"
        )
        try check(await ax.waitUntil(timeout: 3) { self.viewModel.filteredRecordings.count == 1 },
                  "filteredRecordings.count is \(viewModel.filteredRecordings.count) after debounce, expected 1")
        let match = viewModel.filteredRecordings.first?.displayName ?? ""

        let clear = try require(await ax.waitFor(AXDriver.Query(identifier: "msr.sidebar.searchClear")),
                                "clear-search button not in AX tree")
        try check(await ax.press(clear), "AXPress on clear search failed")
        try check(await ax.waitUntil(timeout: 3) {
            self.viewModel.recordingSearchQuery.isEmpty && self.viewModel.filteredRecordings.count == total
        }, "after clear: query '\(viewModel.recordingSearchQuery)', count \(viewModel.filteredRecordings.count) (expected \(total))")
        return "'\(query)' via \(method) → 1 result ('\(match.prefix(30))…'); clear button → \(total)"
    }

    private func inlineRenameCommit(window: NSWindow) async throws -> String {
        let recording = try require(viewModel.selectedRecording, "no recording selected")
        let field = try await openTitleField()
        let newName = "Walkthrough Title"
        let method = try require(
            await ax.setText(newName, on: field, in: window) { self.viewModel.renameDraft == newName },
            "could not set the title field (renameDraft '\(viewModel.renameDraft)'; \(ax.lastTextFailure))"
        )
        try await ensureEditing(field, in: window)
        await ax.sendKey(.returnKey, to: window)
        try check(await ax.waitUntil(timeout: 3) { self.viewModel.selectedRecording?.displayName == newName },
                  "displayName is '\(viewModel.selectedRecording?.displayName ?? "nil")' after Return")
        try check(await ax.waitForAbsence(AXDriver.Query(identifier: "msr.detail.titleField"), timeout: 2),
                  "title field still visible after Return")
        let source = try metadataString("titleSource", for: viewModel.selectedRecording ?? recording)
        try check(source == "user", "on-disk titleSource is \(source ?? "nil"), expected user")
        return "pencil → field; value via \(method); Return → displayName '\(newName)', titleSource=user on disk"
    }

    private func inlineRenameCancel(window: NSWindow) async throws -> String {
        let recording = try require(viewModel.selectedRecording, "no recording selected")
        let before = recording.displayName
        let field = try await openTitleField()
        let method = try require(
            await ax.setText("Cancelled Title", on: field, in: window) { self.viewModel.renameDraft == "Cancelled Title" },
            "could not set the title field (\(ax.lastTextFailure))"
        )
        try await ensureEditing(field, in: window)
        await ax.sendKey(.escape, to: window)
        try check(await ax.waitForAbsence(AXDriver.Query(identifier: "msr.detail.titleField"), timeout: 2),
                  "title field still visible after Escape")
        try? await Task.sleep(for: .milliseconds(300))
        let after = viewModel.selectedRecording?.displayName ?? "nil"
        try check(after == before, "displayName changed to '\(after)' after Escape")
        let onDisk = try metadataString("displayName", for: recording)
        try check(onDisk == before, "on-disk displayName is '\(onDisk ?? "nil")'")
        return "value via \(method); Escape → field closed, name still '\(before)'"
    }

    private func settingsWindowToggles() async throws -> String {
        settingsWindow()?.performClose(nil)
        let gear = try require(await ax.find(AXDriver.Query(identifier: "msr.recordingBar.settings")),
                               "gear button not in AX tree")
        try check(await ax.press(gear), "AXPress on the gear failed")
        var window: NSWindow?
        try check(await ax.waitUntil(timeout: 3) {
            window = self.settingsWindow()
            return window != nil
        }, "no window titled '\(Self.settingsTitle)' appeared")
        let settings = window!
        let title = Self.settingsTitle

        let segment = try await segment(in: "msr.settings.tabs", label: "Transcription & AI", window: title)
        try check(await ax.press(segment), "AXPress on Transcription & AI failed")
        let autoTranscribe = try require(
            await ax.waitFor(AXDriver.Query(identifier: "msr.settings.autoTranscribe"), window: title, timeout: 3),
            "auto-transcribe toggle not found after switching tabs"
        )
        try check(viewModel.settings.autoTranscribe == false, "autoTranscribe should start false")
        try check(await ax.press(autoTranscribe), "AXPress on the auto-transcribe toggle failed")
        try check(await ax.waitUntil(timeout: 2) { self.viewModel.settings.autoTranscribe == true },
                  "autoTranscribe still false after the first press")
        try check(await ax.press(autoTranscribe), "second AXPress failed")
        try check(await ax.waitUntil(timeout: 2) { self.viewModel.settings.autoTranscribe == false },
                  "autoTranscribe still true after the second press")
        // Leave it ON through the control itself: step 7 relies on this toggle, not on
        // a programmatic assignment, to make the next recording transcribe automatically.
        try check(await ax.press(autoTranscribe), "third AXPress failed")
        try check(await ax.waitUntil(timeout: 2) { self.viewModel.settings.autoTranscribe == true },
                  "autoTranscribe still false after the third press")

        let autoTitle = try require(await ax.find(AXDriver.Query(identifier: "msr.settings.autoTitle"), window: title),
                                    "auto-title toggle not found")
        let titleBefore = viewModel.settings.autoTitle
        await ax.press(autoTitle)
        try check(await ax.waitUntil(timeout: 2) { self.viewModel.settings.autoTitle == !titleBefore },
                  "autoTitle did not flip on the first press")
        await ax.press(autoTitle)
        try check(await ax.waitUntil(timeout: 2) { self.viewModel.settings.autoTitle == titleBefore },
                  "autoTitle did not flip back on the second press")

        settings.performClose(nil)
        try check(await ax.waitUntil(timeout: 2) { !settings.isVisible }, "settings window did not close")
        return "gear → '\(title)'; Transcription & AI; auto-transcribe (\(autoTranscribe.role)) false→true→false→true (left on via the toggle); auto-title \(titleBefore)→\(!titleBefore)→\(titleBefore); closed"
    }

    /// Opens Settings (gear) on the Transcription & AI tab; returns the window.
    private func openTranscriptionSettings() async throws -> NSWindow {
        if settingsWindow() == nil {
            let gear = try require(await ax.find(AXDriver.Query(identifier: "msr.recordingBar.settings")),
                                   "gear button not in AX tree")
            try check(await ax.press(gear), "AXPress on the gear failed")
        }
        var window: NSWindow?
        try check(await ax.waitUntil(timeout: 3) {
            window = self.settingsWindow()
            return window != nil
        }, "no window titled '\(Self.settingsTitle)' appeared")
        let segment = try await segment(in: "msr.settings.tabs", label: "Transcription & AI", window: Self.settingsTitle)
        try check(await ax.press(segment), "AXPress on Transcription & AI failed")
        _ = await ax.waitFor(AXDriver.Query(identifier: "msr.settings.autoTranscribe"), window: Self.settingsTitle, timeout: 3)
        return window!
    }

    private func closeSettings(_ window: NSWindow) async throws {
        window.performClose(nil)
        try check(await ax.waitUntil(timeout: 2) { !window.isVisible }, "settings window did not close")
    }

    /// The pop-up button of a Picker whose identifier may sit on the button or a wrapper.
    private func popUpButton(identifier: String, window: String) async throws -> AXNode {
        let control = try require(await ax.waitFor(AXDriver.Query(identifier: identifier), window: window, timeout: 3),
                                  "\(identifier) not in AX tree")
        if control.role == kAXPopUpButtonRole { return control }
        let nodes = await ax.snapshot(window: window)
        return try require(ax.descendants(of: control, in: nodes).first { $0.role == kAXPopUpButtonRole },
                           "\(identifier) is \(control.role) without an AXPopUpButton inside")
    }

    private func transcriptionLanguagePicker() async throws -> String {
        let settings = try await openTranscriptionSettings()
        let title = Self.settingsTitle
        let start = viewModel.settings.transcriptionLanguage
        var log: [String] = []
        // End on English: step 7 transcribes an English clip with this hint.
        for (label, expected) in [("Bahasa Indonesia", TranscriptionLanguage.indonesian), ("English", .english)] {
            var attempts = 0
            var result: (AXDriver.MenuOutcome, String)
            repeat {
                // The pop-up is rebuilt after a selection; give it a moment, then retry once.
                if attempts > 0 { try? await Task.sleep(for: .milliseconds(400)) }
                let popup = try await popUpButton(identifier: "msr.settings.transcriptionLanguage", window: title)
                result = await ax.choose(label, fromMenuButton: popup)
                attempts += 1
            } while !result.0.opened && attempts < 3
            let (outcome, method) = result
            try check(outcome.opened, "the language pop-up did not open for '\(label)' via \(method) after \(attempts) attempts")
            try check(outcome.chosen, "no '\(label)' item in the language menu (items: \(outcome.items))")
            try check(await ax.waitUntil(timeout: 2) { self.viewModel.settings.transcriptionLanguage == expected },
                      "transcriptionLanguage is \(viewModel.settings.transcriptionLanguage.rawValue) after choosing \(label)")
            try check(expected.languageCode == expected.rawValue, "\(label) sends language code \(expected.languageCode ?? "nil")")
            log.append("\(label) → \(expected.rawValue)\(attempts > 1 ? " (attempt \(attempts))" : "")")
        }
        try await closeSettings(settings)
        return "start \(start.rawValue); pop-up (\(AXDriver.Query(identifier: "msr.settings.transcriptionLanguage"))) " + log.joined(separator: "; ")
    }

    /// Passes with or without an OpenAI/DeepSeek key: with one the toggle flips
    /// (and is restored); without one it must be disabled with the key footer.
    private func autoSummarizeToggle() async throws -> String {
        let settings = try await openTranscriptionSettings()
        let title = Self.settingsTitle
        let query = AXDriver.Query(identifier: "msr.settings.autoSummarize")
        let toggle = try require(await ax.waitFor(query, window: title, timeout: 3), "auto-summarize toggle not found")
        let enabled = ax.bool(toggle, kAXEnabledAttribute)
        let before = viewModel.settings.autoSummarize
        let path: String
        if viewModel.canSummarize {
            try check(enabled != false, "toggle is disabled although a summary key exists")
            try check(await ax.press(toggle), "AXPress on the auto-summarize toggle failed")
            try check(await ax.waitUntil(timeout: 2) { self.viewModel.settings.autoSummarize == !before },
                      "autoSummarize did not flip on the first press")
            try check(viewModel.autoSummarizeIsEffective == !before, "autoSummarizeIsEffective does not follow the toggle")
            // Restore, so step 7 does not run (and bill) a summary unless it was already on.
            await ax.press(try require(await ax.find(query, window: title), "toggle vanished"))
            try check(await ax.waitUntil(timeout: 2) { self.viewModel.settings.autoSummarize == before },
                      "autoSummarize did not flip back on the second press")
            path = "key path (\(viewModel.resolvedSummaryProvider?.displayName ?? "?")): enabled, \(before)→\(!before)→\(before)"
        } else {
            try check(enabled == false, "toggle is enabled without an OpenAI or DeepSeek key (AXEnabled \(String(describing: enabled)))")
            await ax.press(toggle)
            try? await Task.sleep(for: .milliseconds(300))
            try check(viewModel.settings.autoSummarize == before, "pressing the disabled toggle changed autoSummarize")
            try check(!viewModel.autoSummarizeIsEffective, "autoSummarizeIsEffective is true without a key")
            let footer = await ax.find(AXDriver.Query(text: "Requires an OpenAI or DeepSeek API key"), window: title)
            try check(footer != nil, "no 'Requires an OpenAI or DeepSeek API key.' footer")
            path = "no-key path: AXEnabled=false, press ignored, footer shown, not effective"
        }
        let deepSeekField = await ax.find(AXDriver.Query(identifier: "msr.settings.deepSeekKey"), window: title)
        let deepSeekTest = await ax.find(AXDriver.Query(identifier: "msr.settings.testDeepSeek"), window: title)
        try check(deepSeekField != nil && deepSeekTest != nil, "DeepSeek key field or Test button missing")
        try await closeSettings(settings)
        return path + "; DeepSeek key row present"
    }

    private func recordViaButton() async throws -> String {
        try check(viewModel.credentialAvailable(for: viewModel.settings.provider),
                  "no API key for \(viewModel.settings.provider.displayName)")
        // Both switches must already be on from step 6's presses on the Settings
        // controls; this step never sets them programmatically.
        try check(viewModel.settings.autoTranscribe, "autoTranscribe is off: step 6 should have left the toggle on")
        try check(viewModel.settings.autoTitle, "autoTitle is off: step 6 should have left it at its default (on)")
        let existing = Set(viewModel.recordings.map(\.id))
        let recordQuery = AXDriver.Query(identifier: "msr.recordingBar.record")

        let record = try require(await ax.find(recordQuery), "Record button not in AX tree")
        let startLabel = record.texts.first ?? ""
        try check(await ax.press(record), "AXPress on Record failed")
        try check(await ax.waitUntil(timeout: 3) { self.viewModel.isRecording },
                  "isRecording false 3 s after pressing Record (\(viewModel.statusMessage))")
        var stopQuery = recordQuery
        stopQuery.exactText = "Stop Recording"
        try check(await ax.waitFor(stopQuery, timeout: 2) != nil, "Record button label did not become 'Stop Recording'")
        try? await Task.sleep(for: .seconds(2))

        observedStates.removeAll()
        let stop = try require(await ax.find(recordQuery), "Stop button not in AX tree")
        try check(await ax.press(stop), "AXPress on Stop Recording failed")
        try check(await ax.waitUntil(timeout: 20) {
            !self.viewModel.isRecording && self.viewModel.recordings.contains { !existing.contains($0.id) }
        }, "recording did not finish (\(viewModel.statusMessage))")
        try check(observedStates.contains(.saved), "workflowState never reached .saved (\(observedStates))")
        let recording = try require(viewModel.recordings.first { !existing.contains($0.id) }, "new recording missing")
        walkthroughRecordingID = recording.id

        var job: TranscriptionJob?
        let finished = await ax.waitUntil(timeout: 120) {
            job = self.latestJob(for: recording.id)
            guard let status = job?.status else { return false }
            return [.completed, .failed, .cancelled].contains(status)
        }
        try check(job != nil, "no transcription job was queued (\(viewModel.statusMessage))")
        try check(finished, "transcription still \(job?.status.rawValue ?? "?") after 120 s")
        try check(job?.status == .completed, "job ended \(job?.status.rawValue ?? "?"): \(job?.errorMessage ?? "")")

        var source: String?
        _ = await ax.waitUntil(timeout: 5) {
            source = try? self.metadataString("titleSource", for: recording)
            return source == "generated"
        }
        try check(source == "generated", "on-disk titleSource is \(source ?? "nil"), expected generated")

        if viewModel.selectedRecording?.id != recording.id,
           let refreshed = viewModel.recordings.first(where: { $0.id == recording.id }) {
            _ = try await select(refreshed)
        }
        let chip = await ax.waitFor(AXDriver.Query(identifier: "msr.detail.chip.autoTitled"), timeout: 5)
        let chipByText = chip == nil ? await ax.find(AXDriver.Query(exactText: "Auto-titled")) : nil
        try check(chip != nil || chipByText != nil, "no 'Auto-titled' chip in the AX tree")
        let title = viewModel.recordings.first { $0.id == recording.id }?.displayName ?? "?"
        return "'\(startLabel)' → isRecording, label 'Stop Recording'; stop → .saved, new recording; job completed in queue; title '\(title)' (generated on disk); 'Auto-titled' chip by \(chip != nil ? "identifier" : "text")"
    }

    private func overflowMenuCopy() async throws -> String {
        let transcript = viewModel.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        try check(!transcript.isEmpty, "selected recording has no transcript")
        let firstWords = firstWordsOf(transcript)
        let more = try require(await ax.find(AXDriver.Query(identifier: "msr.detail.moreActions")),
                               "'More actions' menu button not in AX tree")
        return try await withPasteboardRestored { pasteboard in
            let (outcome, method) = await ax.choose("Copy Transcript", fromMenuButton: more)
            try check(outcome.opened, "the More actions menu did not open via \(method)")
            try check(outcome.chosen, "no 'Copy Transcript' item in the open menu (items: \(outcome.items))")
            try check(await ax.waitUntil(timeout: 2) { pasteboard.string(forType: .string)?.contains(firstWords) == true },
                      "pasteboard does not contain '\(firstWords)'")
            return "⋯ opened via \(method) (\(outcome.items.count) items) → AXPress 'Copy Transcript' → pasteboard has '\(firstWords)…' (clipboard restored)"
        }
    }

    private func menuCopyTranscript() async throws -> String {
        let transcript = viewModel.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        try check(!transcript.isEmpty, "selected recording has no transcript")
        let firstWords = firstWordsOf(transcript)
        return try await withPasteboardRestored { pasteboard in
            let result = ax.performMainMenuItem(["Recording", "Copy Transcript"])
            try check(result == .performed, "menu Recording → Copy Transcript: \(result)")
            try check(await ax.waitUntil(timeout: 2) { pasteboard.string(forType: .string)?.contains(firstWords) == true },
                      "pasteboard does not contain '\(firstWords)'")
            return "Recording → Copy Transcript → pasteboard has '\(firstWords)…' (clipboard restored)"
        }
    }

    /// Notes → Read mode → speaker chip → popover; Return saves the name to
    /// the transcript, segments and metadata; Escape cancels; ⋯ → Reset reverts.
    private func speakerRename(window: NSWindow) async throws -> String {
        let recording = try require(
            viewModel.filteredRecordings.first { FileManager.default.fileExists(atPath: $0.transcriptSegmentsURL.path) },
            "no fixture recording has transcript segments"
        )
        if viewModel.selectedRecording?.id != recording.id {
            _ = try await select(recording)
        }
        let notes = try await segment(in: "msr.detail.tabs", label: RecordingDetailTab.notes.rawValue)
        await ax.press(notes)
        try check(await ax.waitUntil(timeout: 2) { self.viewModel.selectedDetailTab == .notes }, "Notes tab did not open")
        let read = try await segment(in: "msr.notes.transcriptMode", label: TranscriptMode.read.rawValue)
        await ax.press(read)
        let original = try require(viewModel.readModeSegments.first?.speaker, "no segments in Read mode")
        try check(!original.isEmpty, "first segment has no speaker")
        let newName = "Dana Walkthrough"

        let chipQuery = AXDriver.Query(identifier: "msr.notes.speaker.0")
        let chip = try require(await ax.waitFor(chipQuery, timeout: 3), "speaker chip msr.notes.speaker.0 not in AX tree")
        try check(chip.texts.contains(original), "chip reads \(chip.texts), expected '\(original)'")

        // Escape cancels without renaming.
        let fieldQuery = AXDriver.Query(identifier: "msr.notes.speakerNameField")
        let (cancelField, popover) = try await openSpeakerPopover(chipQuery, fieldQuery)
        try check(ax.string(cancelField) == original, "popover field prefilled with '\(ax.string(cancelField) ?? "nil")', expected '\(original)'")
        _ = await ax.setText("Not Saved", on: cancelField, in: popover) { self.ax.string(cancelField) == "Not Saved" }
        await ax.sendKey(.escape, to: popover)
        var cancelMethod = "Escape"
        if !(await ax.waitForAbsence(fieldQuery, timeout: 2)) {
            let cancel = try require(await ax.find(AXDriver.Query(identifier: "msr.notes.speakerCancel")), "no Cancel button")
            await ax.press(cancel)
            cancelMethod = "Cancel button (Escape did not reach the popover)"
            try check(await ax.waitForAbsence(fieldQuery, timeout: 2), "popover still open after Cancel")
        }
        try check(try metadataObject("speakerNames", for: recording) == nil, "cancel wrote speakerNames")

        // Return saves.
        let (field, popoverWindow) = try await openSpeakerPopover(chipQuery, fieldQuery)
        let typed = try require(
            await ax.setText(newName, on: field, in: popoverWindow) { self.ax.string(field) == newName },
            "could not type into the speaker name field (\(ax.lastTextFailure))"
        )
        await ax.sendKey(.returnKey, to: popoverWindow)
        var saveMethod = "Return"
        func savedOnDisk() -> Bool {
            ((try? metadataObject("speakerNames", for: recording)) as? [String: String])?[original] == newName
        }
        if !(await ax.waitUntil(timeout: 2, savedOnDisk)) {
            let save = try require(await ax.find(AXDriver.Query(identifier: "msr.notes.speakerSave")), "no Save button")
            await ax.press(save)
            saveMethod = "Save button (Return did not reach the popover)"
            try check(await ax.waitUntil(timeout: 2, savedOnDisk), "speakerNames on disk: \(String(describing: try? metadataObject("speakerNames", for: recording)))")
        }
        try check(viewModel.selectedRecording?.speakerNames[original] == newName, "view model speakerNames \(viewModel.selectedRecording?.speakerNames ?? [:])")
        let transcript = (try? String(contentsOf: recording.transcriptURL, encoding: .utf8)) ?? ""
        try check(transcript.contains(newName), "transcript on disk does not mention '\(newName)'")
        var renamedChip = chipQuery
        renamedChip.exactText = newName
        try check(await ax.waitFor(renamedChip, timeout: 3) != nil, "chip did not change to '\(newName)'")

        // ⋯ → Reset speaker names reverts transcript and metadata.
        let more = try require(await ax.find(AXDriver.Query(identifier: "msr.detail.moreActions")), "no More actions button")
        let (outcome, method) = await ax.choose("Reset speaker names", fromMenuButton: more)
        try check(outcome.chosen, "no enabled 'Reset speaker names' item (items: \(outcome.items)) via \(method)")
        try check(await ax.waitUntil(timeout: 3) { (try? self.metadataObject("speakerNames", for: recording)) == nil },
                  "speakerNames still on disk after reset")
        var resetChip = chipQuery
        resetChip.exactText = original
        try check(await ax.waitFor(resetChip, timeout: 3) != nil, "chip did not return to '\(original)'")
        return "chip '\(original)' → popover (prefilled); \(cancelMethod) cancels; typed via \(typed); \(saveMethod) → speakerNames['\(original)']='\(newName)' on disk + transcript, chip '\(newName)'; ⋯ Reset → '\(original)'"
    }

    private func openSpeakerPopover(_ chip: AXDriver.Query, _ field: AXDriver.Query) async throws -> (AXNode, NSWindow) {
        let node = try require(await ax.find(chip), "speaker chip missing")
        try check(await ax.press(node), "AXPress on the speaker chip failed")
        let fieldNode = try require(await ax.waitFor(field, timeout: 3), "speaker name popover did not open")
        var popover: NSWindow?
        _ = await ax.waitUntil(timeout: 2) {
            popover = NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
            return popover != nil
        }
        return (fieldNode, try require(popover ?? NSApp.keyWindow, "no popover window"))
    }

    private func menuCopyMeetingNotes() async throws -> String {
        let recording = try require(viewModel.selectedRecording, "no recording selected")
        try check(viewModel.canCopyMeetingNotes, "selected recording has neither transcript nor summary")
        let item = NSApp.mainMenu?.items.first { $0.title == "Recording" }?.submenu?.items.first { $0.title == "Copy Meeting Notes" }
        let shortcut = item.map { "⌘\($0.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")\($0.keyEquivalent.uppercased())" } ?? "none"
        try check(shortcut == "⌘⇧C", "Copy Meeting Notes shortcut is \(shortcut)")
        let expected = "# \(recording.displayName)"
        return try await withPasteboardRestored { pasteboard in
            let result = ax.performMainMenuItem(["Recording", "Copy Meeting Notes"])
            try check(result == .performed, "menu Recording → Copy Meeting Notes: \(result)")
            try check(await ax.waitUntil(timeout: 2) { pasteboard.string(forType: .string)?.hasPrefix(expected) == true },
                      "pasteboard starts with '\(pasteboard.string(forType: .string)?.prefix(40) ?? "nil")', expected '\(expected)'")
            let text = pasteboard.string(forType: .string) ?? ""
            try check(text.contains("## Summary") && text.contains("## Transcript"), "notes lack Summary/Transcript sections")
            return "Recording → Copy Meeting Notes (\(shortcut)) → pasteboard starts '\(expected.prefix(40))', has Summary + Transcript (clipboard restored)"
        }
    }

    private func menuExportTab() async throws -> String {
        let review = ax.performMainMenuItem(["Recording", "Review Tab"])
        try check(review == .performed, "Review Tab: \(review)")
        try check(await ax.waitUntil(timeout: 2) { self.viewModel.selectedDetailTab == .review }, "Review Tab did not apply")
        let export = ax.performMainMenuItem(["Recording", "Export Tab"])
        try check(export == .performed, "Export Tab: \(export)")
        try check(await ax.waitUntil(timeout: 2) { self.viewModel.selectedDetailTab == .export },
                  "selectedDetailTab is \(viewModel.selectedDetailTab.rawValue)")
        return "Review Tab → review; Export Tab (⌘3) → export"
    }

    private func deleteWithConfirmation(window: NSWindow) async throws -> String {
        // With MSR_UI_WALKTHROUGH_ONLY (step 7 skipped) the selected fixture recording stands in.
        let id = try require(walkthroughRecordingID ?? (onlySteps != nil ? viewModel.selectedRecording?.id : nil),
                             "step 7 did not create a recording")
        let recording = try require(viewModel.recordings.first { $0.id == id }, "walkthrough recording not in library")
        if viewModel.selectedRecording?.id != id {
            _ = try await select(recording)
        }
        // The user just used the search field (focus stays there), then picks
        // Recording → Delete Recording… from the menu bar: that must still ask
        // to delete the recording; only the ⌘⌫ keystroke edits the text (9a).
        let focus = try await focusSearchField(in: window)
        let routing = try deleteCommandRouting(window: window)

        let result = ax.performMainMenuItem(["Recording", "Delete Recording…"])
        try check(result == .performed, "menu Recording → Delete Recording…: \(result)")
        let deleteButton = AXDriver.Query(role: kAXButtonRole, exactText: "Delete")
        let button = try require(await ax.waitFor(deleteButton, timeout: 3),
                                 "no confirmation with a 'Delete' button appeared (first responder \(responderName(window)))")
        let nodes = await ax.snapshot()
        let container = ax.ancestor(of: button, in: nodes) { $0.role == kAXSheetRole || $0.role == kAXWindowRole }
        let heading = container.flatMap { sheet in
            ax.descendants(of: sheet, in: nodes).first { $0.role == kAXStaticTextRole && !$0.texts.isEmpty }?.texts.first
        } ?? ""
        try check(window.attachedSheet != nil || container?.role == kAXSheetRole,
                  "the confirmation is not a sheet (container \(container?.role ?? "none"))")
        try check(await ax.press(button), "AXPress on Delete failed")
        try check(await ax.waitUntil(timeout: 3) { !self.viewModel.recordings.contains { $0.id == id } },
                  "recording still in viewModel.recordings")
        let leftovers = [recording.audioURL, recording.metadataURL, recording.transcriptURL]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        try check(leftovers.isEmpty, "files left on disk: \(leftovers.map(\.lastPathComponent))")
        walkthroughRecordingID = nil
        return "focus \(focus); \(routing); menu → sheet '\(heading.prefix(50))' → Delete; gone from viewModel.recordings and disk"
    }

    /// The menu handler only edits text for a ⌘⌫ keystroke. This run's app is
    /// never active (no key window), so check the routing with the events
    /// a real ⌘⌫ and a real menu-bar click would deliver.
    private func deleteCommandRouting(window: NSWindow) throws -> String {
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            if type == .keyDown {
                return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
                                        charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)
            }
            return NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        }
        try check(DeleteRecordingCommand.textViewToEdit(for: event(.keyDown)) != nil,
                  "⌘⌫ typed in the focused search field would not edit the text")
        try check(DeleteRecordingCommand.textViewToEdit(for: event(.leftMouseUp)) == nil,
                  "a menu-bar click while the search field has focus would edit text instead of deleting")
        try check(DeleteRecordingCommand.textViewToEdit(for: nil) == nil, "a programmatic menu action would edit text")
        return "routing: ⌘⌫ keystroke → text edit, menu click → delete"
    }

    /// ⌘⌫ while typing in the search field deletes to the line start and
    /// does not open the delete confirmation.
    private func commandDeleteInTextField(window: NSWindow) async throws -> String {
        let total = viewModel.recordings.count
        let focus = try await focusSearchField(in: window)
        let field = try require(await ax.find(AXDriver.Query(identifier: "msr.sidebar.search")), "search field missing")
        _ = try require(await ax.setText("zzz", on: field, in: window) { self.viewModel.recordingSearchQuery == "zzz" },
                        "could not type into the search field (\(ax.lastTextFailure))")
        await ax.sendKey(.commandDelete, to: window)
        try check(await ax.waitUntil(timeout: 2) { self.viewModel.recordingSearchQuery.isEmpty },
                  "⌘⌫ did not delete the search text (query '\(viewModel.recordingSearchQuery)', key window \(window.isKeyWindow))")
        try? await Task.sleep(for: .milliseconds(400))
        try check(window.attachedSheet == nil, "⌘⌫ in the search field opened the delete confirmation")
        try check(viewModel.recordings.count == total, "a recording was deleted")
        _ = await ax.waitUntil(timeout: 2) { self.viewModel.filteredRecordings.count == total }
        return "focus \(focus); typed 'zzz'; ⌘⌫ (posted key event) → text deleted, no confirmation sheet"
    }

    private func focusSearchField(in window: NSWindow) async throws -> String {
        let field = try require(await ax.find(AXDriver.Query(identifier: "msr.sidebar.search")), "search field missing")
        await ax.set(field, kAXFocusedAttribute, to: kCFBooleanTrue)
        try check(await ax.waitUntil(timeout: 1) { (window.firstResponder as? NSTextView)?.isEditable == true },
                  "search field did not take focus (first responder \(responderName(window)))")
        return "in the search field (AXFocused)"
    }

    private func responderName(_ window: NSWindow) -> String {
        window.firstResponder.map { "\(type(of: $0))" } ?? "nil"
    }

    private func statusBar() async throws -> String {
        let query = AXDriver.Query(identifier: "msr.statusBar.message")
        try check(await ax.find(query) != nil, "status text (msr.statusBar.message) not in AX tree")
        var seen: [String] = []
        let reflects = await waitUntilAsync(timeout: 2) {
            guard let node = await self.ax.find(query) else { return false }
            seen = node.texts
            return node.texts.contains(self.viewModel.statusMessage)
        }
        try check(reflects, "AX texts \(seen) vs statusMessage '\(viewModel.statusMessage)'")
        return "AX status text == statusMessage '\(viewModel.statusMessage)'"
    }

    /// Menu-bar quick recorder: with the main window hidden, opens the panel
    /// (`showQuickRecorder()`), presses its Record button through AX, waits for
    /// `isRecording`, presses it again and checks the new recording on disk.
    /// Auto-transcribe is switched off for the step (no extra provider call).
    private func quickRecorder(window: NSWindow) async throws -> String {
        try check(!viewModel.isRecording && !viewModel.workflowState.isPaused, "a recording session is already active")
        try check(viewModel.canToggleRecording, "recording cannot start now (\(viewModel.workflowState))")
        let savedAutoTranscribe = viewModel.settings.autoTranscribe
        viewModel.settings.autoTranscribe = false
        defer {
            viewModel.settings.autoTranscribe = savedAutoTranscribe
            viewModel.hideQuickRecorder()
            // Bring the main window back without activating the app.
            window.makeKeyAndOrderFront(nil)
        }
        let existing = Set(viewModel.recordings.map(\.id))

        // The panel must work with the main window closed (shared view model).
        window.orderOut(nil)
        try check(await ax.waitUntil(timeout: 2) { self.mainWindow() == nil }, "main window still visible after orderOut")
        viewModel.showQuickRecorder()
        let controller = try require(viewModel.quickRecorder, "no quick recorder controller after showQuickRecorder()")
        try check(await ax.waitUntil(timeout: 2) { controller.isQuickRecorderShown }, "quick recorder panel did not open")

        let panelTitle = QuickRecorderController.panelTitle
        let recordQuery = AXDriver.Query(identifier: "msr.quick.record")
        var axWindow: String? = panelTitle
        if await ax.waitFor(recordQuery, window: panelTitle, timeout: 5) == nil {
            // Borderless panels may not expose their title; search every window.
            axWindow = nil
        }
        let record = try require(await ax.waitFor(recordQuery, window: axWindow, timeout: 3),
                                 "msr.quick.record not in the AX tree of the panel")
        for identifier in ["msr.quick.source", "msr.quick.secondary", "msr.quick.open"] {
            try check(await ax.find(AXDriver.Query(identifier: identifier), window: axWindow) != nil,
                      "\(identifier) not in the AX tree of the panel")
        }
        let startLabel = record.texts.first ?? ""
        try check(await ax.press(record), "AXPress on msr.quick.record failed")
        try check(await ax.waitUntil(timeout: 5) { self.viewModel.isRecording },
                  "isRecording false 5 s after pressing the panel's Record (\(viewModel.statusMessage))")
        var stopQuery = recordQuery
        stopQuery.exactText = "Stop Recording"
        try check(await ax.waitFor(stopQuery, window: axWindow, timeout: 2) != nil,
                  "panel Record button label did not become 'Stop Recording'")
        try check(viewModel.sourcePickerDisabled, "source picker is not disabled while recording")
        let sourceEnabled = await ax.find(AXDriver.Query(identifier: "msr.quick.source"), window: axWindow)
            .flatMap { ax.bool($0, kAXEnabledAttribute) }
        try check(sourceEnabled != true, "panel source picker is enabled in AX while recording")
        let secondary = try require(await ax.find(AXDriver.Query(identifier: "msr.quick.secondary"), window: axWindow),
                                    "msr.quick.secondary missing while recording")
        try check(ax.bool(secondary, kAXEnabledAttribute) != false, "panel Pause button is disabled while recording")
        try check(await ax.waitUntil(timeout: 3) { self.viewModel.live.recordingElapsed >= 1 },
                  "elapsed time did not advance (\(viewModel.live.recordingElapsed))")
        var menuTitle = "item hidden"
        if controller.isStatusItemInserted {
            try check(await ax.waitUntil(timeout: 2) { !controller.statusItemTitle.isEmpty || !self.viewModel.settings.showMenuBarTimer },
                      "menu-bar item shows no elapsed time while recording")
            menuTitle = "'\(controller.statusItemTitle.trimmingCharacters(in: .whitespaces))'"
        }

        let stop = try require(await ax.find(recordQuery, window: axWindow), "msr.quick.record missing while recording")
        try check(await ax.press(stop), "AXPress on the panel's Stop Recording failed")
        try check(await ax.waitUntil(timeout: 20) {
            !self.viewModel.isRecording && self.viewModel.recordings.contains { !existing.contains($0.id) }
        }, "recording did not finish from the panel (\(viewModel.statusMessage))")
        let recording = try require(viewModel.recordings.first { !existing.contains($0.id) }, "new recording missing")
        try check(FileManager.default.fileExists(atPath: recording.audioURL.path), "new recording has no audio file on disk")
        var startQuery = recordQuery
        startQuery.exactText = "Record"
        try check(await ax.waitFor(startQuery, window: axWindow, timeout: 3) != nil, "panel button did not return to 'Record'")
        if controller.isStatusItemInserted {
            try check(await ax.waitUntil(timeout: 2) { controller.statusItemTitle.isEmpty },
                      "menu-bar item still shows '\(controller.statusItemTitle)' after stopping")
        }
        viewModel.hideQuickRecorder()
        try check(!controller.isQuickRecorderShown, "panel still shown after hideQuickRecorder()")
        let lookup = axWindow == nil ? "found across all AX windows" : "AX window '\(panelTitle)'"
        return "main window hidden; panel (\(lookup)) '\(startLabel)' → isRecording, label 'Stop Recording', source locked, menu bar \(menuTitle); stop → new recording '\(recording.displayName.prefix(30))' on disk; panel closed"
    }

    // MARK: Onboarding

    /// Opens the first-run sheet (`Onboarding.present()`, what "Set up MSR…"
    /// calls), walks Next/Back through all four steps via AXPress, flips
    /// auto-transcribe on step 4 and presses Finish.
    private func onboarding() async throws -> String {
        settingsWindow()?.performClose(nil)
        let main = try require(mainWindow(), "no main window")
        viewModel.settings.hasCompletedOnboarding = false
        Onboarding.present()
        try check(await ax.waitUntil(timeout: 3) { main.attachedSheet != nil }, "onboarding sheet did not open")
        var path = [try await expectOnboardingStep(1)]
        try check(await ax.find(AXDriver.Query(identifier: "msr.onboarding.back")) == nil, "Back is shown on step 1")

        try await pressOnboarding("next")
        path.append(try await expectOnboardingStep(2))
        try check(!viewModel.onboardingPermissionItems.isEmpty, "Permissions step has no microphone/system audio rows")
        for item in viewModel.onboardingPermissionItems {
            try check(await ax.find(AXDriver.Query(identifier: "msr.onboarding.fix.\(item.id)")) != nil,
                      "no Open Privacy Settings button for \(item.id)")
        }
        try await pressOnboarding("back")
        path.append(try await expectOnboardingStep(1))
        for number in 2...4 {
            try await pressOnboarding("next")
            path.append(try await expectOnboardingStep(number))
            if number == 3 {
                let status = try require(await ax.find(AXDriver.Query(identifier: "msr.onboarding.keyStatus.elevenLabs")),
                                         "ElevenLabs key status chip not in AX tree")
                let expected = OnboardingView.chipTitle(
                    saved: viewModel.hasSavedCredential(.elevenLabs),
                    drafted: !viewModel.elevenLabsKeyDraft.isEmpty,
                    remembered: viewModel.settings.rememberCredentials
                )
                let nodes = await ax.snapshot()
                let texts = status.texts + ax.descendants(of: status, in: nodes).flatMap(\.texts)
                try check(texts.contains(expected), "ElevenLabs key status reads \(texts), expected \(expected)")
            }
        }
        try check(await ax.find(AXDriver.Query(identifier: "msr.onboarding.next")) == nil, "Next is still shown on step 4")

        let toggle = try require(await ax.waitFor(AXDriver.Query(identifier: "msr.onboarding.autoTranscribe"), timeout: 2),
                                 "auto-transcribe toggle (msr.onboarding.autoTranscribe) not in AX tree")
        let before = viewModel.settings.autoTranscribe
        try check(await ax.press(toggle), "AXPress on the auto-transcribe toggle failed")
        try check(await ax.waitUntil(timeout: 2) { self.viewModel.settings.autoTranscribe == !before },
                  "autoTranscribe is still \(before) after pressing the toggle")
        let summarize = try require(await ax.find(AXDriver.Query(identifier: "msr.onboarding.autoSummarize")),
                                    "auto-summarize toggle not in AX tree")
        let summarizeEnabled = ax.bool(summarize, kAXEnabledAttribute)
        try check(summarizeEnabled == viewModel.canSummarize,
                  "auto-summarize enabled=\(summarizeEnabled.map(String.init) ?? "nil") but canSummarize=\(viewModel.canSummarize)")

        try await pressOnboarding("finish")
        try check(await ax.waitUntil(timeout: 3) { self.viewModel.settings.hasCompletedOnboarding },
                  "hasCompletedOnboarding is still false after Finish")
        try check(await ax.waitUntil(timeout: 3) { main.attachedSheet == nil }, "sheet still attached after Finish")
        try check(await ax.waitForAbsence(AXDriver.Query(identifier: "msr.onboarding.finish"), timeout: 2),
                  "onboarding controls still in the AX tree after Finish")
        return "sheet opened; steps " + path.joined(separator: "→")
            + "; auto-transcribe \(before)→\(!before); auto-summarize enabled=\(viewModel.canSummarize); Finish → hasCompletedOnboarding=true, sheet gone"
    }

    /// Esc (the Skip button's cancel shortcut) closes the sheet and still marks it done.
    private func onboardingEscape() async throws -> String {
        let main = try require(mainWindow(), "no main window")
        if main.attachedSheet != nil {
            // Left open by a failed step 13: close it so this step starts on Welcome.
            try? await pressOnboarding("skip")
            _ = await ax.waitUntil(timeout: 2) { main.attachedSheet == nil }
        }
        viewModel.settings.hasCompletedOnboarding = false
        Onboarding.present()
        try check(await ax.waitUntil(timeout: 3) { main.attachedSheet != nil }, "onboarding sheet did not open")
        _ = try await expectOnboardingStep(1)
        let sheet = try require(main.attachedSheet, "no sheet")
        sheet.makeKeyAndOrderFront(nil)
        _ = await ax.waitUntil(timeout: 1) { sheet.isKeyWindow }
        await ax.sendKey(.escape, to: sheet)
        var method = "Esc (posted key event)"
        if !(await ax.waitUntil(timeout: 1.5) { main.attachedSheet == nil }) {
            // An inactive app may not route the key to the sheet; Skip is the same action.
            method = "Skip (AXPress; Esc not delivered, sheet key=\(sheet.isKeyWindow) active=\(NSApp.isActive))"
            try await pressOnboarding("skip")
        }
        try check(await ax.waitUntil(timeout: 3) { main.attachedSheet == nil }, "sheet still attached after \(method)")
        try check(viewModel.settings.hasCompletedOnboarding, "hasCompletedOnboarding is false after \(method)")
        return "\(method) → sheet closed, hasCompletedOnboarding=true"
    }

    private func pressOnboarding(_ control: String) async throws {
        let identifier = "msr.onboarding.\(control)"
        let button = try require(await ax.waitFor(AXDriver.Query(identifier: identifier), timeout: 2),
                                 "\(identifier) not in AX tree")
        try check(await ax.press(button), "AXPress on \(identifier) failed")
    }

    @discardableResult
    private func expectOnboardingStep(_ number: Int) async throws -> String {
        try check(await ax.waitFor(AXDriver.Query(identifier: "msr.onboarding.step.\(number)"), timeout: 2) != nil,
                  "msr.onboarding.step.\(number) not in AX tree")
        return String(number)
    }

    // MARK: Empty library

    private func runEmptyLibrary() async {
        guard await prepare() != nil else {
            record("setup", ok: false, detail: "main window did not appear")
            return
        }
        await step("11a-empty-ready-state") {
            try self.check(self.viewModel.recordings.isEmpty, "library is not empty (\(self.viewModel.recordings.count))")
            let title = await self.ax.waitFor(AXDriver.Query(identifier: "msr.ready.title"), timeout: 3)
            try self.check(title?.texts.contains("Ready to record") == true,
                           "'Ready to record' (msr.ready.title) not in the AX tree (\(title?.summary ?? "missing"))")
            let empty = await self.ax.find(AXDriver.Query(text: "No recordings yet"))
            return "'Ready to record' shown, no selection; sidebar empty state \(empty != nil ? "shown" : "missing")"
        }
        await step("11b-empty-setup-fixes") {
            let items = self.viewModel.setupItemsNeedingAttention
            var found: [String] = []
            for item in items {
                let expected = self.viewModel.fixActionTitle(for: item)
                let button = try self.require(
                    await self.ax.find(AXDriver.Query(identifier: "msr.ready.fix.\(item.id)")),
                    "no fix button for setup item '\(item.id)' (\(item.severity))"
                )
                try self.check(button.texts.contains(expected),
                               "fix button for \(item.id) reads \(button.texts), expected '\(expected)'")
                found.append("\(item.id)=\(expected)")
            }
            return items.isEmpty
                ? "no setup item needs attention, so no fix buttons expected"
                : "fix buttons present, not pressed: " + found.joined(separator: ", ")
        }
    }

    // MARK: Helpers

    private func select(_ recording: RecordingItem) async throws -> String {
        let identifier = "msr.sidebar.row.\(recording.id.uuidString)"
        let row = try require(await ax.waitFor(AXDriver.Query(identifier: identifier), timeout: 3),
                              "sidebar row \(identifier) not in AX tree")
        let method = await ax.selectRow(containing: row) { self.viewModel.selectedRecording?.id == recording.id }
        return try require(method, "row '\(recording.displayName)' did not become selected (still '\(viewModel.selectedRecording?.displayName ?? "nil")')")
    }

    /// The segment labelled `label` inside the segmented control `identifier`.
    private func segment(in identifier: String, label: String, window: String? = nil) async throws -> AXNode {
        let control = try require(await ax.waitFor(AXDriver.Query(identifier: identifier), window: window, timeout: 3),
                                  "\(identifier) not in AX tree")
        let nodes = await ax.snapshot(window: window)
        let candidates = ax.descendants(of: control, in: nodes)
        if let match = candidates.first(where: AXDriver.Query(exactText: label).matches) {
            return match
        }
        throw StepFailure(detail: "no '\(label)' segment in \(identifier) [\(candidates.map(\.summary).joined(separator: " | "))]")
    }

    private func openTitleField() async throws -> AXNode {
        let fieldQuery = AXDriver.Query(identifier: "msr.detail.titleField")
        if let open = await ax.find(fieldQuery) { return open }
        let pencil = try require(await ax.find(AXDriver.Query(identifier: "msr.detail.rename")),
                                 "rename pencil (msr.detail.rename) not in AX tree")
        try check(await ax.press(pencil), "AXPress on the rename pencil failed")
        return try require(await ax.waitFor(fieldQuery, timeout: 2), "title text field did not appear after pressing the pencil")
    }

    /// Return/Escape go to the first responder: make sure it is the title field's editor.
    private func ensureEditing(_ field: AXNode, in window: NSWindow) async throws {
        if window.firstResponder is NSTextView { return }
        await ax.set(field, kAXFocusedAttribute, to: kCFBooleanTrue)
        try check(await ax.waitUntil(timeout: 1) { window.firstResponder is NSTextView },
                  "title field is not focused (first responder \(String(describing: window.firstResponder)))")
    }

    private func withPasteboardRestored(_ body: (NSPasteboard) async throws -> String) async throws -> String {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            // Leave the user's clipboard as it was.
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pasteboard.clearContents()
        return try await body(pasteboard)
    }

    private func firstWordsOf(_ text: String) -> String {
        // Skip "[00:00] Speaker 1:" / "Speaker 1:" header lines so the probe is real speech.
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let speech = lines.first { !$0.isEmpty && !$0.hasPrefix("[") && !$0.hasSuffix(":") } ?? text
        return speech.split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
    }

    private func metadataObject(_ key: String, for recording: RecordingItem) throws -> Any? {
        let data = try Data(contentsOf: recording.metadataURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?[key]
    }

    private func metadataString(_ key: String, for recording: RecordingItem) throws -> String? {
        let data = try Data(contentsOf: recording.metadataURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?[key] as? String
    }

    private func latestJob(for recordingID: UUID) -> TranscriptionJob? {
        viewModel.transcriptionJobs
            .filter { $0.recordingID == recordingID }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private func waitUntilAsync(timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if await condition() { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func check(_ condition: Bool, _ detail: @autoclosure () -> String) throws {
        if !condition { throw StepFailure(detail: detail()) }
    }

    private func require<T>(_ value: T?, _ detail: @autoclosure () -> String) throws -> T {
        guard let value else { throw StepFailure(detail: detail()) }
        return value
    }

    private var onlySteps: [String]? {
        environment["MSR_UI_WALKTHROUGH_ONLY"].map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    private func step(_ name: String, _ body: () async throws -> String) async {
        if let onlySteps, !onlySteps.contains(String(name.prefix { $0.isNumber })) {
            return
        }
        do {
            let detail = try await body()
            record(name, ok: true, detail: detail)
        } catch let failure as StepFailure {
            record(name, ok: false, detail: failure.detail)
        } catch {
            record(name, ok: false, detail: error.localizedDescription)
        }
    }

    private func record(_ name: String, ok: Bool, detail: String) {
        if ok { passed += 1 } else { failed += 1 }
        Self.write("{\"step\":\(Self.json(name)),\"ok\":\(ok),\"detail\":\(Self.json(detail))}")
        if !ok, environment["MSR_UI_WALKTHROUGH_DUMP"] != nil {
            Task { ax.dump(await ax.snapshot()) }
        }
    }

    private func finish() {
        cancellables.removeAll()
        Self.write("{\"walkthrough\":\"done\",\"passed\":\(passed),\"failed\":\(failed)}")
        if environment["MSR_UI_SNAPSHOT_PATH"]?.isEmpty == false {
            return
        }
        exit(failed == 0 ? 0 : 1)
    }

    private static func write(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func json(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [string], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
