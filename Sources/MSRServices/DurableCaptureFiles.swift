import AVFoundation
import Foundation
import MSRCore

/// Deterministic names let recovery find PCM even if capture startup never returned.
public enum DurableCaptureFiles {
    public static func rawURL(for output: URL, channel: AudioSignalChannel) -> URL {
        output.deletingLastPathComponent().appendingPathComponent(
            output.lastPathComponent + (channel == .microphone ? ".mic.caf" : ".system.caf"))
    }

    public static func rawURLs(for output: URL, source: AudioSource) -> [URL] {
        switch source {
        case .microphone: [rawURL(for: output, channel: .microphone)]
        case .system: [rawURL(for: output, channel: .system)]
        case .micAndSystem: [rawURL(for: output, channel: .system), rawURL(for: output, channel: .microphone)]
        }
    }

    @discardableResult
    public static func restoreSegmentIfNeeded(output: URL, source: AudioSource) async throws -> Bool {
        let raw = rawURLs(for: output, source: source).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !raw.isEmpty else { return false }
        var readable: [URL] = []
        for url in raw where await isReadable(url) { readable.append(url) }
        guard !readable.isEmpty else { return false }
        // Export can be interrupted too; reconstruct from retained PCM rather than
        // mistaking the mere existence of an incomplete M4A for a saved segment.
        try await AudioTrackMixer.mixToSingleM4A(inputs: readable, outputURL: output)
        return readable.count < rawURLs(for: output, source: source).count
    }

    public static func removeRawFiles(for output: URL, source: AudioSource) {
        for raw in rawURLs(for: output, source: source) { try? FileManager.default.removeItem(at: raw) }
    }

    /// Damaged sources not represented in the publication remain available for
    /// forensic/manual recovery; cleanup must never erase those only copies.
    public static func removeReadableRawFiles(for output: URL, source: AudioSource) async -> [String] {
        var retained: [String] = []
        for raw in rawURLs(for: output, source: source) where FileManager.default.fileExists(atPath: raw.path) {
            if await isReadable(raw) { try? FileManager.default.removeItem(at: raw) }
            else { retained.append(raw.lastPathComponent) }
        }
        return retained
    }

    private static func isReadable(_ url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let duration = try? await asset.load(.duration).seconds else { return false }
        return duration.isFinite && duration > 0
    }
}

/// A queue-confined PCM CAF writer: no end-of-recording `moov` atom is required.
final class DurableSystemAudioSink {
    private var file: AVAudioFile?
    let url: URL
    private var origin: CMTime?
    private var framesWritten: Int64 = 0
    init(url: URL) { self.url = url }

    func append(_ sample: CMSampleBuffer) throws {
        guard let description = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else {
            throw RecordingError.writerFailed("System audio PCM format was unavailable.")
        }
        var needed = 0
        var queryBlock: CMBlockBuffer?
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,
            bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: &queryBlock)
        guard needed >= MemoryLayout<AudioBufferList>.size else {
            throw RecordingError.writerFailed("System audio buffer list size was invalid.")
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: needed)
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,
            bufferListSizeNeededOut: nil, bufferListOut: list,
            bufferListSize: needed,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: &block)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard status == noErr else {
            throw RecordingError.writerFailed("System audio buffer extraction failed (\(status)).")
        }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else {
            throw RecordingError.writerFailed("System audio PCM buffer was unavailable.")
        }
        pcm.frameLength = AVAudioFrameCount(sample.numSamples)
        let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        guard destination.count == buffers.count else {
            throw RecordingError.writerFailed("System audio PCM channel layout changed.")
        }
        for index in 0..<destination.count {
            guard let source = buffers[index].mData, let target = destination[index].mData,
                  buffers[index].mDataByteSize >= destination[index].mDataByteSize else {
                throw RecordingError.writerFailed("System audio PCM data was incomplete.")
            }
            memcpy(target, source, Int(destination[index].mDataByteSize))
        }
        if file == nil {
            file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        }
        if origin == nil { origin = sample.presentationTimeStamp }
        if let origin {
            let elapsed = (sample.presentationTimeStamp - origin).seconds
            guard elapsed.isFinite, elapsed >= 0, elapsed < 7 * 24 * 60 * 60 else {
                throw RecordingError.writerFailed("System audio timestamp was invalid.")
            }
            let expected = Int64(elapsed * format.sampleRate)
            var missing = expected - framesWritten
            guard missing <= Int64(format.sampleRate * 30) else {
                throw RecordingError.writerFailed("System audio gap exceeded 30 seconds; capture was stopped and PCM preserved.")
            }
            while missing > Int64(format.sampleRate * 0.02) {
                let count = AVAudioFrameCount(min(missing, 4_800))
                guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { break }
                silence.frameLength = count
                for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                try file?.write(from: silence)
                framesWritten += Int64(count)
                missing -= Int64(count)
            }
        }
        try file?.write(from: pcm)
        framesWritten += Int64(pcm.frameLength)
        // Keep retained sample storage alive through the synchronous file write.
        withExtendedLifetime(block) {}
    }

    func close() { file = nil }
}
