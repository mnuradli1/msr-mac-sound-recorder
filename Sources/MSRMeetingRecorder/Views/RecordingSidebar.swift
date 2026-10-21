import SwiftUI
import MSRCore

struct RecordingSection: Identifiable {
    let title: String
    let recordings: [RecordingItem]
    var id: String { title }
}

/// One row badge. Add cases here (e.g. an auto-generated title or an
/// automatically queued transcription) and they render everywhere rows do.
enum RecordingBadge: Hashable, Identifiable {
    case warning
    case transcript
    case summary
    case recovered
    case imported
    case autoTitled

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .warning: "exclamationmark.triangle.fill"
        case .transcript: "text.quote"
        case .summary: "sparkles"
        case .recovered: "lifepreserver"
        case .imported: "square.and.arrow.down"
        case .autoTitled: "wand.and.stars"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .warning: "Recording check warning"
        case .transcript: "Has transcript"
        case .summary: "Has summary"
        case .recovered: "Recovered recording"
        case .imported: "Imported recording"
        case .autoTitled: "Title generated from the transcript"
        }
    }

    var tint: Color {
        switch self {
        case .warning: Theme.warning
        default: Theme.textSecondary
        }
    }
}

/// History sidebar: search + sort, a native selectable list grouped by day,
/// and a compact transcription queue that only appears when jobs need attention.
struct RecordingSidebar: View {
    @ObservedObject var viewModel: AppViewModel
    var searchFocused: FocusState<Bool>.Binding
    let onRequestDelete: (RecordingItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            recordingList

            if viewModel.hasVisibleTranscriptionJobs {
                HairlineDivider()
                TranscriptionQueueBlock(viewModel: viewModel)
            }
        }
        .background(Theme.sidebarBackground)
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text("Recordings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if !viewModel.recordings.isEmpty {
                Text(verbatim: "\(viewModel.recordings.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 4)
            }
            Spacer()

            Menu {
                Picker("Sort", selection: $viewModel.settings.sortOrder) {
                    ForEach(RecordingSortOrder.allCases) { order in
                        Text(LocalizedStringKey(order.displayName)).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 26, height: 24)
            .help("Sort recordings")
            .accessibilityLabel("Sort recordings")
            .accessibilityIdentifier("msr.sidebar.sort")
            .onChange(of: viewModel.settings.sortOrder) { _, _ in viewModel.saveSettings() }

            iconButton("plus", label: "Import audio") { viewModel.importRecording() }
                .disabled(!viewModel.canMutateRecordingLibrary)
                .accessibilityIdentifier("msr.sidebar.import")
            iconButton("arrow.clockwise", label: "Refresh history") { Task { await viewModel.refreshLibrary() } }
                .disabled(!viewModel.canSelectHistory)
                .accessibilityIdentifier("msr.sidebar.refresh")
        }
        .foregroundStyle(Theme.textSecondary)
    }

    private func iconButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search recordings", text: $viewModel.recordingSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused(searchFocused)
                    .disabled(!viewModel.canSelectHistory)
                    .accessibilityIdentifier("msr.sidebar.search")
                    .onChange(of: viewModel.recordingSearchQuery) { _, _ in viewModel.scheduleRecordingSearch() }
                    .onExitCommand {
                        viewModel.clearRecordingSearch()
                        searchFocused.wrappedValue = false
                    }
                if viewModel.isSearchingRecordings {
                    Button {
                        viewModel.clearRecordingSearch()
                        searchFocused.wrappedValue = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textTertiary)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                    .accessibilityIdentifier("msr.sidebar.searchClear")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Theme.textSurface, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                    .strokeBorder(searchFocused.wrappedValue ? Theme.action : Theme.separator, lineWidth: searchFocused.wrappedValue ? 1.5 : 1)
            }

            if viewModel.isSearchingRecordings {
                Text("\(viewModel.recordingSearchResultCount) results")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 2)
                    .accessibilityIdentifier("msr.sidebar.searchResultCount")
            }
        }
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { viewModel.selectedRecording?.id },
            set: { newID in
                guard let newID,
                      newID != viewModel.selectedRecording?.id,
                      let recording = viewModel.filteredRecordings.first(where: { $0.id == newID })
                else { return }
                viewModel.select(recording)
            }
        )
    }

    @ViewBuilder
    private var recordingList: some View {
        let sections = viewModel.recordingSections
        if sections.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            List(selection: selectionBinding) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.recordings) { recording in
                            RecordingRow(
                                recording: recording,
                                sourceLabel: viewModel.sourceLabel(for: recording),
                                badges: viewModel.rowBadges(for: recording),
                                jobChip: viewModel.jobChip(for: recording)
                            )
                            .tag(recording.id)
                            .accessibilityIdentifier("msr.sidebar.row.\(recording.id.uuidString)")
                            .contextMenu { contextMenu(for: recording) }
                        }
                    } header: {
                        Text(LocalizedStringKey(section.title))
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("msr.sidebar.list")
            .disabled(!viewModel.canSelectHistory)
            .opacity(viewModel.canSelectHistory ? 1 : 0.6)
        }
    }

    @ViewBuilder
    private func contextMenu(for recording: RecordingItem) -> some View {
        Button {
            viewModel.select(recording)
            viewModel.togglePlayback()
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        .disabled(!viewModel.canPlaySelectedRecording)
        Button {
            viewModel.startRename(recording)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .disabled(!viewModel.canMutateRecordingLibrary)
        Button {
            viewModel.showInFinder(recording)
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            onRequestDelete(recording)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(!viewModel.canMutateRecordingLibrary)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(viewModel.isSearchingRecordings ? "No recordings found" : "No recordings yet"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(LocalizedStringKey(viewModel.isSearchingRecordings ? "Try a different query." : "Your recordings will appear here."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            if !viewModel.isSearchingRecordings {
                Text("Drop audio files here to import them.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

/// Row content: title + time, source · duration, badges and a job chip.
struct RecordingRow: View {
    let recording: RecordingItem
    let sourceLabel: String
    let badges: [RecordingBadge]
    let jobChip: (title: String, tone: Tone, isAutomatic: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(recording.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(timeText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            HStack(spacing: 5) {
                (Text(LocalizedStringKey(sourceLabel)) + Text(verbatim: " · \(formatClock(recording.durationSeconds))"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let jobChip {
                    if jobChip.isAutomatic {
                        StatusChip(title: "Auto", tone: .info, compact: true)
                            .help("Queued automatically by auto-transcribe")
                    }
                    StatusChip(title: jobChip.title, tone: jobChip.tone, compact: true)
                }
                RecordingRowBadges(badges: badges)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var timeText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(recording.startedAt) || calendar.isDateInYesterday(recording.startedAt) {
            return recording.startedAt.formatted(date: .omitted, time: .shortened)
        }
        return recording.startedAt.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Renders an explicit badge list; the only place row badges are drawn.
struct RecordingRowBadges: View {
    let badges: [RecordingBadge]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(badges) { badge in
                Image(systemName: badge.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(badge.tint)
                    .help(badge.label)
                    .accessibilityLabel(badge.label)
            }
        }
    }
}

/// Collapsible "Transcription queue" block at the bottom of the sidebar.
struct TranscriptionQueueBlock: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Transcription queue")
                        .font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Text(verbatim: "\(viewModel.visibleTranscriptionJobs.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Transcription queue")
            .accessibilityValue(Text(verbatim: "\(viewModel.visibleTranscriptionJobs.count)"))

            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(Array(viewModel.visibleTranscriptionJobs.prefix(4)), id: \.id) { job in
                        TranscriptionJobRow(
                            job: job,
                            statusText: viewModel.jobStatusText(for: job),
                            onCancel: { viewModel.cancelTranscription(recordingID: job.recordingID) },
                            onRetry: { viewModel.retryTranscription(recordingID: job.recordingID) }
                        )
                    }
                    if !viewModel.recentTranscriptionHistory.isEmpty {
                        DisclosureGroup("History") {
                            VStack(spacing: 4) {
                                ForEach(viewModel.recentTranscriptionHistory, id: \.id) { job in
                                    TranscriptionJobRow(job: job, statusText: viewModel.jobStatusText(for: job), onCancel: {}, onRetry: {})
                                }
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct TranscriptionJobRow: View {
    let job: TranscriptionJob
    let statusText: String
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if job.status == .running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tone.accent)
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(job.recordingName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text.uiString(statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(job.status == .failed ? tone.foreground : Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)

            if job.status == .failed {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Retry transcription")
                .accessibilityLabel("Retry transcription")
            }
            if job.status == .queued || job.status == .running {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
                .help("Cancel transcription")
                .accessibilityLabel("Cancel transcription")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
    }

    private var tone: Tone {
        switch job.status {
        case .queued, .running: .progress
        case .failed: .warning
        case .completed: .success
        case .cancelled: .neutral
        }
    }

    private var iconName: String {
        switch job.status {
        case .queued: "clock"
        case .running: "waveform"
        case .failed: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }
}
