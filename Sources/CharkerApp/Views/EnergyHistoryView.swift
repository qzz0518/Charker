import AppKit
import Charts
import CharkerCore
import SwiftUI
import UniformTypeIdentifiers

private struct AnalyticsSideColumnHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Long-term, local-only energy history. The visual metaphor is an EV trip log:
/// a calm odometer at the top, a range chart, then inspectable connection runs.
struct EnergyHistoryView: View {
    @ObservedObject var model: AppModel
    @State private var range: HistoryRange
    @State private var selectedPeriod: Date?
    @State private var chartMetric: HistoryChartMetric = .energy
    @State private var contentRevision = 0
    @State private var visibleSessionLimit = 16
    @State private var contentWidth: CGFloat = 0
    @State private var operationResult: String?
    @State private var confirmingClear = false
    @State private var pendingClearScope: HistoryClearScope?
    @State private var showingElectricityRate = false
    @State private var sideBySideAnalyticsHeight: CGFloat = 0
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel) {
        self.model = model
        _range = State(initialValue:
            HistoryRange(rawValue: model.preferences.dashboardEnergyScope) ?? .session
        )
    }

    private var history: EnergyHistory { model.displayedEnergyHistory }

    /// All range-scoped aggregates, resolved once per body evaluation. These
    /// used to be computed properties that re-ran the full-history
    /// filter + reduce on every access — `summary` alone was read ~18 times per
    /// pass — and, because `Date()` was re-read for each access, no two reads
    /// even agreed on the range bounds. One digest per pass fixes both.
    private struct HistoryDigest {
        let now: Date
        let rangeStart: Date?
        let rangeEnd: Date
        let summary: EnergyHistorySummary
        let periods: [EnergyPeriodRecord]
        let sessions: [EnergySessionRecord]
        let portSlices: [PortEnergySlice]
        let renderedPortSlices: [PortEnergySlice]
        let loadBands: [PowerLoadBand]
        let loadBandCeiling: Double
    }

    private enum PortMixLayout {
        case stacked
        case inline
    }

    private func makeDigest() -> HistoryDigest {
        let now = Date()
        let rangeStart: Date?
        if range == .session {
            rangeStart = history.activeSession?.startedAt
        } else {
            rangeStart = range.start(now: now, calendar: calendar)
        }
        let rangeEnd = now.addingTimeInterval(1)

        let summary: EnergyHistorySummary
        let periods: [EnergyPeriodRecord]
        let sessions: [EnergySessionRecord]
        if range == .session {
            summary = history.currentSessionSummary
            periods = history.currentSessionPeriod.map { [$0] } ?? []
            sessions = history.activeSession.map { [$0] } ?? []
        } else {
            summary = history.summary(from: rangeStart, to: rangeEnd)
            periods = history.periods(
                from: rangeStart,
                to: rangeEnd,
                granularity: range.granularity,
                calendar: calendar
            )
            sessions = history.sessionRecords(from: rangeStart, to: rangeEnd)
        }

        let portSlices = makePortSlices(summary: summary)
        let loadBands = makeLoadBands(periods: periods)
        return HistoryDigest(
            now: now,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            summary: summary,
            periods: periods,
            sessions: sessions,
            portSlices: portSlices,
            renderedPortSlices: portSlices.filter { $0.energyWh > 0 && $0.percentage > 0 },
            loadBands: loadBands,
            loadBandCeiling: max(1, loadBands.map(\.seconds).max() ?? 0)
        )
    }

    var body: some View {
        let digest = makeDigest()
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header

                // 两条警告说的是两件独立的事，可以同时成立：一条讲这份存档是
                // 怎么读进来（或没读进来）的，另一条讲系统时间不可信、这一轮
                // 保留期裁剪主动跳过了。后者没有出口时，用户只会觉得历史页的
                // 数字有点怪，却没有任何线索指向 Mac 的日期与时间。
                if !model.energyHistoryIsEphemeral {
                    if let warning = model.energyHistoryWarning {
                        warningCard(warning)
                    }
                    if let notice = history.skippedCompactionNotice {
                        warningCard(notice)
                    }
                }

                if digest.periods.isEmpty, digest.sessions.isEmpty {
                    emptyState
                } else {
                    summaryCard(digest)
                    analyticsWorkspace(digest)
                    sessionLedger(digest)
                }

                provenance
            }
            .padding(Space.xxl)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.bg.ignoresSafeArea())
        .measuringContainerWidth()
        .onContainerWidthChange { contentWidth = $0 }
        .onChange(of: range) { _, newValue in
            selectedPeriod = nil
            contentRevision += 1
            visibleSessionLimit = 16
            if newValue != .all {
                model.preferences.dashboardEnergyScope = newValue.rawValue
            }
        }
        .onChange(of: chartMetric) { _, _ in
            // A hover date from the old metric must not be projected through a
            // new Chart while its marks and coordinate space are being rebuilt.
            selectedPeriod = nil
        }
        .sheet(isPresented: $showingElectricityRate) {
            ElectricityRateSheet(model: model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .top, spacing: Space.l) {
                titleBlock
                Spacer(minLength: Space.m)
                observationBadge
            }
            headerControls
        }
    }

    private var headerControls: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.m) {
                    rangePicker
                    Spacer(minLength: 0)
                    exportMenu
                    endSessionButton
                    clearHistoryButton
                }
                VStack(alignment: .leading, spacing: Space.m) {
                    rangePicker
                    HStack(spacing: Space.m) {
                        exportMenu
                        endSessionButton
                        clearHistoryButton
                    }
                }
            }
            if let operationResult {
                Text(operationResult)
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .transition(.opacity)
            }
        }
        .animation(Motion.reduced(Motion.value, reduceMotion), value: operationResult)
        // 和 AppModel 的操作提示一样自己退场：导出是一次性动作，成功提示留在
        // 屏幕上比消失更碍事。
        .task(id: operationResult) {
            guard operationResult != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            operationResult = nil
        }
    }

    /// 导出走视图自己的 `NSSavePanel`，取数和口径声明都由 `EnergyHistory`
    /// 提供，两种格式共用同一份说明，不会各写各的。
    private var exportMenu: some View {
        Menu {
            Button(L10n.text("导出 CSV…")) { export(.csv) }
            Button(L10n.text("导出 JSON…")) { export(.json) }
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(GhostButtonStyle())
        .fixedSize()
        .disabled(exportUnavailable)
        .help(model.energyHistoryIsEphemeral
              ? L10n.text("演示数据不写入历史，也不提供导出")
              : L10n.text("导出这台 Mac 上的能耗记录；文件里会写明这些数字是怎么来的"))
    }

    /// 演示数据不导出：它在界面上有"演示"角标，落成文件之后就没有了，
    /// 和真实观测记录长得一模一样。
    private var exportUnavailable: Bool {
        model.energyHistoryIsEphemeral
            || (history.hourly.isEmpty && history.sessions.isEmpty && history.activeSession == nil)
    }

    private enum HistoryExportFormat {
        case csv
        case json

        var contentType: UTType { self == .csv ? .commaSeparatedText : .json }
        var suggestedName: String {
            L10n.text(self == .csv ? "charker-能耗.csv" : "charker-能耗.json")
        }
    }

    private func export(_ format: HistoryExportFormat) {
        // 先取一份再开面板：`runModal()` 会把主线程停在这里几秒到几分钟，
        // 期间遥测还在往历史里写，导出的内容应该是用户按下按钮那一刻看到的。
        let exported = history
        let generatedAt = Date()

        let panel = NSSavePanel()
        panel.nameFieldStringValue = format.suggestedName
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            switch format {
            case .csv:
                // 表头注释是中文，而 Excel 在 macOS 上不带 BOM 就按系统编码猜，
                // 猜错一次整列都是乱码。Numbers 与命令行工具都能忽略 BOM。
                var data = Data([0xEF, 0xBB, 0xBF])
                data.append(Data(exported.exportCSV(generatedAt: generatedAt).utf8))
                try data.write(to: url, options: .atomic)
            case .json:
                try exported.exportJSON(generatedAt: generatedAt).write(to: url, options: .atomic)
            }
            operationResult = L10n.format("已导出到 %@", url.lastPathComponent)
        } catch {
            operationResult = L10n.format("导出失败：%@", error.localizedDescription)
        }
    }

    private var endSessionButton: some View {
        Button {
            model.endCurrentEnergySession()
        } label: {
            Label("结束本次", systemImage: "stop.circle")
        }
        .buttonStyle(GhostButtonStyle())
        .disabled(!model.hasActiveEnergySession)
        .help("只结束统计，不影响充电；之后会自动开始新的一段")
        .accessibilityHint(Text("不会断开充电器或停止供电"))
    }

    private var clearHistoryButton: some View {
        Menu {
            ForEach(HistoryClearScope.calendarScopes) { scope in
                Button(scope.menuTitle, role: .destructive) {
                    pendingClearScope = scope
                    confirmingClear = true
                }
                .disabled(!hasRecords(in: scope))
            }
            Divider()
            Button(HistoryClearScope.all.menuTitle, role: .destructive) {
                pendingClearScope = .all
                confirmingClear = true
            }
        } label: {
            Label("清理记录", systemImage: "trash")
        }
        .menuStyle(.button)
        .buttonStyle(CharkerActionButtonStyle(emphasis: .destructive))
        .disabled(!model.canClearEnergyHistory)
        .help(model.energyHistoryIsEphemeral
              ? L10n.text("演示数据不会写入本机记录")
              : L10n.text("按今天、本周、本月或全部范围清理本机能耗记录"))
        .confirmationDialog(
            pendingClearScope?.confirmationTitle ?? L10n.text("清理能耗记录？"),
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            if let scope = pendingClearScope {
                Button(scope.confirmButtonTitle, role: .destructive) {
                    clearHistory(scope)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(clearConfirmationMessage)
        }
    }

    private func clearHistory(_ scope: HistoryClearScope) {
        let succeeded: Bool
        if scope == .all {
            succeeded = model.clearEnergyHistory()
        } else if let interval = scope.interval(now: Date(), calendar: calendar) {
            succeeded = model.clearEnergyHistory(from: interval.start, to: interval.end)
        } else {
            succeeded = false
        }

        if succeeded {
            selectedPeriod = nil
            contentRevision += 1
            visibleSessionLimit = 16
            operationResult = scope.successMessage
        } else if let warning = model.energyHistoryWarning {
            operationResult = warning
        }
        pendingClearScope = nil
    }

    private var clearConfirmationMessage: String {
        guard pendingClearScope != .all else {
            return L10n.text(
                "这会永久删除这台 Mac 上保存的全部能耗记录，无法撤销。不会断开充电器或停止供电；如果仍在连接，下一次采样会从零开始一段新记录。"
            )
        }
        return L10n.text(
            "这会永久删除所选日历范围内的能耗记录，无法撤销。跨越范围边界的连接旅程也会从列表移除，但范围外的能耗汇总会保留。不会断开充电器或停止供电；仍在连接时，下一次采样会开始新记录。"
        )
    }

    private func hasRecords(in scope: HistoryClearScope) -> Bool {
        guard let interval = scope.interval(now: Date(), calendar: calendar) else {
            return model.canClearEnergyHistory
        }
        return history.hourly.contains {
            $0.startedAt < interval.end && $0.endedAt > interval.start
        } || history.sessions.contains {
            $0.startedAt < interval.end && $0.endedAt >= interval.start
        } || history.activeSession.map {
            $0.startedAt < interval.end && $0.endedAt >= interval.start
        } == true
    }

    private var observationBadge: some View {
        HStack(spacing: Space.s) {
            Image(systemName: model.energyHistoryIsEphemeral ? "sparkles" : "lock.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(L10n.text(model.energyHistoryIsEphemeral
                ? "演示数据 · 不写入历史"
                : "仅保存在这台 Mac"))
                .font(Typo.micro)
        }
        .foregroundStyle(Palette.textTertiary)
        .padding(.horizontal, Space.s)
        .padding(.vertical, 5)
        .background(Palette.well)
        .clipShape(Capsule())
        .overlay { Capsule().strokeBorder(Palette.stroke, lineWidth: Stroke.hairline) }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text("能耗里程")
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                Chip(
                    text: L10n.text(model.energyHistoryIsEphemeral ? "演示数据" : "本机记录"),
                    tone: model.energyHistoryIsEphemeral ? .accent : .neutral
                )
            }
        }
    }

    private var rangePicker: some View {
        CharkerSegmentedControl(
            label: "能耗统计范围",
            selection: $range,
            segments: HistoryRange.allCases.map { CharkerSegment($0.title, value: $0) }
        )
        .frame(maxWidth: 430)
    }

    private func summaryCard(_ digest: HistoryDigest) -> some View {
        SlateCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: Space.m) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("里程总览")
                            .font(Typo.heading)
                            .foregroundStyle(Palette.textPrimary)
                        Text(range.coverageLabel(now: digest.now, calendar: calendar))
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Spacer(minLength: Space.m)
                    if model.hasActiveEnergySession, range == .session {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Palette.ok)
                                .frame(width: 6, height: 6)
                            Text("正在记录")
                                .font(Typo.micro)
                                .foregroundStyle(Palette.okText)
                        }
                    }
                }
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.l)
                .padding(.bottom, Space.m)

                Rectangle().fill(Palette.stroke).frame(height: Stroke.hairline)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        odometer(digest.summary)
                            .padding(.trailing, Space.xl)
                            .frame(minWidth: 270, maxWidth: .infinity, alignment: .leading)
                        verticalDivider
                        metricGrid(digest.summary)
                            .frame(minWidth: 370, maxWidth: 460)
                    }

                    VStack(spacing: Space.l) {
                        odometer(digest.summary)
                        Rectangle().fill(Palette.stroke).frame(height: Stroke.hairline)
                        metricGrid(digest.summary)
                    }
                }
                .padding(Space.xl)

                summaryInsightRail(digest.summary)
            }
        }
        .id(contentRevision)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func summaryInsightRail(_ summary: EnergyHistorySummary) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                summaryInsight(icon: "bolt.horizontal.fill", label: "主力端口", value: dominantPortLabel(summary))
                summaryInsightDivider
                summaryInsight(
                    icon: "waveform.path.ecg",
                    label: "最高负载",
                    value: L10n.format("%.1f W", summary.peakWatts)
                )
                summaryInsightDivider
                summaryInsight(
                    icon: "point.3.filled.connected.trianglepath.dotted",
                    label: "每段平均",
                    value: averageJourneyEnergy(summary)
                )
                summaryInsightDivider
                electricityCostInsight(summary)
            }
            VStack(alignment: .leading, spacing: Space.s) {
                summaryInsight(icon: "bolt.horizontal.fill", label: "主力端口", value: dominantPortLabel(summary))
                summaryInsight(icon: "waveform.path.ecg", label: "最高负载", value: L10n.format("%.1f W", summary.peakWatts))
                summaryInsight(icon: "point.3.filled.connected.trianglepath.dotted", label: "每段平均", value: averageJourneyEnergy(summary))
                electricityCostInsight(summary)
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.m)
        .background(Palette.well.opacity(0.72))
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.stroke).frame(height: Stroke.hairline)
        }
    }

    private func summaryInsight(icon: String, label: String, value: String) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.accentText)
                .frame(width: 16)
            Text(L10n.text(label))
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(.numeral(11, .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func electricityCostInsight(_ summary: EnergyHistorySummary) -> some View {
        Button {
            showingElectricityRate = true
        } label: {
            summaryInsight(
                icon: "banknote.fill",
                label: "估算电费",
                value: electricityCostText(summary)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(electricityRateHelp)
        .accessibilityHint(Text("打开货币和每度电价格设置"))
    }

    private func electricityCostText(_ summary: EnergyHistorySummary) -> String {
        guard let amount = model.preferences.estimatedEnergyCost(wattHours: summary.energyWh) else {
            return L10n.text("设置电价")
        }
        return formattedCurrency(amount, code: model.preferences.energyCurrencyCode)
    }

    private var electricityRateHelp: String {
        guard model.preferences.energyPricePerKWh > 0 else {
            return L10n.text("点击设置货币和每度电价格")
        }
        return L10n.format(
            "按 %@/kWh 估算，点击修改",
            formattedCurrency(
                model.preferences.energyPricePerKWh,
                code: model.preferences.energyCurrencyCode
            )
        )
    }

    private var summaryInsightDivider: some View {
        Rectangle()
            .fill(Palette.stroke)
            .frame(width: Stroke.hairline, height: 22)
            .padding(.horizontal, Space.m)
    }

    private func odometer(_ summary: EnergyHistorySummary) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(range.summaryLabel)
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                let energy = energyText(summary.energyWh)
                HStack(alignment: .lastTextBaseline, spacing: Space.s) {
                    Text(energy.value)
                        .font(.numeral(38, .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(energy.unit)
                        .font(.ui(14, .medium))
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            PortEnergyRail(values: summary.perPortWh)

            HStack(spacing: Space.l) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: Space.xs) {
                        Circle()
                            .fill(portColor(index))
                            .frame(width: 6, height: 6)
                        Text("C\(index + 1) \(shortEnergy(summary.perPortWh[index]))")
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func metricGrid(_ summary: EnergyHistorySummary) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            alignment: .leading,
            spacing: Space.l
        ) {
            historyMetric("监测时长", durationText(summary.activeSeconds), nil)
            historyMetric("连接旅程", L10n.format("%d 段", summary.sessionCount), nil)
            historyMetric("平均功率", L10n.format("%.1f", summary.averageWatts), "W")
            historyMetric("峰值功率", L10n.format("%.1f", summary.peakWatts), "W")
        }
        .padding(.leading, Space.xl)
    }

    private func historyMetric(_ label: String, _ value: String, _ unit: String?) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(L10n.text(label))
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.numeral(18, .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .contentTransition(.numericText())
                if let unit {
                    Text(L10n.text(unit))
                        .font(.ui(10, .medium))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(Palette.stroke)
            .frame(width: Stroke.hairline)
            .padding(.vertical, Space.xs)
    }

    /// Deliberately *not* `ViewThatFits`: it builds every candidate to measure
    /// it, which meant the trend chart (5 marks per sample over up to 600
    /// samples) was built twice and both side cards three times per layout
    /// pass. The scroll view's width decides the branch instead, and only the
    /// winning branch is ever instantiated. (Same lesson as
    /// `DashboardView.instrumentBody` / `WidthBreakpoint.swift`.)
    private func analyticsWorkspace(_ digest: HistoryDigest) -> some View {
        Group {
            if analyticsFitsSideBySide {
                HStack(alignment: .top, spacing: Space.l) {
                    trendCard(digest, minimumHeight: sideBySideAnalyticsHeight)
                        .frame(minWidth: 470, maxWidth: .infinity)
                    VStack(spacing: Space.l) {
                        portMixCard(digest)
                        loadProfileCard(digest)
                    }
                    .frame(width: 258)
                    .background {
                        GeometryReader { sideColumn in
                            Color.clear.preference(
                                key: AnalyticsSideColumnHeightKey.self,
                                value: sideColumn.size.height
                            )
                        }
                    }
                }
                .onPreferenceChange(AnalyticsSideColumnHeightKey.self) { measuredHeight in
                    guard measuredHeight > 0 else { return }
                    let height = ceil(measuredHeight)
                    guard abs(height - sideBySideAnalyticsHeight) > 0.5 else { return }
                    sideBySideAnalyticsHeight = height
                }
            } else {
                VStack(spacing: Space.l) {
                    trendCard(digest)
                    if compactAnalyticsPairFits {
                        HStack(alignment: .top, spacing: Space.l) {
                            portMixCard(digest, layout: .inline)
                            loadProfileCard(digest)
                        }
                    } else {
                        VStack(spacing: Space.l) {
                            portMixCard(digest)
                            loadProfileCard(digest)
                        }
                    }
                }
            }
        }
    }

    /// The wide row needs the trend card's declared 470 pt minimum, the 16 pt
    /// gap and the fixed 258 pt side column. Chrome between the scroll view and
    /// the row is the content column's 28 pt padding per side, and the column
    /// never exceeds 1120 pt.
    ///
    /// Before the first measurement lands, stack. `RootView` builds this view
    /// fresh out of a `switch`, so `contentWidth` is 0 on the first frame of
    /// *every* entry into 能耗记录, not just at launch — and the wide row's
    /// 800 pt minimum against the detail column's 600 pt would overflow by up
    /// to 200 pt for that frame, mid-transition. The stacked branch cannot
    /// overflow, and it is also the branch the default 960 pt window lands on.
    private var analyticsFitsSideBySide: Bool {
        guard contentWidth > 0 else { return false }
        let available = min(contentWidth, 1120) - 2 * Space.xxl
        return available >= 470 + Space.l + 258
    }

    /// Below the wide breakpoint the two side cards sit next to each other only
    /// while each can keep enough room for the port donut and its legend on one
    /// line. Keeping this breakpoint content-based prevents the inline layout
    /// from becoming a squeezed version of the old vertical stack.
    private var compactAnalyticsPairFits: Bool {
        guard contentWidth > 0 else { return false }
        let available = min(contentWidth, 1120) - 2 * Space.xxl
        return available >= 300 + Space.l + 300
    }

    private func trendCard(_ digest: HistoryDigest, minimumHeight: CGFloat = 0) -> some View {
        let minimumContentHeight = max(0, minimumHeight - 2 * Space.xl)
        let expandsChart = minimumHeight > 0
        return SlateCard(padding: Space.xl) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .top, spacing: Space.m) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(L10n.text(range == .session ? "实时功率轨迹" : "能耗趋势"))
                            .font(Typo.heading)
                            .foregroundStyle(Palette.textPrimary)
                        Text(range == .session
                             ? L10n.text("指针移到图上查看任意时刻")
                             : range.chartSubtitle)
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textTertiary)
                        if range != .session {
                            let referenceValue = chartReferenceValue(digest.periods)
                            if referenceValue > 0 {
                                chartReferenceLegend(referenceValue)
                            }
                        }
                    }
                    Spacer(minLength: Space.m)
                    if range != .session {
                        metricPicker
                    }
                }

                if range == .session, model.snapshot.history.count > 1 {
                    livePowerChart(expandsVertically: expandsChart)
                } else if digest.periods.isEmpty {
                    VStack(spacing: Space.s) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 18, weight: .medium))
                        Text(L10n.text(range == .session
                             ? "正在积累本次功率轨迹…"
                             : "该范围内暂无记录"))
                            .font(Typo.caption)
                    }
                    .foregroundStyle(Palette.textTertiary)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 238,
                        idealHeight: 238,
                        maxHeight: expandsChart ? .infinity : 238
                    )
                } else {
                    energyChart(digest, expandsVertically: expandsChart)
                }

                chartInspector(digest)
            }
            // In the wide layout the two compact cards establish the row's
            // natural height. Give that same proposal to this card so its chart
            // absorbs the spare room and both columns finish on one baseline.
            .frame(
                maxWidth: .infinity,
                minHeight: minimumContentHeight,
                alignment: .topLeading
            )
        }
    }

    private var metricPicker: some View {
        CharkerSegmentedControl(
            label: "趋势图指标",
            selection: $chartMetric,
            segments: HistoryChartMetric.allCases.map { CharkerSegment($0.title, value: $0) }
        )
        .frame(width: 180)
    }

    private func livePowerChart(expandsVertically: Bool) -> some View {
        Chart {
            ForEach(model.snapshot.history) { sample in
                AreaMark(
                    x: .value(ChartLabel.time, sample.at),
                    y: .value(ChartLabel.totalWatts, sample.total)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(
                    colors: [Palette.accent.opacity(0.26), Palette.accent.opacity(0.01)],
                    startPoint: .top,
                    endPoint: .bottom
                ))

                LineMark(
                    x: .value(ChartLabel.time, sample.at),
                    y: .value(ChartLabel.totalWatts, sample.total),
                    series: .value(ChartLabel.series, ChartLabel.totalOutput)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Palette.accent)

                ForEach(0..<min(3, sample.perPort.count), id: \.self) { port in
                    LineMark(
                        x: .value(ChartLabel.time, sample.at),
                        y: .value(ChartLabel.portWatts, sample.perPort[port]),
                        series: .value(ChartLabel.series, "C\(port + 1)")
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(
                        lineWidth: 1,
                        lineCap: .round,
                        dash: port == 0 ? [] : [Double(3 + port), Double(2 + port)]
                    ))
                    .foregroundStyle(portColor(port).opacity(port == 0 ? 0.82 : 0.62))
                }
            }

            if let selected = selectedLiveSample {
                RuleMark(x: .value(ChartLabel.selectedTime, selected.at))
                    .foregroundStyle(
                        Palette.textSecondary.opacity(ChartHoverStyle.crosshairOpacity)
                    )
                    .lineStyle(StrokeStyle(
                        lineWidth: ChartHoverStyle.crosshairWidth,
                        dash: ChartHoverStyle.crosshairDash
                    ))
                PointMark(
                    x: .value(ChartLabel.selectedTime, selected.at),
                    y: .value(ChartLabel.selectedWatts, selected.total)
                )
                .symbolSize(38)
                .foregroundStyle(Palette.accent)
            }
        }
        .chartYScale(domain: 0...168)
        .chartYAxis {
            AxisMarks(position: .leading, values: Array(stride(from: 0, through: 160, by: 20))) { value in
                if let watts = value.as(Int.self) {
                    AxisGridLine(stroke: StrokeStyle(
                        lineWidth: watts.isMultiple(of: 80) ? Stroke.hairline : 0.5
                    ))
                    .foregroundStyle(Palette.stroke.opacity(watts.isMultiple(of: 80) ? 1 : 0.55))
                    AxisValueLabel {
                        if watts.isMultiple(of: 40) {
                            Text("\(watts) W")
                                .font(.numeral(9, .medium))
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Palette.stroke.opacity(0.72))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(
                            .dateTime
                                .hour(.twoDigits(amPM: .omitted))
                                .minute(.twoDigits)
                                .second(.twoDigits)
                                .locale(L10n.locale())
                        ))
                            .font(.numeral(9, .medium))
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot
                .background(Palette.well.opacity(0.36))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .chartOverlay { proxy in chartSelectionOverlay(proxy: proxy, point: liveHoverPoint) }
        .frame(
            minHeight: 238,
            idealHeight: 238,
            maxHeight: expandsVertically ? .infinity : 238
        )
        .accessibilityLabel(Text("本次实时功率趋势"))
    }

    @ViewBuilder
    private func chartInspector(_ digest: HistoryDigest) -> some View {
        if range == .session {
            let sample = selectedLiveSample ?? model.snapshot.history.last
            HStack(spacing: Space.l) {
                chartLegendDot("总输出", color: Palette.accent, solid: true)
                chartLegendDot("C1", color: portColor(0), solid: false)
                chartLegendDot("C2", color: portColor(1), solid: false)
                chartLegendDot("C3", color: portColor(2), solid: false)
                Spacer(minLength: Space.s)
                if let sample {
                    Text(L10n.format(
                        "%@ · %.1f W",
                        sample.at.formatted(
                            .dateTime.hour().minute().second().locale(L10n.locale())
                        ),
                        sample.total
                    ))
                        .font(.numeral(10, .medium))
                        .foregroundStyle(Palette.accentText)
                        .contentTransition(.numericText())
                }
            }
        } else if let selected = selectedRecord(in: digest.periods) ?? digest.periods.last {
            HStack(spacing: 0) {
                inspectorMetric("时段", periodLabel(selected.startedAt))
                inspectorDivider
                inspectorMetric("能量", shortEnergy(selected.energyWh))
                inspectorDivider
                inspectorMetric("平均", L10n.format("%.1f W", selected.averageWatts))
                inspectorDivider
                inspectorMetric("峰值", L10n.format("%.1f W", selected.peakWatts))
            }
        }
    }

    private func chartLegendDot(_ label: String, color: Color, solid: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(color.opacity(solid ? 1 : 0.68))
                .frame(width: 12, height: solid ? 3 : 2)
            Text(L10n.text(label))
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private func inspectorMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(label))
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .font(.numeral(10, .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inspectorDivider: some View {
        Rectangle()
            .fill(Palette.stroke)
            .frame(width: Stroke.hairline, height: 26)
            .padding(.horizontal, Space.s)
    }

    private func energyChart(
        _ digest: HistoryDigest,
        expandsVertically: Bool
    ) -> some View {
        let periods = digest.periods
        let selectedRecord = selectedRecord(in: periods)
        let referenceValue = chartReferenceValue(periods)
        let interpolation: InterpolationMethod = periods.count >= 3 ? .catmullRom : .linear
        return Chart {
            if chartMetric == .energy {
                ForEach(periods) { period in
                    BarMark(
                        x: .value(L10n.text("时段"), period.startedAt),
                        y: .value(L10n.text("能量"), period.energyWh)
                    )
                    .foregroundStyle(LinearGradient(
                        colors: [Palette.accentDim.opacity(0.76), Palette.accent],
                        startPoint: .bottom,
                        endPoint: .top
                    ))
                    .cornerRadius(4)
                    .opacity(selectedRecord == nil || selectedRecord?.id == period.id ? 1 : 0.38)
                    .accessibilityLabel(Text(periodLabel(period.startedAt)))
                    .accessibilityValue(Text(L10n.format("能量 %@", shortEnergy(period.energyWh))))
                }
            } else {
                ForEach(periods) { period in
                    AreaMark(
                        x: .value(L10n.text("时段"), period.startedAt),
                        y: .value(chartMetric.title, chartMetric.value(period))
                    )
                    .interpolationMethod(interpolation)
                    .foregroundStyle(LinearGradient(
                        colors: [Palette.accent.opacity(0.24), Palette.accent.opacity(0.01)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))

                    LineMark(
                        x: .value(L10n.text("时段"), period.startedAt),
                        y: .value(chartMetric.title, chartMetric.value(period)),
                        series: .value(L10n.text("系列"), chartMetric.title)
                    )
                    .interpolationMethod(interpolation)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Palette.accent)

                    PointMark(
                        x: .value(L10n.text("时段"), period.startedAt),
                        y: .value(chartMetric.title, chartMetric.value(period))
                    )
                    .symbolSize(selectedRecord?.id == period.id ? 38 : 18)
                    .foregroundStyle(Palette.accent)
                    .opacity(selectedRecord == nil || selectedRecord?.id == period.id ? 1 : 0.46)
                    .accessibilityLabel(Text(periodLabel(period.startedAt)))
                    .accessibilityValue(Text(L10n.format("%.1f 瓦", chartMetric.value(period))))
                }
            }

            if referenceValue > 0 {
                RuleMark(y: .value(L10n.text("范围平均"), referenceValue))
                    .foregroundStyle(Palette.textTertiary.opacity(0.58))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }

            if let selected = selectedRecord {
                RuleMark(x: .value(L10n.text("选中时段"), selected.startedAt))
                    .foregroundStyle(
                        Palette.textSecondary.opacity(ChartHoverStyle.crosshairOpacity)
                    )
                    .lineStyle(StrokeStyle(
                        lineWidth: ChartHoverStyle.crosshairWidth,
                        dash: ChartHoverStyle.crosshairDash
                    ))
                PointMark(
                    x: .value(L10n.text("选中时段"), selected.startedAt),
                    y: .value(L10n.text("选中值"), chartMetric.value(selected))
                )
                .symbolSize(42)
                .foregroundStyle(Palette.accent)
            }
        }
        .chartYScale(domain: 0...chartCeiling(periods))
        .chartXScale(
            domain: chartDomain(digest),
            range: .plotDimension(startPadding: 18, endPadding: 18)
        )
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 7)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Palette.stroke.opacity(0.82))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(chartMetric.axisLabel(amount))
                            .font(.numeral(9, .medium))
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
            }
        }
        .chartXAxis {
            if range == .all {
                AxisMarks(values: periods.map(\.startedAt)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Palette.stroke.opacity(0.66))
                    AxisValueLabel(collisionResolution: .greedy(minimumSpacing: 16)) {
                        if let date = value.as(Date.self) {
                            Text(axisLabel(date))
                                .font(Typo.micro)
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
            } else {
                // Calendar ranges need evenly spaced calendar ticks. Using the
                // observed records as ticks bunches every label at the end of a
                // quiet month, exactly where the newest bars already live.
                AxisMarks(values: .automatic(desiredCount: chartXAxisDesiredCount)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Palette.stroke.opacity(0.66))
                    AxisValueLabel(collisionResolution: .greedy(minimumSpacing: 16)) {
                        if let date = value.as(Date.self) {
                            Text(axisLabel(date))
                                .font(Typo.micro)
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot
                .background(Palette.well.opacity(0.36))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .chartOverlay { proxy in chartSelectionOverlay(proxy: proxy, point: periodHoverPoint(periods)) }
        .frame(
            minHeight: 238,
            idealHeight: 238,
            maxHeight: expandsVertically ? .infinity : 238
        )
        // Energy uses bars while average/peak use an area-line-point stack.
        // Treat each topology as a new Chart instead of asking Charts to
        // interpolate between incompatible mark graphs while telemetry updates.
        .id("history-chart-\(range.rawValue)-\(chartMetric.rawValue)")
        .transaction { transaction in transaction.animation = nil }
    }

    private var chartXAxisDesiredCount: Int {
        switch range {
        case .session: return 4
        case .day: return 5
        case .week: return 7
        case .month: return 5
        case .all: return 6
        }
    }

    /// The rule still communicates the reference level inside the plot; its
    /// text belongs in the header where it cannot cover a bar or hover target.
    private func chartReferenceLegend(_ referenceValue: Double) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(Palette.textTertiary.opacity(0.58))
                        .frame(width: 4, height: 1)
                }
            }
            Text(L10n.format("均值 %@", chartReferenceLabel(referenceValue)))
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// 纵轴过去是 `max × 1.18`：每来一个样本刻度就漂一点，切换时间范围时同样
    /// 高的柱子代表完全不同的量，跨范围比较全靠错觉。
    ///
    /// 功率两档直接固定成和实时图一样的 0…168：160 W 是这台机器的物理上限，
    /// 固定刻度不会浪费画布，而且让实时轨迹和历史趋势读起来是同一把尺。
    ///
    /// 能量没有这样的上限——小时桶最多约 160 Wh，月桶能到上百 kWh——一刀切成
    /// 物理上限会让日常的柱子只剩几个像素。所以退一步：把上限吸到 1/2/5×10ⁿ
    /// 的整档上。同一量级内刻度不再随每个样本移动，量级相同的两个范围也会落在
    /// 同一档，柱高因此可以直接对比。
    private func chartCeiling(_ periods: [EnergyPeriodRecord]) -> Double {
        guard chartMetric == .energy else { return 168 }
        return Self.quantizedCeiling(above: periods.map(chartMetric.value).max() ?? 0)
    }

    private static func quantizedCeiling(above value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        let steps: [Double] = [1, 1.5, 2, 3, 4, 5, 6, 8, 10]
        return (steps.first { value <= $0 * magnitude } ?? 10) * magnitude
    }

    private func chartReferenceValue(_ periods: [EnergyPeriodRecord]) -> Double {
        guard !periods.isEmpty else { return 0 }
        let average = periods.map(chartMetric.value).reduce(0, +) / Double(periods.count)
        return average.isFinite ? max(0, average) : 0
    }

    private func chartReferenceLabel(_ referenceValue: Double) -> String {
        chartMetric == .energy
            ? shortEnergy(referenceValue)
            : L10n.format("%.1f W", referenceValue)
    }

    private var selectedLiveSample: PowerSample? {
        guard let selectedPeriod else { return nil }
        return model.snapshot.history.min {
            abs($0.at.timeIntervalSince(selectedPeriod))
                < abs($1.at.timeIntervalSince(selectedPeriod))
        }
    }

    /// 选点原来靠 `DragGesture(minimumDistance: 0)`：要按住鼠标才能读出一个
    /// 时刻，而且松手之后选中态一直挂着，谁也不知道那条虚线为什么还在。macOS
    /// 上这件事的原生形态是 hover——指针扫过就读数，离开就回到静默。
    ///
    /// 键盘可达性没有回退：原来的实现整块 `accessibilityHidden`，本来就没有
    /// 键盘选点。图元自己带 `accessibilityLabel/Value`，VoiceOver 走的是那条路。
    private func chartSelectionOverlay(proxy: ChartProxy, point: ChartHoverPoint?) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let frame = geometry[plotFrame]
                            let x = location.x - frame.origin.x
                            guard x >= 0, x <= frame.width,
                                  let date: Date = proxy.value(atX: x) else {
                                selectedPeriod = nil
                                return
                            }
                            selectedPeriod = date
                        case .ended:
                            selectedPeriod = nil
                        }
                    }

                if let point, let plotFrame = proxy.plotFrame {
                    hoverBubble(point, in: geometry[plotFrame], proxy: proxy)
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// 气泡的定位和外观都在 `ChartHoverBubble` 里，与主看板的功率时间线共用；
    /// 这里只把数据点换算成绘图区坐标。
    @ViewBuilder
    private func hoverBubble(
        _ point: ChartHoverPoint,
        in plot: CGRect,
        proxy: ChartProxy
    ) -> some View {
        if let x = proxy.position(forX: point.date),
           let y = proxy.position(forY: point.value),
           x.isFinite, y.isFinite {
            ChartHoverBubble(
                anchor: CGPoint(x: plot.minX + x, y: plot.minY + y),
                plot: plot,
                headline: point.headline,
                caption: point.caption
            )
        }
    }

    /// 实时轨迹的气泡跟着采样点走，读数与图例行保持同一口径。
    private var liveHoverPoint: ChartHoverPoint? {
        guard let sample = selectedLiveSample else { return nil }
        return ChartHoverPoint(
            date: sample.at,
            value: sample.total,
            headline: L10n.format("%.1f W", sample.total),
            caption: sample.at.formatted(
                .dateTime.hour().minute().second().locale(L10n.locale())
            )
        )
    }

    private func periodHoverPoint(_ periods: [EnergyPeriodRecord]) -> ChartHoverPoint? {
        guard let record = selectedRecord(in: periods) else { return nil }
        let value = chartMetric.value(record)
        return ChartHoverPoint(
            date: record.startedAt,
            value: value,
            headline: chartMetric == .energy
                ? shortEnergy(record.energyWh)
                : L10n.format("%.1f W", value),
            caption: periodLabel(record.startedAt)
        )
    }

    private func dominantPortLabel(_ summary: EnergyHistorySummary) -> String {
        guard let dominant = summary.perPortWh.enumerated().max(by: { $0.element < $1.element }),
              summary.energyWh > 0 else { return L10n.text("暂无") }
        let percentage = Int((dominant.element / summary.energyWh * 100).rounded())
        return "C\(dominant.offset + 1) · \(percentage)%"
    }

    private func averageJourneyEnergy(_ summary: EnergyHistorySummary) -> String {
        guard summary.sessionCount > 0 else { return L10n.text("暂无") }
        return shortEnergy(summary.energyWh / Double(summary.sessionCount))
    }

    /// Keep the chart tied to the selected interval instead of expanding only
    /// around days that happen to contain energy. Quiet time remains visible.
    private func chartDomain(_ digest: HistoryDigest) -> ClosedRange<Date> {
        let now = digest.now
        let periods = digest.periods
        let today = calendar.startOfDay(for: now)
        if range == .session {
            let start = history.activeSession?.startedAt ?? now
            let end = max(now.addingTimeInterval(1), start.addingTimeInterval(60))
            return start.addingTimeInterval(-1)...end
        }
        if range == .all, let first = periods.first, let last = periods.last {
            let start = calendar.dateInterval(of: .month, for: first.startedAt)?.start
                ?? first.startedAt
            let lastMonth = calendar.dateInterval(of: .month, for: last.startedAt)?.start
                ?? last.startedAt
            let end = calendar.date(byAdding: .month, value: 1, to: lastMonth)
                ?? last.startedAt.addingTimeInterval(31 * 86_400)
            return start.addingTimeInterval(-1)...end
        }

        let start = digest.rangeStart ?? today
        let end: Date
        if range == .day {
            // Do not compress today's observed hours into the first few pixels
            // of a full 24-hour domain. Future time is not "quiet time" yet.
            end = max(now.addingTimeInterval(60), start.addingTimeInterval(3_600))
        } else {
            end = calendar.date(byAdding: .day, value: 1, to: today)
                ?? today.addingTimeInterval(86_400)
        }
        return start.addingTimeInterval(-1)...end
    }

    private func selectedRecord(in periods: [EnergyPeriodRecord]) -> EnergyPeriodRecord? {
        guard let selectedPeriod else { return nil }
        return periods.min {
            abs($0.startedAt.timeIntervalSince(selectedPeriod))
                < abs($1.startedAt.timeIntervalSince(selectedPeriod))
        }
    }

    private func portMixCard(
        _ digest: HistoryDigest,
        layout: PortMixLayout = .stacked
    ) -> some View {
        let summary = digest.summary
        return SlateCard(padding: Space.l) {
            VStack(alignment: .leading, spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("端口构成")
                        .font(Typo.heading)
                        .foregroundStyle(Palette.textPrimary)
                    Text("累计能量占比")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                }

                if summary.energyWh > 0 {
                    Group {
                        switch layout {
                        case .inline:
                            HStack(alignment: .center, spacing: Space.l) {
                                portMixDonut(digest)
                                portMixLegend(digest.portSlices)
                                    .frame(maxWidth: .infinity)
                            }
                            .frame(maxWidth: .infinity, minHeight: 104)
                        case .stacked:
                            VStack(spacing: Space.m) {
                                portMixDonut(digest)
                                portMixLegend(digest.portSlices)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                } else {
                    compactChartEmpty("暂无端口能量")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: summary.perPortWh)
    }

    private func portMixDonut(_ digest: HistoryDigest) -> some View {
        let renderedPortSlices = digest.renderedPortSlices
        let totalEnergy = energyText(digest.summary.energyWh)
        return ZStack {
            Chart(renderedPortSlices) { slice in
                SectorMark(
                    angle: .value(L10n.text("能量"), slice.energyWh),
                    innerRadius: .ratio(0.66),
                    angularInset: renderedPortSlices.count > 1 ? 0.8 : 0
                )
                .cornerRadius(renderedPortSlices.count > 1 ? 2 : 0)
                .foregroundStyle(portColor(slice.index))
                .accessibilityLabel(Text("C\(slice.index + 1)"))
                .accessibilityValue(Text("\(slice.percentage)%"))
            }
            .chartLegend(.hidden)

            VStack(spacing: 1) {
                Text("总计")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(totalEnergy.value)
                        .font(.numeral(14, .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(totalEnergy.unit)
                        .font(.ui(8, .medium))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
        .frame(width: 104, height: 104)
    }

    private func portMixLegend(_ slices: [PortEnergySlice]) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(slices) { slice in
                HStack(spacing: 5) {
                    Circle()
                        .fill(portColor(slice.index))
                        .frame(width: 6, height: 6)
                    Text("C\(slice.index + 1)")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textSecondary)
                    Text(shortEnergy(slice.energyWh))
                        .font(.numeral(9, .medium))
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("\(slice.percentage)%")
                        .font(.numeral(10, .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadProfileCard(_ digest: HistoryDigest) -> some View {
        let loadBands = digest.loadBands
        return SlateCard(padding: Space.l) {
            VStack(alignment: .leading, spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("负载分布")
                        .font(Typo.heading)
                        .foregroundStyle(Palette.textPrimary)
                    Text("各功率档位的累计时长")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                }

                if loadBands.contains(where: { $0.seconds > 0 }) {
                    VStack(spacing: Space.s) {
                        ForEach(loadBands) { band in
                            loadBandRow(band, ceiling: digest.loadBandCeiling)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 104)
                } else {
                    compactChartEmpty("尚无负载样本")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: loadBands)
    }

    private func loadBandRow(_ band: PowerLoadBand, ceiling: Double) -> some View {
        HStack(spacing: Space.s) {
            Text(band.label)
                .font(.numeral(9, .medium))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 58, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Palette.idle.opacity(0.16))
                    if band.seconds > 0 {
                        let fillWidth = geometry.size.width * CGFloat(band.seconds / ceiling)
                        Capsule()
                            .fill(Palette.accent.opacity(band.opacity))
                            .frame(width: min(geometry.size.width, max(3, fillWidth)))
                    }
                }
            }
            .frame(height: 6)

            Text(compactDuration(band.seconds))
                .font(.numeral(9, .medium))
                .foregroundStyle(band.seconds > 0 ? Palette.textSecondary : Palette.textTertiary)
                .lineLimit(1)
                .frame(width: 52, alignment: .trailing)
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.format(
            "%@，观测 %@",
            band.label,
            compactDuration(band.seconds)
        )))
    }

    private func compactChartEmpty(_ text: String) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: "chart.xyaxis.line")
            Text(L10n.text(text))
        }
        .font(Typo.caption)
        .foregroundStyle(Palette.textTertiary)
        .frame(maxWidth: .infinity, minHeight: 104)
    }

    private func makePortSlices(summary: EnergyHistorySummary) -> [PortEnergySlice] {
        let values = (0..<3).map { index in
            max(0, summary.perPortWh.indices.contains(index) ? summary.perPortWh[index] : 0)
        }
        let total = values.reduce(0, +)
        guard total > 0 else {
            return (0..<3).map { PortEnergySlice(index: $0, energyWh: 0, percentage: 0) }
        }

        let rawPercentages = values.map { $0 / total * 100 }
        var percentages = rawPercentages.map { Int($0.rounded(.down)) }
        let remainder = max(0, 100 - percentages.reduce(0, +))
        let remainderOrder = rawPercentages.indices.sorted {
            let lhs = rawPercentages[$0] - rawPercentages[$0].rounded(.down)
            let rhs = rawPercentages[$1] - rawPercentages[$1].rounded(.down)
            if lhs == rhs { return values[$0] > values[$1] }
            return lhs > rhs
        }
        for offset in 0..<remainder {
            percentages[remainderOrder[offset % remainderOrder.count]] += 1
        }

        return (0..<3).map { index in
            PortEnergySlice(
                index: index,
                energyWh: values[index],
                percentage: percentages[index]
            )
        }
    }

    private func makeLoadBands(periods: [EnergyPeriodRecord]) -> [PowerLoadBand] {
        let definitions: [(String, ClosedRange<Double>, Double)] = [
            (L10n.format("%d–%d W", 0, 20), 0...20, 0.34),
            (L10n.format("%d–%d W", 20, 60), 20...60, 0.52),
            (L10n.format("%d–%d W", 60, 100), 60...100, 0.72),
            (L10n.format("%d–%d W", 100, 160), 100...Double.greatestFiniteMagnitude, 1.0),
        ]
        let source: [(watts: Double, seconds: TimeInterval)]
        if range == .session, model.snapshot.history.count > 1 {
            source = zip(model.snapshot.history, model.snapshot.history.dropFirst()).compactMap { previous, current in
                let elapsed = current.at.timeIntervalSince(previous.at)
                guard elapsed > 0, elapsed < EnergyHistory.maximumIntegrableGap else { return nil }
                return ((previous.total + current.total) / 2, elapsed)
            }
        } else {
            source = periods.map { ($0.averageWatts, $0.activeSeconds) }
        }

        return definitions.enumerated().map { index, definition in
            let seconds = source.reduce(0) { partial, item in
                let inBand = index == definitions.count - 1
                    ? item.watts >= definition.1.lowerBound
                    : item.watts >= definition.1.lowerBound && item.watts < definition.1.upperBound
                return partial + (inBand ? item.seconds : 0)
            }
            return PowerLoadBand(
                label: definition.0,
                seconds: seconds,
                opacity: definition.2
            )
        }
    }

    private func sessionLedger(_ digest: HistoryDigest) -> some View {
        let sessions = digest.sessions
        return SlateCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: Space.m) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("连接旅程")
                            .font(Typo.heading)
                            .foregroundStyle(Palette.textPrimary)
                    }
                    Spacer(minLength: Space.s)
                    Chip(text: L10n.format("%d 段", sessions.count), tone: .neutral)
                }
                .padding(Space.l)

                Rectangle().fill(Palette.stroke).frame(height: Stroke.hairline)

                LazyVStack(alignment: .leading, spacing: Space.l) {
                    ForEach(groupedSessions(sessions), id: \.day) { group in
                        VStack(alignment: .leading, spacing: Space.s) {
                            HStack {
                                Text(dayLabel(group.day))
                                    .font(Typo.micro)
                                    .foregroundStyle(Palette.textTertiary)
                                Spacer(minLength: Space.s)
                                Text(L10n.format("%d 段", group.records.count))
                                    .font(.numeral(9, .medium))
                                    .foregroundStyle(Palette.textTertiary)
                            }
                            .padding(.horizontal, Space.xs)

                            VStack(spacing: 0) {
                                ForEach(Array(group.records.enumerated()), id: \.element.id) { index, record in
                                    SessionRecordRow(
                                        record: record,
                                        isActive: model.snapshot.phase.isLive
                                            && history.activeSession?.id == record.id
                                    )
                                    if index < group.records.count - 1 {
                                        Rectangle()
                                            .fill(Palette.stroke)
                                            .frame(height: Stroke.hairline)
                                            .padding(.leading, 42)
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
                    }

                    if sessions.count > visibleSessionLimit {
                        HStack(spacing: Space.m) {
                            Text(L10n.format(
                                "已显示最近 %d / %d 段",
                                min(visibleSessionLimit, sessions.count),
                                sessions.count
                            ))
                                .font(Typo.micro)
                                .foregroundStyle(Palette.textTertiary)
                            Spacer(minLength: Space.s)
                            Button {
                                withAnimation(Motion.reduced(Motion.ui, reduceMotion)) {
                                    visibleSessionLimit += 16
                                }
                            } label: {
                                Label("显示更多", systemImage: "chevron.down")
                            }
                            .buttonStyle(GhostButtonStyle())
                        }
                        .padding(.horizontal, Space.xs)
                    }
                }
                .padding(Space.l)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.format("连接旅程，%d 段", sessions.count)))
    }

    private func groupedSessions(
        _ sessions: [EnergySessionRecord]
    ) -> [(day: Date, records: [EnergySessionRecord])] {
        Dictionary(grouping: Array(sessions.prefix(visibleSessionLimit))) {
            calendar.startOfDay(for: $0.startedAt)
        }
            .map { (day: $0.key, records: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.day > $1.day }
    }

    private var emptyState: some View {
        SlateCard(padding: Space.xxl) {
            VStack(spacing: Space.m) {
                Image(systemName: "gauge.with.dots.needle.0percent")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(Palette.accentText)
                VStack(spacing: Space.xs) {
                    Text(emptyTitle)
                        .font(Typo.heading)
                        .foregroundStyle(Palette.textPrimary)
                    Text(emptyMessage)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 230)
        }
    }

    private var emptyTitle: String {
        if range == .session { return L10n.text("本次统计尚未开始") }
        return L10n.text(model.energyHistoryIsEphemeral ? "演示能耗正在生成" : "该时段还没有能耗记录")
    }

    private var emptyMessage: String {
        if range == .session {
            return L10n.text("收到新数据后会自动开始记录。")
        }
        return L10n.text(model.energyHistoryIsEphemeral
            ? "保持演示连接几秒，第一段记录就会出现。"
            : "连接充电器并保持 Charker 运行，记录会自动累积。")
    }

    private func warningCard(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warnText)
            Text(warning)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .cjkParagraph(11)
            Spacer(minLength: 0)
        }
        .padding(Space.m)
        .background(Palette.warn.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                .strokeBorder(Palette.warn.opacity(0.28), lineWidth: Stroke.hairline)
        }
    }

    /// Demo mode already says so in the header chip, so the footnote only
    /// has to explain what the real numbers mean.
    @ViewBuilder
    private var provenance: some View {
        if !model.energyHistoryIsEphemeral {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .top, spacing: Space.s) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .medium))
                    Text("只统计 Charker 运行并连接期间的能耗，没运行的时间不计入。")
                        .cjkParagraph(10, target: 1.52)
                }
                // 裁剪必须说出来。总量一分不少，但"连接旅程"列表里确实少了行，
                // 用户对着两个数字发愣之前先给个解释。
                if history.archivedSessionCount > 0 {
                    HStack(alignment: .top, spacing: Space.s) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 10, weight: .medium))
                        Text(L10n.format(
                            "%d 天前的记录已折叠为日/月汇总，总量不变；更早的 %d 段旅程只保留计数。",
                            EnergyHistory.hourlyDetailDays,
                            history.archivedSessionCount
                        ))
                        .cjkParagraph(10, target: 1.52)
                    }
                }
            }
            .font(Typo.micro)
            .foregroundStyle(Palette.textTertiary)
            .help(model.energyHistoryPath)
            .padding(.horizontal, Space.xs)
        }
    }

    private func energyText(_ wattHours: Double) -> (value: String, unit: String) {
        if wattHours >= 1000 {
            return (L10n.format(wattHours >= 10_000 ? "%.1f" : "%.2f", wattHours / 1000), "kWh")
        }
        return (L10n.format(wattHours < 10 ? "%.2f" : "%.1f", wattHours), "Wh")
    }

    private func shortEnergy(_ wattHours: Double) -> String {
        let value = energyText(wattHours)
        return L10n.format("%@ %@", value.value, value.unit)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        if totalSeconds < 60 { return L10n.format("%d秒", totalSeconds) }
        let totalMinutes = totalSeconds / 60
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return L10n.format("%d天 %d小时", days, hours) }
        if hours > 0 { return L10n.format("%d小时 %d分", hours, minutes) }
        return L10n.format("%d分钟", minutes)
    }

    private func compactDuration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "—" }
        if seconds < 60 { return L10n.format("%ds", max(1, Int(seconds.rounded()))) }
        let minutes = max(0, Int(seconds) / 60)
        if minutes >= 60 { return L10n.format("%dh%dm", minutes / 60, minutes % 60) }
        return L10n.format("%dm", minutes)
    }

    private func portColor(_ index: Int) -> Color {
        EnergyPortStyle.color(index)
    }

    private func periodLabel(_ date: Date) -> String {
        switch range {
        case .session, .day:
            return date.formatted(.dateTime.hour().minute().locale(L10n.locale()))
        case .week, .month:
            return date.formatted(.dateTime.month().day().locale(L10n.locale()))
        case .all:
            return date.formatted(
                .dateTime.year().month(.abbreviated).locale(L10n.locale())
            )
        }
    }

    private func axisLabel(_ date: Date) -> String {
        switch range {
        case .session:
            return date.formatted(
                .dateTime
                    .hour(.twoDigits(amPM: .omitted))
                    .minute(.twoDigits)
                    .locale(L10n.locale())
            )
        case .day:
            return date.formatted(
                .dateTime.hour(.twoDigits(amPM: .omitted)).locale(L10n.locale())
            )
        case .week:
            return date.formatted(
                .dateTime.weekday(.abbreviated).locale(L10n.locale())
            )
        case .month:
            return date.formatted(.dateTime.month().day().locale(L10n.locale()))
        case .all:
            return date.formatted(
                .dateTime.year().month(.abbreviated).locale(L10n.locale())
            )
        }
    }

    private func dayLabel(_ date: Date) -> String {
        if calendar.isDateInToday(date) { return L10n.text("今天") }
        if calendar.isDateInYesterday(date) { return L10n.text("昨天") }
        return date.formatted(
            .dateTime.year().month().day().weekday(.abbreviated).locale(L10n.locale())
        )
    }
}

private enum HistoryClearScope: String, Identifiable, Equatable {
    case day
    case week
    case month
    case all

    var id: String { rawValue }
    static let calendarScopes: [HistoryClearScope] = [.day, .week, .month]

    var menuTitle: String {
        switch self {
        case .day: return L10n.text("清空今天的记录…")
        case .week: return L10n.text("清空本周的记录…")
        case .month: return L10n.text("清空本月的记录…")
        case .all: return L10n.text("清空全部记录…")
        }
    }

    var confirmationTitle: String {
        switch self {
        case .day: return L10n.text("清空今天的能耗记录？")
        case .week: return L10n.text("清空本周的能耗记录？")
        case .month: return L10n.text("清空本月的能耗记录？")
        case .all: return L10n.text("清空全部能耗记录？")
        }
    }

    var confirmButtonTitle: String {
        switch self {
        case .day: return L10n.text("清空今天")
        case .week: return L10n.text("清空本周")
        case .month: return L10n.text("清空本月")
        case .all: return L10n.text("清空全部记录")
        }
    }

    var successMessage: String {
        switch self {
        case .day: return L10n.text("今天的能耗记录已清空；充电连接不受影响")
        case .week: return L10n.text("本周的能耗记录已清空；充电连接不受影响")
        case .month: return L10n.text("本月的能耗记录已清空；充电连接不受影响")
        case .all: return L10n.text("能耗记录已清空；充电连接不受影响")
        }
    }

    func interval(now: Date, calendar: Calendar) -> DateInterval? {
        switch self {
        case .day: return calendar.dateInterval(of: .day, for: now)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: now)
        case .month: return calendar.dateInterval(of: .month, for: now)
        case .all: return nil
        }
    }
}

private struct ElectricityRateSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var currencyCode: String
    @State private var priceText: String

    init(model: AppModel) {
        self.model = model
        _currencyCode = State(initialValue: model.preferences.energyCurrencyCode)
        _priceText = State(initialValue: Self.initialPriceText(model.preferences.energyPricePerKWh))
    }

    private var normalizedCurrency: String? {
        Preferences.normalizedCurrencyCode(currencyCode)
    }

    private var parsedPrice: Double? {
        let text = priceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale()
        formatter.numberStyle = .decimal
        let value = formatter.number(from: text)?.doubleValue
            ?? Double(text.replacingOccurrences(of: ",", with: "."))
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private var canSave: Bool { normalizedCurrency != nil && parsedPrice != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: "banknote.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.accentText)
                    .frame(width: 32, height: 32)
                    .background(Palette.accentWash)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("电费估算")
                        .font(Typo.heading)
                        .foregroundStyle(Palette.textPrimary)
                    Text("输入当地每千瓦时价格；估算只使用当前范围内 Charker 实际观测到的能耗。")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SlateCard(padding: Space.l) {
                VStack(spacing: Space.m) {
                    rateRow(label: "货币代码") {
                        TextField("CNY", text: $currencyCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 92)
                            .onChange(of: currencyCode) { _, value in
                                let uppercased = String(value.uppercased().prefix(3))
                                if uppercased != value { currencyCode = uppercased }
                            }
                    }

                    Rectangle().fill(Palette.stroke).frame(height: Stroke.hairline)

                    rateRow(label: "每度电价格") {
                        HStack(spacing: Space.s) {
                            TextField("0.60", text: $priceText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 112)
                            Text("/ kWh")
                                .font(Typo.caption)
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }

                    HStack {
                        Text("输入 0 可关闭电费估算")
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textTertiary)
                        Spacer(minLength: Space.m)
                        if let code = normalizedCurrency, let price = parsedPrice {
                            Text(L10n.format(
                                "当前电价 %@/kWh",
                                formattedCurrency(price, code: code)
                            ))
                                .font(.numeral(10, .medium))
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
            }

            HStack(spacing: Space.m) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .secondary))
                Button("保存") { save() }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                    .disabled(!canSave)
            }
        }
        .padding(Space.xl)
        .frame(width: 460)
        .background(Palette.bg)
    }

    private func rateRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: Space.m) {
            Text(L10n.text(label))
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: Space.m)
            content()
        }
    }

    private func save() {
        guard let code = normalizedCurrency, let price = parsedPrice else { return }
        var updated = model.preferences
        updated.energyCurrencyCode = code
        updated.energyPricePerKWh = price
        model.preferences = updated
        dismiss()
    }

    private static func initialPriceText(_ price: Double) -> String {
        guard price > 0, price.isFinite else { return "0" }
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSNumber(value: price)) ?? String(price)
    }
}

private func formattedCurrency(_ amount: Double, code rawCode: String) -> String {
    let code = Preferences.normalizedCurrencyCode(rawCode)
        ?? Preferences.defaultEnergyCurrencyCode
    let safeAmount = amount.isFinite ? max(0, amount) : 0
    let formatter = NumberFormatter()
    formatter.locale = L10n.locale()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = safeAmount < 1 ? 4 : 2
    return formatter.string(from: NSNumber(value: safeAmount))
        ?? L10n.format("%@ %.2f", code, safeAmount)
}

/// Chart axis/series labels resolved once per process instead of once per
/// plotted sample — the live chart made 15 `L10n.text` calls for every one of
/// up to 600 samples. Swift Charts feeds `PlottableValue` labels to the
/// accessibility descriptor, so each label must stay semantically distinct:
/// collapsing 时间 and 总功率 into one constant would make VoiceOver misread
/// the axes. Mirrors the enum of the same name in `DashboardView`.
private enum ChartLabel {
    static let time = L10n.text("时间")
    static let totalWatts = L10n.text("总功率")
    static let series = L10n.text("系列")
    static let totalOutput = L10n.text("总输出")
    static let portWatts = L10n.text("端口功率")
    static let selectedTime = L10n.text("选中时间")
    static let selectedWatts = L10n.text("选中功率")
}

private enum HistoryChartMetric: String, CaseIterable, Identifiable {
    case energy
    case averagePower
    case peakPower

    var id: String { rawValue }

    var title: String {
        switch self {
        case .energy: return L10n.text("能量")
        case .averagePower: return L10n.text("平均")
        case .peakPower: return L10n.text("峰值")
        }
    }

    func value(_ period: EnergyPeriodRecord) -> Double {
        let value: Double
        switch self {
        case .energy: value = period.energyWh
        case .averagePower: value = period.averageWatts
        case .peakPower: value = period.peakWatts
        }
        return value.isFinite ? max(0, value) : 0
    }

    func axisLabel(_ value: Double) -> String {
        switch self {
        case .energy:
            if value >= 1000 { return L10n.format("%.1f kWh", value / 1000) }
            return L10n.format(value < 10 ? "%.1f Wh" : "%.0f Wh", value)
        case .averagePower, .peakPower:
            return L10n.format("%.0f W", value)
        }
    }
}

private enum HistoryRange: String, CaseIterable, Identifiable {
    case session
    case day
    case week
    case month
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: return L10n.text("本次")
        case .day: return L10n.text("今天")
        case .week: return L10n.text("本周")
        case .month: return L10n.text("本月")
        case .all: return L10n.text("全部")
        }
    }

    var summaryLabel: String {
        switch self {
        case .session: return L10n.text("本次累计能量")
        case .day: return L10n.text("今日累计能量")
        case .week: return L10n.text("本周累计能量")
        case .month: return L10n.text("本月累计能量")
        case .all: return L10n.text("全部累计能量")
        }
    }

    var chartSubtitle: String {
        switch self {
        case .session: return L10n.text("本次按小时分段 · 指针移过查看")
        case .day: return L10n.text("今天按小时分段 · 指针移过查看")
        case .week: return L10n.text("本周按天分段 · 指针移过查看")
        case .month: return L10n.text("本月按天分段 · 指针移过查看")
        case .all: return L10n.text("按月分段 · 指针移过查看")
        }
    }

    func coverageLabel(now: Date, calendar: Calendar) -> String {
        switch self {
        case .session:
            return L10n.text("本次记录")
        case .day:
            return now.formatted(.dateTime.year().month().day().locale(L10n.locale()))
        case .week:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else {
                return L10n.text("本周")
            }
            let end = interval.end.addingTimeInterval(-1)
            return L10n.format(
                "%@ – %@",
                interval.start.formatted(
                    .dateTime.month().day().locale(L10n.locale())
                ),
                end.formatted(.dateTime.month().day().locale(L10n.locale()))
            )
        case .month:
            return now.formatted(
                .dateTime.year().month(.wide).locale(L10n.locale())
            )
        case .all:
            return L10n.text("全部历史")
        }
    }

    var granularity: EnergyHistoryGranularity {
        switch self {
        case .session, .day: return .hour
        case .week, .month: return .day
        case .all: return .month
        }
    }

    func start(now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .session: return nil
        case .day: return today
        case .week: return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .month: return calendar.dateInterval(of: .month, for: now)?.start
        case .all: return nil
        }
    }
}

/// 一次 hover 要标注的那个数据点。`date` / `value` 交给 `ChartProxy` 换算屏幕
/// 坐标，两行文字则由调用方按当前指标算好——气泡不认识"能量还是功率"。
private struct ChartHoverPoint: Equatable {
    let date: Date
    let value: Double
    let headline: String
    let caption: String
}

private struct PortEnergySlice: Identifiable, Equatable {
    var id: Int { index }
    let index: Int
    let energyWh: Double
    let percentage: Int
}

private struct PowerLoadBand: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let seconds: TimeInterval
    let opacity: Double
}

private enum EnergyPortStyle {
    static func color(_ index: Int) -> Color {
        switch index {
        case 0: return Palette.accent
        case 1: return Palette.accent.opacity(0.74)
        default: return Palette.accent.opacity(0.54)
        }
    }
}

private struct PortEnergyRail: View {
    let values: [Double]

    private var activeIndices: [Int] {
        values.indices.filter { max(0, values[$0]) > 0.000_001 }
    }

    private var total: Double {
        activeIndices.reduce(0) { $0 + max(0, values[$1]) }
    }

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 1.5
            let segmentCount = CGFloat(activeIndices.count)
            let gapWidth = spacing * max(0, segmentCount - 1)
            let availableWidth = max(0, geometry.size.width - gapWidth)
            let minimumWidth = segmentCount > 0 ? min(2, availableWidth / segmentCount) : 0
            let proportionalWidth = max(0, availableWidth - minimumWidth * segmentCount)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.idle.opacity(0.16))

                if total > 0 {
                    HStack(spacing: spacing) {
                        ForEach(activeIndices, id: \.self) { index in
                            let fraction = max(0, values[index]) / total
                            Capsule()
                                .fill(EnergyPortStyle.color(index))
                                .frame(width: minimumWidth + proportionalWidth * fraction)
                        }
                    }
                    .frame(width: geometry.size.width, alignment: .leading)
                    .clipShape(Capsule())
                } else {
                    Capsule()
                        .fill(Palette.idle.opacity(0.22))
                }
            }
            .frame(width: geometry.size.width)
            .clipped()
        }
        .frame(height: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("端口能量占比"))
        .accessibilityValue(Text(
            (0..<3).map { L10n.format("C%d %.1f 瓦时", $0 + 1, values[$0]) }
                .joined(separator: L10n.text("，"))
        ))
    }
}

private struct SessionRecordRow: View {
    let record: EnergySessionRecord
    let isActive: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.m) {
                identity
                    .frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)
                metric("能量", energyText)
                    .frame(width: 92, alignment: .leading)
                metric("监测", durationText)
                    .frame(width: 90, alignment: .leading)
                metric("平均 / 峰值", L10n.format("%.1f / %.1f W", record.averageWatts, record.peakWatts))
                    .frame(width: 126, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: Space.m) {
                identity
                HStack(spacing: Space.xl) {
                    metric("能量", energyText)
                    metric("监测", durationText)
                    metric("平均 / 峰值", L10n.format("%.1f / %.1f W", record.averageWatts, record.peakWatts))
                }
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.m)
        .background(hovering ? Palette.surfaceRaised.opacity(0.58) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.reduced(Motion.value, reduceMotion), value: hovering)
        .accessibilityElement(children: .combine)
    }

    private var identity: some View {
        HStack(spacing: Space.m) {
            ZStack {
                Circle()
                    .fill(isActive ? Palette.accentWash : Palette.surfaceRaised)
                    .frame(width: 28, height: 28)
                Image(systemName: isActive ? "bolt.fill" : "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isActive ? Palette.accentText : Palette.textTertiary)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(timeRange)
                        .font(.numeral(12, .medium))
                        .foregroundStyle(Palette.textPrimary)
                    if isActive { Chip(text: L10n.text("进行中"), tone: .accent) }
                }
                PortEnergyRail(values: record.perPortWh)
                    .frame(maxWidth: 170)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(label))
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .font(.numeral(11, .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
        }
    }

    private var timeRange: String {
        let timeStyle = Date.FormatStyle.dateTime.hour().minute().locale(L10n.locale())
        let start = record.startedAt.formatted(timeStyle)
        let end = isActive ? L10n.text("更新中") : record.endedAt.formatted(timeStyle)
        return L10n.format("%@ – %@", start, end)
    }

    private var energyText: String {
        record.energyWh >= 1000
            ? L10n.format("%.2f kWh", record.energyWh / 1000)
            : L10n.format(record.energyWh < 10 ? "%.2f Wh" : "%.1f Wh", record.energyWh)
    }

    private var durationText: String {
        let seconds = max(0, Int(record.activeSeconds))
        if seconds < 60 { return L10n.format("%d秒", seconds) }
        let minutes = seconds / 60
        if minutes >= 60 { return L10n.format("%d小时 %d分", minutes / 60, minutes % 60) }
        return L10n.format("%d分钟", minutes)
    }
}
