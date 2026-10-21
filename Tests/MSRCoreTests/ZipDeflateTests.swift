import Foundation
import Testing
@testable import MSRCore

@Suite("ZIP writer DEFLATE")
struct ZipDeflateTests {
    @Test func rawDeflateOmitsTheZlibHeaderAndShrinks() throws {
        let text = String(repeating: "Adli: ship the build on Friday. ", count: 64)
        let data = Data(text.utf8)
        let deflated = try #require(ZipArchiveWriter.deflate(data))
        #expect(deflated.count < data.count / 4)
        // A zlib stream would start with 0x78 (CMF: deflate, 32K window).
        #expect(deflated.first != 0x78)
        #expect(ZipArchiveWriter.deflate(Data(repeating: 0x41, count: ZipArchiveWriter.deflateThreshold - 1)) == nil)
    }

    @Test func mixesStoredAndDeflatedEntries() throws {
        let folder = try HardeningTestFolder()
        let tiny = Data("hello".utf8)
        let big = Data(String(repeating: "<w:p><w:r><w:t>Line</w:t></w:r></w:p>\n", count: 300).utf8)
        let noise = Self.noise(count: 4_096)
        let boundary = Data(repeating: 0x42, count: ZipArchiveWriter.deflateThreshold - 1)

        var writer = ZipArchiveWriter(modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try writer.addEntry("tiny.txt", data: tiny)
        try writer.addEntry("word/big.xml", data: big)
        try writer.addEntry("noise.bin", data: noise)
        try writer.addEntry("boundary.txt", data: boundary)
        let archive = try writer.finalized()
        let url = folder.url.appendingPathComponent("mixed.zip")
        try archive.write(to: url)

        let test = try Self.run("/usr/bin/unzip", ["-t", url.path])
        #expect(test.status == 0)
        #expect(String(decoding: test.output, as: UTF8.self).contains("No errors detected"))

        let methods = try Self.methods(url)
        #expect(methods["tiny.txt"] == "stor")
        #expect(methods["word/big.xml"] == "defN")
        #expect(methods["noise.bin"] == "stor")
        #expect(methods["boundary.txt"] == "stor")

        #expect(try Self.run("/usr/bin/unzip", ["-p", url.path, "tiny.txt"]).output == tiny)
        #expect(try Self.run("/usr/bin/unzip", ["-p", url.path, "word/big.xml"]).output == big)
        #expect(try Self.run("/usr/bin/unzip", ["-p", url.path, "noise.bin"]).output == noise)
        #expect(try Self.run("/usr/bin/unzip", ["-p", url.path, "boundary.txt"]).output == boundary)

        let verbose = try Self.run("/usr/bin/zipinfo", ["-v", url.path])
        let verboseText = String(decoding: verbose.output, as: UTF8.self)
        #expect(verboseText.contains("compression method:                             deflated"))
        #expect(verboseText.contains("compression method:                             none (stored)"))
        #expect(!verboseText.contains("extended local header:                          yes"))
    }

    @Test func localHeaderCarriesBothSizesAndNoDataDescriptor() throws {
        let big = Data(String(repeating: "abcabcabc ", count: 200).utf8)
        var writer = ZipArchiveWriter(modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try writer.addEntry("big.txt", data: big)
        let archive = try writer.finalized()
        let flags: UInt16 = Self.uint16(archive, at: 6)
        let method: UInt16 = Self.uint16(archive, at: 8)
        let crc: UInt32 = Self.uint32(archive, at: 14)
        let compressed: UInt32 = Self.uint32(archive, at: 18)
        let uncompressed: UInt32 = Self.uint32(archive, at: 22)
        #expect(Self.uint16(archive, at: 4) == 20)
        #expect(flags & 0x0008 == 0)
        #expect(method == 8)
        #expect(crc == CRC32.checksum(big))
        #expect(uncompressed == UInt32(big.count))
        #expect(compressed < uncompressed)
    }

    @Test func largeTranscriptDocxIsDeflatedAndRoundTrips() throws {
        let folder = try HardeningTestFolder()
        let segments = Self.segments(totalBytes: 32 * 1_024)
        let transcript = segments.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        #expect(transcript.utf8.count >= 32 * 1_024)
        let now = Date(timeIntervalSince1970: 1_000)
        let item = RecordingItem(
            metadata: RecordingMetadata(
                id: UUID(), storageKey: "recording-deflate", displayName: "Quarterly Planning",
                source: .micAndSystem, audioFileName: "recording-deflate.m4a",
                startedAt: now, endedAt: now.addingTimeInterval(3_600), durationSeconds: 3_600,
                createdAt: now, updatedAt: now
            ),
            folderURL: folder.url
        )
        let input = MeetingNotesExportInput(recording: item, transcript: transcript, segments: segments, summary: "## Action Items\n- Ship the build")
        let docx = folder.url.appendingPathComponent("long.docx")
        try TranscriptExporter.export(input, format: .docx, to: docx)

        let size: Int = try Data(contentsOf: docx).count
        let documentXML = try Self.run("/usr/bin/unzip", ["-p", docx.path, "word/document.xml"]).output
        // Stored, the archive would be bigger than document.xml alone.
        #expect(documentXML.count > transcript.utf8.count)
        #expect(size * 4 < documentXML.count)
        #expect(try Self.methods(docx)["word/document.xml"] == "defN")
        #expect(try Self.run("/usr/bin/unzip", ["-t", docx.path]).status == 0)

        let converted = try Self.run("/usr/bin/textutil", ["-convert", "txt", "-stdout", docx.path])
        let text = String(decoding: converted.output, as: UTF8.self)
        #expect(converted.status == 0)
        #expect(text.contains("Quarterly Planning"))
        #expect(text.contains(segments[0].text))
        #expect(text.contains(segments[segments.count - 1].text))
        #expect(text.contains("Ship the build"))
    }

    // MARK: - Helpers

    private static func segments(totalBytes: Int) -> [TranscriptSegment] {
        let speakers = ["Adli", "Sari", "Budi", "Maya"]
        let topics = ["the release train", "dark mode colours", "the café budget", "hiring", "the export bug", "Friday's demo"]
        var result: [TranscriptSegment] = []
        var bytes = 0
        var index = 0
        while bytes < totalBytes {
            let speaker = speakers[index % speakers.count]
            let topic = topics[(index * 7) % topics.count]
            let text = "Point \(index): we should revisit \(topic) before the next review, and note item \(index * 13 % 97)."
            let start = Double(index * 5)
            result.append(TranscriptSegment(speaker: speaker, startTime: start, endTime: start + 4, text: text))
            bytes += speaker.utf8.count + text.utf8.count + 3
            index += 1
        }
        return result
    }

    private static func noise(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var data = Data(capacity: count)
        for _ in 0..<count {
            data.append(UInt8.random(in: 0...255, using: &generator))
        }
        return data
    }

    /// Entry name -> zipinfo method column ("stor", "defN", ...).
    private static func methods(_ url: URL) throws -> [String: String] {
        let listing = try run("/usr/bin/zipinfo", [url.path])
        var result: [String: String] = [:]
        for line in String(decoding: listing.output, as: UTF8.self).split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 9, columns[0].hasPrefix("-") else { continue }
            result[String(columns[columns.count - 1])] = String(columns[5])
        }
        return result
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        let low = UInt16(data[data.startIndex + offset])
        let high = UInt16(data[data.startIndex + offset + 1])
        return low | (high << 8)
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        let low = UInt32(uint16(data, at: offset))
        let high = UInt32(uint16(data, at: offset + 2))
        return low | (high << 16)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
