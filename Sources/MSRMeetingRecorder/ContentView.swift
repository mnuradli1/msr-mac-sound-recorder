import AppKit
import SwiftUI
import MSRCore

/// Main window: compact title strip, recording bar, notices, history sidebar +
/// detail, and a slim status bar.
struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @FocusState private var recordingSearchFocused: Bool
    @State private var pendingDelete: RecordingItem?
    @State private var showingOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            RecordingBar(viewModel: viewModel)
            notices
            mainArea
            StatusBar(viewModel: viewModel)
        }
        .frame(minWidth: 980, minHeight: 640)
        // The transparent 28 pt title bar (traffic lights + native window title)
        // takes the chrome color, so it reads as one compact brand strip.
        .background(Theme.chromeBackground.ignoresSafeArea())
        .navigationTitle("MSR Meeting Recorder")
        .preferredColorScheme(preferredColorScheme)
        .environment(\.locale, preferredLocale)
        .background(WindowChromeConfigurator())
        .sheet(isPresented: $viewModel.showingRename) {
            renameSheet
        }
        .overlay(alignment: .bottomTrailing) {
            MiniRecordingIndicator(viewModel: viewModel, live: viewModel.live)
                .padding(.trailing, 16)
                .padding(.bottom, Theme.statusBarHeight + 12)
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { recording in
            Button("Delete", role: .destructive) {
                viewModel.delete(recording)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("The audio, transcript and summary files will be removed.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusRecordingSearch)) { _ in
            recordingSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearRecordingSearch)) { _ in
            viewModel.clearRecordingSearch()
            recordingSearchFocused = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestDeleteRecording)) { _ in
            requestDelete(viewModel.selectedRecording)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in
            showingOnboarding = true
        }
        .onAppear {
            if Onboarding.shouldPresentAtLaunch(settings: viewModel.settings, environment: ProcessInfo.processInfo.environment) {
                showingOnboarding = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            if let window = notification.object as? NSWindow, window.isMainWindow {
                viewModel.persistWindowSize(window.frame.size)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await viewModel.importRecordings(from: urls) }
            return !urls.isEmpty
        }
    }

    private var deleteDialogTitle: Text {
        if let pendingDelete {
            return Text("Delete “\(pendingDelete.displayName)”?")
        }
        return Text("Delete Recording")
    }

    private func requestDelete(_ recording: RecordingItem?) {
        guard let recording, viewModel.canMutateRecordingLibrary else { return }
        pendingDelete = recording
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

    @ViewBuilder
    private var notices: some View {
        if !viewModel.recoveryMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NoticeBanner(message: viewModel.recoveryMessage, severity: viewModel.recoveryNoticeSeverity)
        } else if let errorMessage = viewModel.workflowErrorMessage {
            NoticeBanner(message: errorMessage, severity: .error)
        } else if let notice = viewModel.autoTranscribeNotice {
            dismissibleNotice(notice, severity: .warning) { viewModel.clearAutoTranscribeNotice() }
        } else if viewModel.lastAutoTitleNotice != nil || viewModel.lastAutoSummaryNotice != nil {
            // Title and summary arrive together after one transcription; show both.
            VStack(spacing: 0) {
                if let notice = viewModel.lastAutoTitleNotice {
                    dismissibleNotice(notice, severity: .info) { viewModel.clearAutoTitleNotice() }
                }
                if let notice = viewModel.lastAutoSummaryNotice {
                    dismissibleNotice(
                        notice,
                        severity: viewModel.lastAutoSummaryFailed ? .warning : .success
                    ) { viewModel.clearAutoSummaryNotice() }
                }
            }
        }
    }

    private func dismissibleNotice(_ message: String, severity: AppNoticeSeverity, onDismiss: @escaping () -> Void) -> some View {
        NoticeBanner(message: message, severity: severity)
            .overlay(alignment: .trailing) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.trailing, Theme.gutter)
                .help("Dismiss")
                .accessibilityLabel("Dismiss notice")
            }
    }

    private var mainArea: some View {
        HSplitView {
            RecordingSidebar(
                viewModel: viewModel,
                searchFocused: $recordingSearchFocused,
                onRequestDelete: { requestDelete($0) }
            )
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 440)

            detail
                .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        // On its own view (not next to the rename sheet) so both sheets work.
        .sheet(isPresented: $showingOnboarding, onDismiss: {
            // Any way out (Finish, Skip, Esc) counts as having seen it once.
            if !viewModel.settings.hasCompletedOnboarding { Onboarding.complete(viewModel, saveKeys: false) }
        }) {
            OnboardingView(viewModel: viewModel) { showingOnboarding = false }
        }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            if let recording = viewModel.selectedRecording {
                RecordingDetailView(
                    viewModel: viewModel,
                    recording: recording,
                    onRequestDelete: { requestDelete($0) }
                )
            } else {
                ReadyStateView(viewModel: viewModel)
            }
        }
        .background(Theme.windowBackground)
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Recording")
                .font(.headline)
            TextField("Recording name", text: $viewModel.renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit { viewModel.applyRename() }
            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.showingRename = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    viewModel.applyRename()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

/// Floating "Recording 00:12" capsule. Observes `RecordingLiveState` for the
/// elapsed time, so the timer tick re-renders only this view.
private struct MiniRecordingIndicator: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var live: RecordingLiveState

    var body: some View {
        if let text = viewModel.miniRecordingIndicatorText {
            HStack(spacing: 6) {
                Image(systemName: viewModel.isRecording ? "record.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(text)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(viewModel.isRecording ? Theme.recording : Theme.warning, in: Capsule())
            .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)
            .accessibilityLabel(Text(text))
        }
    }
}

extension Notification.Name {
    static let focusRecordingSearch = Notification.Name("MSRFocusRecordingSearch")
    static let clearRecordingSearch = Notification.Name("MSRClearRecordingSearch")
    static let requestDeleteRecording = Notification.Name("MSRRequestDeleteRecording")
}

/// Keeps the native title bar compact and transparent: traffic lights and the
/// window title sit in a 28 pt strip directly above the recording bar.
private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        if window.titleVisibility != .visible { window.titleVisibility = .visible }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        if !window.isMovableByWindowBackground { window.isMovableByWindowBackground = true }
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
    }
}
