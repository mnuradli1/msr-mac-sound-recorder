import Foundation
import Security
import MSRCore

public final class APIKeyStore {
    private let serviceName = "MSRMeetingRecorder"
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func apiKey(for provider: AIProvider) -> String? {
        if let keychainValue = keychainValue(for: provider),
           let normalized = APIKeyNormalizer.normalized(keychainValue) {
            return normalized
        }
        let envName: String
        switch provider {
        case .elevenLabs:
            envName = "ELEVENLABS_API_KEY"
        case .openAI:
            envName = "OPENAI_API_KEY"
        }
        return environment[envName].flatMap(APIKeyNormalizer.normalized)
    }

    public func save(apiKey: String, for provider: AIProvider) throws {
        guard let normalized = APIKeyNormalizer.normalized(apiKey) else {
            throw KeyStoreError.emptyAPIKey
        }
        let data = Data(normalized.utf8)
        let query = keychainQuery(for: provider)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes = [kSecValueData: data] as CFDictionary
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes)
            guard updateStatus == errSecSuccess else {
                throw KeyStoreError.writeFailed(updateStatus)
            }
        } else if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeyStoreError.writeFailed(addStatus)
            }
        } else {
            throw KeyStoreError.readFailed(status)
        }
    }

    private func keychainValue(for provider: AIProvider) -> String? {
        var query = keychainQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func keychainQuery(for provider: AIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: provider.rawValue
        ]
    }
}

public enum KeyStoreError: Error, LocalizedError {
    case emptyAPIKey
    case readFailed(OSStatus)
    case writeFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyAPIKey:
            return "API key is empty."
        case let .readFailed(status):
            return "Could not read API key from Keychain. Status: \(status)."
        case let .writeFailed(status):
            return "Could not save API key to Keychain. Status: \(status)."
        }
    }
}
