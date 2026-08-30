import A2687Protocol
import AppKit
import Charts
import CharkerCore
import SwiftUI

/// Nameplate figures, not readings. The charger never broadcasts its port count
/// or its rated total, so every one of these is a number this app knows about
/// the hardware — the official app hardcodes the same 0–160 W axis, which is why
/// neither UI needs to disclaim it. They live together because they used to be
/// literals scattered across the summary line, the rail's scale and the chart,
/// free to drift apart one edit at a time.
private enum DeviceSpec {
    /// Three USB-C ports. Read off the protocol's own enum so a future model with
    /// a fourth port cannot leave this screen insisting there are three.
    static let portCount = A2687.Port.allCases.count
    /// Rated total output, W: the rail's full scale and the chart's top label.
    static let ratedWatts = 160
    /// Chart y-domain top, W. 5% of headroom over the rating so the end-point dot
    /// at a full 160 W is drawn whole instead of clipped by the plot's ceiling.
    static let chartCeiling = 168
    /// Chart gridline spacing, W: a line every 20, labelled and brighter every 80
    /// so the plot reads as halves of the rating rather than eight faint bands.
    static let chartGridStep = 20
    static let chartMajorStep = 80
    /// The 3D stage should never become shorter than its original compact size.
    /// When the adjacent inspector needs more room, the stage grows to match it.
    static let instrumentMinimumHeight: CGFloat = 304
}

private struct PortInspectorHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    /// Seeded from the model so the entrance choreography plays once per app
    /// run, not on every trip back from the settings pages.
    @State private var appeared: Bool
    /// Digital-twin linkage: card hover spotlights the model's slot; clicking
    /// a slot (or a card) selects the port and filters the chart.
    @State private var hoveredPort: Int?
    @State private var selectedPort: Int?
    /// Width of the scroll view, i.e. the detail pane. Window-driven, so it is
    /// never influenced by which instrument layout we pick — see
    /// ``WidthBreakpoint``'s note on why `ViewThatFits` was too expensive here.
    @State private var contentWidth: CGFloat = 0
    /// The inspector grows when a fourth information row is present. Measure its
    /// real height and let the 3D stage follow so the two instruments share one
    /// bottom edge instead of freezing the left side at 304 pt.
    @State private var sideBySideInstrumentHeight = DeviceSpec.instrumentMinimumHeight
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel) {
        self.model = model
        _appeared = State(initialValue: model.dashboardHasEntered)
    }

    private var snapshot: SessionSnapshot { model.snapshot }

    /// A single animation driver: plain state flip, per-view `.animation(value:)`.
    /// Mixing withAnimation over the same flag double-drove the entrance.
    private func entrance(delay: Double) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(response: 0.4, dampingFraction: 1).delay(delay)
    }

    private func entering<Content: View>(_ content: Content, delay: Double) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 10)
            .animation(entrance(delay: delay), value: appeared)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                entering(hero, delay: 0)

                if let stats = model.sessionStats, snapshot.telemetry != nil {
                    entering(statsRow(stats), delay: 0.05)
                }

                notices
            }
            .padding(Space.xxl)
            .frame(maxWidth: 1040, alignment: .leading)
            // Centered by the scroll view itself. Wrapping the ScrollView in an
            // outer flexible frame displaced the legacy scroller off the
            // window edge under "always show scroll bars".
            .frame(maxWidth: .infinity)
        }
        .background {
            ZStack {
                Palette.bg.ignoresSafeArea()
                OutsideClickFocusDismissal()
                    .frame(width: 0, height: 0)
            }
        }
        .measuringContainerWidth()
        .onContainerWidthChange { contentWidth = $0 }
        .onAppear {
            // Debug hook: `-selectPort N` forces the linkage states for review.
            // Launch arguments arrive as strings, so parse rather than cast.
            if UserDefaults.standard.object(forKey: "selectPort") != nil {
                let forced = UserDefaults.standard.integer(forKey: "selectPort")
                if (0...2).contains(forced) {
                    selectedPort = forced
                    hoveredPort = forced
                }
            }
            guard !appeared else { return }
            appeared = true
            model.markDashboardEntered()
        }
    }

    // MARK: - Hero

    private var showsSearchingHero: Bool {
        snapshot.telemetry == nil && !snapshot.phase.isLive
    }

    /// A remembered charger has a reconnect story; a brand-new install needs a
    /// destination and a choice. Keeping these states separate prevents the
    /// generic scanner copy from becoming the whole onboarding experience.
    private var isFirstConnection: Bool {
        !snapshot.isDemo && !model.hasRememberedCharger && snapshot.peripheralID == nil
    }

    private var hero: some View {
        SlateCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if showsSearchingHero {
                    searchingHero
                        .transition(.opacity)
                } else {
                    liveHero
                        .transition(.opacity)
                }
            }
            // Keyed on the actual branch condition: telemetry can arrive before
            // the session is fully live, and that swap deserves the fade too.
            .animation(Motion.reduced(Motion.ui, reduceMotion), value: showsSearchingHero)
        }
    }

    private var liveHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            liveSummary

            Rectangle()
                .fill(Palette.stroke)
                .frame(height: Stroke.hairline)

            instrumentBody
                .padding(Space.xl)

            Rectangle()
                .fill(Palette.stroke)
                .frame(height: Stroke.hairline)

            chartSection
        }
    }

    /// The total is a compact instrument header now, not a billboard. Its rail
    /// still answers both "how much" and "which ports" before the eye enters 3D.
    private var liveSummary: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .center, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("实时总输出")
                        .font(Typo.label)
                        .foregroundStyle(Palette.textSecondary)
                    Text(portSummaryText)
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                if !(snapshot.phase.isLive && !snapshot.isStale) { statusRow }
                TotalReadout(
                    watts: snapshot.totalPower,
                    isStale: snapshot.isStale,
                    size: 36
                )
            }

            PowerRail(
                watts: snapshot.totalPower ?? 0,
                // Same ceiling the summary line quotes and the chart plots to.
                ceiling: Double(DeviceSpec.ratedWatts),
                isDelivering: (snapshot.totalPower ?? 0) > 0,
                segments: portSegments,
                // A 30 fps TimelineView shimmer forced the whole SwiftUI host
                // through display cycles while the user dragged the native 3D
                // camera. The segmented Anker-blue rail already communicates
                // live flow without competing for the main thread.
                flowing: false,
                dimmed: snapshot.isStale
            )
            railLegendSlot
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.l)
    }

    /// Side-by-side at the normal Mac window size; below the minimum width the
    /// same controls stack instead of hiding the physical device altogether.
    ///
    /// Deliberately *not* `ViewThatFits`: it builds every candidate to measure
    /// it, which meant a second SceneKit digital twin and a second port
    /// inspector were constructed and discarded on every display cycle. The
    /// scroll view's own width decides the branch instead, and only the winning
    /// branch is ever instantiated.
    private var instrumentBody: some View {
        Group {
            if instrumentFitsSideBySide {
                HStack(alignment: .top, spacing: Space.m) {
                    digitalTwin(height: sideBySideInstrumentHeight)
                        .frame(minWidth: 276, maxWidth: .infinity)
                    portInspector
                        .frame(width: 284)
                        .frame(minHeight: DeviceSpec.instrumentMinimumHeight, alignment: .top)
                        .background {
                            GeometryReader { inspector in
                                Color.clear.preference(
                                    key: PortInspectorHeightKey.self,
                                    value: inspector.size.height
                                )
                            }
                        }
                }
                .onPreferenceChange(PortInspectorHeightKey.self) { measuredHeight in
                    guard measuredHeight > 0 else { return }
                    let height = ceil(measuredHeight)
                    guard abs(height - sideBySideInstrumentHeight) > 0.5 else { return }
                    sideBySideInstrumentHeight = height
                }
            } else {
                VStack(alignment: .leading, spacing: Space.l) {
                    digitalTwin(height: 270)
                    portInspector
                }
            }
        }
    }

    /// The side-by-side row needs the twin's 276 pt minimum, the 12 pt gap and
    /// the inspector's fixed 284 pt. Chrome between the scroll view and the row:
    /// the content column's 28 pt padding on each side plus the instrument
    /// block's own 20 pt, and the column never exceeds 1040 pt.
    private var instrumentFitsSideBySide: Bool {
        guard contentWidth > 0 else { return true }
        let available = min(contentWidth, 1040) - 2 * Space.xxl - 2 * Space.xl
        return available >= 276 + Space.m + 284
    }

    private func digitalTwin(height: CGFloat) -> some View {
        DigitalTwinStage(
            portWatts: portWatts,
            portsLit: portsLit,
            portCables: portCables,
            totalWatts: snapshot.totalPower ?? 0,
            active: snapshot.phase.isLive,
            highlightedPort: hoveredPort,
            selectedPort: selectedPort,
            homeCamera: $model.preferences.modelHomeCamera,
            screenStyle: $model.preferences.modelScreenStyle,
            customScreenImage: model.modelScreenCustomImage,
            screenArtworkRevision: model.modelScreenArtworkRevision,
            onPortTap: { togglePortSelection($0) },
            onPortHover: { hoveredPort = $0 },
            height: height
        )
    }

    private var portInspector: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("端口")
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: Space.s)
                Text(selectedPort.map { L10n.format("已选 C%d", $0 + 1) }
                    ?? L10n.text("点击端口查看单口曲线"))
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)

            Rectangle()
                .fill(Palette.stroke)
                .frame(height: Stroke.hairline)

            ForEach(A2687.Port.allCases, id: \.rawValue) { port in
                PortCard(
                    port: port,
                    telemetry: snapshot.telemetry?.port(port),
                    nickname: $model.preferences.portNicknames[port.rawValue],
                    totalPower: snapshot.totalPower,
                    isStale: snapshot.isStale,
                    canSwitch: snapshot.writesEnabled && snapshot.phase.isLive,
                    gracePeriod: max(45, Double(model.preferences.pollSeconds) * 3),
                    onToggle: { model.setPort(port, on: $0) },
                    onSetTimer: { model.setPortTimer(port, seconds: $0) },
                    shutdownSchedule: model.activePortShutdownSchedule(for: port),
                    isSelected: selectedPort == port.rawValue,
                    onHoverChange: { inside in
                        if inside {
                            hoveredPort = port.rawValue
                        } else if hoveredPort == port.rawValue {
                            hoveredPort = nil
                        }
                    },
                    onSelect: { togglePortSelection(port.rawValue) },
                    presentation: .inspector
                )
                if port != A2687.Port.allCases.last {
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

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Text("功率时间线")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: Space.s)
                if let selectedPort {
                    Text(L10n.format("总输出 + C%d", selectedPort + 1))
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                        .transition(.opacity)
                } else {
                    // 这张图的读数只有 hover 能拿到：没有光标变化，也没有任何
                    // 视觉暗示，不明写出来就等于没有这个交互。文案与能耗页的
                    // 实时轨迹共用一句，两屏教的是同一个手势。
                    Text(L10n.text("指针移到图上查看任意时刻"))
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                        .transition(.opacity)
                }
            }
            chartWell
        }
        .padding(Space.xl)
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: selectedPort)
    }

    private var statusRow: some View {
        HStack(spacing: Space.s) {
            StateDot(phase: snapshot.phase, stale: snapshot.isStale)
            if snapshot.isStale, let updated = snapshot.lastUpdate {
                Text(L10n.format(
                    "数据陈旧 · %@更新",
                    updated.formatted(
                        .relative(presentation: .named)
                            .locale(L10n.locale())
                    )
                ))
                    .font(Typo.label)
                    .foregroundStyle(Palette.warnText)
                    .monospacedDigit()
            } else {
                Text(verbatim: snapshot.statusLabel)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.18), value: snapshot.statusLabel)
            }
        }
    }

    /// The smallest per-port reading that gets its own band on the rail and its
    /// own row in the legend. `PowerRail` pins every band it draws to a 6 pt
    /// minimum so a thin one stays visible, which would render a 0.05 W trickle
    /// at the size of a 2 W load; below this floor drawing nothing is the more
    /// honest answer. Must stay in step with `PowerRail`'s own copy of it.
    private static let railSegmentFloor: Double = 0.1

    /// This line used to print `activePortCount` (`isDelivering`: over 0.02 A and
    /// over 3 V) while the rail directly below drew a band for every `isOn` port
    /// with power, and the total summed the same set. A port sitting at 20 V /
    /// 0.01 A therefore painted a visible band and pushed 0.2 W into the total
    /// while this line said zero ports were active — two numbers on one screen
    /// contradicting each other, which costs more trust than a missing number.
    ///
    /// Both populations are now named instead of one being silently dropped, and
    /// each maps onto something visible in the same card: charging ports are the
    /// ones glowing on the digital twin, connected ports are the ones wearing a
    /// cable. Charging is always a subset of connected, because `isCableAttached`
    /// reports true for anything that is delivering — the second clause therefore
    /// states the *difference*, so the two counts can never be read as one total.
    private var portSummaryText: String {
        let charging = snapshot.telemetry?.activePortCount ?? 0
        let connected = connectedPortCount
        if connected > charging {
            return L10n.format(
                "%d / %d 端口在充电 · %d 口已连接未充电 · %d W 上限",
                charging, DeviceSpec.portCount, connected - charging, DeviceSpec.ratedWatts
            )
        }
        return L10n.format(
            "%d / %d 端口在充电 · %d W 上限",
            charging, DeviceSpec.portCount, DeviceSpec.ratedWatts
        )
    }

    /// Ports with something plugged into them. `isCableAttached == nil` means the
    /// firmware did not report a cable, never "unplugged", so only an explicit
    /// true counts. The output clause is what keeps this line and the rail in
    /// agreement: a port drawing enough to paint a band counts as connected even
    /// when its cable was never reported, so no band can exist that neither
    /// number accounts for.
    private var connectedPortCount: Int {
        guard let telemetry = snapshot.telemetry else { return 0 }
        return A2687.Port.allCases.reduce(into: 0) { count, port in
            guard let reading = telemetry.port(port) else { return }
            if reading.isCableAttached == true
                || (reading.isOn && reading.power > Self.railSegmentFloor) {
                count += 1
            }
        }
    }

    private var portsLit: [Bool] {
        A2687.Port.allCases.map { snapshot.telemetry?.port($0)?.isDelivering == true }
    }

    private var portWatts: [Double] {
        A2687.Port.allCases.map { port in
            snapshot.telemetry?.port(port).map { $0.isOn ? $0.power : 0 } ?? 0
        }
    }

    private var portCables: [DigitalTwinCableState] {
        A2687.Port.allCases.map { port in
            guard let telemetry = snapshot.telemetry?.port(port) else { return .unknown }
            return DigitalTwinCableState(
                attached: telemetry.isCableAttached,
                capability: cableCapabilityText(telemetry.cable)
            )
        }
    }

    private func cableCapabilityText(_ capability: CableCapability?) -> String? {
        switch capability {
        case .some(.max60W): "60 W"
        case .some(.max100W): "100 W"
        case .some(.epr240W): "240 W EPR"
        case .some(.unknown): L10n.text("未知规格")
        case .some(.none), nil: nil
        }
    }

    private func togglePortSelection(_ index: Int) {
        withAnimation(Motion.reduced(Motion.ui, reduceMotion)) {
            selectedPort = selectedPort == index ? nil : index
        }
    }

    /// The rail's bands are the total taken apart, so they are summed over the
    /// same set the total is: every `isOn` port's power, including the ones too
    /// small to call charging. The summary line above accounts for those under
    /// "已连接" rather than leaving them as an unexplained sliver.
    private var portSegments: [Double]? {
        guard let telemetry = snapshot.telemetry else { return nil }
        let values = A2687.Port.allCases.map { port -> Double in
            guard let p = telemetry.port(port), p.isOn else { return 0 }
            return p.power
        }
        return values.contains(where: { $0 > Self.railSegmentFloor }) ? values : nil
    }

    private var railLegendVisible: Bool {
        (portSegments?.filter { $0 > Self.railSegmentFloor }.count ?? 0) > 1
    }

    /// Keeps the instrument header's geometry stable while live port power
    /// crosses the legend threshold. Only the legend content fades; the row it
    /// occupies never enters or leaves the surrounding VStack.
    private var railLegendSlot: some View {
        ZStack(alignment: .leading) {
            railLegend
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Space.m, alignment: .leading)
        .clipped()
        .accessibilityHidden(!railLegendVisible)
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: railLegendVisible)
    }

    /// Which band is which port, only while more than one port shares the rail.
    @ViewBuilder
    private var railLegend: some View {
        if let segments = portSegments,
           segments.filter({ $0 > Self.railSegmentFloor }).count > 1 {
            HStack(spacing: Space.m) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, value in
                    if value > Self.railSegmentFloor {
                        HStack(spacing: Space.xs) {
                            Circle()
                                .fill(Palette.accent)
                                .opacity([1.0, 0.72, 0.5][index % 3])
                                .frame(width: 6, height: 6)
                            Text("C\(index + 1)")
                                .font(.numeral(10, .medium))
                                .foregroundStyle(Palette.textTertiary)
                            // A band worth 0.2 W printed as "0 W" is the same
                            // self-contradiction one row up: the legend claims
                            // nothing is there while the rail draws something.
                            // Single digits keep a decimal, the rest do not.
                            Text(value < 10
                                ? L10n.format("%.1f W", value)
                                : L10n.format("%.0f W", value))
                                .font(.numeral(10, .medium))
                                .foregroundStyle(Palette.textSecondary)
                                .contentTransition(.numericText(value: value))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .animation(Motion.reduced(Motion.value, reduceMotion), value: segments)
            .transition(.opacity)
        }
    }

    /// The searching state gets a real moment instead of a dead zero: radar
    /// rings around the bolt while the handshake ladder narrates progress.
    private var searchingHero: some View {
        VStack(spacing: Space.l) {
            ZStack {
                RadarPulse(diameter: 128, active: snapshot.phase.isBusy)
                if failed {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Palette.danger)
                } else {
                    // The rings search for exactly this device.
                    ChargerFigure(height: 72)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: Space.xs) {
                Text(verbatim: isFirstConnection
                    ? L10n.text("连接你的 Anker Prime")
                    : snapshot.statusLabel)
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.18), value: snapshot.statusLabel)
                Text(verbatim: isFirstConnection
                    ? L10n.text("打开「设备与连接」，从扫描结果中选择带“充电器”标记的设备。")
                    : snapshot.statusDetail)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .cjkParagraph(11, target: 1.5)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420)

            if isFirstConnection {
                HStack(spacing: Space.s) {
                    Button {
                        model.openDevicePicker()
                    } label: {
                        Label("查找充电器", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))

                    Button {
                        model.enterDemoMode()
                    } label: {
                        Label("体验模拟设备", systemImage: "play.fill")
                    }
                    .buttonStyle(CharkerActionButtonStyle())
                }

                Text("先给充电器通电，并暂时退出正在占用它的官方 Anker App。")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }

            if let progress = snapshot.phase.negotiationProgress, progress < 1 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.idle.opacity(0.22))
                        Capsule().fill(Palette.accent).frame(width: geometry.size.width * progress)
                    }
                }
                .frame(width: 220, height: 2)
                .animation(Motion.reduced(Motion.value, reduceMotion), value: progress)
                .transition(.opacity)
            }

            if failed && !isFirstConnection {
                Button("重新连接") { model.reconnect() }
                    .buttonStyle(WashButtonStyle())
            }
        }
        .padding(.vertical, Space.xxxl)
        .padding(.horizontal, Space.xl)
        .frame(maxWidth: .infinity)
        // Drives the progress bar's and retry button's appearance; their
        // .transitions need a transaction to play.
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: snapshot.phase.negotiationProgress != nil)
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: failed)
    }

    private var failed: Bool {
        switch snapshot.phase {
        case .failed, .bluetoothUnavailable: return true
        default: return false
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartWell: some View {
        Group {
            if model.plottedHistory.count > 1 {
                // `.equatable()` is the point of extracting this: Swift Charts
                // re-resolves every mark whenever the enclosing body is
                // re-evaluated, and the dashboard is re-evaluated on hover,
                // selection and staleness changes that the curve does not
                // depend on.
                PowerChart(
                    history: model.plottedHistory,
                    selectedPort: selectedPort
                )
                .equatable()
            } else {
                HStack(spacing: Space.s) {
                    Spacer()
                    if snapshot.phase.isLive {
                        ProgressView().controlSize(.small)
                    }
                    Text(L10n.text(snapshot.phase.isLive
                        ? "正在积累功率曲线…"
                        : "连接后开始记录功率曲线"))
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                    Spacer()
                }
                .frame(height: 132)
            }
        }
        .background(Palette.well)
        .clipShape(RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
        )
    }


    // MARK: - Stats

    private var energyScope: DashboardEnergyScope {
        DashboardEnergyScope(rawValue: model.preferences.dashboardEnergyScope) ?? .session
    }

    private var energyScopeBinding: Binding<DashboardEnergyScope> {
        Binding(
            get: { energyScope },
            set: { model.preferences.dashboardEnergyScope = $0.rawValue }
        )
    }

    private var scopedEnergySummary: EnergyHistorySummary {
        let history = model.displayedEnergyHistory
        guard energyScope != .session else { return history.currentSessionSummary }
        let now = Date()
        return history.summary(
            from: energyScope.start(now: now, calendar: calendar),
            to: now.addingTimeInterval(1)
        )
    }

    private var scopedEnergyText: (value: String, unit: String) {
        let wattHours = scopedEnergySummary.energyWh
        if wattHours >= 1000 {
            return (L10n.format(wattHours >= 10_000 ? "%.1f" : "%.2f", wattHours / 1000), "kWh")
        }
        return (L10n.format(wattHours < 10 ? "%.2f" : "%.1f", wattHours), "Wh")
    }

    private func statsRow(_ stats: AppModel.SessionStats) -> some View {
        // Read once: the getter aggregates the whole persisted energy history,
        // and asking it for the value and the unit separately ran that scan
        // twice on every body evaluation.
        let energy = scopedEnergyText
        return SlateCard(padding: 0) {
            HStack(spacing: 0) {
                statTile("峰值", L10n.format("%.1f", stats.peak), "W")
                divider
                statTile("平均", L10n.format("%.1f", stats.average), "W")
                divider
                Menu {
                    Picker("统计周期", selection: energyScopeBinding) {
                        ForEach(DashboardEnergyScope.allCases) { scope in
                            Text(scope.menuTitle).tag(scope)
                        }
                    }

                    Divider()

                    Button {
                        withAnimation(Motion.reduced(Motion.ui, reduceMotion)) {
                            model.selectedSection = .energy
                        }
                    } label: {
                        Label("查看能耗记录", systemImage: "chart.bar.xaxis")
                    }

                    Button {
                        model.endCurrentEnergySession()
                    } label: {
                        Label("结束本次统计", systemImage: "stop.circle")
                    }
                    .disabled(!model.hasActiveEnergySession)
                } label: {
                    statTile(
                        energyScope.tileTitle,
                        energy.value,
                        energy.unit,
                        accessorySymbol: "chevron.down"
                    )
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity)
                .help("切换统计周期")
                .accessibilityLabel(Text(L10n.format(
                    "%@，%@ %@",
                    energyScope.tileTitle,
                    scopedEnergyText.value,
                    scopedEnergyText.unit
                )))
                divider
                durationTile(stats.connectedAt)
            }
            .padding(.vertical, Space.l)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Palette.stroke)
            .frame(width: Stroke.hairline)
            .padding(.vertical, Space.xs)
    }

    private func statTile(
        _ label: String,
        _ value: String,
        _ unit: String,
        accessorySymbol: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Text(L10n.text(label))
                if let accessorySymbol {
                    Image(systemName: accessorySymbol)
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .font(Typo.micro)
            .foregroundStyle(accessorySymbol == nil ? Palette.textTertiary : Palette.accentText)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.numeral(17, .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .contentTransition(.numericText())
                    .animation(Motion.reduced(Motion.value, reduceMotion), value: value)
                Text(L10n.text(unit))
                    .font(.ui(10, .medium))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.l)
    }

    private func durationTile(_ connectedAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("连接时长")
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
            Group {
                if let connectedAt {
                    // Live-ticking without re-rendering: the text drives itself.
                    Text(connectedAt, style: .timer)
                } else {
                    Text("—")
                }
            }
            .font(.numeral(17, .medium))
            .monospacedDigit()
            .foregroundStyle(Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.l)
    }

    // MARK: - Notices

    private var noticeKey: [String] {
        [
            snapshot.phase.isLive ? nil : snapshot.scanHint,
            snapshot.warning,
            snapshot.phase.isLive ? nil : snapshot.lastError,
            model.lastActionMessage,
        ].compactMap { $0 }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            // Scan trouble is only news while we are actually looking for a
            // charger; next to live data it reads as a contradiction.
            if let hint = snapshot.scanHint, !snapshot.phase.isLive {
                noticeCard(hint, tint: Palette.warn, symbol: "antenna.radiowaves.left.and.right.slash")
            }
            if let warning = snapshot.warning {
                noticeCard(warning, tint: Palette.warn, symbol: "exclamationmark.triangle.fill")
            }
            if let error = snapshot.lastError, !snapshot.phase.isLive {
                noticeCard(error, tint: Palette.danger, symbol: "bolt.slash.fill")
            }
            if let message = model.lastActionMessage {
                noticeCard(message, tint: Palette.textTertiary, symbol: "info.circle.fill")
            }
        }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: noticeKey)
    }

    private func noticeCard(_ text: String, tint: Color, symbol: String) -> some View {
        SlateCard(padding: Space.m) {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(verbatim: text)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                    .cjkParagraph(13)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .padding(.bottom, Space.xxs)
        }
        .transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 4)),
                    removal: .opacity
                )
        )
    }
}

/// The official Anker app uses a fine graph-paper field behind its live trace.
/// Keep that density responsive to the plot width while leaving axis labels and
/// the power series as the only semantic foreground content.
private struct PowerTimelineVerticalGrid: View {
    private let targetSpacing: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            let divisions = max(1, Int((size.width / targetSpacing).rounded()))
            var path = Path()

            for index in 1..<divisions {
                let x = size.width * CGFloat(index) / CGFloat(divisions)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }

            context.stroke(
                path,
                with: .color(Palette.stroke.opacity(0.48)),
                lineWidth: 0.5
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private enum DashboardEnergyScope: String, CaseIterable, Identifiable {
    case session
    case day
    case week
    case month

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .session: return L10n.text("本次")
        case .day: return L10n.text("今天")
        case .week: return L10n.text("本周")
        case .month: return L10n.text("本月")
        }
    }

    var tileTitle: String {
        switch self {
        case .session: return L10n.text("本次能量")
        case .day: return L10n.text("今日能量")
        case .week: return L10n.text("本周能量")
        case .month: return L10n.text("本月能量")
        }
    }

    func start(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .session:
            return nil
        case .day:
            return calendar.startOfDay(for: now)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .month:
            return calendar.dateInterval(of: .month, for: now)?.start
        }
    }
}

/// NSTextField keeps the shared field editor as first responder when the user
/// clicks static SwiftUI content. Restore normal desktop behavior without
/// swallowing the original click: clicks inside any text field are left alone;
/// every other left click resigns the active field editor after dispatch.
private struct OutsideClickFocusDismissal: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                guard let window = event.window,
                      let fieldEditor = window.firstResponder as? NSTextView,
                      fieldEditor.delegate is NSTextField,
                      let contentView = window.contentView else { return event }

                let point = contentView.convert(event.locationInWindow, from: nil)
                guard !Self.isInsideTextField(contentView.hitTest(point)) else { return event }

                DispatchQueue.main.async { [weak window, weak fieldEditor] in
                    guard let window, let fieldEditor,
                          window.firstResponder === fieldEditor else { return }
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private static func isInsideTextField(_ hitView: NSView?) -> Bool {
            var view = hitView
            while let current = view {
                if current is NSTextField { return true }
                view = current.superview
            }
            return false
        }
    }
}

/// The overview's power curve, isolated behind `Equatable`.
///
/// Swift Charts resolves its whole mark set every time the view that contains
/// it is re-evaluated. Inlined in `DashboardView` that meant a full re-resolve
/// of ~1200 marks on hovering a port card, on a staleness flip, on any model
/// publish — measured at roughly a fifth of the main thread. Taking only the
/// series and the selection, and comparing them by hand, lets SwiftUI skip the
/// chart entirely whenever the curve itself has not moved.
private struct PowerChart: View, Equatable {
    let history: [PowerSample]
    let selectedPort: Int?

    /// The series only ever grows at its end, so the last timestamp plus the
    /// count identifies it without walking 600 elements on every comparison.
    static func == (lhs: PowerChart, rhs: PowerChart) -> Bool {
        lhs.selectedPort == rhs.selectedPort
            && lhs.history.count == rhs.history.count
            && lhs.history.last?.at == rhs.history.last?.at
            && lhs.history.last?.total == rhs.history.last?.total
    }

    /// Axis and series names, and the area fill, resolved once instead of per
    /// plotted sample.
    ///
    /// The history holds up to 600 points, and the old body asked `L10n.text`
    /// for six labels and built a fresh `LinearGradient` inside the `ForEach` —
    /// thousands of bundle lookups and gradient allocations every time a new
    /// telemetry sample landed. Sampling put this getter at roughly a sixth of
    /// the main thread on a long-running session.
    private enum ChartLabel {
        static let time = L10n.text("时间")
        static let watts = L10n.text("功率")
        static let series = L10n.text("系列")
        static let total = L10n.text("总输出")
        static let areaFill = LinearGradient(
            colors: [Palette.accent.opacity(0.30), Palette.accent.opacity(0.02)],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// The selected port's curve, flattened once rather than re-derived per
    /// mark. Samples predate the port count on older histories, hence the guard.
    private var selectedPortSeries: [PowerSample] {
        guard let selected = selectedPort else { return [] }
        return history.filter { selected < $0.perPort.count }
    }

    private var historySpanIsShort: Bool {
        guard let first = history.first, let last = history.last else { return true }
        return last.at.timeIntervalSince(first.at) < 150
    }

    var body: some View {
        Chart {
            ForEach(history) { sample in
                AreaMark(
                    x: .value(ChartLabel.time, sample.at),
                    y: .value(ChartLabel.watts, sample.total)
                )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(ChartLabel.areaFill)
                LineMark(
                    x: .value(ChartLabel.time, sample.at),
                    y: .value(ChartLabel.watts, sample.total),
                    series: .value(ChartLabel.series, ChartLabel.total)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .foregroundStyle(Palette.accent)
            }
            // The selected port's own curve rides along, dashed and quieter.
            if let selected = selectedPort {
                let seriesName = "C\(selected + 1)"
                ForEach(selectedPortSeries) { sample in
                    LineMark(
                        x: .value(ChartLabel.time, sample.at),
                        y: .value(ChartLabel.watts, sample.perPort[selected]),
                        series: .value(ChartLabel.series, seriesName)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 3]))
                    .foregroundStyle(Palette.accentDim)
                }
            }
            if let last = history.last {
                PointMark(
                    x: .value(ChartLabel.time, last.at),
                    y: .value(ChartLabel.watts, last.total)
                )
                    .symbolSize(28)
                    .foregroundStyle(Palette.accent)
            }
        }
        // Fixed domain on purpose: a rescaling axis makes stationary data look
        // like it is moving.
        .chartYScale(domain: 0...Double(DeviceSpec.chartCeiling))
        .chartYAxis {
            AxisMarks(
                position: .trailing,
                values: Array(stride(
                    from: 0,
                    through: DeviceSpec.ratedWatts,
                    by: DeviceSpec.chartGridStep
                ))
            ) { value in
                if let watts = value.as(Int.self) {
                    let isMajor = watts.isMultiple(of: DeviceSpec.chartMajorStep)
                    AxisGridLine(
                        stroke: StrokeStyle(lineWidth: isMajor ? Stroke.hairline : 0.5)
                    )
                    .foregroundStyle(isMajor ? Palette.stroke : Palette.stroke.opacity(0.58))
                }
                AxisValueLabel {
                    // The top mark carries the unit for the whole axis.
                    if let watts = value.as(Int.self),
                       watts.isMultiple(of: DeviceSpec.chartMajorStep) {
                        Text(watts == DeviceSpec.ratedWatts
                            ? L10n.format("%d W", watts)
                            : "\(watts)")
                            .font(.numeral(10, .medium))
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
            }
        }
        .chartXAxis {
            // Sub-minute spans rendered as hour:minute printed the same label
            // four times across the axis; bare mm:ss reads as a wall clock. The
            // short-span format keeps the hour so "01:14:39" cannot be misread.
            AxisMarks(values: .automatic(desiredCount: historySpanIsShort ? 3 : 4)) { _ in
                AxisValueLabel(
                    format: historySpanIsShort
                        ? .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
                        : .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
                )
                .font(.numeral(10, .medium))
                .foregroundStyle(Palette.textTertiary)
            }
        }
        .chartPlotStyle { plot in
            plot.background {
                PowerTimelineVerticalGrid()
            }
        }
        .chartOverlay { proxy in
            PowerCurveHoverLayer(
                proxy: proxy,
                history: history,
                selectedPort: selectedPort
            )
        }
        .padding(.top, Space.m)
        .padding(.horizontal, Space.m)
        .padding(.bottom, Space.s)
        .frame(height: 148)
    }
}

/// Reading a value off the overview curve: a bubble that follows the pointer,
/// leaves when the pointer does, and flips sides rather than hang off an edge.
/// Same shape as the two charts on the energy page — pointer in, read; pointer
/// out, silence — so the two screens do not teach two different gestures.
///
/// This is a view of its own rather than `@State` on `PowerChart` because hover
/// changes state on every mouse-move frame, and re-evaluating `PowerChart`'s
/// body makes Swift Charts re-resolve the whole mark set — the very cost the
/// `.equatable()` split exists to avoid. Keeping the state down here means a
/// moving pointer only redraws this overlay.
///
/// For the same reason the crosshair is a plain `Path` and a `Circle` instead of
/// `RuleMark`/`PointMark`: those live inside the `Chart` builder, so following
/// the pointer with them would drag all ~1200 marks along on every frame.
private struct PowerCurveHoverLayer: View {
    let proxy: ChartProxy
    let history: [PowerSample]
    let selectedPort: Int?

    /// A time, not a sample: the history is a sliding, re-bucketed window, so a
    /// captured `PowerSample` can outlive its place in the series and leave the
    /// bubble annotating a point the curve no longer contains.
    @State private var hoveredAt: Date?

    /// Nearest sample in time, not the one under the pixel: the thinned history
    /// is not evenly spaced, so an exact hit test would leave dead columns
    /// between points where the bubble blinks out.
    private var hovered: PowerSample? {
        guard let hoveredAt else { return nil }
        return history.min {
            abs($0.at.timeIntervalSince(hoveredAt)) < abs($1.at.timeIntervalSince(hoveredAt))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoveredAt = date(at: location, in: geometry)
                        case .ended:
                            hoveredAt = nil
                        }
                    }

                if let hovered, let plotFrame = proxy.plotFrame {
                    let plot = geometry[plotFrame]
                    // Both sit above the tracking rectangle, and the crosshair
                    // is drawn exactly under the pointer by construction. Left
                    // hit-testable they would steal the hover from the layer
                    // that produced them and flicker the bubble away.
                    crosshair(hovered, in: plot)
                        .allowsHitTesting(false)
                    bubble(hovered, in: plot)
                        .allowsHitTesting(false)
                }
            }
            // The marks carry their own labels for VoiceOver; this layer is
            // pointer-only affordance and has nothing to add to that.
            .accessibilityHidden(true)
        }
    }

    /// Pointer position to a time on the x scale. Outside the plot area — the
    /// axis gutter, the padding — reads as no selection rather than as the
    /// nearest edge, so the bubble does not cling on beyond the curve.
    private func date(at location: CGPoint, in geometry: GeometryProxy) -> Date? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let plot = geometry[plotFrame]
        let x = location.x - plot.origin.x
        guard x >= 0, x <= plot.width else { return nil }
        return proxy.value(atX: x)
    }

    @ViewBuilder
    private func crosshair(_ sample: PowerSample, in plot: CGRect) -> some View {
        if let x = proxy.position(forX: sample.at) {
            let column = plot.minX + x
            Path { path in
                path.move(to: CGPoint(x: column, y: plot.minY))
                path.addLine(to: CGPoint(x: column, y: plot.maxY))
            }
            .stroke(
                Palette.textSecondary.opacity(ChartHoverStyle.crosshairOpacity),
                style: StrokeStyle(
                    lineWidth: ChartHoverStyle.crosshairWidth,
                    dash: ChartHoverStyle.crosshairDash
                )
            )
            if let y = proxy.position(forY: sample.total) {
                Circle()
                    .fill(Palette.accent)
                    .frame(width: 7, height: 7)
                    .position(x: column, y: plot.minY + y)
            }
        }
    }

    /// Placement and chrome live in `ChartHoverBubble`, shared with the energy
    /// page. This end only turns a sample into plot coordinates and phrases the
    /// lines the way this chart reads them.
    @ViewBuilder
    private func bubble(_ sample: PowerSample, in plot: CGRect) -> some View {
        if let x = proxy.position(forX: sample.at),
           let y = proxy.position(forY: sample.total) {
            ChartHoverBubble(
                anchor: CGPoint(x: plot.minX + x, y: plot.minY + y),
                plot: plot,
                headline: L10n.format("%.1f W", sample.total),
                detail: portReading(sample),
                caption: sample.at.formatted(
                    .dateTime.hour().minute().second().locale(L10n.locale())
                )
            )
        }
    }

    /// The dashed curve only exists while a port is selected, and so does its
    /// reading. Older samples predate the per-port array, hence the bounds
    /// check rather than a subscript on faith.
    private func portReading(_ sample: PowerSample) -> String? {
        guard let selectedPort, selectedPort < sample.perPort.count else { return nil }
        return L10n.format(
            "%@ · %.1f W",
            "C\(selectedPort + 1)",
            sample.perPort[selectedPort]
        )
    }
}
