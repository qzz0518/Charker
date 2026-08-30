import CharkerCore
import SwiftUI

/// An original vector rendition of the A2687 — metal brick, dark glass face,
/// ring button, fold-out prongs, three USB-C ports along the bottom.
///
/// Drawn, not photographed: the official renders are Anker's copyrighted
/// assets, and a drawing can do what a bitmap cannot — the port slots light up
/// from live telemetry, so the figure IS a readout. No wordmark on the face,
/// deliberately: the app is unaffiliated and says so.
struct ChargerFigure: View {
    /// Which ports are currently delivering; drives the slot glow.
    var portsLit: [Bool] = [false, false, false]
    /// 0…1 of the charger's ceiling — the on-device screen really does show an
    /// arc gauge, and ours shows the live one.
    var totalFraction: Double = 0
    var height: CGFloat = 96
    /// Gentle 2.5D tilt on hover. Off for static contexts.
    var interactive = false

    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var width: CGFloat { height * 0.74 }

    var body: some View {
        ZStack {
            prongs
            body3Q
        }
        .frame(width: width, height: height)
        .rotation3DEffect(
            .degrees(interactive && hovering && !reduceMotion ? 7 : 0),
            axis: (x: -0.25, y: 1, z: 0),
            perspective: 0.6
        )
        .animation(Motion.reduced(Motion.pop, reduceMotion), value: hovering)
        .onHover { if interactive { hovering = $0 } }
        .accessibilityLabel(Text("充电器示意图"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    private var accessibilitySummary: String {
        let lit = portsLit.enumerated().filter(\.element).map { "C\($0.offset + 1)" }
        return lit.isEmpty
            ? L10n.text("没有端口在输出")
            : L10n.format("%@ 正在输出", lit.joined(separator: L10n.text("、")))
    }

    // MARK: Layers

    /// The wall prongs peeking over the top edge — the same two-ear motif as
    /// the app icon.
    private var prongs: some View {
        HStack(spacing: width * 0.16) {
            prong
            prong
        }
        // Half the prong pokes above the shell — the same two-ear silhouette
        // as the app icon.
        .offset(y: -height * 0.53)
    }

    private var prong: some View {
        RoundedRectangle(cornerRadius: width * 0.035, style: .continuous)
            .fill(scheme == .dark
                  ? Color(red: 0.10, green: 0.11, blue: 0.13)
                  : Color(red: 0.28, green: 0.30, blue: 0.34))
            .frame(width: width * 0.10, height: height * 0.16)
    }

    private var body3Q: some View {
        let cornerRadius = height * 0.14
        return ZStack {
            // Metal shell.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(
                    colors: scheme == .dark
                        ? [Color(red: 0.27, green: 0.29, blue: 0.33),
                           Color(red: 0.16, green: 0.17, blue: 0.20)]
                        : [Color(red: 0.82, green: 0.84, blue: 0.87),
                           Color(red: 0.62, green: 0.65, blue: 0.70)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(
                    // The machined top edge, same trick as SlateCard.
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Palette.specular, .clear],
                                startPoint: .top, endPoint: .center
                            ),
                            lineWidth: 1
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
                )

            VStack(spacing: height * 0.045) {
                glassFace
                portRow
            }
            .padding(width * 0.09)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.18), radius: 8, y: 5)
    }

    /// The dark glass front with the ring button and a diagonal sheen.
    private var glassFace: some View {
        RoundedRectangle(cornerRadius: height * 0.09, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 0.05, green: 0.06, blue: 0.08),
                         Color(red: 0.10, green: 0.11, blue: 0.14)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay(
                // Sheen: light raking across glass.
                RoundedRectangle(cornerRadius: height * 0.09, style: .continuous)
                    .fill(LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.10), location: 0),
                            .init(color: .white.opacity(0.02), location: 0.35),
                            .init(color: .clear, location: 0.6),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            )
            .overlay(alignment: .top) {
                // The screen's arc gauge, fed by live total power — the same
                // thing the physical display shows.
                arcGauge
                    .padding(.top, height * 0.075)
            }
            .overlay(alignment: .bottom) {
                // The ring button.
                Circle()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: max(1, height * 0.012))
                    .frame(width: height * 0.13, height: height * 0.13)
                    .padding(.bottom, height * 0.055)
            }
            .overlay(
                RoundedRectangle(cornerRadius: height * 0.09, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.5), lineWidth: Stroke.hairline)
            )
    }

    private var arcGauge: some View {
        let fraction = max(0, min(1, totalFraction))
        let lineWidth = max(1.2, height * 0.02)
        return ZStack {
            Circle()
                .trim(from: 0.125, to: 0.875)
                .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0.125, to: 0.125 + 0.75 * fraction)
                .stroke(
                    AngularGradient(
                        colors: [Palette.accentDim, Palette.accent],
                        center: .center,
                        startAngle: .degrees(45), endAngle: .degrees(315)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .shadow(color: fraction > 0.02 ? Palette.accentGlow : .clear, radius: 2)
        }
        .rotationEffect(.degrees(90))  // gap at the bottom, like the device
        .frame(width: height * 0.24, height: height * 0.24)
        .animation(Motion.reduced(Motion.value, reduceMotion), value: fraction)
    }

    /// Three USB-C slots; a delivering port's slot fills with the accent and
    /// casts a small glow — the figure mirrors the charger in real time.
    private var portRow: some View {
        HStack(spacing: width * 0.07) {
            ForEach(0..<3, id: \.self) { index in
                let lit = index < portsLit.count && portsLit[index]
                Capsule(style: .continuous)
                    .fill(lit
                          ? AnyShapeStyle(Palette.accent)
                          : AnyShapeStyle(Color.black.opacity(scheme == .dark ? 0.55 : 0.35)))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                lit ? Palette.accent.opacity(0.9) : Palette.specular,
                                lineWidth: Stroke.hairline
                            )
                    )
                    .frame(width: width * 0.17, height: height * 0.045)
                    .shadow(color: lit ? Palette.accentGlow : .clear, radius: 4)
                    .animation(.easeOut(duration: 0.3), value: lit)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, height * 0.014)
    }
}
