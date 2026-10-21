import AVFoundation
import Foundation
import Testing
@testable import MSRCore
@testable import MSRServices

// MARK: - Search folding and sketches

@Suite("Search folding")
struct SearchFoldingTests {
    @Test func foldsCaseDiacriticsAndWhitespaceOnce() {
        #expect(String(decoding: SearchFolding.fold("  Café\tRÉSUMÉ \n\n Naïve  "), as: UTF8.self) == "cafe resume naive")
        // Decomposed input (e + combining acute) folds like the precomposed form.
        #expect(SearchFolding.fold("Cafe\u{301}") == SearchFolding.fold("Café"))
        #expect(SearchFolding.fold("Let\u{2019}s go") == Array("let\u{2019}s go".utf8))
        // Non-ASCII whitespace collapses too.
        #expect(SearchFolding.fold("a\u{00A0}\u{2003}b") == Array("a b".utf8))
        #expect(SearchFolding.fold("") == [])
    }

    @Test func queryMatchingIsCaseAndDiacriticInsensitive() throws {
        let item = makeItem(name: "Résumé Review", source: .system)
        let document = RecordingSearchDocument(recording: item, transcriptText: "Speaker 1:\nThe CAFÉ opens Monday.", summaryText: "Ünïcode summary")
        #expect(RecordingSearch.filter([document], query: "resume").count == 1)
        #expect(RecordingSearch.filter([document], query: "café monday").count == 1)
        #expect(RecordingSearch.filter([document], query: "UNICODE system").count == 1)
        #expect(RecordingSearch.filter([document], query: "cafe tuesday").isEmpty)
        // Tokens never span the transcript/summary boundary.
        #expect(RecordingSearch.filter([document], query: "monday.ünïcode").isEmpty)
    }

    @Test func sketchNeverRejectsTextThatContainsTheToken() {
        var generator = SplitMix64(seed: 42)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz éü")
        for _ in 0..<50 {
            let text = String((0..<Int(200 + generator.next() % 6_000)).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
            let folded = SearchFolding.fold(text)
            let sketch = SearchSketch(folded)
            for _ in 0..<40 {
                let start = Int(generator.next() % UInt64(max(1, folded.count - 8)))
                let length = 1 + Int(generator.next() % 7)
                let token = Array(folded[start..<min(folded.count, start + length)])
                #expect(sketch.mayContain(token))
            }
            #expect(sketch.byteCount <= 2_048 + 32)
        }
    }

    @Test func sketchRulesOutAbsentTokens() {
        let sketch = SearchSketch(SearchFolding.fold(String(repeating: "budget review timeline speaker ", count: 200)))
        #expect(!sketch.mayContain(Array("zzqx".utf8)))
        #expect(!sketch.mayContain(Array("q".utf8)))
        #expect(sketch.mayContain(Array("budget".utf8)))
        // A small vocabulary folds the filter down to its minimum size.
        #expect(sketch.byteCount < 1_024)
    }
}

// MARK: - Waveform cache and audio scanning

@Suite("Waveform cache")
struct WaveformCacheTests {
    @Test func encodesRoundTripAndRejectsStaleOrForeignData() {
        let stamp = WaveformCacheFile.AudioStamp(size: 1_234, modifiedSeconds: 1_700_000_000, modifiedNanoseconds: 5)
        let samples: [Float] = (0..<96).map { Float($0) / 95 }
        let data = WaveformCacheFile.encode(samples, audio: stamp)
        #expect(data.count == 32 + 96 * 2)
        let decoded = WaveformCacheFile.decode(data, bucketCount: 96, audio: stamp)
        #expect(decoded?.count == 96)
        #expect(zip(decoded ?? [], samples).allSatisfy { abs($0 - $1) <= 1 / 65_535 })
        var touched = stamp
        touched.modifiedNanoseconds += 1
        #expect(WaveformCacheFile.decode(data, bucketCount: 96, audio: touched) == nil)
        #expect(WaveformCacheFile.decode(data, bucketCount: 48, audio: stamp) == nil)
        #expect(WaveformCacheFile.decode(Data("not a cache".utf8), bucketCount: 96, audio: stamp) == nil)
    }

    @Test func libraryStoresLoadsInvalidatesAndDeletesTheCache() throws {
        let folder = try HardeningTestFolder()
        let capture = folder.url.appendingPathComponent("capture.m4a")
        try Data("audio".utf8).write(to: capture)
        let library = RecordingLibrary(folderURL: folder.url)
        let item = try library.finishRecording(
            temporaryAudioURL: capture, requestedName: "Wave", source: .microphone,
            startedAt: Date(timeIntervalSince1970: 10), endedAt: Date(timeIntervalSince1970: 20)
        )
        #expect(library.loadWaveformCache(for: item, bucketCount: 96) == nil)
        let samples = [Float](repeating: 0.5, count: 96)
        try library.storeWaveformCache(samples, for: item)
        #expect(item.waveformURL.lastPathComponent == "\(item.storageBaseName).waveform")
        #expect(library.loadWaveformCache(for: item, bucketCount: 96)?.allSatisfy { abs($0 - 0.5) < 0.001 } == true)
        // Not metadata: the library still lists exactly one recording.
        #expect(try library.loadRecordings().count == 1)

        // The audio changed (new modification date): the cache is stale.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 99)], ofItemAtPath: item.audioURL.path)
        #expect(library.loadWaveformCache(for: item, bucketCount: 96) == nil)

        try library.storeWaveformCache(samples, for: item)
        try library.delete(item)
        #expect(!FileManager.default.fileExists(atPath: item.waveformURL.path))
    }

    @Test func legacyMigrationMovesTheCache() throws {
        let folder = try HardeningTestFolder()
        try Data("audio".utf8).write(to: folder.url.appendingPathComponent("Old.m4a"))
        try """
        {"id":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","displayName":"Old","source":"microphone","audioFileName":"Old.m4a",
         "startedAt":"1970-01-01T00:00:10Z","endedAt":"1970-01-01T00:00:20Z","durationSeconds":10,
         "createdAt":"1970-01-01T00:00:20Z","updatedAt":"1970-01-01T00:00:20Z"}
        """.write(to: folder.url.appendingPathComponent("Old.json"), atomically: true, encoding: .utf8)
        let library = RecordingLibrary(folderURL: folder.url)
        let legacy = try #require(library.loadRecordings().first)
        try library.storeWaveformCache([Float](repeating: 0.25, count: 96), for: legacy)
        #expect(legacy.waveformURL.lastPathComponent == "Old.waveform")

        let migrated = try library.migrateIfNeeded(legacy)
        #expect(migrated.usesImmutableStorage)
        #expect(!FileManager.default.fileExists(atPath: legacy.waveformURL.path))
        // Moving keeps the audio's size and date, so the moved cache is still valid.
        #expect(library.loadWaveformCache(for: migrated, bucketCount: 96)?.first.map { abs($0 - 0.25) < 0.001 } == true)
    }

    @Test func parallelScanMatchesASingleThreadedScan() async throws {
        let folder = try HardeningTestFolder()
        let wav = folder.url.appendingPathComponent("long.wav")
        // 75 s: silence for the first third, then a 0.4 tone (8 kHz mono).
        try writeSegmentedWAV(to: wav, sampleRate: 8_000, seconds: 75, silentSeconds: 25, amplitude: 0.4)
        let single = try await AudioLevelScanner.scan(url: wav, bucketCount: 96, maxParallelism: 1)
        let parallel = try await AudioLevelScanner.scan(url: wav, bucketCount: 96, maxParallelism: 4)
        #expect(single.frameCount == 600_000)
        #expect(parallel.frameCount == single.frameCount)
        #expect(parallel.sampleCount == single.sampleCount)
        #expect(parallel.peak == single.peak)
        #expect(parallel.buckets == single.buckets)
        #expect(abs(parallel.sumOfSquares - single.sumOfSquares) <= single.sumOfSquares * 1e-6)
        #expect(abs(single.durationSeconds - 75) < 0.001)
        // Bucket b covers frames [b·N/96, (b+1)·N/96): the first 32 are silent.
        #expect(single.buckets.prefix(32).allSatisfy { $0 == 0 })
        #expect(single.buckets.suffix(63).allSatisfy { abs($0 - 0.4) < 0.01 })
        #expect(abs(single.rms - 0.4 / Float(2).squareRoot() * Float(50.0 / 75).squareRoot()) < 0.005)
    }

    @Test func confidenceAnalysisReturnsTheWaveformOfTheSameDecode() async throws {
        let folder = try HardeningTestFolder()
        let wav = folder.url.appendingPathComponent("short.wav")
        try writeSegmentedWAV(to: wav, sampleRate: 16_000, seconds: 2, silentSeconds: 1, amplitude: 0.3)
        let (report, waveform) = try await RecordingConfidenceAnalyzer.analyzeWithWaveform(audioURL: wav, source: .microphone, minimumDuration: 1)
        let samples = try await WaveformAnalyzer().samples(for: wav)
        #expect(waveform == samples)
        #expect(waveform.count == 96)
        #expect(abs(report.peakLevel - 0.3) < 0.005)
        #expect(abs(report.durationSeconds - 2) < 0.01)
    }

    @Test func scanCanBeCancelled() async throws {
        let folder = try HardeningTestFolder()
        let wav = folder.url.appendingPathComponent("cancel.wav")
        try writeSegmentedWAV(to: wav, sampleRate: 8_000, seconds: 120, silentSeconds: 0, amplitude: 0.1)
        let task = Task { try await AudioLevelScanner.scan(url: wav, bucketCount: 96) }
        task.cancel()
        do {
            _ = try await task.value
        } catch {
            #expect(error is CancellationError)
        }
    }
}

// MARK: - DOCX without ZIPFoundation

@Suite("Stored ZIP writer")
struct ZipArchiveWriterTests {
    @Test func crc32MatchesTheStandardCheckValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test func archiveIsValidForUnzip() throws {
        let folder = try HardeningTestFolder()
        var writer = ZipArchiveWriter(modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try writer.addEntry("a.txt", text: "hello")
        try writer.addEntry("dir/b.txt", text: "wörld")
        #expect(throws: ZipArchiveWriter.ZipError.duplicateEntry("a.txt")) { try writer.addEntry("a.txt", text: "again") }
        #expect(throws: ZipArchiveWriter.ZipError.invalidEntryName("../x")) { try writer.addEntry("../x", text: "") }
        let url = folder.url.appendingPathComponent("test.zip")
        try writer.finalized().write(to: url)
        let test = try run("/usr/bin/unzip", ["-t", url.path])
        #expect(test.status == 0)
        #expect(test.output.contains("No errors detected"))
        let listed = try run("/usr/bin/unzip", ["-p", url.path, "dir/b.txt"])
        #expect(listed.output == "wörld")
    }

    @Test func docxRoundTripsThroughTextutil() throws {
        let folder = try HardeningTestFolder()
        let now = Date(timeIntervalSince1970: 1_000)
        let item = RecordingItem(
            metadata: RecordingMetadata(
                id: UUID(), storageKey: "recording-docx", displayName: "Planning & <Review>",
                source: .micAndSystem, audioFileName: "recording-docx.m4a",
                startedAt: now, endedAt: now.addingTimeInterval(10), durationSeconds: 10,
                createdAt: now, updatedAt: now
            ),
            folderURL: folder.url
        )
        let segments = [TranscriptSegment(speaker: "Adli", startTime: 0, endTime: 2, text: "Ship it on Friday, café included")]
        let input = MeetingNotesExportInput(recording: item, transcript: "Adli: Ship it on Friday, café included", segments: segments, summary: "## Action Items\n- Ship the build")
        let docx = folder.url.appendingPathComponent("notes.docx")
        try TranscriptExporter.export(input, format: .docx, to: docx)
        #expect(try Data(contentsOf: docx).prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        #expect(try run("/usr/bin/unzip", ["-t", docx.path]).status == 0)

        let converted = try run("/usr/bin/textutil", ["-convert", "txt", "-stdout", docx.path])
        #expect(converted.status == 0)
        #expect(converted.output.contains("Planning & <Review>"))
        #expect(converted.output.contains("Ship it on Friday, café included"))
        #expect(converted.output.contains("Ship the build"))
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Library metadata index

@Suite("Library metadata index")
struct LibraryMetadataIndexTests {
    @Test func renamesDeduplicateAgainstPatchedAndExternalChanges() throws {
        let folder = try HardeningTestFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let first = try capture(in: library, folder: folder, name: "Alpha", at: 10)
        let second = try capture(in: library, folder: folder, name: "Beta", at: 20)
        let third = try capture(in: library, folder: folder, name: "Gamma", at: 30)
        _ = try library.loadRecordings()

        // The index is patched by the first rename, so the second sees "Weekly".
        #expect(try library.rename(first, to: "Weekly").displayName == "Weekly")
        #expect(try library.rename(second, to: "Weekly").displayName == "Weekly 2")

        // Another library instance (the app makes one per call) shares the index.
        #expect(try RecordingLibrary(folderURL: folder.url).rename(third, to: "weekly").displayName == "weekly 3")

        // An in-place external edit of a metadata file (no new folder entry) is seen.
        let thirdURL = third.metadataURL
        var json = try String(contentsOf: thirdURL, encoding: .utf8)
        json = json.replacingOccurrences(of: "\"weekly 3\"", with: "\"Roadmap\"")
        let handle = try FileHandle(forWritingTo: thirdURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(json.utf8))
        try handle.close()
        #expect(try library.rename(first, to: "Roadmap").displayName == "Roadmap 2")

        // A recording added by someone else (a new folder entry) is seen.
        let external = RecordingLibrary(folderURL: folder.url)
        _ = try capture(in: external, folder: folder, name: "Launch", at: 40)
        #expect(try library.rename(second, to: "Launch").displayName == "Launch 2")
    }

    @Test func aPendingJournalStillReplaysBeforeARename() throws {
        let folder = try HardeningTestFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let keep = try capture(in: library, folder: folder, name: "Keep", at: 10)
        let doomed = try capture(in: library, folder: folder, name: "Doomed", at: 20)
        _ = try library.loadRecordings()
        // An interrupted delete (as left by a crash) appears after the index was built.
        let journal = """
        {"recordingID":"\(doomed.id.uuidString)","fileNames":["\(doomed.audioURL.lastPathComponent)","\(doomed.metadataURL.lastPathComponent)"]}
        """
        try journal.write(to: folder.url.appendingPathComponent(".delete-\(doomed.id.uuidString).json"), atomically: true, encoding: .utf8)

        // The folder changed, so the rename reloads (replaying the journal): "Doomed" is free.
        #expect(try library.rename(keep, to: "Doomed").displayName == "Doomed")
        #expect(!FileManager.default.fileExists(atPath: doomed.metadataURL.path))
        #expect(try library.loadRecordings().map(\.displayName) == ["Doomed"])
    }

    @Test func duplicateIDsAreRejectedFromTheIndexToo() throws {
        let folder = try HardeningTestFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let existing = try capture(in: library, folder: folder, name: "One", at: 10)
        _ = try library.loadRecordings()
        let capture = folder.url.appendingPathComponent("again.m4a")
        try Data("audio".utf8).write(to: capture)
        #expect(throws: RecordingLibraryError.duplicateRecordingID(existing.id)) {
            try library.finishRecording(
                temporaryAudioURL: capture, requestedName: "Two", source: .microphone,
                startedAt: Date(timeIntervalSince1970: 30), endedAt: Date(timeIntervalSince1970: 40),
                recordingID: existing.id
            )
        }
        // A rename of a recording deleted behind the library's back still fails cleanly.
        try FileManager.default.removeItem(at: existing.metadataURL)
        #expect(throws: RecordingLibraryError.recordingNotFound(existing.id)) { try library.rename(existing, to: "Gone") }
    }

    @Test func speakerRenameUsesTheIndexAndKeepsItCurrent() throws {
        let folder = try HardeningTestFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let item = try capture(in: library, folder: folder, name: "Speakers", at: 10)
        _ = try library.writeTranscript("Speaker 1:\nHello\n\nSpeaker 2:\nHi", for: item)
        _ = try library.loadRecordings()
        let renamed = try library.renameSpeaker(item, label: "Speaker 1", to: "Budi")
        #expect(renamed.speakerNames == ["Speaker 1": "Budi"])
        #expect(try String(contentsOf: renamed.transcriptURL, encoding: .utf8).hasPrefix("Budi:"))
        // The metadata write was patched into the index: a rename sees the new state.
        let titled = try library.rename(renamed, to: "Speakers Renamed")
        #expect(titled.speakerNames == ["Speaker 1": "Budi"])
        #expect(try library.loadRecordings().first?.displayName == "Speakers Renamed")
    }

    private func capture(in library: RecordingLibrary, folder: HardeningTestFolder, name: String, at seconds: TimeInterval) throws -> RecordingItem {
        let source = folder.url.appendingPathComponent("capture-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: source)
        return try library.finishRecording(
            temporaryAudioURL: source, requestedName: name, source: .microphone,
            startedAt: Date(timeIntervalSince1970: seconds), endedAt: Date(timeIntervalSince1970: seconds + 10)
        )
    }
}

// MARK: - Helpers

private func makeItem(name: String, source: AudioSource) -> RecordingItem {
    let start = Date(timeIntervalSince1970: 1_000)
    return RecordingItem(
        metadata: RecordingMetadata(
            id: UUID(), displayName: name, source: source, audioFileName: "\(name).m4a",
            startedAt: start, endedAt: start.addingTimeInterval(10), durationSeconds: 10,
            createdAt: start, updatedAt: start
        ),
        folderURL: FileManager.default.temporaryDirectory
    )
}

/// Mono float WAV: `silentSeconds` of silence, then a 440 Hz tone.
private func writeSegmentedWAV(to url: URL, sampleRate: Double, seconds: Double, silentSeconds: Double, amplitude: Float) throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * sampleRate)),
          let channel = buffer.floatChannelData?[0] else {
        throw CocoaError(.featureUnsupported)
    }
    buffer.frameLength = buffer.frameCapacity
    let silentFrames = Int(silentSeconds * sampleRate)
    for frame in 0..<Int(buffer.frameLength) {
        channel[frame] = frame < silentFrames ? 0 : amplitude * Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

@Suite("Search folding growth")
struct SearchFoldingGrowthTests {
    @Test func expandingRunsFollowedByASCIIStayInBounds() {
        // "ﬃ" (3 bytes) folds to "ffi"; "ŉ" (2 bytes) to "ʼn" (3 bytes); many of
        // them, then a long ASCII tail, exercise the buffer growth.
        let text = String(repeating: "ŉ", count: 400) + String(repeating: "abc ", count: 2_000)
        let folded = SearchFolding.fold(text)
        #expect(folded == Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).precomposedStringWithCanonicalMapping.utf8).dropLast())
        #expect(SearchFolding.fold("ﬃx").count >= 2)
    }
}
