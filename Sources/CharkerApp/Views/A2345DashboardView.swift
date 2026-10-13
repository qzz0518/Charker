import A2345Protocol
import Charts
import CharkerCore
import SwiftUI

/// Six-port overview for the A2345 cloud path: live readings, the power
/// timeline, and per-port switch, countdown and daily times. A1 and A2 share
/// one switch on the charger, so their two rows drive the same control.
struct A2345DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var selectedPort: ChargerPortID?
    // Seeded from the last mount: every tab switch rebuilds this view, and a
    // first frame at zero width picked the stacked layout, then rebuilt the
    // 3D stage when the real width arrived.
    @MainActor private static var lastContentWidth: CGFloat = 0
    @State private var contentWidth = A2345DashboardView.lastContentWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var snapshot: A2345ConnectionSnapshot { model.a2345Snapshot }
    private var reading: ChargerReading? { snapshot.reading }
    private var history: [PowerSample] { model.a2345PlottedHistory }
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
        FillingScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                overviewCard
                if reading != nil {
                    metricsRow
                }
                if let settings = snapshot.settings, settings.hasFault {
                    faultNotice(settings)
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
        .onContainerWidthChange {
            contentWidth = $0
            Self.lastContentWidth = $0
        }
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
                        text: L10n.text(snapshot.isDemo ? "模拟数据" : "Wi-Fi 云端"),
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
        case .failed: return L10n.text("连接没有完成")
        case .waitingForTelemetry: return L10n.text("等待充电器数据")
        default: return L10n.text("连接 Anker Prime 250W")
        }
    }

    @ViewBuilder
    private var instrumentBody: some View {
        // The default 969 pt window leaves roughly 760 pt after the sidebar.
        // Keep the six-port instrument in its compact two-column form there;
        // stacking at the old 820 pt threshold made the default overview taller
        // than the window and introduced avoidable page scrolling.
        if contentWidth == 0 || contentWidth >= 720 {
            HStack(alignment: .top, spacing: Space.l) {
                A2345ModelStage(
                    active: snapshot.hasFreshTelemetry,
                    stale: snapshot.isStale,
                    reading: reading,
                    homeCamera: $model.preferences.a2345ModelHomeCamera,
                    height: 338
                )
                .frame(maxWidth: .infinity)
                portPanel.frame(width: 344)
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
        let group = port.a2345Group
        let faulted = group.map { snapshot.settings?.hasFault($0) ?? false } ?? false
        return HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.xs) {
                    Image(systemName: faulted
                        ? "exclamationmark.triangle.fill"
                        : (port.connectorLabel == "USB-C" ? "cable.connector" : "powerplug"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(faulted
                            ? Palette.danger
                            : (freshDelivery ? Palette.accentText : Palette.textTertiary))
                    Text(port.label)
                        .font(.numeral(12, .semibold))
                        .foregroundStyle(freshDelivery ? Palette.accentText : Palette.textPrimary)
                    let nickname = model.preferences.portNicknames[port.rawValue]
                    if let name = nickname.isEmpty ? value?.deviceBrand.map(brandLabel) : nickname {
                        Text(name)
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                    }
                    if let fastCharge = value?.fastCharge {
                        Chip(text: fastChargeChipLabel(fastCharge), tone: freshDelivery ? .accent : .neutral)
                            .scaleEffect(0.86, anchor: .leading)
                    }
                }
                Text(portDetail(value, group: group))
                    .font(Typo.micro)
                    .foregroundStyle(faulted ? Palette.dangerText : Palette.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                if let group {
                    A2345PortTimerLine(model: model, group: group)
                }
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
            .frame(width: 62, alignment: .trailing)
            if let group, snapshot.hasSettings {
                A2345PortControls(model: model, group: group)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.xs)
        .frame(minHeight: 48)
        .background(selected
            ? (snapshot.isStale ? Palette.surfaceRaised : Palette.accentWash.opacity(0.62))
            : Color.clear)
        .contentShape(Rectangle())
        // Not a Button: the switch and countdown menu inside the row must stay
        // clickable. A tap elsewhere on the row selects the port.
        .onTapGesture { toggleSelection(port) }
        .focusable()
        .onKeyPress(phases: .down) { press in
            guard press.key == .return || press.characters == " " else { return .ignored }
            toggleSelection(port)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.format("%@ 端口", port.label)))
        .accessibilityValue(Text(portAccessibilityValue(value, group: group)))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { toggleSelection(port) }
        .accessibilityHint(Text(selected
            ? L10n.text("按下以取消此端口曲线筛选")
            : L10n.text("按下以筛选此端口曲线")))
    }

    private func toggleSelection(_ port: ChargerPortID) {
        withAnimation(Motion.reduced(Motion.ui, reduceMotion)) {
            selectedPort = selectedPort == port ? nil : port
        }
    }

    private func faultNotice(_ settings: A2345DeviceSettings) -> some View {
        let groups = A2345PortGroup.allCases.filter { settings.hasFault($0) }
        let text = settings.isOverTemperature
            ? L10n.text("充电器温度过高，已启用过温保护。")
            : (groups.isEmpty
                ? L10n.text("充电器报告了端口异常。")
                : L10n.format("%@ 端口异常。", groups.map(\.label).joined(separator: L10n.text("、"))))
        return SlateCard(padding: Space.m) {
            HStack(alignment: .center, spacing: Space.m) {
                Image(systemName: settings.isOverTemperature ? "thermometer.high" : "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.danger)
                    .accessibilityHidden(true)
                Text(text)
                    .font(Typo.body)
                    .foregroundStyle(Palette.dangerText)
                    .cjkParagraph(13)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private func portDetail(_ value: ChargerPortReading?, group: A2345PortGroup? = nil) -> String {
        if let group, let settings = snapshot.settings {
            if settings.hasFault(group) { return L10n.text("端口异常") }
            if settings.portControls[group]?.isOn == false { return L10n.text("已关闭") }
        }
        guard let value, value.isOn else { return L10n.text("未输出") }
        if value.hasReadings {
            let electrical = L10n.format("%.2f V · %.2f A", value.voltage, value.current)
            guard let cable = value.cable else { return electrical }
            return L10n.format("%@ · %@", electrical, cableLabel(cable))
        }
        return L10n.text("已开启 · 等待负载")
    }

    // Short forms: the row is 310 pt wide and also carries the readings.
    private func cableLabel(_ cable: PortCable) -> String {
        switch cable {
        case .threeAmp: L10n.text("3A 线")
        case .fiveAmp: L10n.text("5A 线")
        case .epr: L10n.text("EPR 线")
        case .huawei: L10n.text("华为线")
        case .xiaomi: L10n.text("小米线")
        }
    }

    private func fastChargeChipLabel(_ fastCharge: PortFastCharge) -> String {
        switch fastCharge {
        case .huaweiSCP: "SCP"
        case .xiaomiHyperCharge: L10n.text("澎湃秒充")
        }
    }

    private func fastChargeLabel(_ fastCharge: PortFastCharge) -> String {
        switch fastCharge {
        case .huaweiSCP: L10n.text("华为 SCP")
        case .xiaomiHyperCharge: L10n.text("小米澎湃秒充")
        }
    }

    private func brandLabel(_ brand: PortDeviceBrand) -> String {
        switch brand {
        case .huaweiHonor: L10n.text("华为/荣耀")
        case .xiaomi: L10n.text("小米")
        }
    }

    private func portAccessibilityValue(_ value: ChargerPortReading?, group: A2345PortGroup?) -> String {
        var parts: [String] = []
        if let value, value.hasReadings {
            parts.append(L10n.format("%.1f 瓦", value.power))
        }
        parts.append(portDetail(value, group: group))
        if let fastCharge = value?.fastCharge { parts.append(fastChargeLabel(fastCharge)) }
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
                // Each line needs its own `series`: without it Swift Charts
                // joins the total and the selected port into one polyline that
                // zigzags between the two values on every sample.
                ForEach(history) { sample in
                    AreaMark(
                        x: .value(ChartLabel.time, sample.at),
                        y: .value(ChartLabel.totalPower, sample.total)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(snapshot.isStale ? ChartLabel.staleAreaFill : ChartLabel.areaFill)
                    LineMark(
                        x: .value(ChartLabel.time, sample.at),
                        y: .value(ChartLabel.totalPower, sample.total),
                        series: .value(ChartLabel.series, ChartLabel.total)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(snapshot.isStale ? Palette.textTertiary : Palette.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
                if let selectedPort {
                    ForEach(selectedPortSeries) { sample in
                        LineMark(
                            x: .value(ChartLabel.time, sample.at),
                            y: .value(ChartLabel.totalPower, sample.perPort[selectedPort.rawValue]),
                            series: .value(ChartLabel.series, selectedPort.label)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Palette.textSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [4, 3]))
                    }
                }
            }
            // Selecting a port swaps the dashed series in place. Animating
            // that change morphs hundreds of points at once and reads as the
            // whole chart flickering.
            .transaction(value: selectedPort) { transaction in
                transaction.animation = nil
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
            // Grows with the window, see ``FillingScrollView``.
            .frame(minHeight: 172, idealHeight: 172, maxHeight: .infinity)
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
        let stats = self.stats
        return HStack(spacing: 0) {
            metric("峰值", value: formatted(stats.peak, decimals: 1), unit: "W")
            metricDivider
            metric("平均", value: formatted(stats.average, decimals: 1), unit: "W")
            metricDivider
            metric("本次能量", value: formatted(stats.energyWh, decimals: 2), unit: "Wh")
            metricDivider
            metric("数据来源", value: snapshot.isDemo ? L10n.text("模拟") : L10n.text("云端"), unit: nil)
        }
        .padding(.vertical, Space.m)
        .fixedSize(horizontal: false, vertical: true)
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
        static let series = L10n.text("系列")
        static let total = L10n.text("总输出")
        static let areaFill = LinearGradient(
            colors: [Palette.accent.opacity(0.26), Palette.accent.opacity(0.02)],
            startPoint: .top, endPoint: .bottom
        )
        static let staleAreaFill = LinearGradient(
            colors: [Palette.textTertiary.opacity(0.16), Palette.textTertiary.opacity(0.01)],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// Samples that carry the selected port, so the dashed line never has to
    /// skip an older reading recorded before the port count was known.
    private var selectedPortSeries: [PowerSample] {
        guard let selectedPort else { return [] }
        return history.filter { selectedPort.rawValue < $0.perPort.count }
    }
}
