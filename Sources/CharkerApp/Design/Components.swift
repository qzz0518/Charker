import A2687Protocol
import AppKit
import CharkerCore
import SwiftUI

/// The app's one surface treatment: an elevated slate with a machined top edge.
/// `hovering` lifts the card by deepening its shadow — never by scaling, which
/// pushes the 1px specular line onto sub-pixels and makes it shimmer.
struct SlateCard<Content: View>: View {
    var radius: CGFloat = Radius.card
    var padding: CGFloat = Space.l
    var hovering = false
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.surfaceElevated)
                    .overlay {
                        // Light catching a machined edge: a 1px specular that fades
                        // out by mid-height. This is what stops a dark card reading
                        // as a flat rectangle.
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Palette.specular, .clear],
                                    startPoint: .top, endPoint: .center
                                ),
                                lineWidth: Stroke.hairline
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
                    }
            }
            // Without this SwiftUI shadows each subview separately.
            .compositingGroup()
            .shadow(
                color: .black.opacity(scheme == .dark ? (hovering ? 0.56 : 0.44) : (hovering ? 0.10 : 0.06)),
                radius: hovering ? 16 : 12,
                y: hovering ? 8 : 6
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.04), radius: 3, y: 1)
            .shadow(color: .black.opacity(scheme == .dark ? 0.00 : 0.03), radius: 1, y: 0)
            .offset(y: hovering && !reduceMotion ? -1 : 0)
            .animation(Motion.reduced(Motion.ui, reduceMotion), value: hovering)
    }
}

/// Every port is drawn on the same 0–160 W scale, on purpose: per-port auto-scaling
/// makes a 5 W trickle look as busy as a 100 W laptop charge.
///
/// `segments` (the hero rail) splits the fill into per-port bands of one hue at
/// stepped opacity, so the total also says who is drawing it. `flowing` adds the
/// energy shimmer — reserved for the hero, mounted only while power actually
/// flows, and removed entirely under reduce-motion.
struct PowerRail: View {
    let watts: Double
    var ceiling: Double = 160
    var isDelivering: Bool
    var segments: [Double]? = nil
    var flowing = false
    var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double { max(0, min(1, watts / ceiling)) }
    /// Chroma encodes magnitude, so the card physically brightens under load.
    private var intensity: Double { isDelivering ? 0.45 + 0.55 * pow(fraction, 0.6) : 0 }
    private static let segmentOpacities: [Double] = [1.0, 0.72, 0.5]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.idle.opacity(0.22))
                fill(width: width)
                    .opacity(intensity * (dimmed ? 0.45 : 1))
                    .overlay(alignment: .leading) {
                        if flowing && isDelivering && !dimmed && !reduceMotion {
                            ShimmerBand()
                                .frame(width: max(Stroke.rail, width * fraction))
                                .clipShape(Capsule())
                        }
                    }
            }
        }
        .frame(height: Stroke.rail)
        .animation(Motion.reduced(Motion.value, reduceMotion), value: watts)
        .animation(Motion.reduced(Motion.value, reduceMotion), value: segments)
        .accessibilityLabel(Text("功率"))
        .accessibilityValue(Text(L10n.format("%.1f 瓦", watts)))
    }

    @ViewBuilder
    private func fill(width: CGFloat) -> some View {
        if let segments, segments.contains(where: { $0 > 0.1 }) {
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, value in
                    if value > 0.1 {
                        Capsule()
                            .fill(Palette.accent)
                            .opacity(Self.segmentOpacities[index % Self.segmentOpacities.count])
                            .frame(width: max(Stroke.rail, width * value / ceiling))
                    }
                }
            }
            .clipShape(Capsule())
        } else {
            Capsule()
                .fill(LinearGradient(
                    colors: [Palette.accentDim, Palette.accent],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(width: max(isDelivering ? Stroke.rail : 0, width * fraction))
        }
    }
}

/// The face of the app. The number is Latin-only so it may use the rounded face
/// and negative tracking; the unit sits in the default face to match the Chinese
/// around it, and that face contrast is deliberate.
struct TotalReadout: View {
    let watts: Double?
    let isStale: Bool
    var size: CGFloat = 56
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: Space.s) {
            if let watts {
                Text(L10n.format("%.1f", watts))
                    .font(.numeral(size, .semibold))
                    // Latin-only view, so negative tracking is safe here. It would
                    // crush a Chinese string, which is why the unit sits apart.
                    .tracking(-0.6)
                    // Metal-ink gradient: full strength at the top, a shade
                    // quieter at the baseline.
                    .foregroundStyle(LinearGradient(
                        colors: [Palette.textPrimary, Palette.textPrimary.opacity(0.76)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .contentTransition(.numericText(value: watts))
                    .animation(Motion.reduced(Motion.value, reduceMotion), value: watts)
                // The unit only exists while there is a number for it to measure.
                Text("W")
                    .font(.ui(size * 0.39, .medium))
                    .foregroundStyle(Palette.textSecondary)
            } else {
                // An em dash at display size reads as a horizontal rule, not as a
                // missing value. Set the placeholder small and quiet instead.
                Text("暂无数据")
                    .font(.ui(size * 0.33, .medium))
                    .foregroundStyle(Palette.textTertiary)
                    .baselineOffset(size * 0.06)
            }
        }
        .opacity(isStale ? 0.45 : 1)
        .animation(.easeOut(duration: 0.2), value: isStale)
    }
}

struct Chip: View {
    let text: String
    var tone: Tone = .neutral

    enum Tone { case neutral, warn, accent, ok }

    var body: some View {
        Text(text)
            .font(Typo.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(foreground)
            .padding(.horizontal, Space.s)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .strokeBorder(border, lineWidth: Stroke.hairline)
            )
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return Palette.textSecondary
        case .warn: return Palette.warnText
        case .accent: return Palette.accentText
        case .ok: return Palette.okText
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: return Palette.idle.opacity(0.14)
        case .warn: return Palette.warn.opacity(0.16)
        case .accent: return Palette.accentWash
        case .ok: return Palette.ok.opacity(0.14)
        }
    }

    private var border: Color {
        tone == .warn ? Palette.warn.opacity(0.34) : .clear
    }
}

/// Connection state as a determinate ladder rather than an indefinite spinner:
/// the handshake really does have nine named steps, so show which one it is on.
///
/// The bar is allowed to finish: it animates to 1.0 and only then fades, instead
/// of vanishing the frame the session opens.
struct ConnectionLadder: View {
    let phase: SessionPhase
    var compact = false
    @State private var barVisible = false
    @State private var displayProgress: Double = 0
    @State private var hideGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            // The dot belongs to the status label, not to the whole text stack.
            // A small optical offset centers it on the first line while the
            // detail and progress bar keep the exact same textual leading edge.
            StateDot(phase: phase)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: Space.s) {
                Text(phase.shortLabel)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.18), value: phase.shortLabel)
                if !compact {
                    Text(phase.detail)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .cjkParagraph(11, target: 1.50)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if barVisible {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.idle.opacity(0.22))
                            Capsule()
                                .fill(Palette.accent)
                                .frame(width: geometry.size.width * displayProgress)
                        }
                    }
                    .frame(height: 2)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: phase.negotiationProgress, initial: true) { _, progress in
            hideGeneration += 1
            switch progress {
            case .some(let value) where value < 1:
                if barVisible {
                    withAnimation(Motion.reduced(Motion.value, reduceMotion)) { displayProgress = value }
                } else {
                    // A fresh handshake: place the bar before revealing it, so
                    // it does not animate down from a previous run's 100%.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { displayProgress = value }
                    withAnimation(Motion.reduced(Motion.ui, reduceMotion)) { barVisible = true }
                }
            case .some:
                // Session opened: the bar gets to be seen finishing, then fades.
                // The generation guard drops the fade if a new handshake starts.
                withAnimation(Motion.reduced(Motion.value, reduceMotion)) { displayProgress = 1 }
                let generation = hideGeneration
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard generation == hideGeneration else { return }
                    withAnimation(.easeOut(duration: 0.3)) { barVisible = false }
                }
            case .none:
                // Failure or drop: a defeated handshake must not play the
                // triumphant sweep to 100% — the bar just leaves where it stood.
                withAnimation(.easeOut(duration: 0.25)) { barVisible = false }
            }
        }
    }
}

/// The session dot. Busy phases breathe — a static grey dot said nothing about
/// the app actively working through scan/connect/handshake.
struct StateDot: View {
    let phase: SessionPhase
    var stale = false
    var diameter: CGFloat = 7
    var glowsWhenLive = true
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .shadow(
                color: color.opacity(glowsWhenLive ? 0.55 : 0),
                radius: glowsWhenLive && phase.isLive ? 4 : 0
            )
            .opacity(pulsing ? 0.35 : 1)
            .onChange(of: phase.isBusy, initial: true) { _, busy in
                setPulsing(busy)
            }
            // A long scan can outlive a mid-flight reduce-motion toggle; the
            // repeatForever must stop (or start) the moment the setting changes.
            .onChange(of: reduceMotion) { _, _ in
                setPulsing(phase.isBusy)
            }
            .accessibilityLabel(Text(phase.shortLabel))
    }

    private func setPulsing(_ busy: Bool) {
        if busy && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { pulsing = false }
        }
    }

    private var color: Color {
        if stale { return Palette.warn }
        switch phase {
        case .monitoring: return Palette.ok
        case .failed, .bluetoothUnavailable: return Palette.danger
        case .reconnecting: return Palette.warn
        default: return Palette.idle
        }
    }
}

/// Sidebar and popover backing. `.sidebar` is what makes a macOS sidebar read as
/// part of the window rather than a grey rectangle.
struct VibrancyBacking: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

// MARK: - Chart hover

/// 主看板的功率时间线和能耗页的两张趋势图共用同一个 hover 手势，这里放的是它
/// 们必须长一样的那几个数：十字线的粗细淡度、气泡与数据点之间的留白。
///
/// 十字线的**画法**两边有意不同，不要合并：主看板用 `Path` 手绘，因为把
/// `RuleMark` 放回 `Chart` 里意味着指针每动一帧都要重解析上千个图元（见
/// `PowerCurveHoverLayer` 的注释）；能耗页的图元只有几十个，`RuleMark` 更省事。
/// 画法可以不同，长相不行——同一个手势在两屏上出现两种淡度就是 bug。
enum ChartHoverStyle {
    static let crosshairWidth: CGFloat = 1
    static let crosshairDash: [CGFloat] = [3, 3]
    static let crosshairOpacity: Double = 0.72
    /// 气泡与被标注的那个点之间的留白。
    static let bubbleGap: CGFloat = 12
}

/// 指针停在图上时贴出来的读数气泡。
///
/// 气泡贴着被标注的那个数据点，而不是贴着光标：光标本来就压在点上，气泡跟着
/// 光标就会盖住自己在解释的东西。
///
/// 首选浮在点的正上方，水平居中并向绘图区内夹取——横向贴边不会挡住下方的点。
/// 顶到天花板时不能简单地压到下方：柱状图的图元是一整根竖条，压下来正好盖住
/// 它，所以改成翻到点的侧边，右边放不下再翻到左边。
///
/// 调用方只负责 `anchor`（数据点在窗口坐标里的位置）、`plot`（夹取用的绘图区）
/// 和两到三行已经本地化好的文字——气泡不认识"能量还是功率"。
struct ChartHoverBubble: View {
    /// 被标注的数据点，窗口坐标系。
    let anchor: CGPoint
    /// 绘图区矩形，气泡在它内部夹取。
    let plot: CGRect
    let headline: String
    /// 中间那行强调文字，`nil` 就不画这一行——主看板只在选中某个端口时才有它。
    var detail: String?
    let caption: String

    @State private var size: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(headline)
                .font(.numeral(13, .semibold))
                .foregroundStyle(Palette.textPrimary)
            if let detail {
                Text(detail)
                    .font(.numeral(10, .medium))
                    .foregroundStyle(Palette.accentText)
            }
            Text(caption)
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
        }
        .fixedSize()
        .padding(.horizontal, Space.s)
        .padding(.vertical, 5)
        .background(Palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
        }
        .shadow(color: .black.opacity(0.16), radius: 8, y: 2)
        .background {
            GeometryReader { bubble in
                Color.clear.preference(key: SizeKey.self, value: bubble.size)
            }
        }
        .position(Self.center(anchor: anchor, plot: plot, size: size))
        // 第一帧还没量到尺寸，先透明地量一次，避免气泡在 (0,0) 闪一下。
        .opacity(size == .zero ? 0 : 1)
        .onPreferenceChange(SizeKey.self) { size = $0 }
    }

    /// 上方优先，放不下翻到右边，右边也放不下翻到左边，最后横向夹进绘图区。
    private static func center(anchor: CGPoint, plot: CGRect, size: CGSize) -> CGPoint {
        let gap = ChartHoverStyle.bubbleGap
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        let fitsAbove = anchor.y - gap - size.height >= plot.minY
        let toRight = anchor.x + gap + halfWidth
        let toLeft = anchor.x - gap - halfWidth
        let wantedX = fitsAbove
            ? anchor.x
            : (toRight + halfWidth <= plot.maxX ? toRight : toLeft)
        return CGPoint(
            x: min(max(wantedX, plot.minX + halfWidth), plot.maxX - halfWidth),
            y: fitsAbove
                ? anchor.y - gap - halfHeight
                : max(plot.minY + halfHeight, anchor.y)
        )
    }

    /// 气泡自己的尺寸：翻面和贴边夹取都得先知道它有多大。`onGeometryChange`
    /// 要 macOS 15，这里的部署目标是 14，所以沿用仓库里既有的 PreferenceKey 写法。
    private struct SizeKey: PreferenceKey {
        static let defaultValue: CGSize = .zero

        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            let next = nextValue()
            if next != .zero { value = next }
        }
    }
}

// MARK: - Port presentation

extension PortTelemetry {
    /// A 60 W cable on a port already pulling more than ~55 W is the real reason
    /// charging is slow, and the official app never says so. This is the only
    /// non-fault condition in the app allowed to turn amber.
    var cableIsBottleneck: Bool {
        guard isDelivering, let cable else { return false }
        switch cable {
        case .max60W: return power > 55
        case .max100W: return power > 92
        case .epr240W, .none, .unknown: return false
        }
    }

    /// Text for the cable slot, or `nil` when there is nothing to say — the
    /// firmware's `.none` covers both "no cable" and "not reported", so this
    /// cannot claim either. `nil` means *no chip*, never *no slot*: the caller
    /// keeps the row's shape and dashes the value out, the same as the volt and
    /// amp readings. See `PortCard.cableSlot`.
    var cableChipText: String? {
        guard let cable, cable != .none else { return nil }
        switch cable {
        case .max60W: return L10n.text(cableIsBottleneck ? "线缆限制 60W" : "3A · 60W 线")
        case .max100W: return L10n.text(cableIsBottleneck ? "线缆限制 100W" : "5A · 100W 线")
        case .epr240W: return L10n.text("EPR · 240W 线")
        case .none: return nil
        // The raw code is still in the diagnostics log; on a port card it
        // supports no decision the user can make.
        case .unknown: return L10n.text("未知线缆")
        }
    }

    var profileText: String? { chargingProfile?.label }
}

// MARK: - Connected device (B4)

/// USB VID → 厂商名。**只放能确定的**。
///
/// 0x05AC 是本机实测出来的：三次拔插里，插着 Mac 和 iPhone 的口都报
/// `ac 05`（小端）；没报身份的槽是 `fa ff`。其余几条是不会认错的大厂号段。
///
/// 这张表只回答「谁做的」。**它永远不许回答「哪台机器」**——型号要靠 b5 的
/// 品牌码，而本机的 b5 恒为 `ffffffff`，根本拿不到；靠 PID 猜型号需要一张我们
/// 没有的对照表，猜错的名字比不显示型号更有害。用户界面只保留确定的厂商名，
/// 原始 VID/PID 继续留在协议数据与诊断视图中。
///
/// 表小是刻意的：宁可少认，不可认错。
enum USBVendorTable {
    private static let names: [UInt16: String] = [
        0x04E8: "Samsung",
        0x05AC: "Apple",            // 本机实测
        0x0BDA: "Realtek",
        0x12D1: "Huawei",
        0x18D1: "Google",
        0x1D6B: "Linux Foundation",
        0x2717: "Xiaomi",
        0x291A: "Anker",
        0x8087: "Intel",
    ]

    static func name(for vendorID: UInt16) -> String? { names[vendorID] }
}

extension PortTelemetry {
    /// B4 那对 VID/PID 到底在说什么。四种情况必须分开，它们的文案不许互相顶替。
    ///
    /// 尤其是后两种：`fa ff fb ff` 只说明这一槽没有 USB 身份（口上可能正在充电），`0000:0000` 是报了设备但没给
    /// 东西、只是没报出身份——三口满载时 C3 就是后者。把它们并成一句
    /// 「未接入」是这一行最容易犯也最难被发现的错。
    enum ConnectedDeviceState: Equatable {
        /// 这一帧根本没有 B4。旧固件、或者被截断的帧。
        case unreported
        /// 固件给这一槽报了 FFFA:FFFB —— 只说明没有 USB 身份，不说明口上有没有东西。
        /// 用户自己的抓包里三个口都在充电时这一槽仍是哨兵，所以这个 case 绝不能
        /// 被读成「空口」。
        case noIdentity
        /// 插着东西，但 VID/PID 全零。
        case unidentified
        case identified(USBDeviceID)
    }

    var connectedDeviceState: ConnectedDeviceState {
        guard let device = connectedDevice else { return .unreported }
        if device.isNoIdentity { return .noIdentity }
        if device.vendorID == 0, device.productID == 0 { return .unidentified }
        return .identified(device)
    }

    /// 「接入设备」这一行印什么。`nil` = 没有值可印，调用方留占位符——和线缆槽
    /// 位、伏安读数同一个规矩，整行不许因为没值就消失。
    var connectedDeviceText: String? {
        switch connectedDeviceState {
        case .unreported, .noIdentity:
            return nil
        case .unidentified:
            return L10n.text("已接入 · 未报告身份")
        case .identified(let device):
            return USBVendorTable.name(for: device.vendorID) ?? L10n.text("已接入")
        }
    }

    /// 悬停/读屏时的解释。技术标识留给诊断界面；这里最多说明确定的厂商，避免
    /// 把用户无需理解的 VID/PID 又从 tooltip 或 VoiceOver 暴露出来。
    var connectedDeviceHelp: String {
        switch connectedDeviceState {
        case .unreported:
            return L10n.text("充电器没有报告接入设备的信息")
        case .noIdentity:
            return L10n.text("充电器没报这个口接的是什么。要看有没有插东西，看上面的电压电流。")
        case .unidentified:
            return L10n.text("设备已接入，但没有报出 USB 身份")
        case .identified(let device):
            if let vendor = USBVendorTable.name(for: device.vendorID) {
                return L10n.format("充电器识别到 %@ 设备", vendor)
            }
            return L10n.text("充电器识别到设备，但无法判断厂商")
        }
    }
}
