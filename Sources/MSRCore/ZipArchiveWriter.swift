import Compression
import Foundation

/// A minimal ZIP writer for small containers (the DOCX export). Entries of at
/// least `deflateThreshold` bytes are DEFLATE-compressed (method 8) when that
/// actually shrinks them; everything else is *stored* (method 0). Names are
/// UTF-8 (general-purpose flag bit 11), sizes and CRC-32 sit in the local
/// header (no data descriptor), and there is no ZIP64, so the archive and each
/// entry must stay under 4 GiB and 65,535 entries. Word, Pages,
/// TextEdit/`textutil` and `unzip` all read both methods.
///
/// Layout (PKWARE APPNOTE 6.3): per entry a local file header followed by the
/// data, then the central directory, then the end-of-central-directory record.
public struct ZipArchiveWriter {
    public enum ZipError: Error, LocalizedError, Equatable {
        case tooLarge
        case invalidEntryName(String)
        case duplicateEntry(String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge: "The archive is too large for a ZIP file without ZIP64."
            case let .invalidEntryName(name): "Invalid ZIP entry name: \(name)"
            case let .duplicateEntry(name): "Duplicate ZIP entry: \(name)"
            }
        }
    }

    /// Entries smaller than this are always stored: DEFLATE's block overhead
    /// eats most of the gain and stored entries are cheaper to read.
    public static let deflateThreshold = 256

    private struct CentralEntry {
        var name: [UInt8]
        var crc: UInt32
        var method: UInt16
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var localHeaderOffset: UInt32
    }

    private var output = Data()
    private var entries: [CentralEntry] = []
    private var names = Set<String>()
    private let dosTime: UInt16
    private let dosDate: UInt16

    /// `modifiedAt` is stored (local time, 2-second resolution) as every entry's date.
    public init(modifiedAt: Date = Date(), calendar: Calendar = .current) {
        (dosTime, dosDate) = Self.dosTimestamp(modifiedAt, calendar: calendar)
    }

    /// Appends an entry, deflated when that helps (see `deflateThreshold`).
    /// `path` uses `/` separators and must be relative.
    public mutating func addEntry(_ path: String, data: Data) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == ".." }) else {
            throw ZipError.invalidEntryName(path)
        }
        guard names.insert(path).inserted else { throw ZipError.duplicateEntry(path) }
        let name = Array(path.utf8)
        guard name.count <= Int(UInt16.max), entries.count < Int(UInt16.max),
              data.count <= Int(UInt32.max) else {
            throw ZipError.tooLarge
        }
        let deflated: Data? = Self.deflate(data)
        let payload: Data = deflated ?? data
        let headerEnd: Int = output.count + 30 + name.count
        guard headerEnd + payload.count <= Int(UInt32.max) else { throw ZipError.tooLarge }
        let entry = CentralEntry(
            name: name,
            crc: CRC32.checksum(data),                  // over the uncompressed bytes
            method: deflated == nil ? 0 : 8,
            compressedSize: UInt32(payload.count),
            uncompressedSize: UInt32(data.count),
            localHeaderOffset: UInt32(output.count)
        )
        // Local file header.
        output.appendLittleEndian(UInt32(0x0403_4B50))
        output.appendLittleEndian(Self.versionNeeded(entry.method))
        output.appendLittleEndian(Self.flags)
        output.appendLittleEndian(entry.method)
        output.appendLittleEndian(dosTime)
        output.appendLittleEndian(dosDate)
        output.appendLittleEndian(entry.crc)
        output.appendLittleEndian(entry.compressedSize)
        output.appendLittleEndian(entry.uncompressedSize)
        output.appendLittleEndian(UInt16(name.count))
        output.appendLittleEndian(UInt16(0))            // extra field length
        output.append(contentsOf: name)
        output.append(payload)
        entries.append(entry)
    }

    public mutating func addEntry(_ path: String, text: String) throws {
        try addEntry(path, data: Data(text.utf8))
    }

    /// The finished archive: entries, central directory, end record.
    public func finalized() throws -> Data {
        var archive = output
        let directoryOffset = archive.count
        for entry in entries {
            archive.appendLittleEndian(UInt32(0x0201_4B50))
            archive.appendLittleEndian(UInt16(0x0314))      // made by: UNIX, spec 2.0
            archive.appendLittleEndian(Self.versionNeeded(entry.method))
            archive.appendLittleEndian(Self.flags)
            archive.appendLittleEndian(entry.method)
            archive.appendLittleEndian(dosTime)
            archive.appendLittleEndian(dosDate)
            archive.appendLittleEndian(entry.crc)
            archive.appendLittleEndian(entry.compressedSize)
            archive.appendLittleEndian(entry.uncompressedSize)
            archive.appendLittleEndian(UInt16(entry.name.count))
            archive.appendLittleEndian(UInt16(0))           // extra
            archive.appendLittleEndian(UInt16(0))           // comment
            archive.appendLittleEndian(UInt16(0))           // disk number start
            archive.appendLittleEndian(UInt16(0))           // internal attributes
            archive.appendLittleEndian(UInt32(0o100644) << 16) // external: regular file, rw-r--r--
            archive.appendLittleEndian(entry.localHeaderOffset)
            archive.append(contentsOf: entry.name)
        }
        let directorySize = archive.count - directoryOffset
        guard archive.count + 22 <= Int(UInt32.max) else { throw ZipError.tooLarge }
        archive.appendLittleEndian(UInt32(0x0605_4B50))
        archive.appendLittleEndian(UInt16(0))               // this disk
        archive.appendLittleEndian(UInt16(0))               // disk with the directory
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt32(directorySize))
        archive.appendLittleEndian(UInt32(directoryOffset))
        archive.appendLittleEndian(UInt16(0))               // comment length
        return archive
    }

    /// Bit 11: file names are UTF-8.
    private static let flags: UInt16 = 1 << 11

    /// 1.0 for stored entries, 2.0 for DEFLATE.
    private static func versionNeeded(_ method: UInt16) -> UInt16 {
        method == 8 ? 20 : 10
    }

    /// Raw DEFLATE (RFC 1951) of `data`, or nil when the entry is below the
    /// threshold or would not shrink. Apple's `COMPRESSION_ZLIB` emits raw
    /// deflate without the zlib header/Adler-32 trailer, which is exactly the
    /// ZIP method-8 payload. The destination holds `data.count - 1` bytes, so
    /// an output that would not be smaller fails (returns 0) and is stored.
    static func deflate(_ data: Data) -> Data? {
        guard data.count >= deflateThreshold else { return nil }
        let capacity: Int = data.count - 1
        var output = Data(count: capacity)
        let written: Int = output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let targetBase = target.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(targetBase, capacity, sourceBase, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < data.count else { return nil }
        output.count = written
        return output
    }

    static func dosTimestamp(_ date: Date, calendar: Calendar) -> (time: UInt16, date: UInt16) {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        // Kept as separate typed steps: Swift 6.0 cannot type-check the folded
        // expression in reasonable time.
        let year: Int = min(max((parts.year ?? 1980) - 1980, 0), 127)
        let hour: Int = parts.hour ?? 0
        let minute: Int = parts.minute ?? 0
        let second: Int = (parts.second ?? 0) / 2
        let month: Int = parts.month ?? 1
        let dayOfMonth: Int = parts.day ?? 1
        let timeBits: Int = (hour << 11) | (minute << 5) | second
        let dateBits: Int = (year << 9) | (month << 5) | dayOfMonth
        return (UInt16(timeBits), UInt16(dateBits))
    }
}

/// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320), as used by ZIP.
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for byte in bytes {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
