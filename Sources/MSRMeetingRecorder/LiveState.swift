import Combine
import Foundation
import MSRServices

/// High-frequency recording state (meter levels, elapsed time), kept out of
/// `AppViewModel` so a meter or timer tick only re-renders the views that draw
/// it (`RecordingBar`'s meters and timer, the mini recording indicator), not
/// the whole window. Owned and updated by `AppViewModel`.
@MainActor
final class RecordingLiveState: ObservableObject {
    @Published var microphoneLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var recordingElapsed: TimeInterval = 0

    /// Writes only real changes: an unchanged value never invalidates a view.
    func setLevel(_ level: Float, for channel: AudioSignalChannel) {
        switch channel {
        case .microphone:
            if microphoneLevel != level { microphoneLevel = level }
        case .system:
            if systemLevel != level { systemLevel = level }
        }
    }

    func setElapsed(_ elapsed: TimeInterval) {
        if recordingElapsed != elapsed { recordingElapsed = elapsed }
    }

    func resetLevels() {
        setLevel(0, for: .microphone)
        setLevel(0, for: .system)
    }
}

/// Playback and review state that changes while audio plays or a trim slider
/// is dragged (4 Hz position updates), observed only by the Review tab's
/// playback strip, waveform and trim group and the Play/Pause menu command.
/// Owned and updated by `AppViewModel`.
@MainActor
final class PlaybackState: ObservableObject {
    @Published var isPlaying = false
    @Published var playbackPosition: TimeInterval = 0
    @Published var playbackDuration: TimeInterval = 0
    @Published var reviewWaveform: [Float] = []
    @Published var trimStartSeconds: TimeInterval = 0
    @Published var trimEndSeconds: TimeInterval = 0
}
