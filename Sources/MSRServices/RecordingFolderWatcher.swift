import Darwin
import Foundation

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
