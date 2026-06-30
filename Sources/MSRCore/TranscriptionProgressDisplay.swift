import Foundation

public enum TranscriptionProgressDisplay {
    public static func message(provider: AIProvider, tick: Int) -> String {
        let dotCount = max(0, tick % 4)
        return "Transcribing with \(provider.displayName)" + String(repeating: ".", count: dotCount)
    }

    public static func elapsedText(seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
