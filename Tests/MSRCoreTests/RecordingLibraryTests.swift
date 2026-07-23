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

private final class TemporaryFolder: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
