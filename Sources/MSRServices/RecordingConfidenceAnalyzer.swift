import AVFoundation
import Foundation
import MSRCore

public enum RecordingConfidenceAnalyzer {
    public static func analyze(
        audioURL: URL,
        source: AudioSource,
        expectedChannels: [AudioSignalChannel: Float] = [:],
        minimumDuration: TimeInterval = 3,
        silenceThreshold: Float = 0.01,
        now: Date = Date()
    ) async throws -> RecordingConfidenceReport {
        let stats = try audioStats(for: audioURL)
        var issues: [RecordingConfidenceIssue] = []

        if stats.durationSeconds <= 0 {
            issues.append(
                RecordingConfidenceIssue(
                    kind: .emptyAudio,
                    severity: .error,
                    message: "Audio has no readable duration."
                )
            )
        }

        if stats.durationSeconds > 0, stats.durationSeconds < minimumDuration {
            issues.append(
                RecordingConfidenceIssue(
                    kind: .tooShort,
                    severity: .warning,
                    message: "Recording is very short (\(durationText(stats.durationSeconds)))."
                )
            )
        }

        if stats.peakLevel < silenceThreshold || stats.averageLevel < silenceThreshold {
            issues.append(
                RecordingConfidenceIssue(
                    kind: .silentAudio,
                    severity: .warning,
                    message: "Audio level is nearly silent."
                )
            )
        }

        for channel in expectedChannelsToCheck(for: source) {
            let peak = expectedChannels[channel] ?? 0
            if peak < silenceThreshold {
                issues.append(
                    RecordingConfidenceIssue(
                        kind: .missingExpectedSource,
                        severity: .warning,
                        message: "\(displayName(for: channel)) signal was not detected."
                    )
                )
            }
        }

        return RecordingConfidenceReport(
            checkedAt: now,
            durationSeconds: stats.durationSeconds,
            peakLevel: stats.peakLevel,
            averageLevel: stats.averageLevel,
            issues: issues
        )
    }

    private static func audioStats(for url: URL) throws -> (durationSeconds: TimeInterval, peakLevel: Float, averageLevel: Float) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let duration = format.sampleRate > 0 ? Double(file.length) / format.sampleRate : 0
        let frameCapacity = AVAudioFrameCount(min(4_096, max(1, file.length)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return (duration, 0, 0)
        }

        var peak: Float = 0
        var sumSquares = 0.0
        var sampleCount = 0

        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }

            if let channels = buffer.floatChannelData {
                let channelCount = Int(format.channelCount)
                for channelIndex in 0..<channelCount {
                    let samples = UnsafeBufferPointer(start: channels[channelIndex], count: frames)
                    for sample in samples {
                        let clamped = min(1, max(-1, sample))
                        peak = max(peak, abs(clamped))
                        sumSquares += Double(clamped * clamped)
                        sampleCount += 1
                    }
                }
            }
        }

        let average = sampleCount == 0 ? 0 : Float(min(1, sqrt(sumSquares / Double(sampleCount))))
        return (duration, peak, average)
    }

    private static func expectedChannelsToCheck(for source: AudioSource) -> [AudioSignalChannel] {
        switch source {
        case .microphone:
            return [.microphone]
        case .system:
            return [.system]
        case .micAndSystem:
            return [.microphone, .system]
        }
    }

    private static func displayName(for channel: AudioSignalChannel) -> String {
        switch channel {
        case .microphone:
            return "Mic"
        case .system:
            return "System"
        }
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(format: "%.1fs", seconds)
        }
        return "\(Int(seconds.rounded()))s"
    }
}
