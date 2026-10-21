import AppKit
import Foundation
import Testing
import MSRCore
import MSRServices
@testable import MSRMeetingRecorder

/// 1.4 first-run onboarding: the setting, when the sheet opens by itself,
/// the step order and what finishing or skipping saves.
@Suite("1.4 first-run onboarding", .serialized)
@MainActor
struct OnboardingTests {
    @Test func settingDefaultsToFalseAndRoundTrips() throws {
        #expect(AppSettings.default.hasCompletedOnboarding == false)
        #expect(AppSettings(provider: .elevenLabs, recordingsFolderPath: nil).hasCompletedOnboarding == false)
        var settings = AppSettings.default
        settings.hasCompletedOnboarding = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.hasCompletedOnboarding)
        let explicit = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hasCompletedOnboarding":true}"#.utf8))
        #expect(explicit.hasCompletedOnboarding)
    }

    @Test func presentsAtLaunchOnlyOnAFirstRunOutsideScriptedRuns() {
        var settings = AppSettings.default
        #expect(Onboarding.shouldPresentAtLaunch(settings: settings, environment: [:]))
        // Snapshot runs open it themselves (MSR_UI_SNAPSHOT_ONBOARDING=1); scenarios never get it.
        #expect(!Onboarding.shouldPresentAtLaunch(settings: settings, environment: ["MSR_UI_SNAPSHOT_PATH": "/tmp/x.png"]))
        #expect(!Onboarding.shouldPresentAtLaunch(settings: settings, environment: ["MSR_UI_SCENARIO": "ui-walkthrough"]))
        #expect(Onboarding.shouldPresentAtLaunch(settings: settings, environment: ["MSR_UI_SNAPSHOT_PATH": ""]))
        settings.hasCompletedOnboarding = true
        #expect(!Onboarding.shouldPresentAtLaunch(settings: settings, environment: [:]))
    }

    @Test func stepsRunInOrderWithBackAndNext() {
        #expect(OnboardingStep.allCases.map(\.rawValue) == [1, 2, 3, 4])
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.welcome.next == .permissions)
        #expect(OnboardingStep.keys.previous == .permissions)
        #expect(OnboardingStep.automation.next == nil)
        #expect(OnboardingStep.automation.isLast)
        // Outside snapshot runs the sheet always opens on Welcome.
        #expect(OnboardingStep.initial == .welcome)
    }

    @Test func finishSavesTypedKeysAndSkipOnlyMarksItDone() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("msr-onboarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let skipped = AppViewModel(recordingsFolderOverride: folder)
        skipped.settingsPersistenceSuspended = true
        skipped.settings.hasCompletedOnboarding = false
        skipped.elevenLabsKeyDraft = "typed-but-skipped"
        #expect(skipped.hasUnsavedKeyDrafts)
        // `saveKeys: false` is only the sheet's dismiss fallback (Skip and Esc
        // save typed keys like Finish): it marks onboarding done, saves nothing.
        #expect(Onboarding.complete(skipped, saveKeys: false))
        #expect(skipped.settings.hasCompletedOnboarding)
        #expect(skipped.elevenLabsKeyDraft == "typed-but-skipped")

        let finished = AppViewModel(recordingsFolderOverride: folder)
        finished.settingsPersistenceSuspended = true
        finished.settings.hasCompletedOnboarding = false
        finished.settings.rememberCredentials = false
        finished.openAIKeyDraft = "sk-onboarding-session-only"
        #expect(Onboarding.complete(finished, saveKeys: true))
        #expect(finished.settings.hasCompletedOnboarding)
        #expect(!finished.hasUnsavedKeyDrafts)
        #expect(finished.credentialAvailable(for: .openAI))

        // A key that cannot be saved keeps onboarding open, its draft and the
        // workflow state untouched, and reports the error on the Keys step.
        let failing = AppViewModel(recordingsFolderOverride: folder)
        failing.settingsPersistenceSuspended = true
        failing.settings.hasCompletedOnboarding = false
        failing.settings.rememberCredentials = false
        let state = failing.workflowState
        failing.deepSeekKeyDraft = " \n "
        #expect(!Onboarding.complete(failing, saveKeys: true))
        #expect(!failing.settings.hasCompletedOnboarding)
        #expect(failing.hasUnsavedKeyDrafts)
        #expect(failing.workflowState == state)
        #expect(failing.credentialStatusSeverity == .error)
    }

    @Test func keyChipSaysSessionOnlyWhenNotRemembered() {
        #expect(OnboardingView.chipTitle(saved: true, drafted: false, remembered: true) == "Saved")
        #expect(OnboardingView.chipTitle(saved: true, drafted: false, remembered: false) == "Saved for this session")
        #expect(OnboardingView.chipTitle(saved: true, drafted: true, remembered: false) == "Not saved yet")
        #expect(OnboardingView.chipTitle(saved: false, drafted: false, remembered: false) == "Missing")
    }

    @Test func permissionRowsComeFromSetupHealth() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("msr-onboarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppViewModel(recordingsFolderOverride: folder)
        model.settingsPersistenceSuspended = true
        #expect(model.onboardingPermissionItems.isEmpty)
        model.setupHealthItems = [
            SetupHealthItem(id: "folder", title: "Recordings Folder", detail: "/tmp", severity: .success, systemImage: "folder"),
            SetupHealthItem(id: "screen", title: "System Audio Permission", detail: "x", severity: .warning, systemImage: "speaker"),
            SetupHealthItem(id: "microphone", title: "Microphone Permission", detail: "Allowed", severity: .success, systemImage: "mic")
        ]
        #expect(model.onboardingPermissionItems.map(\.id) == ["microphone", "screen"])
        #expect(model.onboardingPermissionItems.allSatisfy { model.fixActionTitle(for: $0) == "Open Privacy Settings" })
    }
}
