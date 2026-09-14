import AppKit
import CharkerCore
import SwiftUI

/// Locates the bundled product render. A packaged app carries it in
/// Contents/Resources/Model3D; a dev build reads it straight from the repo
/// (the #filePath trick only works on the machine that built the binary,
/// which is exactly the dev case). Nil falls back to the drawn figure —
/// telemetry never depends on the artwork being present.
enum ProductArt {
    static let image: NSImage? = {
        // Debug hook: `-noProductArt YES` exercises the fallback path.
        if UserDefaults.standard.bool(forKey: "noProductArt") { return nil }
        if let base = Bundle.main.resourceURL {
            let bundled = base.appendingPathComponent("Model3D/A2687.webp")
            if let image = NSImage(contentsOf: bundled) { return image }
        }
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Design
            .deletingLastPathComponent()  // CharkerApp
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Resources/Model3D/A2687.webp")
        return NSImage(contentsOf: repo)
        #else
        return nil
        #endif
    }()
}

/// The device as a digital twin, not a decoration: port slots carry live,
/// power-scaled light; hovering a data card spotlights its slot here; the
/// slots are click targets that select the card back; a dead session dims the
/// whole device. Instrument, not HUD: the only cyan is delivering ports.
struct ProductStage: View {
    /// Live wattage per port; scales slot brightness (clamped, smoothed).
    var portWatts: [Double] = []
    var portsLit: [Bool] = []
    var totalFraction: Double = 0
    /// False (disconnected / no live session): lights out, device asleep.
    var active = true
    /// Card-hover linkage: this port's slot spotlights, the others recede.
    var highlightedPort: Int? = nil
    var selectedPort: Int? = nil
    var onPortTap: ((Int) -> Void)? = nil
    var height: CGFloat = 150
    /// Settle in from a slight turn on first appearance (600 ms, ease-out).
    var settlesIn = false

    @State private var settled = false
    @State private var hovering = false
    @State private var lastLit: [Bool]?
    @State private var pulses: [Int] = [0, 0, 0]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Each slot's geometry in the render, in unit coordinates — centre, width
    /// as a share of image width, and the slot's apparent tilt, which grows
    /// down the face with the perspective. Calibrated against the asset with a
    /// marker overlay (Scripts-free: scratch calibrate.swift), not eyeballed
    /// off app screenshots.
    private struct SlotGeometry {
        let center: CGPoint
        let width: Double
        let tilt: Angle
    }

    private static let slots: [SlotGeometry] = [
        SlotGeometry(center: CGPoint(x: 0.750, y: 0.546), width: 0.064, tilt: .degrees(5)),
        SlotGeometry(center: CGPoint(x: 0.736, y: 0.674), width: 0.066, tilt: .degrees(6)),
        SlotGeometry(center: CGPoint(x: 0.733, y: 0.798), width: 0.068, tilt: .degrees(7)),
    ]
    /// ease-out-quart, per the motion spec.
    private static func easeOutQuart(_ duration: Double) -> Animation {
        .timingCurve(0.25, 1, 0.5, 1, duration: duration)
    }

    private var width: CGFloat { height * 0.91 }  // render is 1822×2000

    var body: some View {
        Group {
            if let art = ProductArt.image {
                stage(art)
            } else {
                ChargerFigure(
                    portsLit: active ? portsLit : [false, false, false],
                    totalFraction: active ? totalFraction : 0,
                    height: height * 0.85,
                    interactive: true
                )
            }
        }
        .onAppear {
            // The .animation(value: tiltDegrees) modifier drives the settle-in;
            // a plain state flip is all it needs.
            settled = true
        }
        .onChange(of: portsLit) { _, lit in
            defer { lastLit = lit }
            guard active, !reduceMotion, let previous = lastLit else { return }
            for index in lit.indices where index < previous.count {
                if lit[index] && !previous[index] {
                    pulses[safe: index].map { pulses[index] = $0 + 1 }
                }
            }
        }
        .accessibilityLabel(Text("充电器实拍图"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    private var accessibilitySummary: String {
        guard active else { return L10n.text("未连接") }
        let lit = portsLit.enumerated().filter(\.element).map { "C\($0.offset + 1)" }
        return lit.isEmpty
            ? L10n.text("没有端口在输出")
            : L10n.format("%@ 正在输出", lit.joined(separator: L10n.text("、")))
    }

    // MARK: - Stage

    private var tiltDegrees: Double {
        if !settled { return -7 }
        if reduceMotion { return 0 }
        if highlightedPort != nil { return -4 }
        if hovering { return -5 }
        return 0
    }

    private func stage(_ art: NSImage) -> some View {
        VStack(spacing: -1) {
            artView(art)
            reflection(art)
        }
        .background(alignment: .bottom) {
            // Contact shadow: the device sits ON something. Dark, tight, no
            // colour — the funnel of cyan light read as sci-fi, not instrument.
            Ellipse()
                .fill(Color.black.opacity(scheme == .dark ? 0.55 : 0.28))
                .frame(width: width * 0.78, height: height * 0.085)
                .blur(radius: 5)
                .offset(y: -height * 0.255)
        }
        .frame(width: height * 1.1)
        .onHover { hovering = $0 }
    }

    private func artView(_ art: NSImage) -> some View {
        Image(nsImage: art)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: width, height: height)
            // Asleep when the session is not live: no lights, less presence.
            .saturation(active ? 1 : 0.5)
            .brightness(active ? 0 : -0.07)
            .overlay { portOverlay }
            .rotation3DEffect(
                .degrees(tiltDegrees),
                axis: (x: 0.15, y: -1, z: 0),
                perspective: 0.55
            )
            // 450 ms ease-out-quart covers both the settle-in and the card-hover
            // lean; reduce-motion pins the model still.
            .animation(reduceMotion ? nil : Self.easeOutQuart(0.45), value: tiltDegrees)
            .animation(.easeOut(duration: 0.4), value: active)
    }

    private var portOverlay: some View {
        GeometryReader { geometry in
            ForEach(0..<3, id: \.self) { index in
                let slot = Self.slots[index]
                let position = CGPoint(
                    x: geometry.size.width * slot.center.x,
                    y: geometry.size.height * slot.center.y
                )
                portLight(index, slot: slot, imageWidth: geometry.size.width)
                    .position(position)
                portTarget(index)
                    .position(position)
                if highlightedPort == index || selectedPort == index {
                    portLabel(index)
                        .position(x: position.x - height * 0.34, y: position.y)
                }
            }
        }
    }

    /// Slot light: brightness follows power (clamped so telemetry jitter never
    /// flickers), spotlight/dim follows the hovered card, one 700 ms pulse on
    /// plug-in.
    private func portLight(_ index: Int, slot: SlotGeometry, imageWidth: CGFloat) -> some View {
        let lit = active && index < portsLit.count && portsLit[index]
        let watts = index < portWatts.count ? portWatts[index] : 0
        // 0.55…1.0 across 0…100 W: visible at a trickle, bounded at full load.
        let brightness = lit ? min(1, 0.55 + 0.45 * min(1, watts / 100)) : 0
        let receded = highlightedPort != nil && highlightedPort != index
        let slotWidth = imageWidth * slot.width
        let slotHeight = slotWidth * 0.30
        return Capsule(style: .continuous)
            .fill(LinearGradient(
                colors: [Palette.accent.opacity(0.95), Palette.accentDim],
                startPoint: .leading, endPoint: .trailing
            ))
            .frame(width: slotWidth, height: slotHeight)
            .rotationEffect(slot.tilt)
            .shadow(color: Palette.accentGlow, radius: 3)
            .shadow(color: Palette.accentGlow, radius: 7)
            .blendMode(.screen)
            .opacity(brightness * (receded ? 0.3 : 1))
            .overlay {
                if selectedPort == index {
                    Capsule(style: .continuous)
                        .strokeBorder(Palette.accent, lineWidth: 1)
                        .frame(width: slotWidth * 1.35, height: slotHeight * 1.9)
                        .rotationEffect(slot.tilt)
                }
            }
            .keyframeAnimator(initialValue: 1.0, trigger: pulses[safe: index] ?? 0) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack(\.self) {
                    CubicKeyframe(1.0, duration: 0.01)
                    CubicKeyframe(1.35, duration: 0.28)
                    CubicKeyframe(1.0, duration: 0.42)
                }
            }
            .animation(Motion.reduced(Motion.value, reduceMotion), value: brightness)
            .animation(.easeOut(duration: 0.25), value: receded)
            .allowsHitTesting(false)
    }

    /// Invisible-but-real click/focus target over each slot. Colour never
    /// carries the meaning alone: the name is in the label, the tooltip and
    /// the accessibility tree.
    private func portTarget(_ index: Int) -> some View {
        Button {
            onPortTap?(index)
        } label: {
            Color.clear
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.format("C%d — 点击选中对应端口卡片", index + 1))
        .accessibilityLabel(Text(L10n.format("选中 C%d 端口", index + 1)))
    }

    /// The spotlight caption: port name and live power, next to the slot.
    private func portLabel(_ index: Int) -> some View {
        let watts = index < portWatts.count ? portWatts[index] : 0
        let lit = active && index < portsLit.count && portsLit[index]
        return HStack(spacing: 3) {
            Text("C\(index + 1)")
                .font(.numeral(10, .bold))
                .foregroundStyle(Palette.accentText)
            Text(lit ? L10n.format("%.0f W", watts) : L10n.text("未输出"))
                .font(lit ? .numeral(10, .medium) : .ui(9, .medium))
                .foregroundStyle(Palette.textSecondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous).fill(Palette.well.opacity(0.92))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
        )
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    /// Floor reflection: the same art mirrored, faded and slightly blurred.
    private func reflection(_ art: NSImage) -> some View {
        Image(nsImage: art)
            .resizable()
            .interpolation(.medium)
            .scaledToFit()
            .frame(width: width, height: height)
            .scaleEffect(x: 1, y: -1)
            .opacity(active ? 0.14 : 0.08)
            .blur(radius: 1.2)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .clear, location: 0.5),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(height: height * 0.26, alignment: .top)
            .clipped()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
