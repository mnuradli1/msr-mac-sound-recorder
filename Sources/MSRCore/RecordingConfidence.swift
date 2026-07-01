import Foundation

public enum RecordingConfidenceIssueKind: String, Codable, Equatable, Sendable {
    case tooShort
    case silentAudio
    case missingExpectedSource
    case emptyAudio
}

public enum RecordingConfidenceSeverity: String, Codable, Equatable, Sendable {
    case info
    case warning
    case error
}

public struct RecordingConfidenceIssue: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(kind.rawValue)-\(message)" }
    public var kind: RecordingConfidenceIssueKind
    public var severity: RecordingConfidenceSeverity
    public var message: String

    public init(kind: RecordingConfidenceIssueKind, severity: RecordingConfidenceSeverity, message: String) {
        self.kind = kind
        self.severity = severity
        self.message = message
    }
}

public struct RecordingConfidenceReport: Codable, Equatable, Sendable {
    public var checkedAt: Date
    public var durationSeconds: TimeInterval
    public var peakLevel: Float
    public var averageLevel: Float
    public var issues: [RecordingConfidenceIssue]

    public var hasWarnings: Bool {
        issues.contains { $0.severity == .warning || $0.severity == .error }
    }

    public init(
        checkedAt: Date,
        durationSeconds: TimeInterval,
        peakLevel: Float,
        averageLevel: Float,
        issues: [RecordingConfidenceIssue]
    ) {
        self.checkedAt = checkedAt
        self.durationSeconds = durationSeconds
        self.peakLevel = peakLevel
        self.averageLevel = averageLevel
        self.issues = issues
    }
}
