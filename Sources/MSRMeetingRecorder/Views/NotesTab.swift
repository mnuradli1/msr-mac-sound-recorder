import SwiftUI
import MSRCore

/// Notes tab: the transcript dominates and fills the height; the summary is a
/// ~300 pt secondary panel that drops below the transcript when space is tight.
struct NotesTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GeometryReader { proxy in
            Group {
                if proxy.size.width >= 720 {
                    HStack(alignment: .top, spacing: 14) {
                        TranscriptPanel(viewModel: viewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        SummaryPanel(viewModel: viewModel)
                            .frame(width: 300)
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 12) {
                        TranscriptPanel(viewModel: viewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        SummaryPanel(viewModel: viewModel)
                            .frame(height: min(220, max(150, proxy.size.height * 0.34)))
                    }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 16)
        }
    }
}

enum TranscriptMode: String, CaseIterable, Identifiable {
    case read = "Read"
    case edit = "Edit text"
    var id: String { rawValue }
}

struct TranscriptPanel: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var mode: TranscriptMode = UISnapshotCapture.requestedTranscriptMode == "edit" ? .edit : .read

    private var canRead: Bool { !viewModel.transcriptSegments.isEmpty }
    private var effectiveMode: TranscriptMode { canRead ? mode : .edit }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Transcript")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if canRead {
                    Picker("Transcript mode", selection: $mode) {
                        ForEach(TranscriptMode.allCases) { item in
                            Text(LocalizedStringKey(item.rawValue)).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help("Read the speaker-labelled transcript, or edit its text")
                    .accessibilityIdentifier("msr.notes.transcriptMode")
                }
                Spacer(minLength: 8)
                saveStatus
            }

            ZStack {
                content
                overlays
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.textSurface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            }
            .contextMenu {
                Button { viewModel.copyTranscript() } label: { Label("Copy Transcript", systemImage: "doc.on.doc") }
                    .disabled(!viewModel.hasTranscript)
                Button { Task { await viewModel.retranscribeSelected() } } label: {
                    Label("Re-transcribe", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!viewModel.hasTranscript || !viewModel.canRunPrimaryAction)
                Divider()
                Button { viewModel.saveTranscript(format: .text) } label: { Label("Save as .txt", systemImage: "doc.plaintext") }
                    .disabled(!viewModel.hasTranscript)
                Button { viewModel.saveTranscript(format: .markdown) } label: { Label("Save as .md", systemImage: "doc.richtext") }
                    .disabled(!viewModel.hasTranscript)
            }
        }
        .onChange(of: viewModel.selectedRecording?.id) { _, _ in mode = .read }
    }

    @ViewBuilder
    private var saveStatus: some View {
        if !viewModel.transcriptSaveMessage.isEmpty {
            Text(LocalizedStringKey(viewModel.transcriptSaveMessage))
                .font(.system(size: 11.5))
                .foregroundStyle(viewModel.transcriptSaveMessage == "Save failed" ? Tone.danger.foreground : Theme.textSecondary)
        }
        if effectiveMode == .edit {
            Button("Save") { viewModel.flushTranscriptEdits() }
                .controlSize(.small)
                .disabled(viewModel.transcriptSaveMessage != "Unsaved changes")
                .help("Save transcript edits (⌘S)")
                .accessibilityIdentifier("msr.notes.transcriptSave")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch effectiveMode {
        case .read:
            let readable = viewModel.readModeTranscript
            VStack(alignment: .leading, spacing: 0) {
                if readable.isEdited {
                    Label("Showing your edited text; timestamps come from the original transcript.", systemImage: "pencil")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                }
                TranscriptReaderView(
                    segments: readable.segments,
                    onJump: viewModel.jumpToTranscriptSegment,
                    canRenameSpeakers: viewModel.canRenameSpeakers,
                    originalLabel: viewModel.originalSpeakerLabel(for:),
                    onRenameSpeaker: viewModel.renameSpeaker(label:to:)
                )
            }
        case .edit:
            TextEditor(text: $viewModel.transcriptText)
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .disabled(viewModel.selectedRecordingIsTranscribing)
                .onChange(of: viewModel.transcriptText) { _, _ in viewModel.scheduleTranscriptAutosave() }
                .accessibilityLabel("Transcript")
                .accessibilityIdentifier("msr.notes.transcriptEditor")
        }
    }

    @ViewBuilder
    private var overlays: some View {
        if !viewModel.hasTranscript,
           !viewModel.selectedRecordingIsTranscribing,
           !viewModel.selectedRecordingIsQueuedForTranscription {
            VStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.textTertiary)
                Text("No transcript yet")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Run transcription when this recording is ready.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .allowsHitTesting(false)
        }

        if viewModel.selectedRecordingIsQueuedForTranscription {
            TranscriptionQueuedOverlay(provider: viewModel.settings.provider)
                .transition(.opacity)
                .allowsHitTesting(false)
        }

        if viewModel.selectedRecordingIsTranscribing {
            TranscriptionProgressOverlay(
                provider: viewModel.settings.provider,
                startedAt: viewModel.transcriptionStartedAt ?? Date()
            )
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
}

/// Speaker-labelled reader with jump-to-time buttons and selectable text.
/// Clicking a speaker chip names that speaker (see `SpeakerNamePopover`).
struct TranscriptReaderView: View {
    let segments: [TranscriptSegment]
    let onJump: (TranscriptSegment) -> Void
    var canRenameSpeakers = false
    /// The provider's label for a renamed speaker (`nil` when not renamed).
    var originalLabel: (String) -> String? = { _ in nil }
    var onRenameSpeaker: ((String, String) -> Void)?

    /// Index of the segment whose speaker popover is open.
    @State private var editingIndex: Int? = UISnapshotCapture.requestedSpeakerPopoverIndex

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    VStack(alignment: .leading, spacing: 4) {
                        if !segment.speaker.isEmpty || segment.startTime != nil {
                            HStack(spacing: 8) {
                                if !segment.speaker.isEmpty {
                                    speakerChip(segment.speaker, index: index)
                                }
                                if let startTime = segment.startTime {
                                    Button {
                                        onJump(segment)
                                    } label: {
                                        Label(formatClock(startTime), systemImage: "play.fill")
                                            .labelStyle(.titleAndIcon)
                                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(Theme.textSecondary)
                                    .help("Jump to audio")
                                    .accessibilityLabel(Text("Jump to audio \(formatClock(startTime))"))
                                }
                            }
                        }
                        Text(segment.text)
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private func speakerChip(_ speaker: String, index: Int) -> some View {
        let original = originalLabel(speaker)
        let editable = canRenameSpeakers && onRenameSpeaker != nil
        Button {
            editingIndex = index
        } label: {
            Text(speaker)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.speakerColor(for: original ?? speaker))
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Theme.speakerColor(for: original ?? speaker).opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!editable)
        .help(original.map { Text("Originally \($0). Click to rename this speaker.") } ?? Text("Click to rename this speaker."))
        .accessibilityLabel(Text(speaker))
        .accessibilityHint(Text("Rename this speaker"))
        .accessibilityIdentifier("msr.notes.speaker.\(index)")
        .popover(isPresented: Binding(
            get: { editingIndex == index },
            set: { if !$0, editingIndex == index { editingIndex = nil } }
        ), arrowEdge: .bottom) {
            SpeakerNamePopover(
                currentName: speaker,
                originalLabel: original ?? speaker,
                onSave: { name in
                    editingIndex = nil
                    onRenameSpeaker?(speaker, name)
                },
                onCancel: { editingIndex = nil }
            )
        }
    }
}

/// "Name this speaker": Return saves, Escape cancels, an empty name reverts
/// to the provider's original label.
struct SpeakerNamePopover: View {
    let currentName: String
    let originalLabel: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(currentName: String, originalLabel: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.currentName = currentName
        self.originalLabel = originalLabel
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: UISnapshotCapture.requestedSpeakerDraft ?? currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name this speaker")
                .font(.system(size: 13, weight: .semibold))
            TextField("Name this speaker", text: $draft, prompt: Text(verbatim: originalLabel))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 220)
                .focused($focused)
                .onSubmit(save)
                .onExitCommand(perform: onCancel)
                .accessibilityIdentifier("msr.notes.speakerNameField")
            Text("Renames \(originalLabel) everywhere in this transcript. Leave empty to use the original label.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 220, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("msr.notes.speakerCancel")
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("msr.notes.speakerSave")
            }
            .controlSize(.small)
        }
        .padding(14)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func save() {
        onSave(draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct SummaryPanel: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Summary")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let provider = viewModel.selectedSummaryProvider {
                    Text("· via \(provider.displayName)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("msr.notes.summaryProvider")
                }
                Spacer()
                if viewModel.hasSummary {
                    Button {
                        viewModel.copySummary()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textSecondary)
                    .help("Copy Summary")
                    .accessibilityLabel("Copy Summary")
                }
            }
            .frame(height: 22)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.summaryText)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .onChange(of: viewModel.summaryText) { _, _ in viewModel.scheduleSummaryAutosave() }
                    .accessibilityLabel("Summary")
                    .accessibilityIdentifier("msr.notes.summaryEditor")

                if !viewModel.hasSummary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No summary yet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(LocalizedStringKey(viewModel.hasTranscript ? "Summarize the transcript to fill this panel." : "Transcript comes first."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(14)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            }
        }
    }
}

// MARK: - Transcription overlays

struct TranscriptionQueuedOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let provider: AIProvider

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.35, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 3 : Int(context.date.timeIntervalSinceReferenceDate * 2) % 4
            VStack(spacing: 10) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Theme.info)
                Text("Queued for \(provider.displayName)\(String(repeating: ".", count: phase))")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("It will start after the current transcription finishes.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.textSurface.opacity(0.95))
        }
    }
}

struct TranscriptionProgressOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let provider: AIProvider
    let startedAt: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30.0)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            let tick = Int(elapsed.rounded(.down))

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(TranscriptionProgressDisplay.message(provider: provider, tick: tick))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .contentTransition(.numericText())
                        Text("Elapsed \(TranscriptionProgressDisplay.elapsedText(seconds: elapsed))")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }

                TranscriptionShimmerBar(date: context.date, animated: !reduceMotion)

                Label("Uploading full recording. Waiting for transcript.", systemImage: "waveform")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.textSurface.opacity(0.95))
        }
    }
}

struct TranscriptionShimmerBar: View {
    let date: Date
    var animated = true

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let highlightWidth = max(90, width * 0.28)
            let cycle = animated ? date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6 : 0.5
            let offset = -highlightWidth + CGFloat(cycle) * (width + highlightWidth)

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.info.opacity(0.15))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Theme.info.opacity(0.05), Theme.info, Theme.success.opacity(0.85), Theme.info.opacity(0.05)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: highlightWidth)
                    .offset(x: offset)
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
