import SwiftUI

// MARK: - Energy shimmer
//
// A specular band that sweeps along a lit power rail. It only exists while power
// is actually flowing, so the motion is information: flowing light = flowing
// energy. TimelineView pauses off-screen, and reduce-motion removes it entirely —
// the rail's fill already carries the value.

struct ShimmerBand: View {
    var period: Double = 2.8
    var bandFraction: CGFloat = 0.42

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GeometryReader { geometry in
                let width = geometry.size.width
                let band = max(18, width * bandFraction)
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = (t.truncatingRemainder(dividingBy: period)) / period
                LinearGradient(
                    colors: [.clear, .white.opacity(0.55), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: band)
                .offset(x: -band + (width + 2 * band) * phase)
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

// MARK: - One-shot burst ring
//
// Fired when a port starts delivering: the card's outline flares and expands
// once. Driven by `keyframeAnimator(trigger:)`, so it replays on every increment
// and never loops.

private struct BurstValue {
    var scale: CGFloat = 1
    var opacity: Double = 0
}

struct CardBurst: View {
    /// Increment to fire. 0 means "never fired yet" and stays invisible.
    var trigger: Int
    var color: Color
    var radius: CGFloat = Radius.card

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(color, lineWidth: 2)
            // BurstValue rests at opacity 0, and keyframes only run on a trigger
            // change, so the ring is invisible until a plug-in event fires it.
            .keyframeAnimator(initialValue: BurstValue(), trigger: trigger) { view, value in
                view
                    .opacity(value.opacity)
                    .scaleEffect(value.scale)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.0, duration: 0.02)
                    CubicKeyframe(1.045, duration: 0.55)
                    CubicKeyframe(1.06, duration: 0.35)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.9, duration: 0.08)
                    LinearKeyframe(0.55, duration: 0.30)
                    LinearKeyframe(0.0, duration: 0.55)
                }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Radar pulse
//
// The searching state: rings expanding from a bolt, like the charger's own
// advertising packets. Three rings share one clock, offset by a third of the
// period each, so the pulse never stutters when SwiftUI re-renders.

struct RadarPulse: View {
    var color: Color = Palette.accent
    var diameter: CGFloat = 96
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if active && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<3, id: \.self) { index in
                            let phase = ((t / 2.4) + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                            Circle()
                                .stroke(color.opacity(0.5 * (1 - phase)), lineWidth: 1.5)
                                .frame(width: diameter * (0.35 + 0.65 * phase),
                                       height: diameter * (0.35 + 0.65 * phase))
                        }
                    }
                }
            } else {
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: 1.5)
                    .frame(width: diameter * 0.55, height: diameter * 0.55)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Button styles
//
// Keep the established names at call sites, but route them through the same
// capsule system as settings actions. Legacy "ghost" actions now keep visible
// secondary chrome at rest; truly quiet actions opt into `.quiet` explicitly.

/// Legacy secondary action, retained as a source-compatible name.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CharkerActionButtonStyle(emphasis: .secondary).makeBody(configuration: configuration)
    }
}

/// Primary inline action: accent wash at rest.
struct WashButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CharkerActionButtonStyle(emphasis: .primary).makeBody(configuration: configuration)
    }
}

// MARK: - USB-C glyph
//
// The port's own shape, drawn rather than borrowed from SF Symbols: a lozenge
// with an inner tongue. Fill state mirrors the port — hollow when empty, lit
// when delivering.

struct USBCGlyph: View {
    var lit: Bool
    var size: CGFloat = 20

    var body: some View {
        let height = size * 0.46
        ZStack {
            Capsule(style: .continuous)
                .strokeBorder(lit ? Palette.accentText : Palette.textTertiary, lineWidth: 1.4)
            Capsule(style: .continuous)
                .fill(lit ? Palette.accent : Palette.idle.opacity(0.4))
                .frame(width: size * 0.52, height: height * 0.32)
                .shadow(color: lit ? Palette.accentGlow : .clear, radius: 3)
        }
        .frame(width: size, height: height)
        .animation(.easeOut(duration: 0.25), value: lit)
        .accessibilityHidden(true)
    }
}
