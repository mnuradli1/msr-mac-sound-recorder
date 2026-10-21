import Darwin
import Foundation

/// The on-disk review waveform of one recording (`RecordingItem.waveformURL`):
/// per-bucket peaks plus the size and modification time of the audio file they
/// were computed from, so a replaced or edited audio file invalidates them.
///
/// Binary, little-endian, 32-byte header then one `UInt16` per bucket
/// (peak × 65,535): `"MSRW"`, version `UInt8`, reserved `UInt8`, bucket count
/// `UInt16`, audio size `Int64`, audio mtime seconds `Int64`, nanoseconds
/// `Int64`. 96 buckets are 224 bytes.
public enum WaveformCacheFile {
    public struct AudioStamp: Equatable, Sendable {
        public var size: Int64
        public var modifiedSeconds: Int64
        public var modifiedNanoseconds: Int64

        public init(size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64) {
            self.size = size
            self.modifiedSeconds = modifiedSeconds
            self.modifiedNanoseconds = modifiedNanoseconds
        }

        /// `stat` of the audio file (symlinks followed), `nil` when it is missing.
        public init?(audioURL: URL) {
            var info = stat()
            guard stat(audioURL.path, &info) == 0 else { return nil }
            size = Int64(info.st_size)
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        }
    }

    static let magic: [UInt8] = Array("MSRW".utf8)
    static let version: UInt8 = 1
    static let headerSize = 32

    public static func encode(_ samples: [Float], audio: AudioStamp) -> Data {
        var data = Data(capacity: headerSize + samples.count * 2)
        data.append(contentsOf: magic)
        data.append(version)
        data.append(0)
        append(UInt16(clamping: samples.count), to: &data)
        append(audio.size, to: &data)
        append(audio.modifiedSeconds, to: &data)
        append(audio.modifiedNanoseconds, to: &data)
        for sample in samples.prefix(Int(UInt16.max)) {
            let clamped = sample.isFinite ? min(1, max(0, sample)) : 0
            append(UInt16((clamped * 65_535).rounded()), to: &data)
        }
        return data
    }

    /// The samples, or `nil` when `data` is not a valid cache for `audio` with
    /// `bucketCount` buckets.
    public static func decode(_ data: Data, bucketCount: Int, audio: AudioStamp) -> [Float]? {
        guard data.count >= headerSize else { return nil }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == magic, bytes[4] == version else { return nil }
        let count = Int(read(UInt16.self, bytes, at: 6))
        guard count == bucketCount, bytes.count == headerSize + count * 2,
              read(Int64.self, bytes, at: 8) == audio.size,
              read(Int64.self, bytes, at: 16) == audio.modifiedSeconds,
              read(Int64.self, bytes, at: 24) == audio.modifiedNanoseconds else { return nil }
        return (0..<count).map { Float(read(UInt16.self, bytes, at: headerSize + $0 * 2)) / 65_535 }
    }

    /// Reads the cache of `recording`; `nil` when missing, unreadable or stale.
    public static func read(for recording: RecordingItem, bucketCount: Int) -> [Float]? {
        guard let audio = AudioStamp(audioURL: recording.audioURL),
              let data = try? Data(contentsOf: recording.waveformURL) else { return nil }
        return decode(data, bucketCount: bucketCount, audio: audio)
    }

    /// Writes the cache of `recording` for its audio file as it is now: a
    /// hidden temporary file in the same folder, renamed over the old cache.
    /// No backup is kept (the cache can always be recomputed).
    public static func write(_ samples: [Float], for recording: RecordingItem) throws {
        guard let audio = AudioStamp(audioURL: recording.audioURL) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: recording.audioURL.path])
        }
        let destination = recording.waveformURL
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try encode(samples, audio: audio).write(to: temporary)
        guard rename(temporary.path, destination.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_ type: T.Type, _ bytes: [UInt8], at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value |= T(truncatingIfNeeded: bytes[offset + index]) << (8 * index)
        }
        return value
    }
}
