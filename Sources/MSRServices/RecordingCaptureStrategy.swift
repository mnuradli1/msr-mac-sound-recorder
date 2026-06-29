import Foundation
import MSRCore

public enum RecordingCaptureStrategy: Equatable, Sendable {
    case microphoneOnly
    case systemOnly
    case separateMicAndSystemMixdown

    public static func strategy(for source: AudioSource) -> RecordingCaptureStrategy {
        switch source {
        case .microphone:
            return .microphoneOnly
        case .system:
            return .systemOnly
        case .micAndSystem:
            return .separateMicAndSystemMixdown
        }
    }
}
