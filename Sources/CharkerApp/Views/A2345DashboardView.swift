import Charts
import CharkerCore
import SwiftUI

/// Six-port, read-only overview for the A2345 cloud path.
///
/// It intentionally does not reuse the A2687 inspector: the latter exposes
/// proven BLE writes and cable fields the MQTT frame does not provide. Here the
/// hierarchy says exactly what is known—live V/A/W, connection freshness and
/// optional USB identity—without mounting switches that cannot be honoured.
struct A2345DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var selectedPort: ChargerPortID?
    @State private var contentWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var snapshot: A2345ConnectionSnapshot { model.a2345Snapshot }
    private var reading: ChargerReading? { snapshot.reading }
    private var history: [PowerSample] { PowerSample.decimated(snapshot.history) }
    private var chartObservedPeak: Double {
        history.reduce(0) { max($0, $1.total) }
    }
    private var chartAxisMaximum: Int {
        PowerChartScale.effectiveMaximum(
            preference: model.preferences.a2345PowerChartMaximum,
            product: .a2345,
            observedPeak: chartObservedPeak
        )
    }
    private var failureReason: String? {
        guard case .failed(let reason) = snapshot.phase else { return nil }
        return reason
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                overviewCard
                if reading != nil {
                    metricsRow
                }
                if let failureReason, reading != nil {
                    failureNotice(failureReason)
                }
                if let warning = snapshot.warning {
                    SlateCard {
                        HStack(alignment: .top, spacing: Space.s) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Palette.warn)
                            Text(warning)
                                .font(Typo.caption)
                                .foregroundStyle(Palette.warnText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(Space.xxl)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.bg.ignoresSafeArea())
        .measuringContainerWidth()
        .onContainerWidthChange { contentWidth = $0 }
        // Telemetry is an instrument reading, not a decorative transition.
        // A new sample replaces the previous values atomically so a 2-second
        // feed cannot keep the whole chart and six rows interpolating almost
        // continuously. Local interactions (selection and navigation) still
        // carry their own scoped animations.
        .transaction(value: snapshot.lastUpdate) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var overviewCard: some View {
        SlateCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                summaryHeader
                Rectangle().fill(Palette.stroke).frame(height: Stroke.hairline)
                if reading == nil {
                    emptyState
                } else {
                    instrumentBody.padding(Space.xl)
                    Rectangle().fill(Palette.stroke).frame(height: Stroke.hairline)
                    chartSection
                }
            }
        }
    }

    private var summaryHeader: some View {
        HStack(alignment: .center, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text("实时总输出")
                        .font(Typo.label)
                        .foregroundStyle(Palette.textSecondary)
                    Chip(
                        text: L10n.text(snapshot.isDemo ? "模拟数据" : "Wi-Fi 云端只读"),
                        tone: .neutral
                    )
                }
                Text(portSummary)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: Space.l)
            VStack(alignment: .trailing, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text(reading.map { formatted($0.totalPower, decimals: 1) } ?? "—")
                        .font(.numeral(34, .semibold))
                        .foregroundStyle(snapshot.isStale ? Palette.textTertiary : Palette.textPrimary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("W")
                        .font(Typo.label)
                        .foregroundStyle(Palette.textSecondary)
                }
                connectionStatus
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.l)
    }

    private var connectionStatus: some View {
        let tone = A2345StateTone(
            phase: snapshot.phase,
            stale: snapshot.isStale,
            isDemo: snapshot.isDemo
        )
        return HStack(spacing: Space.xs) {
            A2345StateDot(
                phase: snapshot.phase,
                stale: snapshot.isStale,
                isDemo: snapshot.isDemo,
                diameter: 6,
                glowsWhenLive: false
            )
            Text(model.activeStatusLabel)
                .font(Typo.micro)
                .foregroundStyle(tone.labelColor)
        }
    }

    private var emptyState: some View {
        Group {
            if contentWidth == 0 || contentWidth >= 720 {
            HStack(alignment: .center, spacing: Space.xl) {
                emptyPreview.frame(maxWidth: 430)
                emptyDetails
            }
            } else {
            VStack(alignment: .leading, spacing: Space.l) {
                emptyPreview.frame(maxWidth: .infinity)
                emptyDetails
            }
            }
        }
        .padding(Space.xl)
    }

    private var emptyPreview: some View {
        A2345ProductStage(active: false, height: 196)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.l)
            .frame(height: 276)
            .background(Palette.well.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                    .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
            }
    }

    private var emptyDetails: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(emptyTitle)
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)
                Text(model.activeStatusDetail)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .cjkParagraph(11, target: 1.55)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Space.s) {
                fact("4 × USB-C + 2 × USB-A", symbol: "powerplug")
                fact("250 W 总功率", symbol: "bolt.fill")
                fact("数据通过 Anker 云端加密订阅读取", symbol: "lock.shield")
            }

            HStack(spacing: Space.s) {
                if snapshot.phase.isBusy || snapshot.phase == .waitingForTelemetry {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(snapshot.phase.shortLabel)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityLabel(Text(verbatim:
                            "\(snapshot.phase.shortLabel)：\(snapshot.phase.detail)"
                        ))
                } else if failureReason != nil, model.canRetryA2345 {
                    Button {
                        model.retryA2345Connection()
                    } label: {
                        Label("重新连接", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                } else {
                    Button {
                        model.useA2345CloudConnection()
                    } label: {
                        Label("前往连接", systemImage: "person.badge.key")
                    }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                }

                Button {
                    model.enterDemoMode(product: .a2345)
                } label: {
                    Label("体验模拟设备", systemImage: "play.fill")
                }
                .buttonStyle(CharkerActionButtonStyle())
                .disabled(snapshot.isDemo)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failureNotice(_ reason: String) -> some View {
        SlateCard(padding: Space.m) {
            HStack(alignment: .center, spacing: Space.m) {
                Image(systemName: "bolt.slash.fill")
                    .foregroundStyle(Palette.danger)
                    .accessibilityHidden(true)
                Text(reason)
                    .font(Typo.body)
                    .foregroundStyle(Palette.dangerText)
                    .cjkParagraph(13)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.m)
                if model.canRetryA2345 {
                    Button {
                        model.retryA2345Connection()
                    } label: {
                        Label("重新连接", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.format("连接失败：%@", reason)))
    }

    private var emptyTitle: String {
        switch snapshot.phase {
        case .failed: return L10n.text("A2345 连接没有完成")
        case .waitingForTelemetry: return L10n.text("已订阅，等待充电器上报")
        default: return L10n.text("连接 Anker Prime 250W")
        }
    }

    private func fact(_ text: String, symbol: String) -> some View {
        Label(L10n.text(text), systemImage: symbol)
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
    }

    @ViewBuilder
    private var instrumentBody: some View {
        // The default 969 pt window leaves roughly 760 pt after the sidebar.
        // Keep the six-port instrument in its compact two-column form there;
        // stacking at the old 820 pt threshold made the default overview taller
        // than the window and introduced avoidable page scrolling.
        if contentWidth >= 720 {
            HStack(alignment: .top, spacing: Space.l) {
                A2345ModelStage(
                    active: snapshot.hasFreshTelemetry,
                    stale: snapshot.isStale,
                    reading: reading,
                    homeCamera: $model.preferences.a2345ModelHomeCamera,
                    height: 338
                )
                .frame(maxWidth: .infinity)
                portPanel.frame(width: 310)
            }
        } else {
            VStack(spacing: Space.l) {
                A2345ModelStage(
                    active: snapshot.hasFreshTelemetry,
                    stale: snapshot.isStale,
                    reading: reading,
                    homeCamera: $model.preferences.a2345ModelHomeCamera,
                    height: 292
                )
                portPanel
            }
        }
    }

    private var portPanel: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("端口")
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: Space.s)
                Text(selectedPort.map { L10n.format("已选 %@", $0.label) }
                    ?? L10n.text("点击端口查看单口曲线"))
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)

            Rectangle().fill(Palette.stroke).frame(height: Stroke.hairline)

            ForEach(ChargerProduct.a2345.ports) { port in
                a2345PortRow(port)
                if port != ChargerProduct.a2345.ports.last {
                    Rectangle()
                        .fill(Palette.stroke)
                        .frame(height: Stroke.hairline)
                        .padding(.horizontal, Space.m)
                }
            }
        }
        .background(Palette.well)
        .clipShape(RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
        }
    }

    private func a2345PortRow(_ port: ChargerPortID) -> some View {
        let value = reading?.port(port)
        let selected = selectedPort == port
        let freshDelivery = value?.isDelivering == true && !snapshot.isStale
        return Button {
            withAnimation(Motion.reduced(Motion.ui, reduceMotion)) {
                selectedPort = selected ? nil : port
            }
        } label: {
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Space.xs) {
                        Image(systemName: port.connectorLabel == "USB-C" ? "cable.connector" : "powerplug")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(freshDelivery ? Palette.accentText : Palette.textTertiary)
                        Text(port.label)
                            .font(.numeral(12, .semibold))
                            .foregroundStyle(freshDelivery ? Palette.accentText : Palette.textPrimary)
                        let nickname = model.preferences.portNicknames[port.rawValue]
                        if !nickname.isEmpty {
                            Text(nickname)
                                .font(Typo.micro)
                                .foregroundStyle(Palette.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Text(portDetail(value))
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: Space.s)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value?.hasReadings == true ? formatted(value?.power ?? 0, decimals: 1) : "—")
                        .font(.numeral(18, .semibold))
                        .foregroundStyle(snapshot.isStale
                            ? Palette.textTertiary
                            : (value?.isDelivering == true ? Palette.textPrimary : Palette.textSecondary))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("W")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                }
                .frame(width: 72, alignment: .trailing)
            }
            .padding(.horizontal, Space.m)
            .frame(height: 48)
            .background(selected
                ? (snapshot.isStale ? Palette.surfaceRaised : Palette.accentWash.opacity(0.62))
                : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.format("%@ 端口", port.label)))
        .accessibilityValue(Text(portAccessibilityValue(value)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(Text(selected
            ? L10n.text("按下以取消此端口曲线筛选")
            : L10n.text("按下以筛选此端口曲线")))
    }

    private func portDetail(_ value: ChargerPortReading?) -> String {
        guard let value, value.isOn else { return L10n.text("未输出") }
        if value.hasReadings {
            return L10n.format("%.2f V · %.2f A", value.voltage, value.current)
        }
        return L10n.text("已开启 · 等待负载")
    }

    private func portAccessibilityValue(_ value: ChargerPortReading?) -> String {
        var parts: [String] = []
        if let value, value.hasReadings {
            parts.append(L10n.format("%.1f 瓦", value.power))
        }
        parts.append(portDetail(value))
        if snapshot.isStale { parts.append(L10n.text("数据已陈旧")) }
        return parts.joined(separator: L10n.text("，"))
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Text("功率时间线")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: Space.s)
                Text(selectedPort.map { L10n.format("总输出 + %@", $0.label) }
                    ?? L10n.text("点击端口筛选单口曲线"))
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                PowerChartScaleMenu(
                    product: .a2345,
                    observedPeak: chartObservedPeak,
                    preference: $model.preferences.a2345PowerChartMaximum
                )
            }

            Chart {
                ForEach(history) { sample in
                    LineMark(
                        x: .value(ChartLabel.time, sample.at),
                        y: .value(ChartLabel.totalPower, sample.total)
                    )
                    .foregroundStyle(snapshot.isStale ? Palette.textTertiary : Palette.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

                    if let selectedPort,
                       selectedPort.rawValue < sample.perPort.count {
                        LineMark(
                            x: .value(ChartLabel.time, sample.at),
                            y: .value(selectedPort.label, sample.perPort[selectedPort.rawValue])
                        )
                        .foregroundStyle(Palette.textSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.1, dash: [4, 3]))
                    }
                }
            }
            .chartYScale(domain: 0...PowerChartScale.chartCeiling(maximum: chartAxisMaximum))
            .chartYAxis {
                AxisMarks(values: PowerChartScale.axisValues(maximum: chartAxisMaximum)) { value in
                    AxisGridLine().foregroundStyle(Palette.stroke)
                    AxisValueLabel {
                        if let watts = value.as(Int.self) {
                            Text(watts == chartAxisMaximum
                                ? L10n.format("%d W", watts)
                                : "\(watts)")
                                .font(Typo.micro)
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Palette.stroke.opacity(0.55))
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .frame(height: 172)
            .accessibilityLabel(Text(L10n.text("本次实时功率趋势")))
            .accessibilityValue(Text(model.activeStatusLabel))
            .padding(Space.m)
            .background(Palette.well)
            .clipShape(RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                    .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
            }
        }
        .padding(Space.xl)
    }

    private var metricsRow: some View {
        HStack(spacing: 0) {
            metric("峰值", value: formatted(stats.peak, decimals: 1), unit: "W")
            metricDivider
            metric("平均", value: formatted(stats.average, decimals: 1), unit: "W")
            metricDivider
            metric("本次能量", value: formatted(stats.energyWh, decimals: 2), unit: "Wh")
            metricDivider
            metric("数据来源", value: snapshot.isDemo ? L10n.text("模拟") : L10n.text("云端"), unit: nil)
        }
        .padding(.vertical, Space.m)
        .opacity(snapshot.isStale ? 0.45 : 1)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
        }
    }

    private func metric(_ title: String, value: String, unit: String?) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(L10n.text(title)).font(Typo.micro).foregroundStyle(Palette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.numeral(17, .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .monospacedDigit()
                if let unit {
                    Text(unit).font(Typo.micro).foregroundStyle(Palette.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.l)
    }

    private var metricDivider: some View {
        Rectangle().fill(Palette.stroke).frame(width: Stroke.hairline, height: 40)
    }

    private var portSummary: String {
        guard let reading else {
            return L10n.text("6 端口 · 250 W 上限")
        }
        return L10n.format(
            "%d / 6 端口在充电 · 250 W 上限",
            reading.activePortCount
        )
    }

    private var stats: (peak: Double, average: Double, energyWh: Double) {
        guard !snapshot.history.isEmpty else { return (0, 0, 0) }
        var peak = 0.0
        var sum = 0.0
        var energy = 0.0
        for (index, sample) in snapshot.history.enumerated() {
            peak = max(peak, sample.total)
            sum += sample.total
            guard index > 0 else { continue }
            let previous = snapshot.history[index - 1]
            let seconds = sample.at.timeIntervalSince(previous.at)
            if seconds > 0, seconds < EnergyHistory.maximumIntegrableGap {
                energy += seconds * (sample.total + previous.total) / 2 / 3_600
            }
        }
        return (peak, sum / Double(snapshot.history.count), energy)
    }

    private func formatted(_ value: Double, decimals: Int) -> String {
        value.formatted(
            .number
                .locale(L10n.locale())
                .precision(.fractionLength(decimals))
        )
    }

    private enum ChartLabel {
        static let time = L10n.text("时间")
        static let totalPower = L10n.text("总功率")
    }
}
