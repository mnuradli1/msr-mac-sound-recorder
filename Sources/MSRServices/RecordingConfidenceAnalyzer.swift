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
        try await analyzeWithWaveform(
            audioURL: audioURL,
            source: source,
            expectedChannels: expectedChannels,
            minimumDuration: minimumDuration,
            silenceThreshold: silenceThreshold,
            waveformBuckets: 0,
            now: now
        ).report
    }

    /// `analyze` plus the review waveform (`waveformBuckets` peaks, as
    /// `WaveformAnalyzer` computes them) from the same decode, so a finished
    /// recording's waveform cache costs no second pass.
    public static func analyzeWithWaveform(
        audioURL: URL,
        source: AudioSource,
        expectedChannels: [AudioSignalChannel: Float] = [:],
        minimumDuration: TimeInterval = 3,
        silenceThreshold: Float = 0.01,
        waveformBuckets: Int = WaveformAnalyzer.defaultBucketCount,
        now: Date = Date()
    ) async throws -> (report: RecordingConfidenceReport, waveform: [Float]) {
        let stats = try await audioStats(for: audioURL, waveformBuckets: waveformBuckets)
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

        let report = RecordingConfidenceReport(
            checkedAt: now,
            durationSeconds: stats.durationSeconds,
            peakLevel: stats.peakLevel,
            averageLevel: stats.averageLevel,
            issues: issues
        )
        return (report, stats.waveform)
    }

    /// Duration, peak and RMS of `url` (clipped to [-1, 1], all channels),
    /// plus `waveformBuckets` review-waveform peaks from the same decode.
    private static func audioStats(
        for url: URL,
        waveformBuckets: Int
    ) async throws -> (durationSeconds: TimeInterval, peakLevel: Float, averageLevel: Float, waveform: [Float]) {
        let levels = try await AudioLevelScanner.scan(url: url, bucketCount: waveformBuckets)
        return (levels.durationSeconds, levels.peak, levels.rms, levels.buckets)
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
