import AppKit
import SwiftUI
import MSRCore

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @FocusState private var recordingSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            mockTitleBar
            topRecordingBar
            recoveryBanner
            appErrorBanner
            mainArea
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(Color(hex: 0xFBFBFC))
        .background(WindowChromeConfigurator())
        .sheet(isPresented: $viewModel.showingRename) {
            renameSheet
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusRecordingSearch)) { _ in
            recordingSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearRecordingSearch)) { _ in
            viewModel.clearRecordingSearch()
            recordingSearchFocused = false
        }
    }

    private var mockTitleBar: some View {
        HStack(spacing: 0) {
            Text("MSR Meeting Recorder")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color(hex: 0x344054))
                .padding(.leading, 112)

            Spacer()
        }
        .frame(height: 58)
        .background(Color(hex: 0xF7F7F8))
    }

    private var topRecordingBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                sourcePickerSection
                meterSection
                Spacer(minLength: 0)
            }
            HStack(spacing: 16) {
                recordingStatusBlock
                recordingControlButtons
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 102)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(hex: 0xD8DEE8))
                .frame(height: 1)
        }
    }

    private var sourcePickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source")
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: 0x667085))
            SourceSegmentedControl(selection: $viewModel.selectedSource, disabled: viewModel.sourcePickerDisabled)
                .frame(width: 258, height: 38)
        }
    }

    private var meterSection: some View {
        HStack(spacing: 18) {
            SignalMeterView(title: "Mic", level: viewModel.microphoneLevel, isActive: viewModel.isRecording, meterWidth: 150)
                .frame(width: 150)
            SignalMeterView(title: "System", level: viewModel.systemLevel, isActive: viewModel.isRecording, meterWidth: 150)
                .frame(width: 150)
        }
    }

    private var recordingStatusBlock: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(statusChipText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(statusChipForeground)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(statusChipBackground, in: Capsule())

            Text(formatDuration(viewModel.recordingElapsed))
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(hex: 0x111827))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(minWidth: 110, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Recording timer \(formatDuration(viewModel.recordingElapsed))")
        }
    }

    private var recordingControlButtons: some View {
        HStack(spacing: 14) {
            if let secondaryTitle = viewModel.secondaryRecordingButtonTitle {
                Button {
                    Task { await viewModel.useSecondaryRecordingAction() }
                } label: {
                    Label(secondaryTitle, systemImage: viewModel.secondaryRecordingButtonSystemImage)
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 104, height: 48)
                }
                .buttonStyle(OutlineButtonStyle(cornerRadius: 14))
                .disabled(!viewModel.canUseSecondaryRecordingAction)
                .help(secondaryTitle)
            }

            Button {
                Task { await viewModel.toggleRecording() }
            } label: {
                Label(viewModel.recordingButtonTitle, systemImage: viewModel.recordingButtonSystemImage)
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 190, height: 54)
            }
            .buttonStyle(PillButtonStyle(
                foreground: .white,
                background: viewModel.isRecording ? Color(hex: 0xDC2626) : Color(hex: 0x2563EB)
            ))
            .disabled(!viewModel.canToggleRecording)
            .help(viewModel.recordingButtonTitle)

            Button {
                viewModel.openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(CircleIconButtonStyle())
            .help("Settings")
            .accessibilityLabel("Settings")
        }
    }

    private var recoveryBanner: some View {
        Group {
            if !viewModel.recoveryMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NoticeBanner(message: viewModel.recoveryMessage, severity: viewModel.recoveryNoticeSeverity)
            }
        }
    }

    private var appErrorBanner: some View {
        Group {
            if let errorMessage = viewModel.workflowErrorMessage,
               viewModel.recoveryMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NoticeBanner(message: errorMessage, severity: .error)
            }
        }
    }

    private var statusChipText: String {
        switch viewModel.workflowState {
        case .ready:
            return "Ready"
        case .starting:
            return "Starting"
        case .recording:
            return "Recording"
        case .suspending:
            return "Pausing"
        case let .paused(_, reason):
            return reason.displayName
        case .finalizing:
            return "Saving"
        case .saved:
            return "Saved"
        case .recovering:
            return "Recovering"
        case .transcribing:
            return "Transcribing"
        case .summarizing:
            return "Summarizing"
        case .failed:
            return "Needs attention"
        }
    }

    private var statusChipForeground: Color {
        switch viewModel.workflowState {
        case .recording:
            return Color(hex: 0x991B1B)
        case .paused, .suspending:
            return Color(hex: 0x92400E)
        case .recovering, .finalizing, .transcribing, .summarizing:
            return Color(hex: 0x1D4ED8)
        case .failed:
            return Color(hex: 0xB91C1C)
        case .ready, .starting, .saved:
            return Color(hex: 0x166534)
        }
    }

    private var statusChipBackground: Color {
        switch viewModel.workflowState {
        case .recording:
            return Color(hex: 0xFEE2E2)
        case .paused, .suspending:
            return Color(hex: 0xFEF3C7)
        case .recovering, .finalizing, .transcribing, .summarizing:
            return Color(hex: 0xDBEAFE)
        case .failed:
            return Color(hex: 0xFEE2E2)
        case .ready, .starting, .saved:
            return Color(hex: 0xDCFCE7)
        }
    }

    private var mainArea: some View {
        HStack(spacing: 0) {
            historySidebar
                .frame(width: 310)
            Rectangle()
                .fill(Color(hex: 0xD8DEE8))
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recordings")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color(hex: 0x111827))
                Spacer()
                Button {
                    viewModel.loadRecordings()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(hex: 0x667085))
                .disabled(!viewModel.canSelectHistory)
                .help("Refresh history")
                .accessibilityLabel("Refresh history")
            }
            .padding(.top, 30)
            .padding(.horizontal, 20)

            recordingSearchField
                .padding(.top, 14)
                .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if recordingSections.isEmpty {
                        sidebarEmptyState
                    } else {
                        ForEach(recordingSections) { section in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(section.title)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color(hex: 0x667085))
                                    .padding(.horizontal, 12)

                                VStack(spacing: 8) {
                                    ForEach(section.recordings) { recording in
                                        RecordingRow(
                                            recording: recording,
                                            isSelected: recording.id == viewModel.selectedRecording?.id
                                        )
                                        .onTapGesture {
                                            viewModel.select(recording)
                                        }
                                        .opacity(viewModel.canSelectHistory ? 1 : 0.68)
                                        .contextMenu {
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
                                                Label("Show in Finder", systemImage: "finder")
                                            }
                                            Button(role: .destructive) {
                                                viewModel.delete(recording)
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                            .disabled(!viewModel.canMutateRecordingLibrary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.top, 18)
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
        }
        .background(Color(hex: 0xF6F8FB))
    }

    private var recordingSearchField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x667085))

                TextField("Search recordings", text: $viewModel.recordingSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(hex: 0x111827))
                    .focused($recordingSearchFocused)
                    .disabled(!viewModel.canSelectHistory)

                if viewModel.isSearchingRecordings {
                    Button {
                        viewModel.clearRecordingSearch()
                        recordingSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(hex: 0x98A2B3))
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(recordingSearchFocused ? Color(hex: 0xF97316) : Color(hex: 0xD0D5DD), lineWidth: 1)
            }

            if viewModel.isSearchingRecordings {
                Text(recordingSearchResultText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x667085))
                    .padding(.horizontal, 4)
            }
        }
    }

    private var recordingSearchResultText: String {
        let count = viewModel.recordingSearchResultCount
        return "\(count) result\(count == 1 ? "" : "s")"
    }

    private var sidebarEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(viewModel.isSearchingRecordings ? "No recordings found" : "No recordings yet")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color(hex: 0x344054))
            Text(viewModel.isSearchingRecordings ? "Try a different query." : "Your recordings will appear here.")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0x667085))
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 18)
    }

    private var detail: some View {
        Group {
            if let recording = viewModel.selectedRecording {
                ScrollView {
                    recordingDetail(recording)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                readyState
            }
        }
        .padding(.top, 29)
        .padding(.leading, 39)
        .padding(.trailing, 53)
        .padding(.bottom, 40)
        .background(Color(hex: 0xFBFBFC))
    }

    private func recordingDetail(_ recording: RecordingItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(recording.displayName)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color(hex: 0x111827))
                        .lineLimit(2)
                    Text(recordingSubtitle(recording))
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: 0x667085))
                }
                Spacer()
            }

            playbackStrip
                .padding(.top, 24)

            actionRow
                .padding(.top, 25)

            transcriptSummaryArea
                .padding(.top, 34)

            Spacer(minLength: 0)
        }
    }

    private var transcriptSummaryArea: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 32) {
                transcriptPanel
                    .frame(minWidth: 460, maxWidth: .infinity)
                summaryPanel
                    .frame(width: 264)
            }

            VStack(alignment: .leading, spacing: 24) {
                transcriptPanel
                    .frame(maxWidth: .infinity)
                summaryPanel
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var playbackStrip: some View {
        HStack(spacing: 18) {
            Button {
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 19, weight: .bold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(CircleButtonStyle())
            .disabled(!viewModel.canPlaySelectedRecording)
            .help(viewModel.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            Text("\(formatDuration(viewModel.playbackPosition)) / \(formatDuration(viewModel.playbackDuration))")
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(hex: 0x344054))
                .frame(width: 118, alignment: .leading)

            ProgressView(value: viewModel.playbackDuration == 0 ? 0 : viewModel.playbackPosition / viewModel.playbackDuration)
                .progressViewStyle(.linear)
                .tint(Color(hex: 0x3B82F6))
                .frame(maxWidth: .infinity)

            Button {
                viewModel.startRename()
            } label: {
                Label("Rename", systemImage: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 142, height: 36)
            }
            .buttonStyle(OutlineButtonStyle())
            .disabled(!viewModel.canMutateRecordingLibrary)
        }
        .padding(.horizontal, 18)
        .frame(height: 68)
        .background(Color(hex: 0xF8FAFC), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: 0xE4E7EC), lineWidth: 1)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await viewModel.runPrimaryAction() }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.workflowState.isTranscribing || viewModel.workflowState.isSummarizing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Label(viewModel.primaryActionTitle, systemImage: viewModel.primaryAction.systemImage)
                }
                .font(.system(size: 16, weight: .bold))
                .frame(height: 44)
                .padding(.horizontal, 22)
            }
            .buttonStyle(PillButtonStyle(foreground: .white, background: Color(hex: 0x2563EB), cornerRadius: 10))
            .disabled(!viewModel.canRunPrimaryAction)

            Button {
                viewModel.copyTranscript()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 140, height: 44)
            }
            .buttonStyle(OutlineButtonStyle(cornerRadius: 10))
            .disabled(!viewModel.hasTranscript)

            Button {
                viewModel.showInFinder()
            } label: {
                Label("Finder", systemImage: "finder")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 150, height: 44)
            }
            .buttonStyle(OutlineButtonStyle(cornerRadius: 10))

            Spacer()
        }
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcript")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color(hex: 0x111827))

            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.transcriptText)
                    .font(.system(size: 16))
                    .foregroundStyle(Color(hex: 0x344054))
                    .scrollContentBackground(.hidden)
                    .background(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .contextMenu {
                        Button {
                            viewModel.copyTranscript()
                        } label: {
                            Label("Copy Transcript", systemImage: "doc.on.doc")
                        }
                        Button {
                            Task { await viewModel.retranscribeSelected() }
                        } label: {
                            Label("Re-transcribe", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Divider()
                        Button {
                            viewModel.saveTranscript(format: .text)
                        } label: {
                            Label("Save as .txt", systemImage: "doc.plaintext")
                        }
                        Button {
                            viewModel.saveTranscript(format: .markdown)
                        } label: {
                            Label("Save as .md", systemImage: "doc.richtext")
                        }
                    }
                    .disabled(viewModel.workflowState.isTranscribing)

                if viewModel.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !viewModel.workflowState.isTranscribing {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No transcript yet")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x344054))
                        Text("Run transcription when this recording is ready.")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: 0x667085))
                    }
                    .padding(24)
                    .allowsHitTesting(false)
                }

                if viewModel.workflowState.isTranscribing {
                    TranscriptionProgressOverlay(
                        provider: viewModel.settings.provider,
                        startedAt: viewModel.transcriptionStartedAt ?? Date()
                    )
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 228)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: 0xD0D5DD), lineWidth: 1)
            }
        }
    }

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Summary")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color(hex: 0x111827))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.summaryText)
                    .font(.system(size: 16))
                    .foregroundStyle(Color(hex: 0x344054))
                    .scrollContentBackground(.hidden)
                    .background(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)

                if viewModel.summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No summary yet")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x344054))
                        Text(viewModel.hasTranscript ? "Summarize the transcript to fill this panel." : "Transcript comes first.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0x667085))
                    }
                    .padding(24)
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 228)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: 0xD0D5DD), lineWidth: 1)
            }
        }
    }

    private var readyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "record.circle")
                .font(.system(size: 48))
                .foregroundStyle(Color(hex: 0x667085))
            Text("Ready to record")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color(hex: 0x111827))
            Text(viewModel.statusMessage)
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: 0x667085))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Recording")
                .font(.headline)
            TextField("Recording name", text: $viewModel.renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.showingRename = false
                }
                Button("Save") {
                    viewModel.applyRename()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private var recordingSections: [RecordingSection] {
        let calendar = Calendar.current
        let recordings = viewModel.filteredRecordings
        let today = recordings.filter { calendar.isDateInToday($0.startedAt) }
        let yesterday = recordings.filter { calendar.isDateInYesterday($0.startedAt) }
        let earlier = recordings.filter {
            !calendar.isDateInToday($0.startedAt) && !calendar.isDateInYesterday($0.startedAt)
        }

        return [
            RecordingSection(title: "TODAY", recordings: today),
            RecordingSection(title: "YESTERDAY", recordings: yesterday),
            RecordingSection(title: "EARLIER", recordings: earlier)
        ].filter { !$0.recordings.isEmpty }
    }

    private func recordingSubtitle(_ recording: RecordingItem) -> String {
        "\(recording.source.displayName) - \(formatDuration(recording.durationSeconds)) - \(relativeSavedText(recording.metadata.updatedAt))"
    }

    private func relativeSavedText(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "saved just now"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "saved \(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "saved \(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        let days = hours / 24
        return "saved \(days) day\(days == 1 ? "" : "s") ago"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

extension Notification.Name {
    static let focusRecordingSearch = Notification.Name("MSRFocusRecordingSearch")
    static let clearRecordingSearch = Notification.Name("MSRClearRecordingSearch")
}

struct NoticeBanner: View {
    let message: String
    let severity: AppNoticeSeverity
    var horizontalPadding: CGFloat = 32

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: severity.iconName)
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 2)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(severity.foregroundColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .padding(.horizontal, horizontalPadding)
        .background(severity.backgroundColor)
        .overlay {
            Rectangle()
                .fill(severity.borderColor)
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

private struct TranscriptionProgressOverlay: View {
    let provider: AIProvider
    let startedAt: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            let tick = Int(elapsed.rounded(.down))

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(TranscriptionProgressDisplay.message(provider: provider, tick: tick))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color(hex: 0x111827))
                            .contentTransition(.numericText())
                        Text("Elapsed \(TranscriptionProgressDisplay.elapsedText(seconds: elapsed))")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x475467))
                    }
                    Spacer()
                }

                TranscriptionShimmerBar(date: context.date)

                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Uploading full recording. Waiting for transcript.")
                        .font(.system(size: 13))
                        .lineLimit(1)
                }
                .foregroundStyle(Color(hex: 0x475467))
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(Color.white.opacity(0.95))
        }
    }
}

private struct TranscriptionShimmerBar: View {
    let date: Date

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let highlightWidth = max(90, width * 0.28)
            let cycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            let offset = -highlightWidth + CGFloat(cycle) * (width + highlightWidth)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(hex: 0xE0E7FF))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: 0x93C5FD).opacity(0.1),
                                Color(hex: 0x2563EB),
                                Color(hex: 0x22C55E).opacity(0.85),
                                Color(hex: 0x93C5FD).opacity(0.1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: highlightWidth)
                    .offset(x: offset)
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }
}

private struct RecordingSection: Identifiable {
    let title: String
    let recordings: [RecordingItem]

    var id: String { title }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
    }
}

private struct SourceSegmentedControl: View {
    @Binding var selection: AudioSource
    let disabled: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AudioSource.allCases) { source in
                Button {
                    guard !disabled else { return }
                    selection = source
                } label: {
                    Text(label(for: source))
                        .font(.system(size: 15, weight: selection == source ? .bold : .regular))
                        .foregroundStyle(Color(hex: 0x344054))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .background {
                    if selection == source {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.white)
                            .overlay {
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(Color(hex: 0x98A2B3), lineWidth: 1)
                            }
                    }
                }

                if source != AudioSource.allCases.last {
                    Rectangle()
                        .fill(Color(hex: 0xD0D5DD))
                        .frame(width: 1, height: 18)
                }
            }
        }
        .padding(1)
        .background(Color(hex: 0xEEF2F7), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color(hex: 0xD0D5DD), lineWidth: 1)
        }
        .opacity(disabled ? 0.7 : 1)
    }

    private func label(for source: AudioSource) -> String {
        switch source {
        case .microphone:
            return "Mic"
        case .system:
            return "System"
        case .micAndSystem:
            return "Both"
        }
    }
}

private struct RecordingRow: View {
    let recording: RecordingItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recording.displayName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color(hex: 0x111827))
                .lineLimit(1)
            Text("\(recording.source.displayName) - \(formatDuration(recording.durationSeconds))")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0x475467))
                .lineLimit(1)
        }
        .padding(.leading, isSelected ? 28 : 28)
        .padding(.trailing, 16)
        .frame(height: 74)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hex: 0x3B82F6))
                    .frame(width: 5, height: 35)
                    .padding(.leading, 12)
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(hex: 0x7AA2F7), lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct SignalMeterView: View {
    let title: String
    let level: Float
    let isActive: Bool
    let meterWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: 0x667085))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(hex: 0xE4E7EC))
                Capsule()
                    .fill(fill)
                    .frame(width: max(8, meterWidth * CGFloat(max(0, min(1, level)))))
            }
            .frame(width: meterWidth, height: 12)
            Text(statusText)
                .font(.system(size: 13))
                .foregroundStyle(statusColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(statusText)")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private var statusText: String {
        guard isActive else { return "idle" }
        return level < 0.02 ? "no signal" : title == "System" ? "capturing audio" : "signal detected"
    }

    private var statusColor: Color {
        guard isActive else { return Color(hex: 0x667085) }
        return level < 0.02 ? Color(hex: 0xD97706) : title == "System" ? Color(hex: 0x005BFF) : Color(hex: 0x008A2E)
    }

    private var fill: LinearGradient {
        if title == "System" {
            return LinearGradient(
                colors: [Color(hex: 0x3B82F6), Color(hex: 0x3B82F6)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [Color(hex: 0x22C55E), Color(hex: 0x84CC16), Color(hex: 0xF59E0B)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

private struct PillButtonStyle: ButtonStyle {
    let foreground: Color
    let background: Color
    var cornerRadius: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background.opacity(configuration.isPressed ? 0.86 : 1), in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

private struct OutlineButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(hex: 0x344054))
            .background(Color.white.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color(hex: 0xD0D5DD), lineWidth: 1)
            }
    }
}

private struct CircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(hex: 0x111827))
            .background(Color.white.opacity(configuration.isPressed ? 0.72 : 1), in: Circle())
            .overlay {
                Circle()
                    .stroke(Color(hex: 0xD0D5DD), lineWidth: 1)
            }
    }
}

private struct CircleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(hex: 0x344054))
            .background(Color(hex: 0xF2F4F7).opacity(configuration.isPressed ? 0.72 : 1), in: Circle())
            .overlay {
                Circle()
                    .stroke(Color(hex: 0xD0D5DD), lineWidth: 1)
            }
    }
}

private extension AppNoticeSeverity {
    var iconName: String {
        switch self {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    var foregroundColor: Color {
        switch self {
        case .info:
            return Color(hex: 0x075985)
        case .success:
            return Color(hex: 0x166534)
        case .warning:
            return Color(hex: 0x92400E)
        case .error:
            return Color(hex: 0x991B1B)
        }
    }

    var backgroundColor: Color {
        switch self {
        case .info:
            return Color(hex: 0xE0F2FE)
        case .success:
            return Color(hex: 0xDCFCE7)
        case .warning:
            return Color(hex: 0xFEF3C7)
        case .error:
            return Color(hex: 0xFEE2E2)
        }
    }

    var borderColor: Color {
        switch self {
        case .info:
            return Color(hex: 0xBAE6FD)
        case .success:
            return Color(hex: 0xBBF7D0)
        case .warning:
            return Color(hex: 0xFDE68A)
        case .error:
            return Color(hex: 0xFECACA)
        }
    }
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xff) / 255
        let green = Double((hex >> 8) & 0xff) / 255
        let blue = Double(hex & 0xff) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
