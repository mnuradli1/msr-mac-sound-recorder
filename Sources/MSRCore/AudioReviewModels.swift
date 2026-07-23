import Foundation

public struct AudioTrimRange: Codable, Equatable, Sendable {
    public var startSeconds: TimeInterval
    public var endSeconds: TimeInterval

    public init(startSeconds: TimeInterval, endSeconds: TimeInterval) {
        self.startSeconds = max(0, startSeconds)
        self.endSeconds = max(self.startSeconds, endSeconds)
    }

    public var duration: TimeInterval { max(0, endSeconds - startSeconds) }

    public func normalized(for duration: TimeInterval) -> AudioTrimRange {
        AudioTrimRange(
            startSeconds: min(max(0, startSeconds), max(0, duration)),
            endSeconds: min(max(startSeconds, endSeconds), max(0, duration))
        )
    }
}

public struct AudioUploadEstimate: Equatable, Sendable {
    public var durationSeconds: TimeInterval
    public var originalBytes: Int64
    public var uploadBytes: Int64
    public var willCompress: Bool

    public init(durationSeconds: TimeInterval, originalBytes: Int64, uploadBytes: Int64, willCompress: Bool) {
        self.durationSeconds = durationSeconds
        self.originalBytes = originalBytes
        self.uploadBytes = uploadBytes
        self.willCompress = willCompress
    }
}

public enum AudioUploadEstimator {
    public static func estimate(
        audioURL: URL,
        durationSeconds: TimeInterval,
        trimRange: AudioTrimRange? = nil,
        compressionEnabled: Bool
    ) -> AudioUploadEstimate {
        let values = try? audioURL.resourceValues(forKeys: [.fileSizeKey])
        let originalBytes = Int64(values?.fileSize ?? 0)
        let selectedDuration = trimRange?.normalized(for: durationSeconds).duration ?? durationSeconds
        let extensionName = audioURL.pathExtension.lowercased()
        let willCompress = compressionEnabled && !["m4a", "mp3"].contains(extensionName)
        let proportionalOriginal = durationSeconds > 0
            ? Int64(Double(originalBytes) * max(0, selectedDuration) / durationSeconds)
            : originalBytes
        let compressed = Int64(max(0, selectedDuration) * 96_000 / 8)
        return AudioUploadEstimate(
            durationSeconds: selectedDuration,
            originalBytes: originalBytes,
            uploadBytes: willCompress ? compressed : proportionalOriginal,
            willCompress: willCompress
        )
    }
}
