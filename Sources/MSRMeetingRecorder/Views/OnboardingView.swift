import SwiftUI
import MSRCore

/// The four first-run onboarding steps, in order (raw value = step number).
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome = 1
    case permissions
    case keys
    case automation

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .welcome: "Welcome to MSR"
        case .permissions: "Allow recording"
        case .keys: "Connect transcription"
        case .automation: "Automate the busywork"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .welcome:
            "Record meetings from your microphone, from Mac system audio, or both. Every recording saves automatically, and a transcript turns it into searchable notes with a summary and action items."
        case .permissions:
            "macOS asks once for each source. Nothing is recorded until you press Record."
        case .keys:
            "Add an ElevenLabs key to transcribe. An OpenAI or DeepSeek key is optional and writes titles and summaries."
        case .automation:
            "Choose what happens after each recording. You can change this any time in Settings."
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: "record.circle"
        case .permissions: "lock.shield"
        case .keys: "key"
        case .automation: "wand.and.stars"
        }
    }

    var tint: Color {
        switch self {
        case .welcome: Theme.recording
        case .permissions: Theme.info
        case .keys: Theme.warning
        case .automation: Theme.success
        }
    }

    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var isLast: Bool { next == nil }

    /// The step a sheet opens on: `MSR_UI_SNAPSHOT_ONBOARDING_STEP` in snapshot runs, else Welcome.
    static var initial: OnboardingStep {
        UISnapshotCapture.requestedOnboardingStep.flatMap(OnboardingStep.init(rawValue:)) ?? .welcome
    }
}

/// When the onboarding sheet opens by itself, and how it is opened and closed.
enum Onboarding {
    /// Presented at launch only on a first run (`hasCompletedOnboarding == false`).
    /// Snapshot runs show it only for `MSR_UI_SNAPSHOT_ONBOARDING=1` (the snapshot
    /// hook opens it then); scripted scenarios never get it on their own.
    static func shouldPresentAtLaunch(settings: AppSettings, environment: [String: String]) -> Bool {
        if environment["MSR_UI_SNAPSHOT_PATH"]?.isEmpty == false { return false }
        if environment["MSR_UI_SCENARIO"]?.isEmpty == false { return false }
        return !settings.hasCompletedOnboarding
    }

    /// Opens the sheet from anywhere (readiness checklist, empty state, walkthrough).
    @MainActor
    static func present() {
        NotificationCenter.default.post(name: .showOnboarding, object: nil)
    }

    /// Marks onboarding done and persists it. With `saveKeys`, typed API keys
    /// are saved as well (`saveAPIKeys()` also persists the settings). Returns
    /// `false`, leaving onboarding not done, when a typed key could not be
    /// saved: the sheet then stays open on the Keys step with the error.
    @MainActor
    @discardableResult
    static func complete(_ viewModel: AppViewModel, saveKeys: Bool) -> Bool {
        let wasCompleted = viewModel.settings.hasCompletedOnboarding
        if !wasCompleted {
            viewModel.settings.hasCompletedOnboarding = true
        }
        guard saveKeys, viewModel.hasUnsavedKeyDrafts else {
            viewModel.saveSettings()
            return true
        }
        if viewModel.saveAPIKeys() { return true }
        viewModel.settings.hasCompletedOnboarding = wasCompleted
        return false
    }
}

extension Notification.Name {
    static let showOnboarding = Notification.Name("MSRShowOnboarding")
}

/// First-run onboarding sheet (~560×520): Welcome → Permissions → Keys →
/// Automation, with a progress indicator and Back / Next / Skip. Esc skips.
/// Keys typed on the Keys step are saved when leaving it by any button (Back,
/// Next, Skip/Esc, Finish); a failed save keeps the sheet on that step.
/// Every control binds straight to `AppViewModel`, so it stays in step with
/// Settings and the readiness checklist.
struct OnboardingView: View {
    @ObservedObject var viewModel: AppViewModel
    let onClose: () -> Void
    @State private var step = OnboardingStep.initial
    @State private var lastTestedCredential: CredentialProvider?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 14)

            ScrollView {
                content
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("msr.onboarding.step.\(step.rawValue)")

            footer
        }
        .frame(width: 560, height: 520)
        .background(Theme.windowBackground)
        .onChange(of: viewModel.settings) { _, _ in viewModel.scheduleSettingsSave() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    ForEach(OnboardingStep.allCases) { item in
                        Capsule()
                            .fill(item.rawValue <= step.rawValue ? Theme.action : Theme.subtleFill)
                            .frame(width: item == step ? 28 : 16, height: 5)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: step)
                .accessibilityHidden(true)
                Text("Step \(step.rawValue) of \(OnboardingStep.allCases.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityIdentifier("msr.onboarding.progress")
                Spacer()
            }

            HStack(alignment: .top, spacing: 14) {
                Image(systemName: step.systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(step.tint)
                    .frame(width: 44, height: 44)
                    .background(step.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(step.subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .permissions: permissionsStep
        case .keys: keysStep
        case .automation: automationStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Record from")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Picker("Record from", selection: $viewModel.settings.preferredSource) {
                    ForEach(AudioSource.allCases) { source in
                        Text(LocalizedStringKey(source.displayName)).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("msr.onboarding.source")
                Text(sourceHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .cardBackground()

            VStack(alignment: .leading, spacing: 8) {
                featureRow("internaldrive", "Recordings save automatically to your recordings folder.")
                featureRow("text.quote", "Transcripts become notes you can search, edit and export.")
                featureRow("keyboard", "Press ⌘⇧R to start or stop recording.")
            }
            .padding(.horizontal, 4)
        }
    }

    private var sourceHint: LocalizedStringKey {
        switch viewModel.settings.preferredSource {
        case .microphone: "Your voice and the room, from the selected microphone."
        case .system: "Everything your Mac plays, such as a video call, without the microphone."
        case .micAndSystem: "Both sides of a call: your microphone plus Mac system audio."
        }
    }

    private func featureRow(_ systemImage: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                let items = viewModel.onboardingPermissionItems
                if items.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking permissions…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(14)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().padding(.leading, 42)
                    }
                    permissionRow(item)
                }
            }
            .cardBackground()

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("After you allow access in System Settings, come back and press Re-check. macOS may ask you to reopen MSR for Screen Recording.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    viewModel.refreshSetupHealth()
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .accessibilityIdentifier("msr.onboarding.recheck")
            }
        }
        .onAppear {
            // Pick up permissions granted while the sheet was open on another step.
            if !viewModel.setupHealthItems.isEmpty { viewModel.refreshSetupHealth() }
        }
    }

    private func permissionRow(_ item: SetupHealthItem) -> some View {
        let allowed = item.severity == .success
        return HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(item.severity.tone.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(item.title))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    StatusChip(
                        title: allowed ? "Allowed" : "Needed",
                        tone: allowed ? .success : item.severity.tone,
                        systemImage: allowed ? "checkmark" : nil,
                        compact: true
                    )
                }
                Text(item.id == "microphone" ? "For your voice and in-room audio." : "For the other side of calls and anything your Mac plays.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !allowed {
                    Text.uiString(item.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(item.severity.tone.foreground)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button(LocalizedStringKey(viewModel.fixActionTitle(for: item))) {
                viewModel.fixSetupItem(item)
            }
            .controlSize(.small)
            .accessibilityIdentifier("msr.onboarding.fix.\(item.id)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .contain)
    }

    private var keysStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                keyBlock(
                    title: "ElevenLabs API Key",
                    caption: "Required for transcription.",
                    credential: .elevenLabs,
                    draft: $viewModel.elevenLabsKeyDraft,
                    testTitle: "Test ElevenLabs Key"
                )
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("Summaries and titles")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Optional")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Picker("Summary provider", selection: $viewModel.settings.summaryProvider) {
                            ForEach(TextModelProvider.allCases) { provider in
                                Text(LocalizedStringKey(provider.displayName)).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("msr.onboarding.summaryProvider")
                    }
                    switch viewModel.settings.summaryProvider {
                    case .openAI:
                        keyBlock(
                            title: "OpenAI API Key",
                            caption: nil,
                            credential: .openAI,
                            draft: $viewModel.openAIKeyDraft,
                            testTitle: "Test OpenAI Key"
                        )
                    case .deepSeek:
                        keyBlock(
                            title: "DeepSeek API Key",
                            caption: nil,
                            credential: .deepSeek,
                            draft: $viewModel.deepSeekKeyDraft,
                            testTitle: "Test DeepSeek Key"
                        )
                    }
                }
            }
            .padding(14)
            .cardBackground()

            Toggle("Remember credentials in Keychain", isOn: $viewModel.settings.rememberCredentials)
                .font(.system(size: 12.5))
                .accessibilityIdentifier("msr.onboarding.rememberCredentials")

            Label {
                Text("Privacy: audio goes to your transcription provider only when a recording is transcribed, and transcripts go to OpenAI or DeepSeek only for titles and summaries. Recordings stay on this Mac.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "hand.raised")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textSecondary)
            .accessibilityIdentifier("msr.onboarding.privacy")
        }
    }

    @ViewBuilder
    private func keyBlock(
        title: LocalizedStringKey,
        caption: LocalizedStringKey?,
        credential: CredentialProvider,
        draft: Binding<String>,
        testTitle: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                credentialChip(credential)
            }
            HStack(spacing: 8) {
                SecureField(title, text: draft, prompt: Text("Paste a key to save or replace it"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityIdentifier("msr.onboarding.\(credential.rawValue)Key")
                Button(testTitle) {
                    lastTestedCredential = credential
                    Task { await viewModel.testCredential(credential: credential) }
                }
                .controlSize(.small)
                .disabled(viewModel.isTestingCredential
                    || (draft.wrappedValue.isEmpty && !viewModel.hasSavedCredential(credential)))
                .accessibilityIdentifier("msr.onboarding.test.\(credential.rawValue)")
            }
            if lastTestedCredential == credential {
                if viewModel.isTestingCredential {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Testing…").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                    }
                } else if !viewModel.credentialStatusMessage.isEmpty {
                    Label {
                        Text.uiString(viewModel.credentialStatusMessage)
                            .lineLimit(2)
                    } icon: {
                        Image(systemName: viewModel.credentialStatusSeverity.iconName)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(viewModel.credentialStatusSeverity.foregroundColor)
                }
            }
        }
    }

    /// Saved/Missing from the cached credential state; a typed key reads "Not
    /// saved yet", and a saved one "Saved for this session" while
    /// "Remember credentials in Keychain" is off.
    private func credentialChip(_ credential: CredentialProvider) -> some View {
        let saved = viewModel.hasSavedCredential(credential)
        let drafted = !draftText(for: credential).isEmpty
        let title = OnboardingView.chipTitle(
            saved: saved, drafted: drafted, remembered: viewModel.settings.rememberCredentials
        )
        let tone: Tone = drafted ? .info : (saved ? .success : (credential == .elevenLabs ? .warning : .neutral))
        return StatusChip(title: title, tone: tone, systemImage: saved && !drafted ? "checkmark" : nil, compact: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("msr.onboarding.keyStatus.\(credential.rawValue)")
    }

    /// The key-status chip's (English, localized-key) title.
    static func chipTitle(saved: Bool, drafted: Bool, remembered: Bool) -> String {
        if drafted { return "Not saved yet" }
        if !saved { return "Missing" }
        return remembered ? "Saved" : "Saved for this session"
    }

    private func draftText(for credential: CredentialProvider) -> String {
        switch credential {
        case .elevenLabs: viewModel.elevenLabsKeyDraft
        case .openAI: viewModel.openAIKeyDraft
        case .deepSeek: viewModel.deepSeekKeyDraft
        }
    }

    private var automationStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                automationToggle(
                    "Auto-transcribe new recordings",
                    isOn: $viewModel.settings.autoTranscribe,
                    identifier: "msr.onboarding.autoTranscribe",
                    detail: viewModel.settings.autoTranscribe && !viewModel.transcriptionKeyIsSaved
                        ? "On, but no key is saved for the transcription provider yet. Go back to add one."
                        : "Queue every finished recording for transcription right away.",
                    warning: viewModel.settings.autoTranscribe && !viewModel.transcriptionKeyIsSaved
                )
                Divider().padding(.leading, 14)
                automationToggle(
                    "Auto-title recordings from the transcript",
                    isOn: $viewModel.settings.autoTitle,
                    identifier: "msr.onboarding.autoTitle",
                    detail: "Rename each recording from what was said, unless you named it yourself."
                )
                Divider().padding(.leading, 14)
                automationToggle(
                    "Auto-summarize after transcription",
                    isOn: Binding(
                        // Reads as off while no summary key exists; the setting itself is kept.
                        get: { viewModel.settings.autoSummarize && viewModel.canSummarize },
                        set: { viewModel.settings.autoSummarize = $0 }
                    ),
                    identifier: "msr.onboarding.autoSummarize",
                    detail: viewModel.canSummarize
                        ? "Write a summary and action items after each transcript."
                        : "Requires an OpenAI or DeepSeek API key.",
                    disabled: !viewModel.canSummarize
                )
            }
            .cardBackground()

            Text("You're all set. Press Finish, then Record (⌘⇧R) when your meeting starts.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func automationToggle(
        _ title: LocalizedStringKey,
        isOn: Binding<Bool>,
        identifier: String,
        detail: LocalizedStringKey,
        warning: Bool = false,
        disabled: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(disabled ? Theme.textTertiary : Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(warning ? Tone.warning.foreground : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(disabled)
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Skip") { close(saveKeys: true) }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
                .keyboardShortcut(.cancelAction)
                .help("Skip setup. You can open it again from the Ready screen.")
                .accessibilityIdentifier("msr.onboarding.skip")
            Spacer()
            if let previous = step.previous {
                Button("Back") { leave(to: previous) }
                    .accessibilityIdentifier("msr.onboarding.back")
            }
            if let next = step.next {
                Button("Next") { leave(to: next) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("msr.onboarding.next")
            } else {
                Button("Finish") { close(saveKeys: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("msr.onboarding.finish")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .frame(height: 60)
        .background(Theme.chromeBackground)
        .overlay(alignment: .top) { HairlineDivider() }
    }

    private func go(to target: OnboardingStep) {
        withAnimation(.easeOut(duration: 0.15)) { step = target }
    }

    /// Back/Next. Typed keys are saved when leaving the Keys step either way,
    /// so its Saved chips and the Automation step (auto-summarize needs a key)
    /// reflect them; a failed save stays on Keys and shows the error.
    private func leave(to target: OnboardingStep) {
        if step == .keys, viewModel.hasUnsavedKeyDrafts, !viewModel.saveAPIKeys() {
            showSaveFailure()
            return
        }
        go(to: target)
    }

    /// Finish, Skip and Esc (Skip's cancel shortcut). Keys the user typed are
    /// saved rather than left behind as drafts; a failed save keeps the sheet
    /// open on the Keys step.
    private func close(saveKeys: Bool) {
        guard Onboarding.complete(viewModel, saveKeys: saveKeys) else {
            showSaveFailure()
            return
        }
        onClose()
    }

    /// Shows `saveAPIKeys()`'s error under the key that failed: keys are saved
    /// in field order and a saved draft is cleared, so it is the first one left.
    private func showSaveFailure() {
        if !viewModel.elevenLabsKeyDraft.isEmpty {
            lastTestedCredential = .elevenLabs
        } else if !viewModel.openAIKeyDraft.isEmpty {
            lastTestedCredential = .openAI
        } else if !viewModel.deepSeekKeyDraft.isEmpty {
            lastTestedCredential = .deepSeek
        }
        if step != .keys { go(to: .keys) }
    }
}
