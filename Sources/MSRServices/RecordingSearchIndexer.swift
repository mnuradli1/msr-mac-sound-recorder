import Foundation
import MSRCore

/// Caches transcript and summary text per recording. `capacity` is the number of recordings kept,
/// evicting the least recently used ones once a scan finishes.
public actor RecordingSearchIndexer {
    private struct CachedText {
        var url: URL
        var modifiedAt: Date?
        var value: String
    }

    private struct Entry {
        var transcript: CachedText
        var summary: CachedText
        var lastUsed: UInt64
    }

    private var cache: [UUID: Entry] = [:]
    private var useCounter: UInt64 = 0
    private let capacity: Int

    public init(capacity: Int = 64) { self.capacity = max(1, capacity) }

    /// Number of recordings currently cached (for diagnostics and tests).
    var cachedRecordingCount: Int { cache.count }

    public func documents(for recordings: [RecordingItem]) -> [RecordingSearchDocument] {
        let documents = recordings.map { recording in
            useCounter += 1
            let previous = cache[recording.id]
            let transcript = cachedText(at: recording.transcriptURL, previous: previous?.transcript)
            let summary = cachedText(at: recording.summaryURL, previous: previous?.summary)
            cache[recording.id] = Entry(transcript: transcript, summary: summary, lastUsed: useCounter)
            return RecordingSearchDocument(
                recording: recording,
                transcriptText: transcript.value,
                summaryText: summary.value
            )
        }
        evictLeastRecentlyUsed()
        return documents
    }

    private func cachedText(at url: URL, previous: CachedText?) -> CachedText {
        let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let previous, previous.url == url, previous.modifiedAt == modifiedAt {
            return previous
        }
        let value = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return CachedText(url: url, modifiedAt: modifiedAt, value: value)
    }

    private func evictLeastRecentlyUsed() {
        let overflow = cache.count - capacity
        guard overflow > 0 else { return }
        let oldest = cache.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(overflow).map(\.key)
        for id in oldest {
            cache.removeValue(forKey: id)
        }
    }
}
