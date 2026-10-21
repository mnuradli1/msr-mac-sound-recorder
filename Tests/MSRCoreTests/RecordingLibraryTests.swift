import Foundation
import Testing
@testable import MSRCore

@Suite("Recording library v2")
struct RecordingLibraryTests {
    @Test func newRecordingUsesImmutableStorageAndRenameIsDisplayOnly() throws {
        let folder = try TemporaryFolder()
        let source = folder.url.appendingPathComponent("capture.m4a")
        try Data("audio".utf8).write(to: source)
        let library = RecordingLibrary(folderURL: folder.url)

        let item = try library.finishRecording(
            temporaryAudioURL: source,
            requestedName: "Weekly Sync",
            source: .microphone,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20)
        )
        let audioURL = item.audioURL
        let metadataURL = item.metadataURL
        let renamed = try library.rename(item, to: "Roadmap")

        #expect(item.usesImmutableStorage)
        #expect(item.storageBaseName.count == "recording-".count + 32)
        #expect(renamed.displayName == "Roadmap")
        #expect(renamed.audioURL == audioURL)
        #expect(renamed.metadataURL == metadataURL)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
    }

    @Test func legacyRecordingLoadsWithoutMutationAndMigratesOnWrite() throws {
        let folder = try TemporaryFolder()
        let audio = folder.url.appendingPathComponent("Legacy.m4a")
        let metadataURL = folder.url.appendingPathComponent("Legacy.json")
        try Data("audio".utf8).write(to: audio)
        let legacy = """
        {
          "id" : "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
          "displayName" : "Legacy",
          "source" : "microphone",
          "audioFileName" : "Legacy.m4a",
          "startedAt" : "1970-01-01T00:00:10Z",
          "endedAt" : "1970-01-01T00:00:20Z",
          "durationSeconds" : 10,
          "createdAt" : "1970-01-01T00:00:20Z",
          "updatedAt" : "1970-01-01T00:00:20Z"
        }
        """
        try legacy.write(to: metadataURL, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: metadataURL)
        let library = RecordingLibrary(folderURL: folder.url)

        let loaded = try #require(library.loadRecordings().first)
        #expect(!loaded.usesImmutableStorage)
        #expect(try Data(contentsOf: metadataURL) == before)

        let migrated = try library.writeTranscript("Hello", for: loaded)
        #expect(migrated.usesImmutableStorage)
        #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
        #expect(FileManager.default.fileExists(atPath: migrated.transcriptURL.path))
        #expect(try library.loadRecordings().first?.displayName == "Legacy")
    }

    @Test func duplicateIDsAreRejectedAsAGroup() throws {
        let folder = try TemporaryFolder()
        let id = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let library = RecordingLibrary(folderURL: folder.url)
        for index in 1...2 {
            let key = "recording-\(index)"
            let audio = folder.url.appendingPathComponent("\(key).m4a")
            try Data("audio".utf8).write(to: audio)
            let now = Date(timeIntervalSince1970: TimeInterval(index))
            let metadata = RecordingMetadata(
                id: id,
                storageKey: key,
                displayName: "Duplicate \(index)",
                source: .microphone,
                audioFileName: audio.lastPathComponent,
                startedAt: now,
                endedAt: now,
                durationSeconds: 0,
                createdAt: now,
                updatedAt: now
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata).write(to: folder.url.appendingPathComponent("\(key).json"))
        }
        #expect(try library.loadRecordings().isEmpty)
    }

    @Test func futureMetadataIsPreservedAndNeverDowngradedFromBackup() throws {
        let folder = try TemporaryFolder()
        let id = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let key = RecordingLibrary.storageKey(for: id)
        let audio = folder.url.appendingPathComponent("\(key).m4a")
        let metadataURL = folder.url.appendingPathComponent("\(key).json")
        try Data("audio".utf8).write(to: audio)
        let now = Date(timeIntervalSince1970: 100)
        let metadata = RecordingMetadata(
            id: id,
            storageKey: key,
            displayName: "Future",
            source: .microphone,
            audioFileName: audio.lastPathComponent,
            startedAt: now,
            endedAt: now,
            durationSeconds: 0,
            createdAt: now,
            updatedAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let currentData = try encoder.encode(metadata)
        try currentData.write(to: DurableFile.backupURL(for: metadataURL))
        let currentText = try #require(String(data: currentData, encoding: .utf8))
        let futureData = try #require(
            currentText
                .replacingOccurrences(of: "\"schemaVersion\":2", with: "\"schemaVersion\":999")
                .data(using: .utf8)
        )
        try futureData.write(to: metadataURL)

        #expect(try RecordingLibrary(folderURL: folder.url).loadRecordings().isEmpty)
        #expect(try Data(contentsOf: metadataURL) == futureData)
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent(".corrupt").path))
    }

    @Test func interruptedPublicationMovesSourceAndFinishesMetadata() throws {
        let folder = try TemporaryFolder()
        let id = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let key = RecordingLibrary.storageKey(for: id)
        let source = folder.url.appendingPathComponent("interrupted-capture.m4a")
        try Data("recoverable audio".utf8).write(to: source)
        let now = Date(timeIntervalSince1970: 200)
        let metadata = RecordingMetadata(
            id: id,
            storageKey: key,
            displayName: "Recovered publish",
            source: .microphone,
            audioFileName: "\(key).m4a",
            startedAt: now,
            endedAt: now.addingTimeInterval(10),
            durationSeconds: 10,
            createdAt: now,
            updatedAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadataObject = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(metadata)) as? [String: Any]
        )
        let journalData = try JSONSerialization.data(withJSONObject: [
            "metadata": metadataObject,
            "sourcePath": source.path
        ])
        let journalURL = folder.url.appendingPathComponent(".publish-\(id.uuidString).json")
        try journalData.write(to: journalURL)

        let loaded = try RecordingLibrary(folderURL: folder.url).loadRecordings()
        let recording = try #require(loaded.first)
        #expect(recording.id == id)
        #expect(try Data(contentsOf: recording.audioURL) == Data("recoverable audio".utf8))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }
}

@Suite("Recording title provenance")
struct RecordingTitleProvenanceTests {
    @Test func finishRecordingIsDefaultAndImportIsUser() throws {
        let folder = try TemporaryFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let recorded = try makeRecording(in: folder, library: library, name: "Meeting 2026-06-29 14.05")
        #expect(recorded.metadata.titleSource == .default)
        #expect(recorded.effectiveTitleSource == .default)

        let external = folder.url.appendingPathComponent("external-\(UUID().uuidString).m4a")
        try Data("imported".utf8).write(to: external)
        let imported = try library.importRecording(
            sourceURL: external,
            requestedName: "Customer Call",
            source: .microphone,
            startedAt: Date(timeIntervalSince1970: 50),
            durationSeconds: 30
        )
        #expect(imported.metadata.titleSource == .user)

        let reloaded = try library.loadRecordings()
        #expect(reloaded.first { $0.id == recorded.id }?.metadata.titleSource == .default)
        #expect(reloaded.first { $0.id == imported.id }?.metadata.titleSource == .user)
        let json = try String(contentsOf: recorded.metadataURL, encoding: .utf8)
        #expect(json.contains("\"titleSource\" : \"default\""))
    }

    @Test func metadataWithoutTitleSourceEncodesWithoutTheKey() throws {
        let now = Date(timeIntervalSince1970: 1)
        let metadata = RecordingMetadata(
            id: UUID(), storageKey: "recording-x", displayName: "Planning", source: .microphone,
            audioFileName: "recording-x.m4a", startedAt: now, endedAt: now, durationSeconds: 0,
            createdAt: now, updatedAt: now
        )
        let json = try #require(String(data: JSONEncoder().encode(metadata), encoding: .utf8))
        #expect(!json.contains("titleSource"))
        #expect(json.contains("\"schemaVersion\":2"))
    }

    @Test func staleSnapshotRenameAppliesOnTopOfOnDiskMetadata() throws {
        let folder = try TemporaryFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let stale = try makeRecording(in: folder, library: library, name: "Meeting 2026-06-29 14.05")

        // Another writer changes the on-disk metadata after `stale` was captured.
        var onDisk = try #require(library.loadRecordings().first).metadata
        onDisk.displayName = "Roadmap Review"
        onDisk.titleSource = .user
        onDisk.recoveryNote = "edited on disk"
        try writeMetadata(onDisk, to: stale.metadataURL)

        // Auto-title with the stale snapshot must not clobber the newer user title.
        #expect(try library.renameIfTitleIsDefault(stale, to: "Generated Title") == nil)
        #expect(try library.migrateIfNeeded(stale) == stale)
        var current = try #require(library.loadRecordings().first)
        #expect(current.displayName == "Roadmap Review")
        #expect(current.metadata.titleSource == .user)

        // An explicit rename from the stale snapshot keeps the other on-disk edits.
        let renamed = try library.rename(stale, to: "Roadmap Review v2", source: .user)
        current = try #require(library.loadRecordings().first)
        #expect(renamed.displayName == "Roadmap Review v2")
        #expect(current.displayName == "Roadmap Review v2")
        #expect(current.metadata.recoveryNote == "edited on disk")
        #expect(current.metadata.updatedAt >= onDisk.updatedAt)
    }

    @Test func renameIfTitleIsDefaultRenamesDefaultAndRefusesUserTitles() throws {
        let folder = try TemporaryFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let recording = try makeRecording(in: folder, library: library, name: "Meeting 2026-06-29 14.05")

        let generated = try #require(try library.renameIfTitleIsDefault(recording, to: "Q3 Budget Review"))
        #expect(generated.displayName == "Q3 Budget Review")
        #expect(generated.metadata.titleSource == .generated)
        #expect(try library.loadRecordings().first?.metadata.titleSource == .generated)
        // A generated title is not replaced again by a later auto-title.
        #expect(try library.renameIfTitleIsDefault(generated, to: "Something Else") == nil)

        let other = try makeRecording(in: folder, library: library, name: "Meeting 2026-06-30 09.00")
        let userRenamed = try library.rename(other, to: "Board Prep")
        #expect(userRenamed.metadata.titleSource == .user)
        #expect(try library.renameIfTitleIsDefault(userRenamed, to: "Generated Title") == nil)
        #expect(try library.loadRecordings().first { $0.id == other.id }?.displayName == "Board Prep")

        // Empty or default-looking generated names are no-ops.
        let third = try makeRecording(in: folder, library: library, name: "Meeting 2026-07-01 10.00")
        #expect(try library.renameIfTitleIsDefault(third, to: "  ") == nil)
        #expect(try library.renameIfTitleIsDefault(third, to: "Untitled Meeting") == nil)
        #expect(try library.loadRecordings().first { $0.id == third.id }?.metadata.titleSource == .default)
        // Generated names are cleaned before use.
        let cleaned = try library.renameIfTitleIsDefault(third, to: "Title: \"Pricing Workshop.\"")
        #expect(cleaned?.displayName == "Pricing Workshop")
    }

    @Test func renameToCurrentNameNeverAddsSuffix() throws {
        let folder = try TemporaryFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let recording = try makeRecording(in: folder, library: library, name: "Weekly Sync")

        let unchanged = try library.rename(recording, to: " Weekly  Sync ")
        #expect(unchanged.displayName == "Weekly Sync")
        // Confirming the current (default) name keeps its provenance, so
        // `rename(x, to: x.displayName)` can never block auto-title.
        #expect(unchanged.metadata.titleSource == .default)
        #expect(try library.rename(recording, to: "weekly sync").displayName == "weekly sync")

        // Stale snapshot ("Weekly Sync") renamed to its current on-disk name.
        let onDisk = try library.rename(recording, to: "Design Review")
        #expect(try library.rename(recording, to: "Design Review").displayName == "Design Review")
        #expect(try library.rename(onDisk, to: "Design Review").displayName == "Design Review")

        // Names still stay unique against other recordings.
        let second = try makeRecording(in: folder, library: library, name: "Standup")
        #expect(try library.rename(second, to: "design review").displayName == "design review 2")
    }

    @Test func legacyMetadataInfersTitleSourceAndCanBeAutoTitled() throws {
        let folder = try TemporaryFolder()
        for (index, name) in ["Meeting 2026-06-29 14.05", "Client Kickoff"].enumerated() {
            try Data("audio".utf8).write(to: folder.url.appendingPathComponent("\(name).m4a"))
            let legacy = """
            {
              "id" : "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA\(index)",
              "displayName" : "\(name)",
              "source" : "microphone",
              "audioFileName" : "\(name).m4a",
              "startedAt" : "1970-01-01T00:00:1\(index)Z",
              "endedAt" : "1970-01-01T00:00:20Z",
              "durationSeconds" : 10,
              "createdAt" : "1970-01-01T00:00:20Z",
              "updatedAt" : "1970-01-01T00:00:20Z"
            }
            """
            try legacy.write(to: folder.url.appendingPathComponent("\(name).json"), atomically: true, encoding: .utf8)
        }
        let library = RecordingLibrary(folderURL: folder.url)
        let loaded = try library.loadRecordings()
        let defaultNamed = try #require(loaded.first { $0.displayName == "Meeting 2026-06-29 14.05" })
        let userNamed = try #require(loaded.first { $0.displayName == "Client Kickoff" })
        #expect(defaultNamed.metadata.titleSource == nil)
        #expect(defaultNamed.effectiveTitleSource == .default)
        #expect(userNamed.metadata.titleSource == nil)
        #expect(userNamed.effectiveTitleSource == .user)

        #expect(try library.renameIfTitleIsDefault(userNamed, to: "Generated") == nil)
        #expect(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("Client Kickoff.json").path))
        let renamed = try #require(try library.renameIfTitleIsDefault(defaultNamed, to: "Pricing Workshop"))
        #expect(renamed.usesImmutableStorage)
        #expect(renamed.metadata.titleSource == .generated)
        #expect(try library.loadRecordings().contains { $0.id == defaultNamed.id && $0.displayName == "Pricing Workshop" })
    }

    @Test func migrateIfNeededMovesLegacyStorageWithoutRenaming() throws {
        let folder = try TemporaryFolder()
        try Data("audio".utf8).write(to: folder.url.appendingPathComponent("Legacy.m4a"))
        try """
        {
          "id" : "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
          "displayName" : "Legacy",
          "source" : "microphone",
          "audioFileName" : "Legacy.m4a",
          "startedAt" : "1970-01-01T00:00:10Z",
          "endedAt" : "1970-01-01T00:00:20Z",
          "durationSeconds" : 10,
          "createdAt" : "1970-01-01T00:00:20Z",
          "updatedAt" : "1970-01-01T00:00:20Z"
        }
        """.write(to: folder.url.appendingPathComponent("Legacy.json"), atomically: true, encoding: .utf8)
        let library = RecordingLibrary(folderURL: folder.url)
        let legacy = try #require(library.loadRecordings().first)

        let migrated = try library.migrateIfNeeded(legacy)
        #expect(migrated.usesImmutableStorage)
        #expect(migrated.displayName == "Legacy")
        #expect(FileManager.default.fileExists(atPath: migrated.audioURL.path))
        // A second call with the stale legacy snapshot returns the migrated item.
        let again = try library.migrateIfNeeded(legacy)
        #expect(again.metadata.storageKey == migrated.metadata.storageKey)
        #expect(again.audioURL == migrated.audioURL)
        #expect(again.displayName == "Legacy")
        #expect(try library.loadRecordings().map(\.displayName) == ["Legacy"])
    }

    @Test func renamingAMissingRecordingThrows() throws {
        let folder = try TemporaryFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let recording = try makeRecording(in: folder, library: library, name: "Meeting 2026-06-29 14.05")
        try library.delete(recording)
        #expect(throws: RecordingLibraryError.recordingNotFound(recording.id)) {
            try library.renameIfTitleIsDefault(recording, to: "Generated")
        }
    }

    private func makeRecording(in folder: TemporaryFolder, library: RecordingLibrary, name: String) throws -> RecordingItem {
        let source = folder.url.appendingPathComponent("capture-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: source)
        return try library.finishRecording(
            temporaryAudioURL: source,
            requestedName: name,
            source: .microphone,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20)
        )
    }

    @Test func segmentsSidecarsAreSkippedByNameButLegacyLookalikesStillLoad() throws {
        let folder = try TemporaryFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let source = folder.url.appendingPathComponent("capture.m4a")
        try Data("audio".utf8).write(to: source)
        let item = try library.finishRecording(
            temporaryAudioURL: source,
            requestedName: "Weekly Sync",
            source: .microphone,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20)
        )
        _ = try library.writeTranscriptBundle(
            "Speaker 1: Hi",
            segments: [TranscriptSegment(speaker: "Speaker 1", startTime: 0, endTime: 1, text: "Hi")],
            for: item
        )
        // A legacy recording whose own name ends in ".transcript.segments" has no
        // "<base>.json" sibling, so its metadata is still decoded.
        let legacyName = "Notes.transcript.segments"
        try Data("audio".utf8).write(to: folder.url.appendingPathComponent("\(legacyName).m4a"))
        let legacy = """
        {
          "id" : "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
          "displayName" : "\(legacyName)",
          "source" : "microphone",
          "audioFileName" : "\(legacyName).m4a",
          "startedAt" : "1970-01-01T00:00:05Z",
          "endedAt" : "1970-01-01T00:00:06Z",
          "durationSeconds" : 1,
          "createdAt" : "1970-01-01T00:00:06Z",
          "updatedAt" : "1970-01-01T00:00:06Z"
        }
        """
        try legacy.write(to: folder.url.appendingPathComponent("\(legacyName).json"), atomically: true, encoding: .utf8)
        // Unknown JSON is still ignored.
        try Data("[1, 2]".utf8).write(to: folder.url.appendingPathComponent("stray.json"))

        let loaded = try library.loadRecordings()
        #expect(loaded.map(\.displayName) == ["Weekly Sync", legacyName])
        #expect(RecordingLibrary.isSegmentsSidecar(item.transcriptSegmentsURL.lastPathComponent, among: [item.metadataURL.lastPathComponent]))
        #expect(!RecordingLibrary.isSegmentsSidecar("\(legacyName).json", among: ["\(legacyName).json"]))
        #expect(!RecordingLibrary.isSegmentsSidecar(".transcript.segments.json", among: [".json"]))
    }

    @Test func finishRecordingStillRejectsAnExistingIDAndDeduplicatesNames() throws {
        let folder = try TemporaryFolder()
        let library = RecordingLibrary(folderURL: folder.url)
        let first = folder.url.appendingPathComponent("a.m4a")
        let second = folder.url.appendingPathComponent("b.m4a")
        let third = folder.url.appendingPathComponent("c.m4a")
        for url in [first, second, third] { try Data("audio".utf8).write(to: url) }
        let item = try library.finishRecording(
            temporaryAudioURL: first, requestedName: "Sync", source: .microphone,
            startedAt: Date(timeIntervalSince1970: 10), endedAt: Date(timeIntervalSince1970: 20)
        )
        let again = try library.finishRecording(
            temporaryAudioURL: second, requestedName: "sync", source: .microphone,
            startedAt: Date(timeIntervalSince1970: 30), endedAt: Date(timeIntervalSince1970: 40)
        )
        #expect(again.displayName == "sync 2")
        #expect(throws: RecordingLibraryError.duplicateRecordingID(item.id)) {
            try library.finishRecording(
                temporaryAudioURL: third, requestedName: "Other", source: .microphone,
                startedAt: Date(timeIntervalSince1970: 50), endedAt: Date(timeIntervalSince1970: 60),
                recordingID: item.id
            )
        }
        #expect(FileManager.default.fileExists(atPath: third.path))
    }

    private func writeMetadata(_ metadata: RecordingMetadata, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try DurableFile.write(metadata, to: url, encoder: encoder)
    }
}

private final class TemporaryFolder: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
