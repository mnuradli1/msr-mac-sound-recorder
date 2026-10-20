import AppKit
import SwiftUI

/// Semantic design tokens for MSR.
///
/// Everything is built on AppKit's dynamic system colors, so light, dark and
/// increased-contrast appearances resolve natively. The only hand-picked values
/// are explicit light/dark pairs for tinted status text, where the system
/// colors alone do not reach comfortable contrast on a tinted background.
enum Theme {
    // MARK: Text

    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    // MARK: Surfaces

    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    /// Background of the history sidebar: a quiet step away from the window.
    static let sidebarBackground = Color(nsColor: NSColor(name: "MSRSidebarBackground") { appearance in
        isDark(appearance)
            ? NSColor(white: 0.135, alpha: 1)
            : NSColor(white: 0.955, alpha: 1)
    })
    /// Chrome strips (title strip, recording bar, status bar).
    static let chromeBackground = Color(nsColor: NSColor(name: "MSRChromeBackground") { appearance in
        isDark(appearance)
            ? NSColor(white: 0.165, alpha: 1)
            : NSColor(white: 0.975, alpha: 1)
    })
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let textSurface = Color(nsColor: .textBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let subtleFill = Color(nsColor: .quaternaryLabelColor).opacity(0.5)

    // MARK: Accents (restrained palette)

    static let recording = Color(nsColor: .systemRed)
    static let action = Color(nsColor: .controlAccentColor)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let info = Color(nsColor: .systemBlue)

    // MARK: Metrics

    static let cornerRadius: CGFloat = 10
    static let smallCornerRadius: CGFloat = 6
    static let gutter: CGFloat = 20
    static let recordingBarHeight: CGFloat = 56
    static let statusBarHeight: CGFloat = 26

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .aqua, .vibrantLight, .accessibilityHighContrastAqua])
            .map { $0 == .darkAqua || $0 == .vibrantDark || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }

    /// An explicit light/dark pair (no luminance heuristics).
    static func pair(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { isDark($0) ? dark : light })
    }

    static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }

    /// Small speaker palette for the transcript reader; works on both appearances.
    static func speakerColor(for speaker: String) -> Color {
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemPink, .systemIndigo, .systemBrown]
        let total = speaker.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Color(nsColor: palette[total % palette.count])
    }
}

/// Semantic tone used by chips, callouts and banners.
enum Tone: Equatable {
    case neutral
    case info
    case progress
    case recording
    case success
    case warning
    case danger

    var accent: Color {
        switch self {
        case .neutral: Theme.textSecondary
        case .info, .progress: Theme.info
        case .recording, .danger: Theme.recording
        case .success: Theme.success
        case .warning: Theme.warning
        }
    }

    /// Text color with comfortable contrast on `background`.
    var foreground: Color {
        switch self {
        case .neutral:
            Theme.textSecondary
        case .info, .progress:
            Theme.pair(light: Theme.srgb(0x1D4ED8), dark: Theme.srgb(0x93C5FD))
        case .recording, .danger:
            Theme.pair(light: Theme.srgb(0xB91C1C), dark: Theme.srgb(0xFCA5A5))
        case .success:
            Theme.pair(light: Theme.srgb(0x15803D), dark: Theme.srgb(0x86EFAC))
        case .warning:
            Theme.pair(light: Theme.srgb(0x92400E), dark: Theme.srgb(0xFCD34D))
        }
    }

    var background: Color {
        switch self {
        case .neutral: Theme.subtleFill
        default: accent.opacity(0.14)
        }
    }

    var border: Color {
        switch self {
        case .neutral: Theme.separator
        default: accent.opacity(0.32)
        }
    }
}

extension AppNoticeSeverity {
    var tone: Tone {
        switch self {
        case .info: .info
        case .success: .success
        case .warning: .warning
        case .error: .danger
        }
    }

    var iconName: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var foregroundColor: Color { tone.foreground }
    var backgroundColor: Color { tone.background }
    var borderColor: Color { tone.border }
}

// MARK: - Reusable pieces

/// Capsule label for short states ("Saved", "Queued", "Needs retry").
struct StatusChip: View {
    let title: String
    let tone: Tone
    var systemImage: String?
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(LocalizedStringKey(title))
                .lineLimit(1)
        }
        .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, compact ? 6 : 8)
        .frame(height: compact ? 18 : 22)
        .background(tone.background, in: Capsule())
        .fixedSize()
    }
}

/// Full-width banner under the recording bar (recovery notes, errors).
struct NoticeBanner: View {
    let message: String
    let severity: AppNoticeSeverity
    var horizontalPadding: CGFloat = Theme.gutter

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: severity.iconName)
                .foregroundStyle(severity.tone.accent)
            Text(message)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.vertical, 8)
        .padding(.horizontal, horizontalPadding)
        .background(severity.tone.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(severity.tone.border).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Prominent red record/stop control used in the recording bar.
struct RecordButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                Theme.recording.opacity(configuration.isPressed ? 0.8 : 1),
                in: Capsule()
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

/// Thin separator line used between chrome regions.
struct HairlineDivider: View {
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 1)
    }
}

/// Section card used in the detail tabs.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            }
    }
}

extension View {
    func cardBackground() -> some View { modifier(CardBackground()) }
}

extension Text {
    /// Localizes fixed UI phrases coming from the view model while keeping
    /// dynamic content (paths, file names, provider errors) verbatim so it is
    /// never parsed as Markdown.
    static func uiString(_ value: String) -> Text {
        let looksDynamic = value.contains("/") || value.contains("_") || value.contains("*")
            || value.contains("`") || value.count > 60
        return looksDynamic ? Text(verbatim: value) : Text(LocalizedStringKey(value))
    }
}

func formatClock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
}
