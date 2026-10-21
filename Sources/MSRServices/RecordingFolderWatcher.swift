import Darwin
import Foundation
import MSRCore

public final class RecordingFolderWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.msr.folder-watcher")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var pending: DispatchWorkItem?

    public init() {}

    public func start(folderURL: URL, debounceMilliseconds: Int = 600, onChange: @escaping @Sendable () -> Void) throws {
        stop()
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let descriptor = open(folderURL.path, O_EVTONLY)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        self.descriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            pending?.cancel()
            let item = DispatchWorkItem(block: onChange)
            pending = item
            queue.asyncAfter(deadline: .now() + .milliseconds(debounceMilliseconds), execute: item)
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }

    deinit { stop() }
}

/// Name, size, modification and status-change times and inode of every entry
/// in a library folder (hidden files included).
///
/// The app keeps the snapshot taken just before its last library load and
/// patches it for files it writes itself afterwards, with the stamps those
/// writes recorded (`OwnFileWrites`). When the folder watcher fires, a fresh
/// snapshot equal to the kept one means the events came only from the app's
/// own writes, so the full reload can be skipped; any external change (a new,
/// removed, renamed or rewritten file, even one replaced with the same size
/// and modification date) makes them differ.
public struct LibraryFolderSnapshot: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let size: Int64
        public let modifiedSeconds: Int
        public let modifiedNanoseconds: Int
        public let changedSeconds: Int
        public let changedNanoseconds: Int
        public let inode: UInt64

        init(_ info: stat) {
            self.init(FileStamp(info))
        }

        public init(_ stamp: FileStamp) {
            size = stamp.size
            modifiedSeconds = stamp.modified.tv_sec
            modifiedNanoseconds = stamp.modified.tv_nsec
            changedSeconds = stamp.changed.tv_sec
            changedNanoseconds = stamp.changed.tv_nsec
            inode = stamp.inode
        }
    }

    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry]) {
        self.entries = entries
    }

    /// `nil` when the folder cannot be listed. Uses `readdir` + `fstatat`
    /// (a few milliseconds for thousands of files).
    public static func capture(folderURL: URL) -> LibraryFolderSnapshot? {
        guard let directory = opendir(folderURL.path) else { return nil }
        defer { closedir(directory) }
        let descriptor = dirfd(directory)
        var entries: [String: Entry] = [:]
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            var info = stat()
            if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                entries[name] = Entry(info)
            }
        }
        return LibraryFolderSnapshot(entries: entries)
    }

    public func contains(_ fileName: String) -> Bool {
        entries[fileName] != nil
    }

    /// Sets the entry of `fileName` to what the app's own write recorded
    /// (`.absent` removes it).
    public mutating func patch(_ fileName: String, with status: OwnFileWrites.Status) {
        switch status {
        case let .present(stamp): entries[fileName] = Entry(stamp)
        case .absent: entries[fileName] = nil
        }
    }

    /// Re-reads the given entries of `folderURL` (a missing file is removed).
    public mutating func refresh(fileNames: [String], in folderURL: URL) {
        for name in fileNames {
            var info = stat()
            if lstat(folderURL.appendingPathComponent(name, isDirectory: false).path, &info) == 0 {
                entries[name] = Entry(info)
            } else {
                entries[name] = nil
            }
        }
    }
}
