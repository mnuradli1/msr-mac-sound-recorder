import AppKit
import Foundation

private func msrUncaughtExceptionHandler(_ exception: NSException) {
    CrashLogService.recordException(exception)
}

enum CrashLogService {
    static func install() {
        NSSetUncaughtExceptionHandler(msrUncaughtExceptionHandler)
        rotate()
    }

    static func recordException(_ exception: NSException) {
        write(
            title: "Uncaught exception",
            // Exception reasons can contain user-provided note or transcript
            // fragments. Keep only the exception class and symbolized stack.
            details: "\(exception.name.rawValue)\n\(exception.callStackSymbols.joined(separator: "\n"))"
        )
    }

    static func record(_ error: Error, context: String) {
        // Error descriptions from networking and provider SDKs may echo request
        // material. Retain the diagnostic type without persisting user content.
        write(title: context, details: String(describing: type(of: error)))
    }

    private static func write(title: String, details: String) {
        let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MSR", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("msr-\(stamp)-\(UUID().uuidString).log")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let safe = "MSR \(version)\n\(sanitized(title))\n\(sanitized(String(details.prefix(20_000))))\n"
        try? safe.write(to: url, atomically: true, encoding: .utf8)
        rotate()
    }

    private static func sanitized(_ value: String) -> String {
        let patterns = [
            #"(?i)bearer\s+[a-z0-9._~+/=-]+"#,
            #"(?i)(api[_ -]?key|token|xi-api-key)\s*[:=]\s*[^\s,;]+"#,
            #"\bsk[-_][A-Za-z0-9_-]{8,}\b"#
        ]
        return patterns.reduce(value) { partial, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return partial }
            let range = NSRange(partial.startIndex..., in: partial)
            return regex.stringByReplacingMatches(in: partial, range: range, withTemplate: "[REDACTED]")
        }
    }

    private static func rotate() {
        let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MSR", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let sorted = urls.filter { $0.pathExtension == "log" }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for url in sorted.dropFirst(10) { try? FileManager.default.removeItem(at: url) }
    }
}

final class MSRApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        CrashLogService.install()
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
        }
    }
}
