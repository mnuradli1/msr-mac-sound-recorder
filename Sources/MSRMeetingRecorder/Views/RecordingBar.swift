import AppKit
import SwiftUI
import MSRCore

/// Top recording bar: source, honest per-source meters, state + timer, and
/// one prominent Record/Stop button with secondary Pause/Save and Settings.
struct RecordingBar: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 16) {
            sourcePicker

            ViewThatFits(in: .horizontal) {
                meters(showStatus: true)
                meters(showStatus: false)
            }
            .frame(minWidth: 150, alignment: .leading)
            .layoutPriority(-1)

            Spacer(minLength: 8)

            statusAndTimer

            controls
        }
        .padding(.horizontal, Theme.gutter)
        .frame(height: Theme.recordingBarHeight)
        .background(Theme.chromeBackground)
        .overlay(alignment: .bottom) { HairlineDivider() }
    }

    private var sourcePicker: some View {
        Picker("Source", selection: $viewModel.selectedSource) {
            Text("Mic").tag(AudioSource.microphone)
            Text("System").tag(AudioSource.system)
            Text("Both").tag(AudioSource.micAndSystem)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(viewModel.sourcePickerDisabled)
        .help("Audio source")
        .accessibilityLabel("Audio source")
        .accessibilityIdentifier("msr.recordingBar.source")
    }

    private func meters(showStatus: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SignalMeterView(
                kind: .microphone,
                level: viewModel.microphoneLevel,
                isSelected: viewModel.meterSource != .system,
                isActive: viewModel.isRecording && viewModel.meterSource != .system,
                showStatus: showStatus
            )
            SignalMeterView(
                kind: .system,
                level: viewModel.systemLevel,
                isSelected: viewModel.meterSource != .microphone,
                isActive: viewModel.isRecording && viewModel.meterSource != .microphone,
                showStatus: showStatus
            )
        }
        .fixedSize()
    }

    private var statusAndTimer: some View {
        HStack(spacing: 10) {
            StatusChip(title: viewModel.statusChip.title, tone: viewModel.statusChip.tone)
            Text(formatClock(viewModel.recordingElapsed))
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(viewModel.isRecordingSessionActive ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(Text("Recording timer \(formatClock(viewModel.recordingElapsed))"))
                .accessibilityIdentifier("msr.recordingBar.timer")
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if let secondaryTitle = viewModel.secondaryRecordingButtonTitle {
                Button {
                    Task { await viewModel.useSecondaryRecordingAction() }
                } label: {
                    Label(LocalizedStringKey(secondaryTitle), systemImage: viewModel.secondaryRecordingButtonSystemImage)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!viewModel.canUseSecondaryRecordingAction)
                .help(LocalizedStringKey(secondaryTitle))
                .accessibilityIdentifier("msr.recordingBar.secondary")
            }

            Button {
                Task { await viewModel.toggleRecording() }
            } label: {
                Label(LocalizedStringKey(viewModel.recordingButtonTitle), systemImage: recordSymbol)
                    .lineLimit(1)
                    .frame(minWidth: 96)
            }
            .buttonStyle(RecordButtonStyle())
            .disabled(!viewModel.canToggleRecording)
            .help(LocalizedStringKey(viewModel.recordingButtonTitle))
            .accessibilityIdentifier("msr.recordingBar.record")

            Button {
                viewModel.openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.textSecondary)
            .help("Settings")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("msr.recordingBar.settings")
        }
    }

    private var recordSymbol: String {
        if viewModel.workflowState.isPaused { return "play.fill" }
        return viewModel.isRecording ? "stop.fill" : "record.circle"
    }
}

/// Honest per-source signal meter: grey when not selected, quiet amber when
/// selected but silent, green/blue only when real signal arrives.
struct SignalMeterView: View {
    enum Kind { case microphone, system }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: Kind
    let level: Float
    let isSelected: Bool
    let isActive: Bool
    var showStatus = true

    private let meterWidth: CGFloat = 96

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind == .microphone ? "mic.fill" : "speaker.wave.2.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.textSecondary : Theme.textTertiary)
                .frame(width: 14)
            // Both rows share the width of the widest (localized) label.
            ZStack(alignment: .leading) {
                Text("Mic").hidden()
                Text("System").hidden()
                Text(LocalizedStringKey(kind == .microphone ? "Mic" : "System"))
                    .foregroundStyle(isSelected ? Theme.textSecondary : Theme.textTertiary)
            }
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            track
            if showStatus {
                Text(LocalizedStringKey(statusText))
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .frame(width: 92, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(kind == .microphone ? "Mic" : "System")))
        .accessibilityValue(Text(LocalizedStringKey(statusText)))
        .help(Text(LocalizedStringKey(statusText)))
    }

    private var track: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.subtleFill)
            Capsule()
                .fill(fill)
                .frame(width: max(4, meterWidth * CGFloat(visualLevel)))
        }
        .frame(width: meterWidth, height: 6)
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: level)
    }

    private var visualLevel: Float {
        let signal = max(0, min(1, level))
        guard isActive, signal > 0.001 else { return 0.04 }
        // RMS values are naturally small, so boost their display curve while
        // preserving a direct, monotonic relationship with the captured audio.
        return min(1, Float(pow(Double(signal), 0.55)))
    }

    private var hasSignal: Bool { isActive && level >= 0.02 }

    private var statusText: String {
        guard isSelected else { return "not selected" }
        guard isActive else { return "idle" }
        return level < 0.02 ? "no signal" : kind == .system ? "capturing audio" : "signal detected"
    }

    private var statusColor: Color {
        guard isActive else { return Theme.textTertiary }
        return level < 0.02 ? Tone.warning.foreground : Tone.success.foreground
    }

    private var fill: Color {
        guard isActive else { return Theme.textTertiary.opacity(0.5) }
        if level < 0.02 { return Theme.warning }
        return kind == .system ? Theme.info : Theme.success
    }
}
