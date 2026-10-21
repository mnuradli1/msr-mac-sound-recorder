import Foundation

/// A minimal ZIP writer for small containers (the DOCX export): every entry is
/// *stored* (method 0, no compression), names are UTF-8 (general-purpose flag
/// bit 11), and there is no ZIP64, so the archive and each entry must stay
/// under 4 GiB and 65,535 entries. Word, Pages, TextEdit/`textutil` and
/// `unzip` all read stored entries.
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

    private struct CentralEntry {
        var name: [UInt8]
        var crc: UInt32
        var size: UInt32
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

    /// Appends a stored entry. `path` uses `/` separators and must be relative.
    public mutating func addEntry(_ path: String, data: Data) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == ".." }) else {
            throw ZipError.invalidEntryName(path)
        }
        guard names.insert(path).inserted else { throw ZipError.duplicateEntry(path) }
        let name = Array(path.utf8)
        guard name.count <= Int(UInt16.max), entries.count < Int(UInt16.max),
              data.count <= Int(UInt32.max),
              output.count + 30 + name.count + data.count <= Int(UInt32.max) else {
            throw ZipError.tooLarge
        }
        let crc = CRC32.checksum(data)
        let offset = UInt32(output.count)
        let size = UInt32(data.count)
        // Local file header.
        output.appendLittleEndian(UInt32(0x0403_4B50))
        output.appendLittleEndian(UInt16(10))           // version needed: 1.0 (stored)
        output.appendLittleEndian(Self.flags)
        output.appendLittleEndian(UInt16(0))            // method: stored
        output.appendLittleEndian(dosTime)
        output.appendLittleEndian(dosDate)
        output.appendLittleEndian(crc)
        output.appendLittleEndian(size)                 // compressed size
        output.appendLittleEndian(size)                 // uncompressed size
        output.appendLittleEndian(UInt16(name.count))
        output.appendLittleEndian(UInt16(0))            // extra field length
        output.append(contentsOf: name)
        output.append(data)
        entries.append(CentralEntry(name: name, crc: crc, size: size, localHeaderOffset: offset))
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
            archive.appendLittleEndian(UInt16(10))          // version needed
            archive.appendLittleEndian(Self.flags)
            archive.appendLittleEndian(UInt16(0))           // stored
            archive.appendLittleEndian(dosTime)
            archive.appendLittleEndian(dosDate)
            archive.appendLittleEndian(entry.crc)
            archive.appendLittleEndian(entry.size)
            archive.appendLittleEndian(entry.size)
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

    static func dosTimestamp(_ date: Date, calendar: Calendar) -> (time: UInt16, date: UInt16) {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max((parts.year ?? 1980) - 1980, 0), 127)
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16(year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
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
