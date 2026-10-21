import Foundation
import MSRCore
import MSRServices

/// What one library refresh read from disk: the recordings, their sidebar
/// facts, the transcription jobs, and the folder listing taken before the load.
struct LibraryLoadResult: Sendable {
    /// The folder as listed just before the load (`nil` when it could not be listed).
    var folderSnapshot: LibraryFolderSnapshot?
    var recordings: Result<[RecordingItem], any Error>
    var rowFacts: [UUID: RecordingRowFacts]
    var jobs: Result<[TranscriptionJob], any Error>
}

/// Runs `AppViewModel`'s library filesystem work (full loads, publishing a
/// capture, imports, folder listings) off the main actor. Being an actor, its
/// own jobs never overlap; `LibraryIO` additionally serializes them against
/// library operations the main actor still performs itself.
actor LibraryLoader {
    /// A full refresh, off the main actor.
    func load(
        library: any RecordingLibraryServing,
        jobsFolder: URL,
        folderSnapshot: LibraryFolderSnapshot?,
        beforeLoad: (@Sendable () -> Void)? = nil
    ) -> LibraryLoadResult {
        beforeLoad?()
        return Self.performLoad(library: library, jobsFolder: jobsFolder, folderSnapshot: folderSnapshot)
    }

    /// Runs `body` off the main actor, after any earlier loader work.
    func run<T: Sendable>(_ body: @Sendable () throws -> T) rethrows -> T {
        try body()
    }

    /// The load itself: also called synchronously on the main actor by
    /// `AppViewModel.loadRecordings()` where an action needs the result at once.
    nonisolated static func performLoad(
        library: any RecordingLibraryServing,
        jobsFolder: URL,
        folderSnapshot: LibraryFolderSnapshot?
    ) -> LibraryLoadResult {
        // Taken before the load: a change landing in between is loaded now
        // and, because the snapshot predates it, also reloaded once more.
        let before = folderSnapshot ?? LibraryFolderSnapshot.capture(folderURL: library.folderURL)
        let loaded: [RecordingItem]
        do {
            loaded = try library.loadRecordings()
        } catch {
            return LibraryLoadResult(folderSnapshot: before, recordings: .failure(error), rowFacts: [:], jobs: .success([]))
        }
        // Journal replay during the load can move sidecars; list again then.
        let listing = before.flatMap { hasPendingJournal($0) ? nil : $0 }
            ?? LibraryFolderSnapshot.capture(folderURL: library.folderURL)
        let facts = Dictionary(
            loaded.map { ($0.id, Self.rowFacts(for: $0, listing: listing)) },
            uniquingKeysWith: { first, _ in first }
        )
        let jobs = Result { try TranscriptionJobStore(folderURL: jobsFolder).loadAll() }
        return LibraryLoadResult(folderSnapshot: before, recordings: .success(loaded), rowFacts: facts, jobs: jobs)
    }

    /// Sidebar facts for one recording: from `listing` when given, else from disk.
    nonisolated static func rowFacts(for recording: RecordingItem, listing: LibraryFolderSnapshot?) -> RecordingRowFacts {
        let hasTranscript: Bool
        let hasSummary: Bool
        if let listing, recording.transcriptURL.deletingLastPathComponent().path == recording.folderURL.path {
            hasTranscript = listing.contains(recording.transcriptURL.lastPathComponent)
            hasSummary = listing.contains(recording.summaryURL.lastPathComponent)
        } else {
            hasTranscript = FileManager.default.fileExists(atPath: recording.transcriptURL.path)
            hasSummary = FileManager.default.fileExists(atPath: recording.summaryURL.path)
        }
        return RecordingRowFacts(recording: recording, hasTranscript: hasTranscript, hasSummary: hasSummary)
    }

    private nonisolated static func hasPendingJournal(_ snapshot: LibraryFolderSnapshot) -> Bool {
        snapshot.entries.keys.contains { name in
            (name.hasPrefix(".delete-") || name.hasPrefix(".migrate-") || name.hasPrefix(".publish-")) && name.hasSuffix(".json")
        }
    }
}
