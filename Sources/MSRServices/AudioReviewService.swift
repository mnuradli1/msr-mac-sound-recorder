import Accelerate
import AVFoundation
import Foundation
import MSRCore

public struct PreparedTranscriptionAudio: Sendable {
    public var url: URL
    public var usedUncompressedFallback: Bool
    public var warning: String?
    public var isTemporary: Bool

    public init(url: URL, usedUncompressedFallback: Bool = false, warning: String? = nil, isTemporary: Bool = false) {
        self.url = url
        self.usedUncompressedFallback = usedUncompressedFallback
        self.warning = warning
        self.isTemporary = isTemporary
    }

    public func cleanUp() {
        if isTemporary { try? FileManager.default.removeItem(at: url) }
    }
}

public enum AudioReviewError: Error, LocalizedError {
    case noAudioTrack
    case exportUnavailable
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: "No readable audio track was found."
        case .exportUnavailable: "This audio cannot be exported on this Mac."
        case let .exportFailed(message): "Audio export failed: \(message)"
        }
    }
}

public enum TranscriptionAudioPreparer {
    public static func prepare(
        sourceURL: URL,
        durationSeconds: TimeInterval,
        trimRange: AudioTrimRange?,
        compressionEnabled: Bool
    ) async throws -> PreparedTranscriptionAudio {
        let normalizedTrim = trimRange?.normalized(for: durationSeconds)
        let needsTrim = normalizedTrim.map { $0.startSeconds > 0.01 || $0.endSeconds < durationSeconds - 0.1 } ?? false
        let needsCompression = compressionEnabled && !["m4a", "mp3"].contains(sourceURL.pathExtension.lowercased())
        guard needsTrim || needsCompression else { return PreparedTranscriptionAudio(url: sourceURL) }

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("msr-prepared-\(UUID().uuidString).m4a")
        do {
            if needsCompression {
                try await compressTo96KbpsM4A(
                    sourceURL: sourceURL,
                    destinationURL: output,
                    trimRange: needsTrim ? normalizedTrim : nil
                )
            } else {
                try await export(sourceURL: sourceURL, destinationURL: output, trimRange: needsTrim ? normalizedTrim : nil)
            }
            return PreparedTranscriptionAudio(url: output, isTemporary: true)
        } catch {
            try? FileManager.default.removeItem(at: output)
            // A cancelled job must stop here rather than fall back to uploading the original audio.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if needsTrim { throw error }
            return PreparedTranscriptionAudio(
                url: sourceURL,
                usedUncompressedFallback: true,
                warning: "Upload compression failed; the original audio will be uploaded."
            )
        }
    }

    public static func saveTrimmedCopy(sourceURL: URL, destinationURL: URL, range: AudioTrimRange) async throws {
        try await export(sourceURL: sourceURL, destinationURL: destinationURL, trimRange: range)
    }

    private static func export(sourceURL: URL, destinationURL: URL, trimRange: AudioTrimRange?) async throws {
        try? FileManager.default.removeItem(at: destinationURL)
        let asset = AVURLAsset(url: sourceURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioReviewError.exportUnavailable
        }
        exporter.outputURL = destinationURL
        exporter.outputFileType = .m4a
        if let trimRange {
            exporter.timeRange = CMTimeRange(
                start: CMTime(seconds: trimRange.startSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: trimRange.duration, preferredTimescale: 600)
            )
        }
        await exporter.export()
        guard exporter.status == .completed else {
            throw AudioReviewError.exportFailed(exporter.error?.localizedDescription ?? "Unknown export error")
        }
    }

    private static func compressTo96KbpsM4A(
        sourceURL: URL,
        destinationURL: URL,
        trimRange: AudioTrimRange?
    ) async throws {
        try? FileManager.default.removeItem(at: destinationURL)
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioReviewError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        if let trimRange {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: trimRange.startSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: trimRange.duration, preferredTimescale: 600)
            )
        }
        let formatDescriptions = try await track.load(.formatDescriptions)
        let stream = formatDescriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        // The AAC encoder rejects 96 kbps below ~44.1 kHz ("Cannot Encode Media"), so low-rate sources
        // (16/22.05 kHz phone or conferencing exports) are resampled by the reader before encoding.
        let sourceRate = stream?.mSampleRate ?? 44_100
        let sampleRate = sourceRate < 44_100 ? 44_100 : min(48_000, sourceRate)
        let channels = max(1, min(2, Int(stream?.mChannelsPerFrame ?? 1)))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw AudioReviewError.exportUnavailable }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 96_000
        ])
        guard writer.canAdd(input) else { throw AudioReviewError.exportUnavailable }
        writer.add(input)
        guard writer.startWriting(), reader.startReading() else {
            throw AudioReviewError.exportFailed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "Could not start audio preparation")
        }
        writer.startSession(atSourceTime: reader.timeRange.start)
        let session = AudioCompressionSession(reader: reader, writer: writer, input: input, output: output)

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    session.install(continuation)
                    // `onCancel` can run before this closure when the task is already
                    // cancelled; asking a cancelled writer input for media data throws
                    // an NSException, so stop here instead.
                    guard !session.isFinished, session.writer.status == .writing else {
                        session.cancelReaderAndWriter()
                        session.finish(throwing: CancellationError())
                        return
                    }
                    let queue = DispatchQueue(label: "app.msr.audio-compression")
                    session.input.requestMediaDataWhenReady(on: queue) {
                        while session.input.isReadyForMoreMediaData, !session.isFinished {
                            if let sample = session.output.copyNextSampleBuffer() {
                                if !session.input.append(sample) {
                                    session.cancelReaderAndWriter()
                                    session.finish(throwing: AudioReviewError.exportFailed(session.writer.error?.localizedDescription ?? "Could not encode audio"))
                                    return
                                }
                                continue
                            }
                            // `nil` means end of data *or* a reader failure/cancellation; only the former may be published.
                            switch session.reader.status {
                            case .failed:
                                session.cancelReaderAndWriter()
                                session.finish(throwing: session.reader.error ?? CocoaError(.fileReadCorruptFile))
                            case .cancelled:
                                session.cancelReaderAndWriter()
                                session.finish(throwing: CancellationError())
                            default:
                                guard session.writer.status == .writing else {
                                    session.finish(throwing: AudioReviewError.exportFailed(session.writer.error?.localizedDescription ?? "Audio preparation was cancelled"))
                                    return
                                }
                                session.input.markAsFinished()
                                session.writer.finishWriting {
                                    if session.writer.status == .completed {
                                        session.finish(throwing: nil)
                                    } else {
                                        session.finish(throwing: AudioReviewError.exportFailed(session.writer.error?.localizedDescription ?? session.reader.error?.localizedDescription ?? "Audio preparation did not complete"))
                                    }
                                }
                            }
                            return
                        }
                    }
                }
            } onCancel: {
                session.cancelReaderAndWriter()
                // A cancelled writer may never ask for more data again, so resume the waiter here.
                session.finish(throwing: CancellationError())
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }
}

private final class AudioCompressionSession: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let output: AVAssetReaderTrackOutput
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    init(reader: AVAssetReader, writer: AVAssetWriter, input: AVAssetWriterInput, output: AVAssetReaderTrackOutput) {
        self.reader = reader
        self.writer = writer
        self.input = input
        self.output = output
    }

    var isFinished: Bool { lock.withLock { finished } }

    /// Cancels whichever side is still active; never touches a writer that already completed or failed.
    func cancelReaderAndWriter() {
        if reader.status == .reading { reader.cancelReading() }
        if writer.status == .writing { writer.cancelWriting() }
    }

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let alreadyFinished = lock.withLock {
            self.continuation = continuation
            return finished
        }
        // Cancellation can win the race before the continuation exists.
        if alreadyFinished { finish(throwing: CancellationError(), force: true) }
    }

    /// Resumes the waiter exactly once; later calls are ignored.
    func finish(throwing error: Error?, force: Bool = false) {
        let waiter: CheckedContinuation<Void, Error>? = lock.withLock {
            guard force || !finished else { return nil }
            finished = true
            let waiter = continuation
            continuation = nil
            return waiter
        }
        guard let waiter else { return }
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
    }
}

public actor WaveformAnalyzer {
    private var cache: [String: [Float]] = [:]
    private var order: [String] = []
    private let capacity: Int

    public init(capacity: Int = 64) { self.capacity = max(1, capacity) }

    public func samples(for url: URL, bucketCount: Int = 96) async throws -> [Float] {
        let key = "\(url.path)#\(bucketCount)"
        if let cached = cache[key] { return cached }
        let result = try await Self.analyze(url: url, bucketCount: bucketCount)
        cache[key] = result
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        return result
    }

    public func clear() {
        cache.removeAll()
        order.removeAll()
    }

    private static func analyze(url: URL, bucketCount: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioReviewError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw AudioReviewError.noAudioTrack }
        reader.add(output)
        guard reader.startReading() else { throw AudioReviewError.noAudioTrack }

        var peaks: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { bytes in
                if let address = bytes.baseAddress {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: address)
                }
            }
            let localPeak: Float = data.withUnsafeBytes { bytes in
                let floats = bytes.bindMemory(to: Float.self)
                guard !floats.isEmpty else { return 0 }
                var value: Float = 0
                vDSP_maxmgv(Array(floats), 1, &value, vDSP_Length(floats.count))
                return min(1, value)
            }
            peaks.append(localPeak)
        }
        guard !peaks.isEmpty else { return Array(repeating: 0, count: bucketCount) }
        return (0..<bucketCount).map { bucket in
            let start = bucket * peaks.count / bucketCount
            let end = max(start + 1, (bucket + 1) * peaks.count / bucketCount)
            return peaks[start..<min(end, peaks.count)].max() ?? 0
        }
    }
}
