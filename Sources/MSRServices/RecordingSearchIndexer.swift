import Compression
import Darwin
import Foundation
import MSRCore

/// The library's full-text search index, off the main actor.
///
/// Per recording it keeps, always resident:
/// - the folded metadata text (name, source, dates, duration; about 200 B),
///   so name/date/source queries never touch the disk;
/// - once its transcript and summary were read, a `SearchSketch` (160 B to
///   2 KB) that rules a document out for most tokens it does not contain.
///
/// The folded transcript + summary text itself is held LZFSE-compressed in an
/// LRU cache bounded by `byteBudget` (all resident bytes: metadata, sketches
/// and cached text): indexing passes and `refresh` evict the least recently
/// used text. A query checks metadata, then sketches, then the cached text
/// (decompressed in parallel); documents whose text is not cached are read
/// from disk only when their sketch (if any) says they may match, in parallel
/// chunks, and the results stream to the caller. Text read by a query is
/// cached only while it fits without evicting (scan resistance).
public actor RecordingSearchIndexer {
    public struct Statistics: Equatable, Sendable {
        public var documents: Int
        /// Documents whose transcript/summary was read at least once (sketch present).
        public var indexedDocuments: Int
        /// Documents whose folded text is cached.
        public var residentDocuments: Int
        public var metadataBytes: Int
        public var sketchBytes: Int
        /// Compressed bytes of the cached text.
        public var contentBytes: Int
        /// Folded (uncompressed) bytes of the cached text.
        public var contentFoldedBytes: Int
        /// Documents read from disk since the indexer was made.
        public var diskReads: Int

        public var residentBytes: Int { metadataBytes + sketchBytes + contentBytes }
    }

    /// Every match found so far for one query, in library order.
    public struct Progress: Equatable, Sendable {
        public var matches: [UUID]
        public var isComplete: Bool
    }

    public static let defaultByteBudget = 7 * 1_048_576

    private struct Entry {
        var recording: RecordingItem
        var metadata: [UInt8]
        /// `nil` until the transcript and summary were read (or after the app changed them).
        var sketch: SearchSketch?
        var stamps: SidecarStamps?
        /// Bumped whenever the entry's content changes (`refresh`, a read
        /// that saw new stamps, moved files). A read started at an older
        /// version is not applied: a newer read already replaced its result.
        var version: UInt64 = 0
    }

    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var contents: [UUID: StoredContent] = [:]
    private var useClock: UInt64 = 0
    private var fixedBytes = 0
    private var contentBytes = 0
    private var diskReads = 0
    private let byteBudget: Int
    /// Date text in the zone of the last check (see `refreshDateTextIfZoneChanged`).
    private var dates: SearchDateText
    private let currentTimeZone: @Sendable () -> TimeZone
    /// Tests: called on the reading thread after each document's files were read.
    private let afterRead: (@Sendable (UUID) -> Void)?

    public init(byteBudget: Int = RecordingSearchIndexer.defaultByteBudget) {
        self.init(byteBudget: byteBudget, timeZone: { TimeZone.current }, afterRead: nil)
    }

    init(
        byteBudget: Int = RecordingSearchIndexer.defaultByteBudget,
        timeZone: @escaping @Sendable () -> TimeZone,
        afterRead: (@Sendable (UUID) -> Void)?
    ) {
        self.byteBudget = max(0, byteBudget)
        currentTimeZone = timeZone
        self.afterRead = afterRead
        dates = Self.dateText(in: timeZone())
    }

    private static func dateText(in zone: TimeZone) -> SearchDateText {
        var calendar = Calendar.current
        calendar.timeZone = zone
        return SearchDateText(calendar: calendar)
    }

    /// Date text is written in the current time zone: after the zone changed
    /// (travel, a settings change), every recording's metadata text is
    /// rebuilt once, lazily, before the next query or update uses it.
    private func refreshDateTextIfZoneChanged() {
        let zone = currentTimeZone()
        guard zone.identifier != dates.timeZone.identifier else { return }
        dates = Self.dateText(in: zone)
        for var entry in entries.values {
            entry.metadata = RecordingSearch.metadataText(for: entry.recording, dates: dates)
            setEntry(entry)
        }
    }

    /// Number of recordings whose text is cached (diagnostics and tests).
    var cachedRecordingCount: Int { contents.count }

    /// Whether `id`'s folded text is cached (tests).
    func isCached(_ id: UUID) -> Bool { contents[id] != nil }

    public var statistics: Statistics {
        Statistics(
            documents: entries.count,
            indexedDocuments: entries.values.filter { $0.sketch != nil }.count,
            residentDocuments: contents.count,
            metadataBytes: entries.values.reduce(0) { $0 + $1.metadata.count },
            sketchBytes: entries.values.reduce(0) { $0 + ($1.sketch?.byteCount ?? 0) },
            contentBytes: contentBytes,
            contentFoldedBytes: contents.values.reduce(0) { $0 + $1.length },
            diskReads: diskReads
        )
    }

    // MARK: - Keeping the index in step with the library

    /// Mirrors the library list: new recordings get their metadata text
    /// (no disk access), changed ones are re-folded, missing ones dropped. A
    /// recording whose sidecar files moved (migration) is read again later.
    public func update(_ recordings: [RecordingItem]) {
        refreshDateTextIfZoneChanged()
        var seen = Set<UUID>()
        for recording in recordings {
            seen.insert(recording.id)
            if var entry = entries[recording.id] {
                guard entry.recording != recording else { continue }
                let moved = entry.recording.transcriptURL != recording.transcriptURL
                    || entry.recording.summaryURL != recording.summaryURL
                entry.recording = recording
                entry.metadata = RecordingSearch.metadataText(for: recording, dates: dates)
                if moved {
                    entry.sketch = nil
                    entry.stamps = nil
                    entry.version += 1
                    dropContent(recording.id)
                }
                setEntry(entry)
            } else {
                setEntry(Entry(recording: recording, metadata: RecordingSearch.metadataText(for: recording, dates: dates)))
            }
        }
        for id in entries.keys where !seen.contains(id) {
            removeEntry(id)
        }
        order = recordings.map(\.id)
    }

    /// Re-reads `recording`'s transcript and summary now (the app just wrote
    /// them), adding the recording when it is new.
    public func refresh(_ recording: RecordingItem) {
        refreshDateTextIfZoneChanged()
        let entry = entries[recording.id]
        if entry == nil { order.insert(recording.id, at: 0) }
        var updated = entry ?? Entry(recording: recording, metadata: [])
        if entry?.recording != recording || updated.metadata.isEmpty {
            updated.recording = recording
            updated.metadata = RecordingSearch.metadataText(for: recording, dates: dates)
        }
        // Reads still in flight for this entry predate the app's write.
        updated.version += 1
        setEntry(updated)
        if let loaded = Self.load(request(for: updated)) {
            apply(loaded)
        }
        evictOverBudget()
    }

    private func request(
        for entry: Entry,
        knownStamps: SidecarStamps? = nil,
        skipIfUnchanged: Bool = false,
        tokens: [[UInt8]]? = nil
    ) -> LoadRequest {
        LoadRequest(
            recording: entry.recording,
            knownStamps: knownStamps,
            skipIfUnchanged: skipIfUnchanged,
            tokens: tokens,
            version: entry.version,
            afterRead: afterRead
        )
    }

    public func remove(_ id: UUID) {
        removeEntry(id)
        order.removeAll { $0 == id }
    }

    /// Reads the transcript and summary of every recording that was never
    /// read or whose files changed on disk (size or modification time), in
    /// parallel chunks; cancellable between chunks. Memory stays within the
    /// budget (the oldest cached text is evicted; sketches stay).
    public func indexContent() async {
        let targets = order.compactMap { entries[$0] }.map {
            request(for: $0, knownStamps: $0.sketch == nil ? nil : $0.stamps, skipIfUnchanged: true)
        }
        for chunk in stride(from: 0, to: targets.count, by: Self.chunkSize).map({ Array(targets[$0..<min($0 + Self.chunkSize, targets.count)]) }) {
            if Task.isCancelled { return }
            // A background pass: a few workers leave the other cores (and
            // less transient scratch memory) to the app.
            let loaded = await Self.loadInParallel(chunk, maxWorkers: Self.indexingWorkers)
            if Task.isCancelled { return }
            for item in loaded.compactMap({ $0 }) { apply(item) }
            evictOverBudget()
        }
    }

    // MARK: - Searching

    /// Finds the recordings whose name, source, date, duration, transcript or
    /// summary contain every token of `query` (case- and diacritic-insensitive).
    ///
    /// `deliver` receives the matches found so far, in library order: first
    /// those decided from memory (metadata, sketches, cached text), then after
    /// each chunk of documents read from disk; the last call has
    /// `isComplete`. A blank query delivers every recording. Cancelling the
    /// calling task stops between chunks without a final delivery.
    public func search(_ query: String, deliver: @Sendable (Progress) -> Void) async {
        refreshDateTextIfZoneChanged()
        let parsed = RecordingSearchQuery(query)
        guard !parsed.isEmpty else {
            deliver(Progress(matches: order, isComplete: true))
            return
        }
        var matched = Set<UUID>()
        var resident: [VerifyItem] = []
        var pending: [LoadRequest] = []
        useClock += 1
        for id in order {
            guard let entry = entries[id] else { continue }
            let missing = parsed.missingTokens(in: entry.metadata)
            if missing.isEmpty {
                matched.insert(id)
                continue
            }
            if let sketch = entry.sketch {
                guard sketch.mayContainAll(missing) else { continue }
                if var stored = contents[id] {
                    stored.lastUse = useClock
                    contents[id] = stored
                    resident.append(VerifyItem(id: id, content: stored, tokens: missing))
                    continue
                }
            }
            pending.append(request(for: entry, knownStamps: entry.sketch == nil ? nil : entry.stamps, tokens: missing))
        }
        matched.formUnion(await Self.verifyInParallel(resident))
        if Task.isCancelled { return }
        deliver(Progress(matches: inLibraryOrder(matched), isComplete: pending.isEmpty))

        // Scan resistance: text read for a query is cached only while it fits
        // without evicting anything, so one full scan does not flush the cache
        // (and an uncached read skips compression). Sketches are always kept.
        var start = 0
        while start < pending.count {
            if Task.isCancelled { return }
            let chunk = pending[start..<min(start + Self.chunkSize, pending.count)]
            start += Self.chunkSize
            // Compress only when an average document still fits.
            let averageText = contents.isEmpty ? 0 : contentBytes / contents.count
            let cacheable = fixedBytes + contentBytes + averageText < byteBudget
            let loaded = await Self.loadInParallel(Array(chunk), compress: cacheable)
            // A cancelled query stores nothing (a newer one, or a refresh, may own the entries now).
            if Task.isCancelled { return }
            for item in loaded.compactMap({ $0 }) {
                let fits = cacheable && fixedBytes + contentBytes + item.content.bytes.count + Self.sketchGrowth(item, entries[item.id]) <= byteBudget
                apply(item, cache: fits)
                if item.matched == true { matched.insert(item.id) }
            }
            evictOverBudget()
            if Task.isCancelled { return }
            deliver(Progress(matches: inLibraryOrder(matched), isComplete: start >= pending.count))
        }
    }

    /// Search documents for `recordings` with their full text (read from disk
    /// when not cached). For tests and diagnostics; the app uses `search`.
    public func documents(for recordings: [RecordingItem]) async -> [RecordingSearchDocument] {
        update(recordings)
        await indexContent()
        return recordings.compactMap { recording in
            guard let entry = entries[recording.id] else { return nil }
            let text = contents[recording.id].map(Self.decompress)
                ?? Self.load(LoadRequest(recording: recording), keepText: true)?.folded
                ?? []
            return RecordingSearchDocument(recording: recording, metadataText: entry.metadata, contentText: text)
        }
    }

    // MARK: - Bookkeeping

    private func inLibraryOrder(_ ids: Set<UUID>) -> [UUID] {
        order.filter(ids.contains)
    }

    private func setEntry(_ entry: Entry) {
        if let old = entries[entry.recording.id] {
            fixedBytes -= old.metadata.count + (old.sketch?.byteCount ?? 0)
        }
        entries[entry.recording.id] = entry
        fixedBytes += entry.metadata.count + (entry.sketch?.byteCount ?? 0)
    }

    private func removeEntry(_ id: UUID) {
        if let old = entries.removeValue(forKey: id) {
            fixedBytes -= old.metadata.count + (old.sketch?.byteCount ?? 0)
        }
        dropContent(id)
    }

    private func dropContent(_ id: UUID) {
        if let old = contents.removeValue(forKey: id) {
            contentBytes -= old.bytes.count
        }
    }

    /// Bytes `loaded`'s sketch adds over the entry's current one.
    private static func sketchGrowth(_ loaded: Loaded, _ entry: Entry?) -> Int {
        guard let sketch = loaded.sketch else { return 0 }
        return sketch.byteCount - (entry?.sketch?.byteCount ?? 0)
    }

    /// Stores what a read produced (sketch, stamps and, with `cache`, the
    /// text), unless the recording left the index, its files moved, or a
    /// newer read or refresh replaced the entry (`version`) meanwhile.
    private func apply(_ loaded: Loaded, cache: Bool = true) {
        diskReads += 1
        guard var entry = entries[loaded.id],
              entry.version == loaded.version,
              entry.recording.transcriptURL == loaded.transcriptURL,
              entry.recording.summaryURL == loaded.summaryURL else { return }
        if let sketch = loaded.sketch { entry.sketch = sketch }
        // New content: reads of the entry started before this one are stale.
        if entry.stamps != loaded.stamps { entry.version += 1 }
        entry.stamps = loaded.stamps
        setEntry(entry)
        dropContent(loaded.id)
        guard cache else { return }
        var stored = loaded.content
        useClock += 1
        stored.lastUse = useClock
        contents[loaded.id] = stored
        contentBytes += stored.bytes.count
    }

    /// Evicts the least recently used cached text until every resident byte
    /// fits the budget (metadata and sketches are never evicted).
    private func evictOverBudget() {
        guard fixedBytes + contentBytes > byteBudget else { return }
        for (id, _) in contents.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
            guard fixedBytes + contentBytes > byteBudget else { break }
            dropContent(id)
        }
    }
}

// MARK: - Work done off the actor (pure, parallel)

extension RecordingSearchIndexer {
    static let chunkSize = 256
    static let indexingWorkers = 4

    struct SidecarStamp: Equatable, Sendable {
        var size: Int64
        var seconds: Int
        var nanoseconds: Int

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            size = Int64(info.st_size)
            seconds = info.st_mtimespec.tv_sec
            nanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    struct SidecarStamps: Equatable, Sendable {
        var transcript: SidecarStamp?
        var summary: SidecarStamp?
    }

    struct StoredContent: Sendable {
        var bytes: [UInt8]
        /// Folded length; equals `bytes.count` when not compressed.
        var length: Int
        var compressed: Bool
        var lastUse: UInt64 = 0
    }

    /// One document to read: `knownStamps` are the file stamps its current
    /// sketch was built from (`nil`: no sketch yet).
    struct LoadRequest: Sendable {
        var recording: RecordingItem
        var knownStamps: SidecarStamps?
        /// Indexing passes: skip the read when the files still match `knownStamps`.
        var skipIfUnchanged = false
        /// Queries: report whether the text holds all of these.
        var tokens: [[UInt8]]?
        /// The entry's `version` when the read was requested.
        var version: UInt64 = 0
        /// Tests: called after the files were read.
        var afterRead: (@Sendable (UUID) -> Void)?
    }

    struct VerifyItem: Sendable {
        var id: UUID
        var content: StoredContent
        var tokens: [[UInt8]]
    }

    struct Loaded: Sendable {
        var id: UUID
        var version: UInt64
        var transcriptURL: URL
        var summaryURL: URL
        var stamps: SidecarStamps
        /// `nil`: the files match the request's `knownStamps`, the sketch stands.
        var sketch: SearchSketch?
        var content: StoredContent
        /// The folded text, when the request asked to keep it.
        var folded: [UInt8]?
        /// Whether the folded text holds every token passed to `load` (`nil` without tokens).
        var matched: Bool?
    }

    /// Buffers one indexing task reuses for every document it reads (file
    /// bytes, folded text, compression output and scratch), so a pass makes one
    /// lasting allocation per document (its compressed text) instead of five
    /// transient ones that fragment the heap.
    final class LoadWorkspace {
        let text = FoldBuffer(capacity: 96 * 1_024)
        private(set) var file: UnsafeMutableRawPointer
        private(set) var fileCapacity: Int
        private(set) var packed: UnsafeMutablePointer<UInt8>
        private(set) var packedCapacity: Int
        /// LZFSE encoder scratch (about 670 KB), made on first compression.
        private var encoderScratch: UnsafeMutableRawPointer?

        init() {
            fileCapacity = 64 * 1_024
            file = .allocate(byteCount: fileCapacity, alignment: 16)
            packedCapacity = 64 * 1_024
            packed = .allocate(capacity: packedCapacity)
        }

        deinit {
            file.deallocate()
            packed.deallocate()
            encoderScratch?.deallocate()
        }

        var scratch: UnsafeMutableRawPointer {
            if let encoderScratch { return encoderScratch }
            let made = UnsafeMutableRawPointer.allocate(
                byteCount: max(1, compression_encode_scratch_buffer_size(COMPRESSION_LZFSE)),
                alignment: 16
            )
            encoderScratch = made
            return made
        }

        func reserveFile(_ size: Int) {
            guard size > fileCapacity else { return }
            file.deallocate()
            fileCapacity = max(size, fileCapacity * 2)
            file = .allocate(byteCount: fileCapacity, alignment: 16)
        }

        func reservePacked(_ size: Int) {
            guard size > packedCapacity else { return }
            packed.deallocate()
            packedCapacity = max(size, packedCapacity * 2)
            packed = .allocate(capacity: packedCapacity)
        }
    }

    /// Reads and folds one recording's transcript and summary, sketches them
    /// (unless they still match `knownStamps`) and, with `compress`, packs
    /// the text for the cache. `nil` for an unchanged file pair when
    /// `skipIfUnchanged`. The stamps are taken before the reads, so a write
    /// racing a read is seen as a change by the next pass.
    ///
    /// A missing file whose `.bak` exists may be a durable write between its
    /// moves (on a file system without hard links, see `DurableFile.write`):
    /// the read is then redone under `LibraryIO`, after that write finished,
    /// instead of recording the document as empty.
    static func load(
        _ request: LoadRequest,
        compress shouldCompress: Bool = true,
        keepText: Bool = false,
        workspace: LoadWorkspace = LoadWorkspace(),
        holdingLibraryIO: Bool = false
    ) -> Loaded? {
        let recording = request.recording
        let current = SidecarStamps(
            transcript: SidecarStamp(path: recording.transcriptURL.path),
            summary: SidecarStamp(path: recording.summaryURL.path)
        )
        if !holdingLibraryIO, mayBeMidWrite(current, recording) {
            return LibraryIO.serialized {
                load(request, compress: shouldCompress, keepText: keepText, workspace: workspace, holdingLibraryIO: true)
            }
        }
        let unchanged = request.knownStamps == current
        if request.skipIfUnchanged, unchanged { return nil }
        let text = workspace.text
        text.removeAll()
        if current.transcript != nil { appendFolded(fileAtPath: recording.transcriptURL.path, to: workspace) }
        if current.summary != nil { appendFolded(fileAtPath: recording.summaryURL.path, to: workspace) }
        request.afterRead?(recording.id)
        let folded = text.bytes
        let matched = request.tokens.map { tokens in tokens.allSatisfy { SearchFolding.contains(folded, $0) } }
        return Loaded(
            id: recording.id,
            version: request.version,
            transcriptURL: recording.transcriptURL,
            summaryURL: recording.summaryURL,
            stamps: current,
            sketch: unchanged ? nil : SearchSketch(folded),
            content: shouldCompress ? compress(folded, workspace: workspace) : StoredContent(bytes: [], length: 0, compressed: false),
            folded: keepText ? Array(folded) : nil,
            matched: matched
        )
    }

    private static func mayBeMidWrite(_ stamps: SidecarStamps, _ recording: RecordingItem) -> Bool {
        func backupExists(_ url: URL) -> Bool { access(DurableFile.backupURL(for: url).path, F_OK) == 0 }
        return (stamps.transcript == nil && backupExists(recording.transcriptURL))
            || (stamps.summary == nil && backupExists(recording.summaryURL))
    }

    /// Reads the whole file (`open`/`read` into the workspace) and appends its
    /// folded text. Reads of different files do not overlap in practice:
    /// 500 × 32 KB took about 9.5 ms on one thread or ten.
    private static func appendFolded(fileAtPath path: String, to workspace: LoadWorkspace) {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0 else { return }
        let size = Int(info.st_size)
        workspace.reserveFile(size)
        var total = 0
        while total < size {
            let result = read(descriptor, workspace.file + total, size - total)
            if result <= 0 { break }
            total += result
        }
        let bytes = UnsafeBufferPointer(start: workspace.file.assumingMemoryBound(to: UInt8.self), count: total)
        workspace.text.appendFolded(utf8: bytes)
    }

    static func compress(_ folded: [UInt8]) -> StoredContent {
        folded.withUnsafeBufferPointer { compress($0, workspace: LoadWorkspace()) }
    }

    /// LZFSE into the workspace, then one exact-size copy; raw when it would
    /// not save at least 10 % (or the text is under 512 bytes).
    static func compress(_ folded: UnsafeBufferPointer<UInt8>, workspace: LoadWorkspace) -> StoredContent {
        guard folded.count >= 512, let source = folded.baseAddress else {
            return StoredContent(bytes: Array(folded), length: folded.count, compressed: false)
        }
        workspace.reservePacked(folded.count)
        let written = compression_encode_buffer(
            workspace.packed, folded.count,
            source, folded.count,
            workspace.scratch, COMPRESSION_LZFSE
        )
        guard written > 0, written < folded.count * 9 / 10 else {
            return StoredContent(bytes: Array(folded), length: folded.count, compressed: false)
        }
        return StoredContent(bytes: Array(UnsafeBufferPointer(start: workspace.packed, count: written)), length: folded.count, compressed: true)
    }

    static func decompress(_ stored: StoredContent) -> [UInt8] {
        guard stored.compressed else { return stored.bytes }
        var output = [UInt8](repeating: 0, count: stored.length)
        let written = decompress(stored, into: &output)
        return written == stored.length ? output : Array(output[0..<written])
    }

    @discardableResult
    private static func decompress(_ stored: StoredContent, into buffer: inout [UInt8]) -> Int {
        if buffer.count < stored.length { buffer = [UInt8](repeating: 0, count: stored.length) }
        return stored.bytes.withUnsafeBufferPointer { source in
            buffer.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(
                    destination.baseAddress!, stored.length,
                    source.baseAddress!, source.count,
                    nil, COMPRESSION_LZFSE
                )
            }
        }
    }

    /// Slices of `items` for `activeProcessorCount` workers, at least `minimum` per slice.
    private static func slices<T>(_ items: [T], minimum: Int) -> [[T]] {
        guard !items.isEmpty else { return [] }
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, items.count / max(1, minimum)))
        let size = (items.count + workers - 1) / workers
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    /// The IDs of the cached documents whose text holds all their tokens.
    static func verifyInParallel(_ items: [VerifyItem]) async -> Set<UUID> {
        await withTaskGroup(of: [UUID].self) { group in
            for slice in slices(items, minimum: 32) {
                group.addTask {
                    var buffer: [UInt8] = []
                    return slice.compactMap { item in
                        let matched: Bool
                        if item.content.compressed {
                            let length = decompress(item.content, into: &buffer)
                            matched = buffer.withUnsafeBufferPointer { text in
                                let prefix = UnsafeBufferPointer(rebasing: text[0..<length])
                                return item.tokens.allSatisfy { SearchFolding.contains(prefix, $0) }
                            }
                        } else {
                            matched = item.content.bytes.withUnsafeBufferPointer { text in
                                item.tokens.allSatisfy { SearchFolding.contains(text, $0) }
                            }
                        }
                        return matched ? item.id : nil
                    }
                }
            }
            var result = Set<UUID>()
            for await ids in group { result.formUnion(ids) }
            return result
        }
    }

    /// `load` for each request, in parallel, results in request order. One
    /// worker per core, each with its own `LoadWorkspace`, takes the next
    /// request from a shared counter (faster cores take more).
    static func loadInParallel(
        _ requests: [LoadRequest],
        compress: Bool = true,
        maxWorkers: Int = ProcessInfo.processInfo.activeProcessorCount
    ) async -> [Loaded?] {
        guard !requests.isEmpty else { return [] }
        let cursor = WorkCursor(count: requests.count)
        let workers = min(maxWorkers, ProcessInfo.processInfo.activeProcessorCount, (requests.count + 1) / 2)
        return await withTaskGroup(of: [(Int, Loaded?)].self) { group in
            for _ in 0..<max(1, workers) {
                group.addTask {
                    let workspace = LoadWorkspace()
                    var done: [(Int, Loaded?)] = []
                    while let index = cursor.next() {
                        done.append((index, load(requests[index], compress: compress, workspace: workspace)))
                    }
                    return done
                }
            }
            var results = [Loaded?](repeating: nil, count: requests.count)
            for await part in group {
                for (offset, loaded) in part { results[offset] = loaded }
            }
            return results
        }
    }
}

/// Hands out the indices `0..<count` once each, to any thread.
private final class WorkCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var position = 0
    private let count: Int

    init(count: Int) { self.count = count }

    func next() -> Int? {
        lock.withLock {
            guard position < count else { return nil }
            defer { position += 1 }
            return position
        }
    }
}
