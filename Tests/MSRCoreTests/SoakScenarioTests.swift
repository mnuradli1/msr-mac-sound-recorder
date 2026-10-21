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
