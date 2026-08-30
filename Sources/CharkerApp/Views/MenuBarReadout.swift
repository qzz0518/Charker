import A2687Protocol
import Charts
import CharkerCore
import SwiftUI

/// The menu bar popover: a compressed mirror of the dashboard — same rail, same
/// shared 0–160 W scale, same face split — so it reads as the same app rather
/// than a second design.
struct MenuBarReadout: View {
    @ObservedObject var model: AppModel
    let openMainWindow: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var snapshot: SessionSnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            total
            sparkline
            ports
            if let warning = snapshot.warning ?? snapshot.lastError {
                Text(warning)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .cjkParagraph(11, target: 1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Palette.stroke)
            footer
        }
        .padding(Space.l)
        .frame(width: 340)
        .background(Palette.surface)
        .tint(Palette.accent)
        // Drives the sparkline's first appearance; its .transition is inert
        // without an animated transaction around the insertion.
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: snapshot.history.count > 8)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(snapshot.displayName ?? L10n.text("未连接"))
                .font(Typo.heading)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Space.s)
            HStack(spacing: Space.xs) {
                StateDot(phase: snapshot.phase, stale: snapshot.isStale)
                Text(snapshot.isStale ? L10n.text("数据陈旧") : snapshot.statusLabel)
                    .font(Typo.caption)
                    .foregroundStyle(snapshot.isStale ? Palette.warnText : Palette.textSecondary)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.18), value: snapshot.statusLabel)
            }
        }
    }

    private var total: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            TotalReadout(watts: snapshot.totalPower, isStale: snapshot.isStale, size: 30)
            PowerRail(
                watts: snapshot.totalPower ?? 0,
                isDelivering: (snapshot.totalPower ?? 0) > 0,
                dimmed: snapshot.isStale
            )
        }
    }

    /// Mark labels and the fill, resolved once — mirroring DashboardView's.
    /// Inline `L10n.text` re-hit the bundle for every one of the 90 samples on
    /// each body evaluation. Swift Charts feeds the labels to the
    /// accessibility descriptor, so they stay semantically distinct.
    private enum ChartLabel {
        static let time = L10n.text("时间")
        static let watts = L10n.text("功率")
        static let areaFill = LinearGradient(
            colors: [Palette.accent.opacity(0.22), Palette.accent.opacity(0.02)],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// The last few minutes at a glance — same curve as the dashboard, stripped
    /// of every axis. Just the shape.
    @ViewBuilder
    private var sparkline: some View {
        if snapshot.history.count > 8 {
            Chart(snapshot.history.suffix(90)) { sample in
                AreaMark(
                    x: .value(ChartLabel.time, sample.at),
                    y: .value(ChartLabel.watts, sample.total)
                )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(ChartLabel.areaFill)
                LineMark(
                    x: .value(ChartLabel.time, sample.at),
                    y: .value(ChartLabel.watts, sample.total)
                )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round))
                    .foregroundStyle(Palette.accent.opacity(0.8))
            }
            .chartYScale(domain: 0...168)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 36)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .transition(.opacity)
        }
    }

    private var ports: some View {
        // One nickname widens the label column for ALL rows — the watt figures
        // have to stay aligned — and the rail is what pays for it, because the
        // popover's width is fixed and the V/A column may not give any back.
        // See `PortStrip.detailWidth` for the full budget.
        let hasNicknames = model.preferences.portNicknames.contains { !$0.isEmpty }
        return VStack(spacing: Space.xxs) {
            ForEach(A2687.Port.allCases, id: \.rawValue) { port in
                PortStrip(
                    port: port,
                    telemetry: snapshot.telemetry?.port(port),
                    nickname: model.preferences.portNicknames.indices.contains(port.rawValue)
                        ? model.preferences.portNicknames[port.rawValue] : "",
                    labelWidth: hasNicknames ? 64 : 22,
                    railWidth: hasNicknames ? 60 : 82
                )
            }
        }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: hasNicknames)
    }

    private var footer: some View {
        HStack(spacing: Space.s) {
            Button("打开主窗口", action: openMainWindow)
                .buttonStyle(WashButtonStyle())
            Button("重新连接") { model.reconnect() }
                .buttonStyle(GhostButtonStyle())
            Spacer()
            // Not a power glyph: in an app that can switch charger ports, ⏻
            // reads as "cut the power", which quitting very much is not.
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(GhostButtonStyle())
                .help("退出 Charker（不影响充电器输出）")
        }
    }
}

private struct PortStrip: View {
    let port: A2687.Port
    let telemetry: PortTelemetry?
    /// Dashboard nickname; shown in place of the bare port name when set.
    var nickname = ""
    var labelWidth: CGFloat = 22
    var railWidth: CGFloat = 82
    /// The V/A column, reserved rather than left to fend for itself.
    ///
    /// It used to be the row's last child behind a `Spacer`, so it got whatever
    /// the other columns had not already taken — 64pt once a nickname widened
    /// the label. `20.0V 2.86A` measures 67.8pt in this face, so a port pulling
    /// two-digit amps printed `20.0V 2.8…` while `5.2V 0.50A` one row above,
    /// 7pt shorter because tabular digits make width a pure digit count, fit
    /// fine. An ellipsis on a reading is worse than no reading at all: it looks
    /// like a number and is not one.
    ///
    /// So the column is pinned wide enough for the longest real form and the
    /// rail absorbs the difference. Budget across the 292pt the strip has
    /// (340pt popover − 2×`Space.l` − 2×`Space.s` of its own padding), with
    /// four `Space.s` gaps: label 64 + watts 56 + rail 60 + detail 72 = 284
    /// with a nickname, 22 + 56 + 82 + 72 = 264 without; the `Spacer` swallows
    /// the 8pt and 28pt left over. A nickname past ~64pt truncates instead —
    /// the user wrote that string and can shorten it; they did not write the
    /// voltage.
    private static let detailWidth: CGFloat = 72
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDelivering: Bool { telemetry?.isDelivering ?? false }
    private var watts: Double { telemetry?.isOn == true ? (telemetry?.power ?? 0) : 0 }

    /// Same rule as the port card: what the strip *prints* is `hasReadings`,
    /// what it *says* is `isDelivering`/`isStandby`. The popover used to gate its
    /// digits on the delivering threshold, so a 5.0 V / 0.1 A device read
    /// "— / 未接入" here while the dashboard inspector, two clicks away, showed
    /// 0.5 W / 5.00 V / 0.10 A for the same sample.
    private var hasReadings: Bool { telemetry?.hasReadings ?? false }

    /// No grace window: the popover is built fresh on every open, so a window
    /// tracked here would be empty exactly when it was needed. See `PortStandby`.
    private var isStandby: Bool { PortStandby.applies(to: telemetry) }

    var body: some View {
        HStack(spacing: Space.s) {
            // The nickname replaces the bare port name — same rule as the menu
            // bar itself. CJK nicknames must not go through the rounded face.
            Text(nickname.isEmpty ? port.label : nickname)
                .font(nickname.isEmpty ? .numeral(12, .bold) : Typo.label)
                .foregroundStyle(isDelivering ? Palette.accentText : Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: labelWidth, alignment: .leading)
                .help(nickname.isEmpty ? port.label : "\(port.label) · \(nickname)")

            Group {
                if hasReadings {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(L10n.format("%.1f", watts))
                            .font(.numeral(13, .medium))
                            .foregroundStyle(isDelivering ? Palette.textPrimary : Palette.textSecondary)
                            .contentTransition(.numericText(value: watts))
                        Text("W")
                            .font(.ui(10, .medium))
                            .foregroundStyle(Palette.textTertiary)
                    }
                } else {
                    Text("—")
                        .font(.numeral(13, .medium))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .frame(width: 56, alignment: .trailing)
            // The transition the dashboard numbers get, the popover gets too:
            // numericText only rolls inside an animated transaction.
            .animation(Motion.reduced(Motion.value, reduceMotion), value: watts)

            PowerRail(watts: watts, isDelivering: isDelivering)
                .frame(width: railWidth)

            Spacer(minLength: 0)

            Text(detail)
                // `.numeral` is tabular, so the column holds still while the
                // reading moves instead of breathing with every digit.
                .font(detailIsNumeric ? .numeral(11, .regular) : Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                // Last resort for a reading nobody budgeted for — a three-digit
                // voltage would want 75pt. Shrink the glyphs, never clip them.
                .minimumScaleFactor(0.85)
                .frame(width: Self.detailWidth, alignment: .trailing)
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .background(
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                .fill(hovering ? Palette.surfaceRaised : .clear)
        )
        .onHover { hovering = $0 }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: hovering)
    }

    /// Chinese status words must not go through the rounded numeral face — the
    /// CJK glyphs silently fall back and the string splits its personality.
    private var detailIsNumeric: Bool { hasReadings }

    /// The card has two slots and can print digits *and* a status word; this row
    /// has one, so the digits win whenever there are any. 待机 is left to say
    /// what it alone can say: attached (cable or held rail) with nothing to read.
    private var detail: String {
        guard let telemetry else { return L10n.text("无数据") }
        guard telemetry.isOn else { return L10n.text("已关闭") }
        if hasReadings {
            return L10n.format("%.1fV %.2fA", telemetry.voltage, telemetry.current)
        }
        if isStandby { return L10n.text("待机") }
        return L10n.text("未接入")
    }
}
