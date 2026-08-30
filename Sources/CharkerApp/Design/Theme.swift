import AppKit
import SwiftUI

// MARK: - Palette
//
// 「仪表石板」— one low-chroma neutral surface with a machined specular edge on
// every card. Energy is the only saturated colour in the app, and magnitude is
// carried by chroma and glow radius on a single hue, never by a rainbow.

/// One dynamic colour = one NSColor with two appearance branches.
/// SwiftUI has no `Color(light:dark:)` and a SwiftPM executable has no asset
/// catalogue, so this is the only way to get real light/dark tokens here.
private func dyn(_ light: UInt32, _ lightAlpha: Double = 1, _ dark: UInt32, _ darkAlpha: Double = 1) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let hex = isDark ? dark : light
        let alpha = isDark ? darkAlpha : lightAlpha
        return NSColor(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    })
}

enum Palette {
    static let bg              = dyn(0xF0F1F4, 1, 0x0D0E12)
    static let surface         = dyn(0xFFFFFF, 1, 0x14161B)
    static let surfaceElevated = dyn(0xFFFFFF, 1, 0x1C1F26)
    static let surfaceRaised   = dyn(0xF7F8FA, 1, 0x252932)
    static let well            = dyn(0xF4F5F8, 1, 0x101216)

    // Light borders are alpha so they recede; dark borders are solid, because an
    // alpha line glows against a dark ground.
    static let stroke          = dyn(0x000000, 0.08, 0x2A2E37)
    static let strokeStrong    = dyn(0x000000, 0.14, 0x3A404B)
    static let specular        = dyn(0xFFFFFF, 0.90, 0xFFFFFF, 0.07)

    static let textPrimary     = dyn(0x0E1116, 1, 0xF3F5F8)
    static let textSecondary   = dyn(0x5A6472, 1, 0x9AA3B2)
    // Light value picked for ≥4.5:1 on the well (0xF4F5F8): 11pt captions sit on
    // it, and 0x79828F measured 3.6:1 there.
    static let textTertiary    = dyn(0x687280, 1, 0x7B8494)

    /// The dark appearance uses Anker's wordmark blue exactly (`#00A7E1`).
    /// Light-mode glyphs use a darker step on the same hue so 11 pt labels keep
    /// 5.97:1 contrast on the light well instead of washing out toward cyan.
    static let accent          = dyn(0x0088B8, 1, 0x00A7E1)
    static let accentText      = dyn(0x00658A, 1, 0x00A7E1)
    static let accentDim       = dyn(0x007BA6, 1, 0x006F97)
    static let accentWash      = dyn(0xDDF4FC, 1, 0x0B2934)
    static let accentGlow      = dyn(0x00A7E1, 0.16, 0x00A7E1, 0.30)

    // Conditions only. These never mean "power is flowing".
    static let ok              = dyn(0x0F9D58, 1, 0x3DD68C)
    static let okText          = dyn(0x0A7C46, 1, 0x3DD68C)
    static let warn            = dyn(0xE08A0B, 1, 0xF5A524)
    static let warnText        = dyn(0x9A5A08, 1, 0xF5A524)
    static let danger          = dyn(0xD6323A, 1, 0xFF5A5F)
    static let dangerText      = dyn(0xC42A32, 1, 0xFF5A5F)
    static let idle            = dyn(0x98A0AE, 1, 0x5A6272)
}

enum Space {
    static let xxs: CGFloat = 2, xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12
    static let l: CGFloat = 16, xl: CGFloat = 20, xxl: CGFloat = 28, xxxl: CGFloat = 40
}

enum Radius {
    static let card: CGFloat = 14, cardInner: CGFloat = 8
    static let chip: CGFloat = 7, control: CGFloat = 6
}

enum Stroke {
    static let hairline: CGFloat = 1, focus: CGFloat = 2, rail: CGFloat = 6
}

// MARK: - Type
//
// Two faces, split by script, never mixed inside one Text. `.rounded` is a no-op
// on Chinese glyphs — CJK falls back to the PingFang UI cut with identical
// metrics — so a rounded font on a mixed string silently splits its personality.

extension Font {
    /// Numerals and units of measure only. SF Pro Rounded with tabular figures.
    static func numeral(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    /// Chinese and Latin UI text. Default design.
    /// Chinese weight mapping breaks above `.semibold`, so nothing here goes heavier.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Named steps. Not an extension on `Font`: `title`, `body` and `caption` already
/// exist there and redeclaring them is an error.
enum Typo {
    static let display  = Font.numeral(56, .semibold)
    static let metric   = Font.numeral(28, .semibold)
    static let metricSm = Font.numeral(17, .medium)
    static let title    = Font.ui(19, .semibold)
    static let heading  = Font.ui(15, .semibold)
    static let body     = Font.ui(13, .regular)
    static let label    = Font.ui(12, .medium)
    static let caption  = Font.ui(11, .regular)
    static let micro    = Font.ui(10, .medium)
}

extension View {
    /// The system font gives every size a 1.178× line box, including for pure-CJK
    /// strings, which is tight for Chinese. Paragraphs need the difference added
    /// back; single-line labels and numerals must not use this.
    func cjkParagraph(_ size: CGFloat, target: CGFloat = 1.62) -> some View {
        lineSpacing(size * (target - 1.178))
    }
}

// MARK: - Motion

enum Motion {
    /// Live numbers and rails refresh every second. A short, non-bouncing ease
    /// keeps the change legible without occupying the main thread while the
    /// user is manipulating the native 3D camera.
    static let value = Animation.easeOut(duration: 0.16)
    static let ui    = Animation.spring(response: 0.30, dampingFraction: 1.0)
    /// Popovers and sheets only — the small bounce is earned by the user's click.
    static let enter = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// Physical events only (a device was just plugged in): the one other place
    /// a bounce is earned, because something really did land.
    static let pop   = Animation.spring(response: 0.35, dampingFraction: 0.60)

    /// Reduced motion never means "no feedback": the value change still has to be
    /// legible, it just must not spring.
    static func reduced(_ animation: Animation, _ reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.14) : animation
    }

    /// For AppKit code, which has no SwiftUI environment to read.
    static var systemReducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
