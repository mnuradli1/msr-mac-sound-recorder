import AVFoundation
import Foundation

public enum AudioTrackMixer {
    public static func mixToSingleM4A(inputs: [URL], outputURL: URL) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let composition = AVMutableComposition()
        let audioMix = AVMutableAudioMix()
        var inputParameters: [AVMutableAudioMixInputParameters] = []
        var insertedAnyTrack = false

        for input in inputs where FileManager.default.fileExists(atPath: input.path) {
            let asset = AVURLAsset(url: input)
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
                    at: .zero
                )
                let parameters = AVMutableAudioMixInputParameters(track: compositionTrack)
                parameters.setVolume(1.0, at: .zero)
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
