import Darwin
import Foundation
import Testing
@testable import MSRCore
@testable import MSRServices

/// Races and stale-state cases found in review of the performance work:
/// durable writes, own-write snapshot patching, the metadata index, the
/// search index and the waveform cache.

// MARK: - Durable writes never remove the primary file

@Suite("Durable write atomicity")
struct DurableWriteAtomicityTests {
    @Test func theBackupIsThePreviousVersionAndThePrimaryIsReplacedInPlace() throws {
        let folder = try HardeningTestFolder()
        let url = folder.url.appendingPathComponent("note.txt")
        try DurableFile.write(Data("one".utf8), to: url)
        #expect(!FileManager.default.fileExists(atPath: DurableFile.backupURL(for: url).path))
        let firstInode = try #require(FileStamp(path: url.path)).inode
        try DurableFile.write(Data("two".utf8), to: url)
        try DurableFile.write(Data("three".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "three")
        #expect(try String(contentsOf: DurableFile.backupURL(for: url), encoding: .utf8) == "two")
        let primary = try #require(FileStamp(path: url.path))
        let backup = try #require(FileStamp(path: DurableFile.backupURL(for: url).path))
        #expect(primary.inode != backup.inode)
        #expect(primary.inode != firstInode)
        // No temporary file is left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(Set(names) == ["note.txt", "note.txt.bak"])
    }

    @Test func aReaderWithoutTheLockNeverSeesTheFileMissing() async throws {
        let folder = try HardeningTestFolder()
        let url = folder.url.appendingPathComponent("race.txt")
        try DurableFile.write(Data("0".utf8), to: url)
        let rounds = 400
        let state = RaceState()
        async let writes: Void = Task.detached {
            for value in 1...rounds { try? DurableFile.write(Data("\(value)".utf8), to: url) }
            state.finish()
        }.value
        async let reads: Void = Task.detached {
            // Plain reads, as the main thread and the search indexer make them.
            while !state.isFinished {
                let missing = access(url.path, F_OK) != 0
                let empty = (try? Data(contentsOf: url))?.isEmpty ?? true
                state.recordRead(missing: missing || empty)
            }
        }.value
        _ = await (writes, reads)
        #expect(state.misses == 0, "the primary file was missing or empty \(state.misses) times in \(state.reads) reads")
        #expect(state.reads > 0)
        #expect(try String(contentsOf: url, encoding: .utf8) == "\(rounds)")
        #expect(try String(contentsOf: DurableFile.backupURL(for: url), encoding: .utf8) == "\(rounds - 1)")
    }
}

private final class RaceState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var readCount = 0
    private var missCount = 0

    var isFinished: Bool { lock.withLock { finished } }
    var reads: Int { lock.withLock { readCount } }
    var misses: Int { lock.withLock { missCount } }

    func finish() { lock.withLock { finished = true } }

    func recordRead(missing: Bool) {
        lock.withLock {
            readCount += 1
            if missing { missCount += 1 }
        }
    }
}

// MARK: - Own-write snapshot patching

@Suite("Own-write snapshot patching")
struct OwnWriteSnapshotTests {
    @Test func anOutsideRewriteStaysVisibleAfterAnOwnWriteOfAnotherFile() throws {
        let folder = try HardeningTestFolder()
        let transcript = folder.url.appendingPathComponent("recording-a.transcript.txt")
        let summary = folder.url.appendingPathComponent("recording-a.summary.md")
        try DurableFile.write(Data("transcript".utf8), to: transcript)
        try DurableFile.write(Data("summary".utf8), to: summary)
        _ = OwnFileWrites.take([transcript, summary])
        var kept = try #require(LibraryFolderSnapshot.capture(folderURL: folder.url))

        // The app's own summary write, patched in from what the write recorded: equal.
        try DurableFile.write(Data("summary, edited".utf8), to: summary)
        patch(&kept, with: [summary])
        #expect(kept == LibraryFolderSnapshot.capture(folderURL: folder.url))

        // Someone else rewrites the transcript, then the app writes the summary again.
        try Data("rewritten outside".utf8).write(to: transcript)
        try DurableFile.write(Data("summary, edited again".utf8), to: summary)
        patch(&kept, with: [summary])
        #expect(kept != LibraryFolderSnapshot.capture(folderURL: folder.url))
    }

    @Test func anOutsideChangeAfterTheOwnWriteIsNotAbsorbed() throws {
        let folder = try HardeningTestFolder()
        let summary = folder.url.appendingPathComponent("recording-a.summary.md")
        try DurableFile.write(Data("v1".utf8), to: summary)
        var kept = try #require(LibraryFolderSnapshot.capture(folderURL: folder.url))
        try DurableFile.write(Data("v2".utf8), to: summary)
        // Rewritten outside after the app's write but before it patched its snapshot.
        try Data("outside".utf8).write(to: summary)
        patch(&kept, with: [summary])
        #expect(kept != LibraryFolderSnapshot.capture(folderURL: folder.url))
    }

    @Test func aReplacementWithTheSameSizeAndDateIsDetected() throws {
        let folder = try HardeningTestFolder()
        let file = folder.url.appendingPathComponent("recording-a.transcript.txt")
        try Data("aaaa".utf8).write(to: file)
        let date = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        let kept = try #require(LibraryFolderSnapshot.capture(folderURL: folder.url))
        // Replaced by rename (new inode) with the same size, date restored.
        let temporary = folder.url.appendingPathComponent(".replacement.tmp")
        try Data("bbbb".utf8).write(to: temporary)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: temporary.path)
        #expect(rename(temporary.path, file.path) == 0)
        let replaced = try #require(LibraryFolderSnapshot.capture(folderURL: folder.url))
        #expect(replaced.entries[file.lastPathComponent]?.size == kept.entries[file.lastPathComponent]?.size)
        #expect(replaced.entries[file.lastPathComponent]?.modifiedSeconds == kept.entries[file.lastPathComponent]?.modifiedSeconds)
        #expect(replaced != kept)
    }

    @Test func clearingASummaryRecordsTheRemovals() throws {
        let folder = try HardeningTestFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let item = try capture(in: library, folder: folder, name: "Clear", at: 10)
        _ = try library.writeSummary("one", for: item)
        _ = try library.writeSummary("two", for: item)
        var kept = try #require(LibraryFolderSnapshot.capture(folderURL: folder.url))
        _ = try library.clearSummary(for: item)
        patch(&kept, with: [item.summaryURL])
        #expect(!kept.contains(item.summaryURL.lastPathComponent))
        #expect(kept == LibraryFolderSnapshot.capture(folderURL: folder.url))
    }

    /// What `AppViewModel.noteOwnLibraryWrites` does: each file and its backup.
    private func patch(_ snapshot: inout LibraryFolderSnapshot, with urls: [URL]) {
        let files = urls.flatMap { [$0, DurableFile.backupURL(for: $0)] }
        for (url, status) in zip(files, OwnFileWrites.take(files)) {
            if let status { snapshot.patch(url.lastPathComponent, with: status) }
        }
    }
}

// MARK: - Metadata index and stale caller copies

@Suite("Metadata index with stale caller copies")
struct MetadataIndexStaleCopyTests {
    @Test func aSidecarWriteWithAStaleCopyKeepsTheRenamedTitle() throws {
        let folder = try HardeningTestFolder()
        let renamer = RecordingLibrary(folderURL: folder.url)
        let stale = try capture(in: renamer, folder: folder, name: "Alpha", at: 10)
        let other = try capture(in: renamer, folder: folder, name: "Other", at: 20)
        _ = try renamer.loadRecordings()
        #expect(try renamer.rename(stale, to: "Beta").displayName == "Beta")

        // Another instance writes sidecars with the copy taken before the rename.
        let writer = RecordingLibrary(folderURL: folder.url)
        _ = try writer.writeTranscript("Hello", for: stale)
        _ = try writer.writeSummary("Notes", for: stale)
        _ = try writer.clearSummary(for: stale)

        let indexed = MetadataIndex.stored(for: writer.folderURL)?.recordings.first { $0.id == stale.id }
        #expect(indexed == nil || indexed?.displayName == "Beta")
        // The uniqueness check sees the new title.
        #expect(try writer.rename(other, to: "Beta").displayName == "Beta 2")

        // A stale copy passed to a migration (a no-op here) is not stored either.
        _ = try writer.migrateIfNeeded(stale)
        let afterMigration = MetadataIndex.stored(for: writer.folderURL)?.recordings.first { $0.id == stale.id }
        #expect(afterMigration == nil || afterMigration?.displayName == "Beta")
    }

    @Test func aSidecarWriteRereadsMetadataChangedOutside() throws {
        let folder = try HardeningTestFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let item = try capture(in: library, folder: folder, name: "Gamma", at: 10)
        let other = try capture(in: library, folder: folder, name: "Other", at: 20)
        _ = try library.loadRecordings()
        // An outside in-place edit of the metadata file, then a sidecar write.
        let json = try String(contentsOf: item.metadataURL, encoding: .utf8)
            .replacingOccurrences(of: "\"Gamma\"", with: "\"Delta\"")
        let handle = try FileHandle(forWritingTo: item.metadataURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(json.utf8))
        try handle.close()
        _ = try library.writeTranscript("Text", for: item)
        #expect(try library.rename(other, to: "Delta").displayName == "Delta 2")
    }
}

// MARK: - Search index versions

@Suite("Search index versions", .serialized)
struct SearchIndexVersionTests {
    @Test func aRefreshRacingASlowReadKeepsTheNewerSketch() async throws {
        let folder = try HardeningTestFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let item = try capture(in: library, folder: folder, name: "Doc", at: 10)
        _ = try library.writeTranscript("alpha words", for: item)
        let gate = ReadGate()
        let indexer = RecordingSearchIndexer(timeZone: { .current }, afterRead: { _ in gate.blockFirstCall() })
        await indexer.update([item])

        // A query reads the old text and stalls before applying it.
        let slow = Task { await indexer.search("alpha") { _ in } }
        while !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        // Meanwhile the app writes new text and refreshes the document.
        _ = try library.writeTranscript("bravo words", for: item)
        await indexer.refresh(item)
        gate.release()
        await slow.value

        #expect(await matches(indexer, "bravo") == [item.id])
        #expect(await matches(indexer, "alpha").isEmpty)
    }

    @Test func aCancelledSearchStoresNothing() async throws {
        let folder = try HardeningTestFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let item = try capture(in: library, folder: folder, name: "Doc", at: 10)
        _ = try library.writeTranscript("alpha words", for: item)
        let gate = ReadGate()
        let indexer = RecordingSearchIndexer(timeZone: { .current }, afterRead: { _ in gate.blockFirstCall() })
        await indexer.update([item])

        let cancelled = Task { await indexer.search("alpha") { _ in } }
        while !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        cancelled.cancel()
        gate.release()
        await cancelled.value
        #expect(await indexer.statistics.indexedDocuments == 0)
        #expect(await !indexer.isCached(item.id))
    }

    @Test func dateTextFollowsTheCurrentTimeZone() async throws {
        let folder = try HardeningTestFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        // 2023-11-14 22:13 UTC is 2023-11-15 07:13 in Tokyo.
        let item = try capture(in: library, folder: folder, name: "Zoned", at: 1_700_000_000)
        let zone = ZoneBox(TimeZone(identifier: "UTC")!)
        let indexer = RecordingSearchIndexer(timeZone: { zone.value }, afterRead: nil)
        await indexer.update([item])
        #expect(await matches(indexer, "2023-11-14") == [item.id])

        zone.value = TimeZone(identifier: "Asia/Tokyo")!
        #expect(await matches(indexer, "2023-11-15") == [item.id])
        #expect(await matches(indexer, "2023-11-14").isEmpty)
    }

    private func matches(_ indexer: RecordingSearchIndexer, _ query: String) async -> [UUID] {
        let collected = ProgressBox()
        await indexer.search(query) { collected.last = $0 }
        return collected.last?.matches ?? []
    }
}

/// Blocks the first caller of `blockFirstCall()` until `release()`.
private final class ReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var calls = 0
    private var didEnter = false

    var entered: Bool { lock.withLock { didEnter } }

    func blockFirstCall() {
        let first = lock.withLock { () -> Bool in
            calls += 1
            if calls == 1 { didEnter = true }
            return calls == 1
        }
        if first { semaphore.wait() }
    }

    func release() { semaphore.signal() }
}

private final class ZoneBox: @unchecked Sendable {
    private let lock = NSLock()
    private var zone: TimeZone

    init(_ zone: TimeZone) { self.zone = zone }

    var value: TimeZone {
        get { lock.withLock { zone } }
        set { lock.withLock { zone = newValue } }
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: RecordingSearchIndexer.Progress?

    var last: RecordingSearchIndexer.Progress? {
        get { lock.withLock { progress } }
        set { lock.withLock { progress = newValue } }
    }
}

// MARK: - Waveform cache stamp

@Suite("Waveform cache audio stamp")
struct WaveformStampTests {
    @Test func aCacheIsNotStoredForAudioReplacedDuringTheScan() throws {
        let folder = try HardeningTestFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let item = try capture(in: library, folder: folder, name: "Wave", at: 10)
        let samples = [Float](repeating: 0.5, count: 96)
        let scanned = try #require(WaveformCacheFile.AudioStamp(audioURL: item.audioURL))

        // Replaced while being scanned: same size and date, another file.
        let date = try #require(try FileManager.default.attributesOfItem(atPath: item.audioURL.path)[.modificationDate] as? Date)
        let temporary = folder.url.appendingPathComponent(".replacement.tmp")
        try Data("AUDIO".utf8).write(to: temporary)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: temporary.path)
        #expect(rename(temporary.path, item.audioURL.path) == 0)

        #expect(try library.storeWaveformCache(samples, for: item, scannedAudio: scanned) == false)
        #expect(!FileManager.default.fileExists(atPath: item.waveformURL.path))
        // A cache written before the replacement is stale too (inode and ctime are stamped).
        let current = try #require(WaveformCacheFile.AudioStamp(audioURL: item.audioURL))
        #expect(current.size == scanned.size && current.modifiedSeconds == scanned.modifiedSeconds)
        #expect(WaveformCacheFile.decode(WaveformCacheFile.encode(samples, audio: scanned), bucketCount: 96, audio: current) == nil)

        #expect(try library.storeWaveformCache(samples, for: item, scannedAudio: current) == true)
        #expect(library.loadWaveformCache(for: item, bucketCount: 96)?.count == 96)
    }
}

// MARK: - Helpers

private func capture(in library: RecordingLibrary, folder: HardeningTestFolder, name: String, at seconds: TimeInterval) throws -> RecordingItem {
    let source = folder.url.appendingPathComponent("capture-\(UUID().uuidString).m4a")
    try Data("audio".utf8).write(to: source)
    return try library.finishRecording(
        temporaryAudioURL: source, requestedName: name, source: .microphone,
        startedAt: Date(timeIntervalSince1970: seconds), endedAt: Date(timeIntervalSince1970: seconds + 10)
    )
}
