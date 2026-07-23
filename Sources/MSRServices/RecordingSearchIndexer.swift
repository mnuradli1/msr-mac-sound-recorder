import Foundation
import MSRCore

public actor RecordingSearchIndexer {
    private struct Entry {
        var modifiedAt: Date?
        var value: String
    }
    private var cache: [URL: Entry] = [:]
    private var order: [URL] = []
    private let capacity: Int

    public init(capacity: Int = 64) { self.capacity = max(1, capacity) }

    public func documents(for recordings: [RecordingItem]) -> [RecordingSearchDocument] {
        recordings.map { recording in
            RecordingSearchDocument(
                recording: recording,
                transcriptText: text(at: recording.transcriptURL),
                summaryText: text(at: recording.summaryURL)
            )
        }
    }

    private func text(at url: URL) -> String {
        let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let entry = cache[url], entry.modifiedAt == modifiedAt {
            touch(url)
            return entry.value
        }
        let value = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        cache[url] = Entry(modifiedAt: modifiedAt, value: value)
        touch(url)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        return value
    }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
    }
}
