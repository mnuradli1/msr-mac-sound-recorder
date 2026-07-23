import Foundation

public enum StorageIntegrityError: Error, LocalizedError, Equatable {
    case invalidFileName(String)
    case pathEscapesLibrary(String)
    case destinationExists(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidFileName(name): "Invalid library file name: \(name)"
        case let .pathEscapesLibrary(name): "The file path escapes the recordings library: \(name)"
        case let .destinationExists(name): "A library file already exists: \(name)"
        }
    }
}

public enum StoragePath {
    public static func containedURL(in root: URL, fileName: String) throws -> URL {
        guard !fileName.isEmpty,
              fileName != ".", fileName != "..",
              !fileName.contains("/"), !fileName.contains("\\") else {
            throw StorageIntegrityError.invalidFileName(fileName)
        }
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = normalizedRoot.appendingPathComponent(fileName).standardizedFileURL
        guard candidate.deletingLastPathComponent() == normalizedRoot else {
            throw StorageIntegrityError.pathEscapesLibrary(fileName)
        }
        return candidate
    }

    public static func isContained(_ url: URL, in root: URL) -> Bool {
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        return normalizedURL.deletingLastPathComponent() == normalizedRoot
    }
}

public enum DurableFile {
    public static func backupURL(for url: URL) -> URL {
        URL(fileURLWithPath: url.path + ".bak")
    }

    public static func write(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let backup = backupURL(for: url)
        do {
            guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()

            if fileManager.fileExists(atPath: url.path) {
                if fileManager.fileExists(atPath: backup.path) {
                    try fileManager.removeItem(at: backup)
                }
                try fileManager.moveItem(at: url, to: backup)
            }
            try fileManager.moveItem(at: temporary, to: url)
        } catch {
            try? fileManager.removeItem(at: temporary)
            if !fileManager.fileExists(atPath: url.path), fileManager.fileExists(atPath: backup.path) {
                try? fileManager.copyItem(at: backup, to: url)
            }
            throw error
        }
    }

    public static func write<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder, fileManager: FileManager = .default) throws {
        try write(encoder.encode(value), to: url, fileManager: fileManager)
    }

    public static func readRecoveringBackup<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        decoder: JSONDecoder,
        validate: (T) -> Bool = { _ in true },
        fileManager: FileManager = .default
    ) -> T? {
        if let value = tryDecode(type, at: url, decoder: decoder), validate(value) {
            return value
        }
        let backup = backupURL(for: url)
        guard let recovered = tryDecode(type, at: backup, decoder: decoder), validate(recovered) else {
            return nil
        }
        quarantine(url, fileManager: fileManager)
        if let data = try? Data(contentsOf: backup) {
            try? write(data, to: url, fileManager: fileManager)
        }
        return recovered
    }

    public static func quarantine(_ url: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let folder = url.deletingLastPathComponent().appendingPathComponent(".corrupt", isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let destination = folder.appendingPathComponent("\(url.lastPathComponent).\(stamp).\(UUID().uuidString).corrupt")
            try fileManager.moveItem(at: url, to: destination)
        } catch {
            // Quarantine is best effort; never destroy the only copy.
        }
    }

    private static func tryDecode<T: Decodable>(_ type: T.Type, at url: URL, decoder: JSONDecoder) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
