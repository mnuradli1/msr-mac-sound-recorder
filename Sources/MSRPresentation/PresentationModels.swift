import Combine
import Foundation
import MSRCore

@MainActor
public final class RecordingSessionPresentationModel: ObservableObject {
    @Published public var selectedSource: AudioSource
    @Published public var workflowState: RecordingWorkflowState = .ready
    @Published public var inputLevel: Float = 0
    @Published public var microphoneLevel: Float = 0
    @Published public var systemLevel: Float = 0
    @Published public var waveform = WaveformBuffer(capacity: 36)
    @Published public var elapsed: TimeInterval = 0

    public init(selectedSource: AudioSource) { self.selectedSource = selectedSource }
}

@MainActor
public final class LibraryPresentationModel: ObservableObject {
    @Published public var recordings: [RecordingItem] = []
    @Published public var selectedRecording: RecordingItem?
    @Published public var searchQuery = ""
    @Published public var renameDraft = ""
    @Published public var showingRename = false
    public init() {}
}

@MainActor
public final class PlaybackPresentationModel: ObservableObject {
    @Published public var isPlaying = false
    @Published public var position: TimeInterval = 0
    @Published public var duration: TimeInterval = 0
    @Published public var waveform: [Float] = []
    @Published public var trimStart: TimeInterval = 0
    @Published public var trimEnd: TimeInterval = 0
    public init() {}
}

@MainActor
public final class QueuePresentationModel: ObservableObject {
    @Published public var jobs: [TranscriptionJob] = []
    @Published public var selectedJob: TranscriptionJob?
    @Published public var startedAt: Date?
    public init() {}
}

@MainActor
public final class NotesExportPresentationModel: ObservableObject {
    @Published public var transcript = ""
    @Published public var summary = ""
    @Published public var segments: [TranscriptSegment] = []
    @Published public var exportFormat: TranscriptExportFormat = .markdown
    @Published public var exportPreview = ""
    @Published public var saveMessage = ""
    @Published public var lastExportURL: URL?
    public init() {}
}

@MainActor
public final class SettingsPresentationModel: ObservableObject {
    @Published public var settings: AppSettings
    public init(settings: AppSettings) { self.settings = settings }
}

@MainActor
public final class PresentationCoordinator {
    public let recordingSession: RecordingSessionPresentationModel
    public let library = LibraryPresentationModel()
    public let playback = PlaybackPresentationModel()
    public let queue = QueuePresentationModel()
    public let notes = NotesExportPresentationModel()
    public let settings: SettingsPresentationModel

    public init(settings: AppSettings) {
        self.settings = SettingsPresentationModel(settings: settings)
        recordingSession = RecordingSessionPresentationModel(selectedSource: settings.preferredSource)
    }

    public var children: [any ObservableObject] {
        [recordingSession, library, playback, queue, notes, settings]
    }
}
