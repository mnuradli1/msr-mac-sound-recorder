import AVFoundation
import Foundation

public struct TimedAudioInput: Sendable {
    public var url: URL
    public var offset: TimeInterval
    public init(url: URL, offset: TimeInterval = 0) {
        self.url = url
        self.offset = max(0, offset)
    }
}

public enum AudioTrackMixer {
    public static func mixToSingleM4A(inputs: [URL], outputURL: URL) async throws {
        try await mixToSingleM4A(inputs: inputs.map { TimedAudioInput(url: $0) }, outputURL: outputURL)
    }

    public static func mixToSingleM4A(inputs: [TimedAudioInput], outputURL: URL) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let composition = AVMutableComposition()
        let audioMix = AVMutableAudioMix()
        var inputParameters: [AVMutableAudioMixInputParameters] = []
        var insertedAnyTrack = false

        let headroom = Float(1 / sqrt(Double(max(1, inputs.count))))
        for input in inputs where FileManager.default.fileExists(atPath: input.url.path) {
            let asset = AVURLAsset(url: input.url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)

            for track in tracks {
                guard let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    continue
                }
                try compositionTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: track,
                    at: CMTime(seconds: input.offset, preferredTimescale: 48_000)
                )
                let parameters = AVMutableAudioMixInputParameters(track: compositionTrack)
                parameters.setVolume(headroom, at: .zero)
                inputParameters.append(parameters)
                insertedAnyTrack = true
            }
        }

        guard insertedAnyTrack else {
            throw AudioTrackMixerError.noAudioTracks
        }

        audioMix.inputParameters = inputParameters
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioTrackMixerError.exportSessionUnavailable
        }
        export.audioMix = audioMix
        export.outputURL = outputURL
        export.outputFileType = .m4a

        await withCheckedContinuation { continuation in
            export.exportAsynchronously {
                continuation.resume()
            }
        }

        if export.status != .completed {
            throw AudioTrackMixerError.exportFailed(export.error?.localizedDescription ?? "Audio export failed.")
        }
    }

    public static func concatenateToSingleM4A(inputs: [URL], outputURL: URL) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioTrackMixerError.exportSessionUnavailable
        }

        var cursor = CMTime.zero
        var insertedAnyTrack = false
        for input in inputs where FileManager.default.fileExists(atPath: input.path) {
            let asset = AVURLAsset(url: input)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)
            guard let track = tracks.first, duration.seconds > 0 else {
                continue
            }
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: track,
                at: cursor
            )
            cursor = cursor + duration
            insertedAnyTrack = true
        }

        guard insertedAnyTrack else {
            throw AudioTrackMixerError.noAudioTracks
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioTrackMixerError.exportSessionUnavailable
        }
        export.outputURL = outputURL
        export.outputFileType = .m4a

        await withCheckedContinuation { continuation in
            export.exportAsynchronously {
                continuation.resume()
            }
        }

        if export.status != .completed {
            throw AudioTrackMixerError.exportFailed(export.error?.localizedDescription ?? "Audio export failed.")
        }
    }
}

public enum AudioTrackMixerError: Error, LocalizedError {
    case noAudioTracks
    case exportSessionUnavailable
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTracks:
            return "No audio tracks were available to mix."
        case .exportSessionUnavailable:
            return "Could not create audio export session."
        case let .exportFailed(message):
            return message
        }
    }
}
