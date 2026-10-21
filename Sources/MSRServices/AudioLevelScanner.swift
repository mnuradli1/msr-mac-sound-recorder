import Accelerate
import AVFoundation
import Foundation

/// Decodes an audio file once and measures it: the overall peak and sum of
/// squares (samples clipped to [-1, 1], all channels) for
/// `RecordingConfidenceAnalyzer`, and per-bucket peaks for the review
/// waveform (`WaveformAnalyzer`), in the same pass.
///
/// Decoding is the whole cost (about 1.3 s per hour of 48 kHz stereo AAC on
/// one core), so long files are split into frame ranges decoded in parallel,
/// each by its own `AVAudioFile` (ExtAudioFile seeks sample-accurately in AAC,
/// WAV, CAF and AIFF). `AVAssetReader` was measured as the alternative: it
/// does not run concurrently within a process (8 readers took as long as one),
/// and asking it for 8 kHz output saves only about 25 %, because the AAC
/// decoder still runs at the source rate.
public enum AudioLevelScanner {
    public struct Levels: Equatable, Sendable {
        /// Frames in the file (`AVAudioFile.length`).
        public var frameCount: Int64
        public var sampleRate: Double
        public var channelCount: Int
        /// Largest sample magnitude, at most 1.
        public var peak: Float
        /// Sum of squares of the clipped samples of every channel.
        public var sumOfSquares: Double
        /// Samples measured (frames × channels).
        public var sampleCount: Int64
        /// Peak magnitude per bucket (empty when no buckets were requested).
        public var buckets: [Float]

        public var durationSeconds: TimeInterval {
            sampleRate > 0 ? Double(frameCount) / sampleRate : 0
        }

        /// Root mean square over all measured samples, at most 1.
        public var rms: Float {
            sampleCount == 0 ? 0 : Float(min(1, (sumOfSquares / Double(sampleCount)).squareRoot()))
        }
    }

    /// Files shorter than this decode on one thread.
    static let parallelThresholdSeconds: Double = 60
    static let chunkFrames: AVAudioFrameCount = 32_768

    /// Scans `url`. `bucketCount` waveform peaks are returned in `buckets`
    /// (0 for none). `maxParallelism` caps the decode threads (the default is
    /// the active core count, at most 8). Cancelling the calling task stops
    /// the decode within one chunk and throws `CancellationError`.
    public static func scan(
        url: URL,
        bucketCount: Int,
        maxParallelism: Int = min(8, ProcessInfo.processInfo.activeProcessorCount)
    ) async throws -> Levels {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let length = file.length
        let channels = Int(format.channelCount)
        let buckets = max(0, bucketCount)
        guard length > 0, channels > 0 else {
            return Levels(
                frameCount: max(0, length), sampleRate: format.sampleRate, channelCount: channels,
                peak: 0, sumOfSquares: 0, sampleCount: 0, buckets: Array(repeating: 0, count: buckets)
            )
        }
        let seekable = ["m4a", "mp4", "aac", "caf", "wav", "wave", "aif", "aiff"].contains(url.pathExtension.lowercased())
        let seconds = format.sampleRate > 0 ? Double(length) / format.sampleRate : 0
        let parts = seekable && seconds >= parallelThresholdSeconds
            ? max(1, min(maxParallelism, Int(seconds / 30)))
            : 1
        let job = ScanJob(url: url, length: length, channels: channels, bucketCount: buckets, parts: parts)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    if parts == 1 {
                        job.run(part: 0)
                    } else {
                        DispatchQueue.concurrentPerform(iterations: parts) { job.run(part: $0) }
                    }
                    if let error = job.failure {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            job.cancel()
        }
        return job.levels(sampleRate: format.sampleRate)
    }
}

/// One scan's shared state: each part writes only its own slot.
private final class ScanJob: @unchecked Sendable {
    struct Partial {
        var peak: Float = 0
        var sumOfSquares: Double = 0
        var sampleCount: Int64 = 0
        var buckets: [Float]
    }

    let url: URL
    let length: Int64
    let channels: Int
    let bucketCount: Int
    let parts: Int
    private var partials: [Partial]
    private let lock = NSLock()
    private var cancelled = false
    private var error: Error?

    init(url: URL, length: Int64, channels: Int, bucketCount: Int, parts: Int) {
        self.url = url
        self.length = length
        self.channels = channels
        self.bucketCount = bucketCount
        self.parts = parts
        partials = Array(repeating: Partial(buckets: Array(repeating: 0, count: bucketCount)), count: parts)
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
    var failure: Error? { lock.withLock { cancelled ? CancellationError() : error } }

    func cancel() { lock.withLock { cancelled = true } }

    private func fail(_ failure: Error) {
        lock.withLock { if error == nil { error = failure } }
    }

    /// First frame of `bucket`: frame `f` belongs to bucket `f * bucketCount / length`.
    private func bucketStart(_ bucket: Int) -> Int64 {
        (Int64(bucket) * length + Int64(bucketCount) - 1) / Int64(bucketCount)
    }

    /// Decodes frames `[start, end)` of part `part` with its own `AVAudioFile`.
    func run(part: Int) {
        let start = length * Int64(part) / Int64(parts)
        let end = length * Int64(part + 1) / Int64(parts)
        var partial = Partial(buckets: Array(repeating: 0, count: bucketCount))
        do {
            let file = try AVAudioFile(forReading: url)
            if file.framePosition != start { file.framePosition = start }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AudioLevelScanner.chunkFrames) else {
                throw AudioReviewError.noAudioTrack
            }
            var scratch = [Float](repeating: 0, count: Int(AudioLevelScanner.chunkFrames))
            var position = start
            var lower: Float = -1
            var upper: Float = 1
            while position < end {
                if isCancelled { return }
                let wanted = AVAudioFrameCount(min(Int64(AudioLevelScanner.chunkFrames), end - position))
                try file.read(into: buffer, frameCount: wanted)
                let frames = Int(buffer.frameLength)
                guard frames > 0, let data = buffer.floatChannelData else { break }
                for channel in 0..<channels {
                    let samples = data[channel]
                    scratch.withUnsafeMutableBufferPointer { clipped in
                        guard let clipped = clipped.baseAddress else { return }
                        vDSP_vclip(samples, 1, &lower, &upper, clipped, 1, vDSP_Length(frames))
                        var peak: Float = 0
                        var squares: Float = 0
                        vDSP_maxmgv(clipped, 1, &peak, vDSP_Length(frames))
                        vDSP_svesq(clipped, 1, &squares, vDSP_Length(frames))
                        partial.peak = max(partial.peak, peak)
                        partial.sumOfSquares += Double(squares)
                        guard bucketCount > 0 else { return }
                        // Split the chunk at bucket boundaries.
                        var offset = 0
                        while offset < frames {
                            let frame = position + Int64(offset)
                            let bucket = min(bucketCount - 1, Int(frame * Int64(bucketCount) / length))
                            let next = bucket + 1 < bucketCount ? bucketStart(bucket + 1) : end
                            let count = max(1, min(frames - offset, Int(next - frame)))
                            var bucketPeak: Float = 0
                            vDSP_maxmgv(clipped + offset, 1, &bucketPeak, vDSP_Length(count))
                            partial.buckets[bucket] = max(partial.buckets[bucket], bucketPeak)
                            offset += count
                        }
                    }
                }
                partial.sampleCount += Int64(frames * channels)
                position += Int64(frames)
            }
        } catch {
            fail(error)
            return
        }
        lock.withLock { partials[part] = partial }
    }

    func levels(sampleRate: Double) -> AudioLevelScanner.Levels {
        lock.withLock {
            var buckets = Array(repeating: Float(0), count: bucketCount)
            for partial in partials {
                for index in 0..<bucketCount { buckets[index] = max(buckets[index], partial.buckets[index]) }
            }
            return AudioLevelScanner.Levels(
                frameCount: length,
                sampleRate: sampleRate,
                channelCount: channels,
                peak: partials.map(\.peak).max() ?? 0,
                sumOfSquares: partials.reduce(0) { $0 + $1.sumOfSquares },
                sampleCount: partials.reduce(0) { $0 + $1.sampleCount },
                buckets: buckets
            )
        }
    }
}
