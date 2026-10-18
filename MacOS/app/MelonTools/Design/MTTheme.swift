import SwiftUI
import AppKit

/// Melon Tools Design System.
/// Apple-style neutral grays, a single golden-melon accent, SF Pro / SF Mono,
/// solid card and button surfaces (no Liquid Glass).
enum MTTheme {

    // MARK: - Adaptive color plumbing

    private static func adaptive(_ name: String, dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name), dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        }))
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    // MARK: - Accent (golden melon)

    /// The one accent: golden melon.
    static let gold = Color(hex: 0xFAC440)
    /// Ink on gold — for text and icons placed on the accent.
    static let onGold = Color(hex: 0x1A1A1C)

    // MARK: - Neutral palette (dark: graphite, light: soft gray)

    /// Window background: dark graphite / light gray.
    static let background = adaptive("mt.background",
        dark: rgb(26, 26, 28),       // #1A1A1C
        light: rgb(238, 238, 242))   // #EEEEF2
    /// Card surface.
    static let cardBackground = adaptive("mt.card",
        dark: rgb(38, 38, 41),       // #262629
        light: rgb(255, 255, 255))
    /// Chips, input wells, nested surfaces.
    static let cardSoft = adaptive("mt.cardSoft",
        dark: rgb(48, 48, 51),       // #303033
        light: rgb(242, 242, 246))   // #F2F2F6
    /// Hairline borders.
    static let borderColor = adaptive("mt.border",
        dark: rgb(64, 64, 68),       // #404044
        light: rgb(222, 222, 228))   // #DEDEE4

    /// Primary text.
    static let textPrimary = adaptive("mt.textPrimary",
        dark: rgb(245, 245, 247),    // #F5F5F7
        light: rgb(29, 29, 31))      // #1D1D1F
    /// Secondary text.
    static let textSecondary = adaptive("mt.textSecondary",
        dark: rgb(162, 162, 170),    // #A2A2AA
        light: rgb(110, 110, 115))   // #6E6E73
    /// Tertiary text / faint glyphs.
    static let textTertiary = adaptive("mt.textTertiary",
        dark: rgb(110, 110, 116),    // #6E6E74
        light: rgb(152, 152, 158))   // #98989E

    // MARK: - Semantic status

    static let ok = Color(nsColor: .systemGreen)
    static let warn = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    static let info = Color(nsColor: .systemBlue)

    // MARK: - Compatibility aliases (older call sites)

    static let paper = background
    static let ink = textPrimary
    static let muted = textSecondary
    static let hairline = borderColor
    static let amber = Color(nsColor: .systemOrange)
    static let surface = cardBackground
    static let nightBg = background
    static let nightSurface = cardBackground
    static let nightText = textPrimary
    static let nightMuted = textSecondary
    static let nightBorder = borderColor

    // MARK: - Spacing

    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24
    static let s6: CGFloat = 32

    // MARK: - Radius

    static let rSmall: CGFloat = 8
    static let rCard: CGFloat = 14

    // MARK: - Fonts (SF Pro / SF Mono)

    /// Display font for page titles (SF Pro Semibold).
    static func display(_ size: CGFloat = 28, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    /// Body font (SF Pro).
    static func body(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    /// Monospace for data, tables, logs (SF Mono).
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Solid surfaces

extension View {
    /// A solid card surface: filled panel with a hairline border. No shadow —
    /// offscreen shadow passes on scrolling card layers are a known macOS
    /// SwiftUI jank source, and the hairline already separates the card.
    func mtCardSurface(cornerRadius: CGFloat = MTTheme.rCard) -> some View {
        self
            .background(MTTheme.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75)
            )
    }
}

/// Button chrome: solid capsule — golden fill for prominent, soft surface for secondary.
struct MTSolidButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MTTheme.body(12, weight: prominent ? .semibold : .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? MTTheme.onGold : MTTheme.textPrimary)
            .background(
                Capsule().fill(prominent ? (tint ?? MTTheme.gold) : MTTheme.cardSoft)
            )
            .overlay(
                Capsule().strokeBorder(prominent ? Color.clear : MTTheme.borderColor, lineWidth: 0.75)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - Colors

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// Status semantic used across fleet doctor, codex quotas, gateway health.
enum MTStatus: String, Codable {
    case ok, warn, error, absent, running, idle, info
    var color: Color {
        switch self {
        case .ok: return MTTheme.ok
        case .warn: return MTTheme.warn
        case .error: return MTTheme.danger
        case .running: return MTTheme.gold
        case .info: return MTTheme.info
        case .idle: return MTTheme.textTertiary
        case .absent: return MTTheme.textTertiary
        }
    }
}
