import Foundation

public enum FileNameSanitizer {
    public static func sanitizedBaseName(_ value: String, fallback: String = "Untitled Meeting") -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let components = value.components(separatedBy: invalidCharacters)
        let collapsed = components
            .joined(separator: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? fallback : collapsed
    }
}
