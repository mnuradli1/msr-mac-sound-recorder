import Foundation
import Testing
@testable import MSRMeetingRecorder

@Suite("Soak scenario helpers")
@MainActor
struct SoakScenarioTests {
    @Test func residentSizeIsReported() {
        let megabytes = UIScenarioRunner.residentMegabytes()
        #expect(megabytes > 1)
        #expect(megabytes < 1_000_000)
    }

    @Test func footprintIsReported() {
        let memory = UIScenarioRunner.memoryMegabytes()
        #expect(memory.footprint > 1)
        #expect(memory.footprint < 1_000_000)
        #expect(memory.resident > 1)
    }

    @Test func leftoversCoverSetAsideFilesAndAtomicWriteTemporaries() throws {
        let folder = try HardeningTestFolder()
        let start = Date().addingTimeInterval(-1)
        let fileManager = FileManager.default
        let failed = folder.url.appendingPathComponent("recovery-failed", isDirectory: true)
        let corrupt = folder.url.appendingPathComponent(".corrupt", isDirectory: true)
        try fileManager.createDirectory(at: failed, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let uuid = UUID().uuidString
        try Data("x".utf8).write(to: failed.appendingPathComponent("segment-1.m4a"))
        try Data("x".utf8).write(to: corrupt.appendingPathComponent("a.json.1.\(uuid).corrupt"))
        try Data("x".utf8).write(to: folder.url.appendingPathComponent(".recording-5.json.\(uuid).tmp"))
        try Data("x".utf8).write(to: folder.url.appendingPathComponent(".hidden.tmp"))
        let found = Set(UIScenarioRunner.soakLeftovers(folder: folder.url, since: start))
        #expect(found.contains("recovery-failed/segment-1.m4a"))
        #expect(found.contains(".corrupt/a.json.1.\(uuid).corrupt"))
        #expect(found.contains(".recording-5.json.\(uuid).tmp"))
        #expect(!found.contains(".hidden.tmp"))
        #expect(UIScenarioRunner.isAtomicWriteTemporary(".x.waveform.\(uuid).tmp"))
        #expect(!UIScenarioRunner.isAtomicWriteTemporary("x.\(uuid).tmp"))
    }

    @Test func tmpAndPrivateTmpAreScannedOnce() throws {
        #expect(UIScenarioRunner.canonicalPath("/tmp") == UIScenarioRunner.canonicalPath("/private/tmp"))
        let name = "msr-upload-soak-dedupe-\(UUID().uuidString).multipart"
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let empty = try HardeningTestFolder()
        let found = UIScenarioRunner.soakLeftovers(folder: empty.url, since: Date().addingTimeInterval(-60))
        #expect(found.filter { $0 == name }.count == 1)
    }

    @Test func libraryFilesMustGrowByTheSameCountEachCycle() {
        #expect(UIScenarioRunner.soakFileDeltaMismatch([]) == nil)
        #expect(UIScenarioRunner.soakFileDeltaMismatch([3, 3, 4, 2, 3]) == nil)
        #expect(UIScenarioRunner.soakFileDeltaMismatch([3, 3, 5])?.contains("cycle 3: 5") == true)
        #expect(UIScenarioRunner.soakFileDeltaMismatch([0, 0]) != nil)
    }

    @Test func leftoversCoverCaptureTemporariesAndManifests() throws {
        let folder = try HardeningTestFolder()
        let start = Date().addingTimeInterval(-1)
        let names = [".in-progress-microphone-1.m4a", ".final-2.m4a", ".session-3.json", "recording-4.m4a", "recording-4.json"]
        for name in names {
            try Data("x".utf8).write(to: folder.url.appendingPathComponent(name))
        }
        let found = Set(UIScenarioRunner.soakLeftovers(folder: folder.url, since: start))
        #expect(found.contains(".in-progress-microphone-1.m4a"))
        #expect(found.contains(".final-2.m4a"))
        #expect(found.contains(".session-3.json"))
        #expect(!found.contains("recording-4.m4a"))
        #expect(!found.contains("recording-4.json"))
    }

    @Test func temporaryUploadsCountOnlySinceTheSoakStarted() throws {
        let name = "msr-upload-soak-test-\(UUID().uuidString).multipart"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let empty = try HardeningTestFolder()
        #expect(UIScenarioRunner.soakLeftovers(folder: empty.url, since: Date().addingTimeInterval(-60)).contains(name))
        #expect(!UIScenarioRunner.soakLeftovers(folder: empty.url, since: Date().addingTimeInterval(60)).contains(name))
    }
}
