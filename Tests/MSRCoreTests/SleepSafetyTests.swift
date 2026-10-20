import Foundation
import AVFoundation
import Testing
@testable import MSRServices

@Suite("Sleep safety")
struct SleepSafetyTests {
    @Test func acknowledgementDeadlineActuallyReleasesWithoutCompletion() async {
        let counter = LockedCounter()
        let ack = SleepAcknowledgement { counter.increment() }
        ack.completeAfter(0.02, on: DispatchQueue(label: "test.deadline"))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(counter.value == 1)
        ack.complete()
        #expect(counter.value == 1)
    }

    @Test(arguments: [false, true]) func systemSinkWritesPlanarAndInterleavedPCM(interleaved: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("system.caf")
        let sink = DurableSystemAudioSink(url: url)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved))
        for index in 0..<10 {
            // A 100ms PTS gap between chunks 4/5 must remain silence, not vanish.
            let offset = index >= 5 ? 4_800 : 0
            try sink.append(makeSample(format: format, frames: 4_800, position: index * 4_800 + offset))
        }
        sink.close()
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 52_800)
        #expect(file.processingFormat.channelCount == 2)
        let output = folder.appendingPathComponent("export.m4a")
        try await AudioTrackMixer.mixToSingleM4A(inputs: [url], outputURL: output)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 1.1) < 0.05)
    }
    @Test func acknowledgementIsExactlyOnceUnderConcurrentCompletion() async {
        let counter = LockedCounter()
        let acknowledgement = SleepAcknowledgement { counter.increment() }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask { acknowledgement.complete() } }
        }
        #expect(counter.value == 1)
    }

    @Test func acknowledgementDeinitReleasesOutstandingToken() {
        let counter = LockedCounter()
        var acknowledgement: SleepAcknowledgement? = SleepAcknowledgement { counter.increment() }
        #expect(acknowledgement != nil)
        acknowledgement = nil
        #expect(counter.value == 1)
    }

    @Test @MainActor func sleepDuringStartWaitsThenFinalizesEvenAfterWake() async {
        let coordinator = RecordingActionCoordinator()
        let transition = AsyncLatch()
        var events: [String] = []
        let starting = Task { @MainActor in
            await coordinator.perform {
                events.append("starting")
                await transition.wait()
                events.append("capturing")
            }
        }
        while !coordinator.actionInFlight { await Task.yield() }
        let sleeping = Task { @MainActor in
            await coordinator.prepareForSleep { events.append("saved") }
        }
        while !coordinator.sleepPending { await Task.yield() }
        coordinator.didWake()
        await coordinator.perform { events.append("unexpected start") }
        transition.open()
        await starting.value
        await sleeping.value
        #expect(events == ["starting", "capturing", "saved"])
        #expect(!coordinator.sleepPending)
        await coordinator.perform { events.append("new start") }
        #expect(events.last == "new start")
    }

    @Test @MainActor func repeatedSleepWaitsForSameFinalizationAndBlocksStartsUntilWake() async {
        let coordinator = RecordingActionCoordinator()
        let finalization = AsyncLatch()
        var saves = 0
        let first = Task { @MainActor in
            await coordinator.prepareForSleep {
                saves += 1
                await finalization.wait()
            }
        }
        while !coordinator.actionInFlight { await Task.yield() }
        var secondCompleted = false
        let second = Task { @MainActor in
            await coordinator.prepareForSleep { saves += 1 }
            secondCompleted = true
        }
        await Task.yield()
        #expect(!secondCompleted)
        finalization.open()
        await first.value
        await second.value
        #expect(saves == 1)
        await coordinator.perform { saves += 100 }
        #expect(saves == 1)
        coordinator.didWake()
        await coordinator.perform { saves += 1 }
        #expect(saves == 2)
    }
}

private func makeSample(format: AVAudioFormat, frames: AVAudioFrameCount, position: Int) throws -> CMSampleBuffer {
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    pcm.frameLength = frames
    for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        for index in 0..<(Int(buffer.mDataByteSize) / 4) { data[index] = 0.15 }
    }
    var description: CMAudioFormatDescription?
    #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &description) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: CMTime(value: Int64(position), timescale: 48_000), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
        sampleCount: Int(frames), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
    let result = try #require(sample)
    #expect(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
    #expect(CMSampleBufferSetDataReady(result) == noErr)
    return result
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

@MainActor private final class AsyncLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
