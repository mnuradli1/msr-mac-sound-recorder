import SwiftUI
import MSRCore

/// Detail for the selected recording: header (title, inline rename, subtitle),
/// recording check, one next-step action, and the Review / Notes / Export tabs.
struct RecordingDetailView: View {
    @ObservedObject var viewModel: AppViewModel
    let recording: RecordingItem
    let onRequestDelete: (RecordingItem) -> Void

    @State private var isEditingTitle = false
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 16)

            if !viewModel.selectedRecordingConfidenceIssues.isEmpty {
                ConfidencePanel(issues: viewModel.selectedRecordingConfidenceIssues, tone: viewModel.confidenceTone)
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 12)
            }

            tabBar
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Group {
                switch viewModel.selectedDetailTab {
                case .review:
                    ReviewTab(viewModel: viewModel)
                case .notes:
                    NotesTab(viewModel: viewModel)
                case .export:
                    ExportTab(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: recording.id) { _, _ in cancelTitleEdit() }
        // A recording session locks the library; drop a half-typed rename.
        .onChange(of: viewModel.isRecording || viewModel.workflowState.isBusy) { _, locked in
            if locked { cancelTitleEdit() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                titleRow
                subtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NextStepActions(viewModel: viewModel, onRename: beginTitleEdit, onRequestDelete: { onRequestDelete(recording) })
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var titleRow: some View {
        if isEditingTitle {
            HStack(spacing: 8) {
                TextField("Recording name", text: $viewModel.renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 17, weight: .semibold))
                    .focused($titleFieldFocused)
                    .onSubmit(commitTitleEdit)
                    .onExitCommand(perform: cancelTitleEdit)
                    .frame(maxWidth: 520)
                    .accessibilityIdentifier("msr.detail.titleField")
                Button("Save", action: commitTitleEdit)
                    .controlSize(.small)
                    .disabled(viewModel.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("msr.detail.titleSave")
                Button("Cancel", action: cancelTitleEdit)
                    .controlSize(.small)
                    .accessibilityIdentifier("msr.detail.titleCancel")
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(recording.displayName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .onTapGesture(count: 2, perform: beginTitleEdit)
                    .accessibilityAddTraits(.isHeader)
                    .help("Double-click to rename")
                    .accessibilityIdentifier("msr.detail.title")

                TitleBadge(recording: recording)

                Button(action: beginTitleEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
                .disabled(!viewModel.canRenameSelection)
                .help("Rename")
                .accessibilityLabel("Rename")
                .accessibilityIdentifier("msr.detail.rename")
            }
        }
    }

    private var subtitle: some View {
        let parts = viewModel.recordingSubtitleParts(recording)
        return (Text(LocalizedStringKey(parts[0])) + Text(verbatim: " · " + parts.dropFirst().joined(separator: " · ")))
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
    }

    private func beginTitleEdit() {
        guard viewModel.beginInlineRename() else { return }
        isEditingTitle = true
        DispatchQueue.main.async { titleFieldFocused = true }
    }

    private func commitTitleEdit() {
        let draft = viewModel.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        if draft != recording.displayName {
            viewModel.applyRename()
        }
        isEditingTitle = false
    }

    private func cancelTitleEdit() {
        isEditingTitle = false
        titleFieldFocused = false
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 12) {
            Picker("Recording detail", selection: $viewModel.selectedDetailTab) {
                ForEach(RecordingDetailTab.allCases) { tab in
                    Text(LocalizedStringKey(tab.rawValue)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Review ⌘1 · Notes ⌘2 · Export ⌘3")
            .accessibilityIdentifier("msr.detail.tabs")

            Spacer()
        }
    }
}

/// Slot next to the detail title for provenance labels (recovered, imported).
/// A future "auto-titled" label belongs here too.
struct TitleBadge: View {
    let recording: RecordingItem

    var body: some View {
        HStack(spacing: 4) {
            if recording.isRecovered {
                StatusChip(title: "Recovered", tone: .warning, systemImage: "lifepreserver", compact: true)
                    .help(Text(recording.metadata.recoveryNote ?? ""))
                    .accessibilityIdentifier("msr.detail.chip.recovered")
            }
            if recording.isImported {
                StatusChip(title: "Imported", tone: .neutral, systemImage: "square.and.arrow.down", compact: true)
                    .accessibilityIdentifier("msr.detail.chip.imported")
            }
            if recording.effectiveTitleSource == .generated {
                StatusChip(title: "Auto-titled", tone: .info, systemImage: "wand.and.stars", compact: true)
                    .help("This title was generated from the transcript. Rename the recording to keep your own title.")
                    .accessibilityIdentifier("msr.detail.chip.autoTitled")
            }
        }
    }
}

/// The single next-step button (Transcribe → Summarize → Copy Meeting Notes) plus an
/// overflow menu holding every secondary action.
struct NextStepActions: View {
    @ObservedObject var viewModel: AppViewModel
    let onRename: () -> Void
    let onRequestDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await viewModel.runPrimaryAction() }
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isPrimaryActionBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: viewModel.primaryAction.systemImage)
                    }
                    Text(LocalizedStringKey(viewModel.primaryActionTitle))
                        .lineLimit(1)
                }
                .fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canRunPrimaryAction)
            .help(LocalizedStringKey(viewModel.primaryActionTitle))
            .accessibilityIdentifier("msr.detail.primaryAction")

            Menu {
                overflowItems
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel("More actions")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .controlSize(.large)
            .fixedSize()
            .help("More actions")
            .accessibilityIdentifier("msr.detail.moreActions")
        }
    }

    @ViewBuilder
    private var overflowItems: some View {
        Section {
            Button("Copy Transcript", systemImage: "doc.on.doc") { viewModel.copyTranscript() }
                .disabled(!viewModel.hasTranscript)
            Button("Copy Summary", systemImage: "doc.on.clipboard") { viewModel.copySummary() }
                .disabled(!viewModel.hasSummary)
            Button("Copy All", systemImage: "doc.on.doc.fill") { viewModel.copyAllNotes() }
                .disabled(!viewModel.hasTranscript)
            Button("Copy Meeting Notes", systemImage: "list.bullet.clipboard") { viewModel.copyMeetingNotes() }
                .disabled(!viewModel.canCopyMeetingNotes)
        }
        Section {
            if viewModel.primaryAction != .summarize {
                Button("Summarize", systemImage: "sparkles") { Task { await viewModel.summarizeSelected() } }
                    .disabled(!viewModel.hasTranscript || !viewModel.canRunPrimaryAction)
            }
            Button("Re-transcribe", systemImage: "arrow.triangle.2.circlepath") { Task { await viewModel.retranscribeSelected() } }
                .disabled(!viewModel.hasTranscript || !viewModel.canRunPrimaryAction)
            Button("Transcribe range", systemImage: "timeline.selection") {
                viewModel.selectedDetailTab = .review
                viewModel.transcribeSelectedRange()
            }
            .disabled(!viewModel.canRunPrimaryAction)
            Button("Reset speaker names", systemImage: "person.2.badge.gearshape") { viewModel.resetSpeakerNames() }
                .disabled(!viewModel.selectedRecordingHasSpeakerNames || !viewModel.canRenameSpeakers)
        }
        Section {
            Menu("Save Transcript") {
                Button("Save as .txt") { viewModel.saveTranscript(format: .text) }
                Button("Save as .md") { viewModel.saveTranscript(format: .markdown) }
            }
            .disabled(!viewModel.hasTranscript)
            Button("Export…", systemImage: "square.and.arrow.up") {
                viewModel.selectedDetailTab = .export
                viewModel.exportSelected()
            }
        }
        Section {
            Button("Rename…", systemImage: "pencil", action: onRename)
                .disabled(!viewModel.canRenameSelection)
            Button("Show in Finder", systemImage: "folder") { viewModel.showInFinder() }
        }
        Section {
            Button("Delete…", systemImage: "trash", role: .destructive, action: onRequestDelete)
                .disabled(!viewModel.canMutateRecordingLibrary)
        }
    }
}

/// Post-recording check: duration/silence/missing-source issues.
struct ConfidencePanel: View {
    let issues: [RecordingConfidenceIssue]
    let tone: Tone

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tone == .info ? "info.circle.fill" : "waveform.badge.exclamationmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Recording Check")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tone.foreground)
                ForEach(issues) { issue in
                    Text(issue.message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tone.background, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.smallCornerRadius + 2, style: .continuous)
                .strokeBorder(tone.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
