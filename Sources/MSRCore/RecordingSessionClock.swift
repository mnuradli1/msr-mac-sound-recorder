import Foundation

public enum RecordingPauseReason: String, Codable, Equatable, Sendable {
    case manual
    case systemSleep

    public var displayName: String {
        switch self {
        case .manual:
            return "Paused"
        case .systemSleep:
            return "Paused by sleep"
        }
    }
}

public struct RecordingSessionClock: Equatable, Sendable {
    public let startedAt: Date
    public private(set) var currentSegmentStartedAt: Date?
    public private(set) var accumulatedActiveDuration: TimeInterval
    public private(set) var pauseReason: RecordingPauseReason?

    public init(startedAt: Date) {
        self.startedAt = startedAt
        currentSegmentStartedAt = startedAt
        accumulatedActiveDuration = 0
        pauseReason = nil
    }

    public var isPaused: Bool {
        currentSegmentStartedAt == nil
    }

    public mutating func pause(at date: Date, reason: RecordingPauseReason) {
        if let currentSegmentStartedAt {
            accumulatedActiveDuration += max(0, date.timeIntervalSince(currentSegmentStartedAt))
        }
        self.currentSegmentStartedAt = nil
        pauseReason = reason
    }

    public mutating func resume(at date: Date) {
        currentSegmentStartedAt = date
        pauseReason = nil
    }

    public func activeDuration(at date: Date) -> TimeInterval {
        guard let currentSegmentStartedAt else {
            return accumulatedActiveDuration
        }
        return accumulatedActiveDuration + max(0, date.timeIntervalSince(currentSegmentStartedAt))
    }
}
