import AppKit
import SwiftUI
import MSRCore

/// Compact recorder shown from the menu-bar item (`QuickRecorderController`):
/// source, live meters and timer, status, Record/Stop and Pause/Save, plus
/// Open MSR and Quit. Every action goes through the shared `AppViewModel`, so
/// it behaves exactly like the main window's recording bar (and the ⌃⌥R
/// shortcut), whether or not the main window is open.
///
/// Re-render discipline: this view observes `AppViewModel` (state changes
/// only); the meters and timer observe `RecordingLiveState`, so a tick
/// re-renders those two subviews and nothing else. The controller drops the
/// whole hosting view while the panel is closed.
struct QuickRecorderPanel: View {
    @ObservedObject var viewModel: AppViewModel
    let onOpenMainWindow: () -> Void
    let onQuit: () -> Void

    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sourcePicker
            levelsAndTimer
            statusLine
            controls
            Divider()
            menuBarTimerToggle
            footer
        }
        .padding(14)
        .frame(width: Self.width)
        .environment(\.locale, preferredLocale)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.isRecording ? "record.circle.fill" : "waveform.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(viewModel.isRecording ? Theme.recording : Theme.textSecondary)
                .accessibilityHidden(true)
            Text("Quick Recorder")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            StatusChip(title: viewModel.statusChip.title, tone: viewModel.statusChip.tone, compact: true)
                .accessibilityIdentifier("msr.quick.status")
        }
    }

    private var sourcePicker: some View {
        Picker("Source", selection: $viewModel.selectedSource) {
            Text("Mic").tag(AudioSource.microphone)
            Text("System").tag(AudioSource.system)
            Text("Both").tag(AudioSource.micAndSystem)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .disabled(viewModel.sourcePickerDisabled)
        .help("Audio source")
        .accessibilityLabel("Audio source")
        .accessibilityIdentifier("msr.quick.source")
    }

    private var levelsAndTimer: some View {
        HStack(alignment: .center, spacing: 10) {
            QuickRecorderMeters(
                live: viewModel.live,
                meterSource: viewModel.meterSource,
                isRecording: viewModel.isRecording
            )
            Spacer(minLength: 4)
            QuickRecorderTimer(live: viewModel.live, isActive: viewModel.isRecordingSessionActive)
        }
    }

    private var statusLine: some View {
        Text.uiString(viewModel.statusMessage)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textSecondary)
            // Two lines are always reserved, so the panel never changes size.
            .lineLimit(2, reservesSpace: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("msr.quick.statusMessage")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            let secondaryTitle = viewModel.secondaryRecordingButtonTitle ?? "Pause"
            Button {
                Task { await viewModel.useSecondaryRecordingAction() }
            } label: {
                Label(LocalizedStringKey(secondaryTitle), systemImage: viewModel.secondaryRecordingButtonSystemImage)
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!viewModel.canUseSecondaryRecordingAction)
            .help(LocalizedStringKey(secondaryTitle))
            .accessibilityIdentifier("msr.quick.secondary")

            Button {
                Task { await viewModel.toggleRecording() }
            } label: {
                Label(LocalizedStringKey(viewModel.recordingButtonTitle), systemImage: recordSymbol)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RecordButtonStyle())
            .disabled(!viewModel.canToggleRecording)
            .help(LocalizedStringKey(viewModel.recordingButtonTitle))
            .accessibilityIdentifier("msr.quick.record")
        }
    }

    private var menuBarTimerToggle: some View {
        Toggle("Show timer in menu bar", isOn: Binding(
            get: { viewModel.settings.showMenuBarTimer },
            set: { newValue in
                viewModel.settings.showMenuBarTimer = newValue
                viewModel.saveSettings()
            }
        ))
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .foregroundStyle(Theme.textSecondary)
        .accessibilityIdentifier("msr.quick.menuBarTimer")
    }

    private var footer: some View {
        HStack {
            Button("Open MSR", action: onOpenMainWindow)
                .accessibilityIdentifier("msr.quick.open")
            Spacer()
            Button("Quit", action: onQuit)
                .accessibilityIdentifier("msr.quick.quit")
        }
        .buttonStyle(.link)
        .font(.system(size: 12, weight: .medium))
    }

    private var recordSymbol: String {
        if viewModel.workflowState.isPaused { return "play.fill" }
        return viewModel.isRecording ? "stop.fill" : "record.circle"
    }

    private var preferredLocale: Locale {
        switch viewModel.settings.language {
        case .system: .current
        case .english: Locale(identifier: "en")
        case .indonesian: Locale(identifier: "id")
        }
    }
}

/// The panel's two source meters (no status text: the panel is narrow).
/// Observes only `RecordingLiveState`.
private struct QuickRecorderMeters: View {
    @ObservedObject var live: RecordingLiveState
    let meterSource: AudioSource
    let isRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SignalMeterView(
                kind: .microphone,
                level: live.microphoneLevel,
                isSelected: meterSource != .system,
                isActive: isRecording && meterSource != .system,
                showStatus: false
            )
            SignalMeterView(
                kind: .system,
                level: live.systemLevel,
                isSelected: meterSource != .microphone,
                isActive: isRecording && meterSource != .microphone,
                showStatus: false
            )
        }
        .fixedSize()
        .accessibilityIdentifier("msr.quick.meters")
    }
}

/// The panel's session clock; observes only `RecordingLiveState`.
private struct QuickRecorderTimer: View {
    @ObservedObject var live: RecordingLiveState
    let isActive: Bool

    var body: some View {
        Text(formatClock(live.recordingElapsed))
            .font(.system(size: 24, weight: .semibold, design: .monospaced))
            .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(Text("Recording timer \(formatClock(live.recordingElapsed))"))
            .accessibilityIdentifier("msr.quick.timer")
    }
}
