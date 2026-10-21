import SwiftUI
import MSRCore

/// Shown when no recording is selected: "Ready to record", plus a compact
/// readiness checklist only when something needs fixing.
struct ReadyStateView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.recording.opacity(0.85))
                    .accessibilityHidden(true)
                Text("Ready to record")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("msr.ready.title")
                Text("Pick a source above and press Record (⌘⇧R). Recordings save automatically.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            let items = viewModel.setupItemsNeedingAttention
            if !items.isEmpty {
                ReadinessChecklist(viewModel: viewModel, items: items)
                    .frame(maxWidth: 440)
            } else if viewModel.recordings.isEmpty {
                // Empty library, nothing to fix: still offer the guided setup.
                Button {
                    Onboarding.present()
                } label: {
                    Label("Set up MSR…", systemImage: "sparkles")
                }
                .controlSize(.regular)
                .accessibilityIdentifier("msr.ready.setup")
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReadinessChecklist: View {
    @ObservedObject var viewModel: AppViewModel
    let items: [SetupHealthItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Before you record")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Set up MSR…") {
                    Onboarding.present()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11.5, weight: .medium))
                .help("Walk through permissions, API keys and automation")
                .accessibilityIdentifier("msr.ready.setup")
                Button {
                    viewModel.refreshSetupHealth()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
                .help("Refresh Health")
                .accessibilityLabel("Refresh Health")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().padding(.leading, 40)
                }
                HStack(spacing: 10) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(item.severity.tone.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(LocalizedStringKey(item.title))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text.uiString(item.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Button(LocalizedStringKey(viewModel.fixActionTitle(for: item))) {
                        viewModel.fixSetupItem(item)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("msr.ready.fix.\(item.id)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
            }
        }
        .padding(.bottom, 4)
        .cardBackground()
    }
}

/// Slim bottom status bar: last status message, transcription queue summary,
/// and the local API state only when the local API is enabled.
struct StatusBar: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 14) {
            Text.uiString(viewModel.statusMessage)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel(Text(viewModel.statusMessage))
                .accessibilityIdentifier("msr.statusBar.message")

            Spacer(minLength: 8)

            if let summary = viewModel.queueSummary {
                HStack(spacing: 5) {
                    if case .active = summary {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: summary.systemImage)
                            .foregroundStyle(summary.tone.accent)
                    }
                    summary.text
                        .lineLimit(1)
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }

            if let api = viewModel.localAPIStatusSummary {
                Label {
                    Text(api).lineLimit(1)
                } icon: {
                    Image(systemName: "network")
                }
                .foregroundStyle(Theme.textTertiary)
                .help(Text(api))
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .frame(height: Theme.statusBarHeight)
        .background(Theme.chromeBackground)
        .overlay(alignment: .top) { HairlineDivider() }
    }
}

enum QueueSummary: Equatable {
    case active(name: String, total: Int)
    case needsRetry(count: Int)
    case queued(count: Int)

    var text: Text {
        switch self {
        case let .active(name, total):
            total > 1 ? Text("Transcribing \(name) · \(total) in queue") : Text("Transcribing \(name)")
        case let .needsRetry(count):
            count == 1 ? Text("1 transcription needs retry") : Text("\(count) transcriptions need retry")
        case let .queued(count):
            count == 1 ? Text("1 transcription queued") : Text("\(count) transcriptions queued")
        }
    }

    var systemImage: String {
        switch self {
        case .active: "waveform"
        case .needsRetry: "exclamationmark.triangle.fill"
        case .queued: "clock"
        }
    }

    var tone: Tone {
        switch self {
        case .needsRetry: .warning
        default: .progress
        }
    }
}
