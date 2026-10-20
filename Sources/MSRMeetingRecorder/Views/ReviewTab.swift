import SwiftUI
import MSRCore

/// Review tab: confirm the audio. Playback strip, a seekable waveform with the
/// trim range shaded, and the trim group.
struct ReviewTab: View {
    @ObservedObject var viewModel: AppViewModel

    private let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 0) {
                    playbackStrip
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    HairlineDivider()
                    ReviewWaveformView(
                        samples: viewModel.reviewWaveform,
                        position: fraction(viewModel.playbackPosition),
                        trimStart: fraction(viewModel.trimStartSeconds),
                        trimEnd: viewModel.playbackDuration > 0 ? fraction(viewModel.trimEndSeconds) : 1
                    ) { value in
                        viewModel.seekPlayback(to: value * viewModel.playbackDuration)
                    }
                    .padding(12)
                }
                .cardBackground()

                trimGroup
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 20)
        }
    }

    private func fraction(_ seconds: TimeInterval) -> Double {
        guard viewModel.playbackDuration > 0 else { return 0 }
        return min(1, max(0, seconds / viewModel.playbackDuration))
    }

    private var playbackStrip: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(Color.white)
                    .background(Theme.action, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canPlaySelectedRecording)
            .opacity(viewModel.canPlaySelectedRecording ? 1 : 0.4)
            .help(LocalizedStringKey(viewModel.isPlaying ? "Pause (⌥Space)" : "Play (⌥Space)"))
            .accessibilityLabel(LocalizedStringKey(viewModel.isPlaying ? "Pause" : "Play"))

            skipButton(seconds: -15, symbol: "gobackward.15", label: "Back 15 seconds")
            skipButton(seconds: 15, symbol: "goforward.15", label: "Forward 15 seconds")

            Text(verbatim: "\(formatClock(viewModel.playbackPosition)) / \(formatClock(viewModel.playbackDuration))")
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 4)
                .accessibilityLabel("Playback position")
                .accessibilityValue(Text(verbatim: "\(formatClock(viewModel.playbackPosition)) / \(formatClock(viewModel.playbackDuration))"))

            Spacer()

            Menu {
                ForEach(speeds, id: \.self) { speed in
                    Button {
                        viewModel.setPlaybackSpeed(speed)
                    } label: {
                        if abs(viewModel.settings.playbackSpeed - speed) < 0.01 {
                            Label(speedLabel(speed), systemImage: "checkmark")
                        } else {
                            Text(speedLabel(speed))
                        }
                    }
                }
            } label: {
                Text(speedLabel(viewModel.settings.playbackSpeed))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help("Playback speed")
            .accessibilityLabel("Playback speed")
        }
    }

    private func speedLabel(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private func skipButton(seconds: TimeInterval, symbol: String, label: LocalizedStringKey) -> some View {
        Button {
            viewModel.skipPlayback(by: seconds)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.textSecondary)
        .disabled(!viewModel.canPlaySelectedRecording)
        .help(label)
        .accessibilityLabel(label)
    }

    private var trimGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Trim range")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(verbatim: "\(formatClock(viewModel.trimStartSeconds)) – \(formatClock(viewModel.trimEndSeconds))")
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Start")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Slider(value: $viewModel.trimStartSeconds, in: 0...max(0.1, viewModel.trimEndSeconds - 0.1))
                        .controlSize(.small)
                        .accessibilityLabel("Trim start")
                }
                GridRow {
                    Text("End")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Slider(
                        value: $viewModel.trimEndSeconds,
                        in: min(viewModel.trimStartSeconds + 0.1, max(0.1, viewModel.playbackDuration))...max(0.1, viewModel.playbackDuration)
                    )
                    .controlSize(.small)
                    .accessibilityLabel("Trim end")
                }
            }

            HStack(spacing: 8) {
                Button("Reset") { viewModel.resetTrim() }
                Button("Preview range") {
                    viewModel.seekPlayback(to: viewModel.trimStartSeconds)
                    viewModel.togglePlayback()
                }
                .disabled(!viewModel.canPlaySelectedRecording)
                Button("Transcribe range") { viewModel.transcribeSelectedRange() }
                    .disabled(!viewModel.canRunPrimaryAction)
                Spacer()
                Button("Save trimmed copy…") { Task { await viewModel.saveTrimmedCopy() } }
            }
            .controlSize(.small)
        }
        .padding(14)
        .cardBackground()
    }
}

/// Seekable waveform: played portion in the accent color, trim range shaded,
/// playhead line. Click or drag to seek.
struct ReviewWaveformView: View {
    let samples: [Float]
    let position: Double
    let trimStart: Double
    let trimEnd: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let values = samples.isEmpty ? Array(repeating: Float(0.06), count: 96) : samples
            let width = max(1, proxy.size.width)
            let height = proxy.size.height
            ZStack(alignment: .leading) {
                // Outside-of-trim shading.
                Rectangle()
                    .fill(Theme.subtleFill)
                    .frame(width: width * trimStart)
                Rectangle()
                    .fill(Theme.subtleFill)
                    .frame(width: width * max(0, 1 - trimEnd))
                    .offset(x: width * trimEnd)

                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, sample in
                        let location = Double(index) / Double(max(1, values.count - 1))
                        Capsule()
                            .fill(barColor(at: location))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(3, CGFloat(sample) * (height - 8)))
                    }
                }
                .frame(maxHeight: .infinity)

                Rectangle()
                    .fill(Theme.action)
                    .frame(width: 2, height: height)
                    .offset(x: max(0, min(width - 2, width * position - 1)))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onSeek(min(1, max(0, value.location.x / width)))
            })
        }
        .frame(height: 112)
        .accessibilityElement()
        .accessibilityLabel("Recording waveform")
        .accessibilityValue(Text("Playback \(Int(position * 100)) percent"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(1, position + 0.05))
            case .decrement: onSeek(max(0, position - 0.05))
            @unknown default: break
            }
        }
    }

    private func barColor(at location: Double) -> Color {
        let inTrim = location >= trimStart && location <= trimEnd
        if location <= position { return Theme.action.opacity(inTrim ? 1 : 0.45) }
        return Theme.textTertiary.opacity(inTrim ? 0.9 : 0.4)
    }
}

/// Export tab: format, actions, and a full-height preview.
struct ExportTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Format", selection: $viewModel.selectedExportFormat) {
                    ForEach(TranscriptExportFormat.allCases) { format in
                        Text(LocalizedStringKey(format.displayName)).tag(format)
                    }
                }
                .fixedSize()
                .onChange(of: viewModel.selectedExportFormat) { _, _ in viewModel.updateExportPreview() }

                Spacer()

                Button("Reveal Last") { viewModel.revealLastExport() }
                    .disabled(viewModel.lastExportURL == nil)
                Button {
                    viewModel.exportSelected()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedExportFormat == .srt && !TranscriptExporter.canExportSRT(viewModel.transcriptSegments))
            }

            if viewModel.selectedExportFormat == .srt && !TranscriptExporter.canExportSRT(viewModel.transcriptSegments) {
                Text("Captions need a timestamped transcript.")
                    .font(.system(size: 12))
                    .foregroundStyle(Tone.warning.foreground)
            }

            ScrollView {
                Text(viewModel.exportPreview.isEmpty ? " " : viewModel.exportPreview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.textSurface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            }
            .accessibilityLabel("Export preview")
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 16)
    }
}
