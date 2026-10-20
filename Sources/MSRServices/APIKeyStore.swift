import Foundation
import Security
import MSRCore

/// Minimal Keychain seam so key precedence and clearing can be tested without touching the real Keychain.
protocol KeychainStoring: Sendable {
    func read(service: String, account: String) -> String?
    func write(_ value: String, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

/// Resolves provider API keys with precedence: session value > Keychain > environment variable.
public final class APIKeyStore: @unchecked Sendable {
    private let serviceName = "MSRMeetingRecorder"
    private let environment: [String: String]
    private let keychain: KeychainStoring
    private let lock = NSLock()
    private var sessionValues: [AIProvider: String] = [:]

    public convenience init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(environment: environment, keychain: SystemKeychain())
    }

    init(environment: [String: String], keychain: KeychainStoring) {
        self.environment = environment
        self.keychain = keychain
    }

    public func apiKey(for provider: AIProvider) -> String? {
        if let sessionValue = lock.withLock({ sessionValues[provider] }) {
            return sessionValue
        }
        if let keychainValue = keychain.read(service: serviceName, account: provider.rawValue),
           let normalized = APIKeyNormalizer.normalized(keychainValue) {
            return normalized
        }
        return environment[Self.environmentVariableName(for: provider)].flatMap(APIKeyNormalizer.normalized)
    }

    /// Uses `apiKey` for this app run only (not persisted).
    public func setSession(apiKey: String, for provider: AIProvider) throws {
        guard let normalized = APIKeyNormalizer.normalized(apiKey) else { throw KeyStoreError.emptyAPIKey }
        lock.withLock { sessionValues[provider] = normalized }
    }

    /// Removes the session value and the Keychain item for `provider`.
    public func forget(_ provider: AIProvider) throws {
        lock.withLock { _ = sessionValues.removeValue(forKey: provider) }
        try keychain.delete(service: serviceName, account: provider.rawValue)
    }

    /// Persists `apiKey` in the Keychain and drops any session value so the saved key takes effect immediately.
    public func save(apiKey: String, for provider: AIProvider) throws {
        guard let normalized = APIKeyNormalizer.normalized(apiKey) else {
            throw KeyStoreError.emptyAPIKey
        }
        try keychain.write(normalized, service: serviceName, account: provider.rawValue)
        lock.withLock { _ = sessionValues.removeValue(forKey: provider) }
    }

    static func environmentVariableName(for provider: AIProvider) -> String {
        switch provider {
        case .elevenLabs:
            return "ELEVENLABS_API_KEY"
        case .openAI:
            return "OPENAI_API_KEY"
        }
    }
}

struct SystemKeychain: KeychainStoring {
    func read(service: String, account: String) -> String? {
        var query = Self.query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let query = Self.query(service: service, account: account)
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

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(Self.query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.writeFailed(status)
        }
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
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
