import Foundation
import Testing
import MSRCore
import MSRServices
@testable import MSRMeetingRecorder

@Suite("Menu-bar quick recorder")
struct QuickRecorderTests {
    @Test func showMenuBarTimerDefaultsOnAndDecodesWhenMissing() throws {
        #expect(AppSettings.default.showMenuBarTimer)
        #expect(AppSettings(provider: .elevenLabs, recordingsFolderPath: nil).showMenuBarTimer)
        // Settings saved before 1.4 have no key: the timer stays on.
        let legacy = Data(#"{"showMenuBarControl":false}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        #expect(decoded.showMenuBarTimer)
        #expect(decoded.showMenuBarControl == false)
    }

    @Test func showMenuBarTimerRoundTrips() throws {
        var settings = AppSettings.default
        settings.showMenuBarTimer = false
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).showMenuBarTimer == false)
    }

    @Test func statusTitleShowsElapsedOnlyDuringAnActiveSessionWithTheTimerOn() {
        #expect(QuickRecorderController.statusTitle(isSessionActive: true, showTimer: true, elapsed: 75) == "01:15")
        #expect(QuickRecorderController.statusTitle(isSessionActive: true, showTimer: true, elapsed: 3_725) == "01:02:05")
        #expect(QuickRecorderController.statusTitle(isSessionActive: true, showTimer: false, elapsed: 75).isEmpty)
        #expect(QuickRecorderController.statusTitle(isSessionActive: false, showTimer: true, elapsed: 75).isEmpty)
    }

    @Test func statusSymbolFollowsRecordingState() {
        #expect(QuickRecorderController.statusSymbol(isRecording: true, isPaused: false) == "record.circle.fill")
        #expect(QuickRecorderController.statusSymbol(isRecording: false, isPaused: true) == "pause.circle.fill")
        #expect(QuickRecorderController.statusSymbol(isRecording: false, isPaused: false) == "waveform.circle")
    }

    @MainActor
    @Test func viewModelHasNoQuickRecorderUntilTheSceneInstallsIt() {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/meeting-en.m4a")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("msr-quick-\(UUID().uuidString)")
        let viewModel = AppViewModel(recorder: FileReplayRecorder(clipURL: clip), recordingsFolderOverride: folder)
        viewModel.settingsPersistenceSuspended = true
        #expect(viewModel.quickRecorder == nil)
        viewModel.hideQuickRecorder() // no-op without a controller
        #expect(viewModel.quickRecorder == nil)
    }
}
