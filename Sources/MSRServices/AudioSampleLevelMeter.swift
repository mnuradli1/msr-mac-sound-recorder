import CoreMedia
import Foundation

public enum AudioSignalChannel: Equatable, Sendable {
    case microphone
    case system
}

public enum AudioSampleLevelMeter {
    public static func normalizedLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return 0
        }

        if let level = normalizedAudioBufferListLevel(from: sampleBuffer, streamDescription: streamDescription) {
            return level
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return 0
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return 0 }

        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
        }
        guard status == kCMBlockBufferNoErr else {
            return 0
        }

        return normalizedPCMLevel(data, streamDescription: streamDescription)
    }

    public static func normalizedInt16PCMLevel(_ data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }

        var sumOfSquares = 0.0
        for offset in stride(from: 0, to: sampleCount * MemoryLayout<Int16>.size, by: MemoryLayout<Int16>.size) {
            let low = UInt16(data[offset])
            let high = UInt16(data[offset + 1]) << 8
            let sample = Int16(bitPattern: low | high)
            let normalized = max(-1.0, Double(sample) / Double(Int16.max))
            sumOfSquares += normalized * normalized
        }
        return Float(min(1.0, sqrt(sumOfSquares / Double(sampleCount))))
    }

    public static func normalizedFloat32PCMLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        let sumOfSquares = samples.reduce(0.0) { partialResult, sample in
            let normalized = min(1.0, max(-1.0, Double(sample)))
            return partialResult + normalized * normalized
        }
        return Float(min(1.0, sqrt(sumOfSquares / Double(samples.count))))
    }

    private static func normalizedFloat32PCMLevel(_ data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Float32>.size
        guard sampleCount > 0 else { return 0 }

        var samples: [Float] = []
        samples.reserveCapacity(sampleCount)
        for offset in stride(from: 0, to: sampleCount * MemoryLayout<Float32>.size, by: MemoryLayout<Float32>.size) {
            let bits = data.withUnsafeBytes { bytes in
                bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            samples.append(Float(bitPattern: UInt32(littleEndian: bits)))
        }
        return normalizedFloat32PCMLevel(samples)
    }

    private static func normalizedAudioBufferListLevel(
        from sampleBuffer: CMSampleBuffer,
        streamDescription: AudioStreamBasicDescription
    ) -> Float? {
        var bufferListSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard sizeStatus == kCMBlockBufferNoErr, bufferListSize > 0 else {
            return nil
        }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        let audioBufferList = rawBufferList.assumingMemoryBound(to: AudioBufferList.self)
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == kCMBlockBufferNoErr else {
            return nil
        }

        var strongestLevel: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let bytes = buffer.mData, buffer.mDataByteSize > 0 else {
                continue
            }
            let data = Data(bytes: bytes, count: Int(buffer.mDataByteSize))
            strongestLevel = max(strongestLevel, normalizedPCMLevel(data, streamDescription: streamDescription))
        }
        return strongestLevel
    }

    private static func normalizedPCMLevel(
        _ data: Data,
        streamDescription: AudioStreamBasicDescription
    ) -> Float {
        let flags = streamDescription.mFormatFlags
        if streamDescription.mBitsPerChannel == 32, flags & kAudioFormatFlagIsFloat != 0 {
            return normalizedFloat32PCMLevel(data)
        }
        if streamDescription.mBitsPerChannel == 16 {
            return normalizedInt16PCMLevel(data)
        }
        return 0
    }
}
