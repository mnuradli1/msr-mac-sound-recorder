import Foundation

public enum APIKeyNormalizer {
    public static func normalized(_ value: String) -> String? {
        let normalized = value.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init)
            .joined()
        return normalized.isEmpty ? nil : normalized
    }
}
