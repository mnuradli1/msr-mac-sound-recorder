import Foundation
import MSRCore

public final class CredentialValidator: @unchecked Sendable {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func validate(provider: AIProvider, apiKey: String) async -> CredentialValidationResult {
        guard let normalized = APIKeyNormalizer.normalized(apiKey) else {
            return CredentialValidationResult(provider: provider, isValid: false, message: "API key is empty.")
        }

        do {
            let request = try Self.validationRequest(provider: provider, apiKey: normalized)
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return CredentialValidationResult(provider: provider, isValid: false, message: "Provider returned an invalid response.")
            }
            if (200..<300).contains(http.statusCode) {
                return CredentialValidationResult(provider: provider, isValid: true, message: "\(provider.displayName) key works for \(provider.validationPurpose).")
            }
            let body = String(data: data, encoding: .utf8) ?? "No response body"
            return CredentialValidationResult(
                provider: provider,
                isValid: false,
                message: Self.providerErrorMessage(provider: provider, statusCode: http.statusCode, body: body)
            )
        } catch {
            return CredentialValidationResult(provider: provider, isValid: false, message: error.localizedDescription)
        }
    }

    public static func validationRequest(provider: AIProvider, apiKey: String) throws -> URLRequest {
        guard let normalized = APIKeyNormalizer.normalized(apiKey) else {
            throw CredentialValidationError.emptyAPIKey
        }

        switch provider {
        case .elevenLabs:
            var multipart = MultipartFormData()
            multipart.appendField(name: "model_id", value: "scribe_v2")
            multipart.appendFile(
                name: "file",
                fileName: "msr-key-test.wav",
                mimeType: "audio/wav",
                data: TinyWAVFixture.data()
            )
            var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
            request.httpMethod = "POST"
            request.setValue(normalized, forHTTPHeaderField: "xi-api-key")
            request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = multipart.finalize()
            return request
        case .openAI:
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(normalized)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    private static func providerErrorMessage(provider: AIProvider, statusCode: Int, body: String) -> String {
        let lowercased = body.lowercased()
        if provider == .elevenLabs, lowercased.contains("missing_permissions") {
            return "ElevenLabs key was recognized but is missing permission for this operation. Enable Speech-to-Text permission for the key, or create a key with Speech-to-Text access. HTTP \(statusCode)."
        }
        if statusCode == 401 || statusCode == 403 {
            return "\(provider.displayName) rejected the key. Check that the key is active and has permission for \(provider.validationPurpose). HTTP \(statusCode)."
        }
        return "\(provider.displayName) rejected the key with HTTP \(statusCode): \(body.prefix(400))"
    }
}

public struct CredentialValidationResult: Equatable, Sendable {
    public var provider: AIProvider
    public var isValid: Bool
    public var message: String

    public init(provider: AIProvider, isValid: Bool, message: String) {
        self.provider = provider
        self.isValid = isValid
        self.message = message
    }
}

public enum CredentialValidationError: Error, LocalizedError {
    case emptyAPIKey

    public var errorDescription: String? {
        "API key is empty."
    }
}

private extension AIProvider {
    var validationPurpose: String {
        switch self {
        case .elevenLabs:
            return "speech-to-text"
        case .openAI:
            return "model access"
        }
    }
}

private enum TinyWAVFixture {
    static func data() -> Data {
        let sampleRate = 16_000
        let sampleCount = 4_000
        let byteRate = sampleRate * 2
        let dataSize = sampleCount * 2
        var data = Data()
        data.appendASCII("RIFF")
        data.appendUInt32LE(UInt32(36 + dataSize))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(1)
        data.appendUInt32LE(UInt32(sampleRate))
        data.appendUInt32LE(UInt32(byteRate))
        data.appendUInt16LE(2)
        data.appendUInt16LE(16)
        data.appendASCII("data")
        data.appendUInt32LE(UInt32(dataSize))
        for index in 0..<sampleCount {
            let angle = 2 * Double.pi * 440 * Double(index) / Double(sampleRate)
            let sample = Int16(Double(Int16.max) * 0.12 * sin(angle))
            data.appendInt16LE(sample)
        }
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(Data(value.utf8))
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    mutating func appendInt16LE(_ value: Int16) {
        appendUInt16LE(UInt16(bitPattern: value))
    }
}
