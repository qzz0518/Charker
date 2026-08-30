import A2687Protocol
import AppKit
import CharkerCore
import ServiceManagement
import SwiftUI

/// Shared chrome so every settings page reads as the same surface as the dashboard.
struct SettingsPage<Content: View>: View {
    let title: String
    /// Optional on purpose. A page whose groups already carry their own
    /// footnotes does not need a thesis statement above them.
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(L10n.text(title)).font(Typo.title).foregroundStyle(Palette.textPrimary)
                    if let subtitle {
                        Text(L10n.text(subtitle))
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .cjkParagraph(11, target: 1.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .padding(Space.xxl)
            .frame(maxWidth: 620, alignment: .leading)
            // Centered by the scroll view itself. Wrapping the ScrollView in an
            // outer flexible frame displaced the legacy scroller off the
            // window edge under "always show scroll bars".
            .frame(maxWidth: .infinity)
        }
        .background(Palette.bg.ignoresSafeArea())
    }
}

struct SettingsGroup<Content: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let title {
                Text(L10n.text(title))
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.leading, Space.xs)
            }
            SlateCard(padding: Space.l) {
                VStack(alignment: .leading, spacing: Space.m) { content }
                    // Cards must share the column's width; hugging content left
                    // toggle-only groups as ragged pills next to full-width ones.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, Space.xxs)
            }
            if let footnote {
                Text(L10n.text(footnote))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .cjkParagraph(11, target: 1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.xs)
            }
        }
    }
}

// MARK: - Shared rows

/// The one switch row used across all settings: label left, switch right —
/// the pattern every macOS settings pane uses.
struct SwitchRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text(title)).font(Typo.body).foregroundStyle(Palette.textPrimary)
                if let subtitle {
                    Text(L10n.text(subtitle)).font(Typo.caption).foregroundStyle(Palette.textTertiary)
                }
            }
            Spacer(minLength: Space.m)
            Toggle(L10n.text(title), isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A bounded numeric preference: label left, live value right, slider with tick
/// marks below. Replaces the stepper, which never showed where the value sat
/// inside its range and made crossing that range a click per unit.
///
/// The value writes through on release, not on every intermediate position:
/// each write saves the whole preference file and re-arms the session's poll
/// timer, and one drag would otherwise fire that dozens of times.
struct SliderRow: View {
    let title: String
    var subtitle: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    /// Ticks mark real stops — one every `tickStep` units, never decoration.
    var tickStep: Int = 1
    /// Sits beside the number in the UI face: `.rounded` is a no-op on CJK, so
    /// a "6 秒" pushed through the numeral face would split its own typeface.
    var unit: String

    /// The knob's own radius, which its travel is inset by at both ends. The
    /// ticks share the inset so they line up with the positions they name.
    /// Measured off the rendered control, not guessed: 1 pt out is visible as a
    /// tick sitting beside the knob it is supposed to be under.
    private let knobRadius: CGFloat = 10

    @State private var draft: Double
    @State private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String,
        subtitle: String? = nil,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        tickStep: Int = 1,
        unit: String
    ) {
        self.title = title
        self.subtitle = subtitle
        self._value = value
        self.range = range
        self.tickStep = tickStep
        self.unit = unit
        self._draft = State(initialValue: Double(value.wrappedValue))
    }

    /// What the user is looking at: the position under their finger while
    /// dragging, the committed preference otherwise.
    private var current: Int { Int(draft.rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text(title)).font(Typo.body).foregroundStyle(Palette.textPrimary)
                    if let subtitle {
                        Text(L10n.text(subtitle)).font(Typo.caption).foregroundStyle(Palette.textTertiary)
                    }
                }
                Spacer(minLength: Space.m)
                valuePill
            }
            VStack(spacing: 5) {
                // Deliberately continuous. Handing the slider a `step` makes
                // AppKit draw one tick per step — 57 hatch marks across this
                // range — so the stops are drawn below instead, and the knob
                // snaps onto the integer when the drag ends.
                Slider(
                    value: $draft,
                    in: Double(range.lowerBound)...Double(range.upperBound)
                ) { editing in
                    dragging = editing
                    if !editing { commit(snapping: true) }
                }
                .labelsHidden()
                // The filled part of the track is energy, like every switch on
                // this page — the system blue would be the one stray hue.
                .tint(Palette.accent)
                ticks
            }
        }
        // Keyboard nudges on a focused slider move the value without ever
        // reporting an edit session, so they commit here instead — without
        // snapping, or a sub-unit arrow press would be pulled straight back and
        // the keyboard could never move the value at all.
        .onChange(of: draft) { _, _ in
            if !dragging { commit(snapping: false) }
        }
        // A preference changed elsewhere (reset, another window) still owns the knob.
        .onChange(of: value) { _, new in
            if !dragging, Int(draft.rounded()) != new { draft = Double(new) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.text(title)))
        .accessibilityValue(Text(L10n.format("%d %@", current, L10n.text(unit))))
    }

    private func commit(snapping: Bool) {
        let clamped = min(max(current, range.lowerBound), range.upperBound)
        if value != clamped { value = clamped }
        if snapping, draft != Double(clamped) { draft = Double(clamped) }
    }

    private var valuePill: some View {
        HStack(spacing: 2) {
            Text("\(current)")
                .font(.numeral(11, .medium))
                .foregroundStyle(Palette.textPrimary)
                .contentTransition(.numericText(value: Double(current)))
            Text(L10n.text(unit))
                .font(.ui(10, .medium))
                .foregroundStyle(Palette.textTertiary)
        }
        // Fixed box: the pill must not resize as the number crosses 9 → 10.
        .frame(minWidth: 40)
        .padding(.horizontal, Space.s)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(Palette.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
        )
        .animation(Motion.reduced(Motion.value, reduceMotion), value: current)
    }

    private var ticks: some View {
        let steps = max(1, (range.upperBound - range.lowerBound) / tickStep)
        return HStack(spacing: 0) {
            ForEach(0...steps, id: \.self) { index in
                Circle()
                    .fill(Palette.textTertiary.opacity(0.35))
                    .frame(width: 2, height: 2)
                if index < steps { Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, knobRadius)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Menu bar

// MARK: - Advanced

struct AdvancedView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage(title: "高级") {
            SettingsGroup(title: "外观") {
                HStack {
                    Text("窗口外观").font(Typo.body)
                    Spacer()
                    CharkerSegmentedControl(
                        label: "窗口外观",
                        selection: $model.preferences.appearance,
                        segments: [
                            CharkerSegment("跟随系统", value: "system"),
                            CharkerSegment("浅色", value: "light"),
                            CharkerSegment("深色", value: "dark"),
                        ]
                    )
                    .frame(width: 240)
                }
            }

            SettingsGroup(title: "常规") {
                SwitchRow(title: "在程序坞显示图标", isOn: $model.preferences.showDockIcon)
                SwitchRow(
                    title: "登录时启动",
                    subtitle: loginStatusText,
                    isOn: $model.preferences.launchAtLogin
                )
                // 3 s is the floor the store and the session both clamp to, so
                // the track stops there rather than offering values that get
                // silently pulled back up.
                SliderRow(
                    title: "轮询间隔",
                    value: $model.preferences.pollSeconds,
                    range: 3...20,
                    unit: "秒"
                )
            }

            SettingsGroup(
                title: "测试",
                footnote: "模拟数据使用独立历史，不连接蓝牙，也不会写入真实设备记录。"
            ) {
                SwitchRow(title: "演示模式（模拟充电器）", isOn: $model.preferences.demoMode)
            }

            // What the user gets from this switch is what changes on screen and
            // what happens when they use it. Our evidence level for the port
            // write — cross-read between two implementations, never run against
            // this firmware — is our problem, and it stays in
            // ``ChargerSession/requireWritable()`` and `Preferences.writesEnabled`
            // where it belongs; the honest half of it that *is* the user's, that
            // the charger may simply not act on the command, is stated here as
            // the outcome they would actually see.
            SettingsGroup(
                title: "端口控制",
                footnote: "模拟模式会自动开放端口控制。连接真实设备时，关掉端口会让正在取电的设备立即断电，所以每次都会先问一次；充电器也可能不响应，开关会弹回原位。"
            ) {
                SwitchRow(
                    title: "允许端口开关",
                    isOn: Binding(
                        get: { model.preferences.demoMode || model.preferences.writesEnabled },
                        set: { model.preferences.writesEnabled = $0 }
                    )
                )
                .disabled(model.preferences.demoMode)
            }

            SettingsGroup(
                title: "诊断",
                footnote: "导出内容默认会隐藏序列号和蓝牙地址。开启原始报文记录后，分享导出文件前请自己看一遍。"
            ) {
                SwitchRow(title: "记录原始报文", isOn: $model.preferences.captureRawPayloads)
                HStack(spacing: Space.s) {
                    Button("导出诊断…") { model.exportDiagnostics() }
                        .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                    // The container path is long, mangles under a Chinese user
                    // name, and is only ever wanted in order to open it.
                    Button("在访达中显示") { model.revealDiagnosticsLog() }
                        .buttonStyle(CharkerActionButtonStyle())
                    Spacer()
                }
            }

        }
        .onAppear { model.refreshLoginItemStatus() }
    }

    /// Only the one status the user has to act on. Every other value narrates
    /// the switch sitting beside it, in SMAppService's vocabulary rather than
    /// theirs — and `.notFound` is reported by any ad-hoc-signed build, not
    /// just the raw binary, so hiding the row on it would take the feature
    /// away from everyone running an unsigned copy. If registration fails,
    /// `applyLoginItem` turns the switch back off and surfaces the system's
    /// own error, which says more than a status label could.
    private var loginStatusText: String? {
        model.loginItemStatus == .requiresApproval
            ? L10n.text("等待在系统设置中批准")
            : nil
    }
}

// MARK: - About

struct AboutView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var updater: AppUpdater
    @State private var markHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let githubURL = URL(string: "https://github.com/qzz0518/Charker")!
    private static let xURL = URL(string: "https://x.com/zerah_eth")!

    var body: some View {
        SettingsPage(title: "关于 Charker", subtitle: "一个读取 Anker Prime 160W（A2687）充电数据的 macOS 应用。") {
            SlateCard {
                HStack(spacing: Space.l) {
                    appMark
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("Charker")
                            .font(Typo.title)
                            .foregroundStyle(Palette.textPrimary)
                        Text(model.versionText.map { L10n.format("版本 %@", $0) } ?? L10n.text("开发构建"))
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Spacer()
                    HStack(spacing: Space.s) {
                        AboutLinkButton(
                            title: "打开 Charker 的 GitHub 仓库",
                            destination: Self.githubURL,
                            mark: BrandAssets.githubLogo,
                            fallback: "GH",
                            markSize: 19
                        )
                        AboutLinkButton(
                            title: "在 X 上关注 @zerah_eth",
                            destination: Self.xURL,
                            mark: BrandAssets.xLogo,
                            fallback: "X",
                            markSize: 17
                        )
                    }
                }
                .padding(.bottom, Space.xxs)
            }

            SettingsGroup {
                HStack(spacing: Space.m) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.text("软件更新"))
                            .font(Typo.body)
                            .foregroundStyle(Palette.textPrimary)
                        Text(L10n.text("由 Sparkle 安全检查并安装新版本"))
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Spacer(minLength: Space.m)
                    Button("检查更新…") { updater.checkForUpdates() }
                        .buttonStyle(CharkerActionButtonStyle(emphasis: .secondary))
                        .disabled(!updater.canCheckForUpdates)
                }
            }

            // Service UUIDs and cipher suites belong in docs/, not in front of
            // users; what a person needs to know fits in two sentences.
            SettingsGroup(
                footnote: "独立项目，与 Anker 无关联、未获其背书。Anker、Anker Prime 为 Anker Innovations 的商标。"
            ) {
                Text(L10n.text("充电数据只在这台 Mac 与充电器之间传输，全程加密，不经过任何服务器。"))
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                    .cjkParagraph(13)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The real product icon. Only when it truly cannot be found (a dev binary
    /// copied off its build machine) does the drawn bolt stand in. The tilt on
    /// hover is the About page's one wink.
    private var appMark: some View {
        Group {
            if let icon = AppIconImage.image {
                // The icon arrives on Apple's grid — shape, margins and shelf
                // shadow baked in — so it renders untouched, like the Dock does.
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 68, height: 68)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Palette.accent.opacity(0.9), Palette.accentDim],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 56, height: 56)
                        .shadow(color: Palette.accentGlow, radius: markHovering ? 14 : 8)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .rotationEffect(.degrees(markHovering && !reduceMotion ? -6 : 0))
        .animation(Motion.reduced(Motion.pop, reduceMotion), value: markHovering)
        .onHover { markHovering = $0 }
        .accessibilityHidden(true)
    }

}

/// Brand links stay icon-only so the identity card remains about the product,
/// while the tooltip and accessibility name carry the full action. The 40 pt
/// target is deliberately larger than the mark itself for reliable clicking.
private struct AboutLinkButton: View {
    let title: String
    let destination: URL
    let mark: NSImage?
    let fallback: String
    let markSize: CGFloat

    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Link(destination: destination) {
            Group {
                if let mark {
                    Image(nsImage: mark)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Text(fallback)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
            }
            .frame(width: markSize, height: markSize)
            .accessibilityHidden(true)
        }
        .buttonStyle(AboutLinkButtonStyle(
            hovering: hovering,
            focused: focused,
            reduceMotion: reduceMotion
        ))
        .focused($focused)
        .onHover { hovering = $0 }
        .help(L10n.text(title))
        .accessibilityLabel(Text(L10n.text(title)))
    }
}

private struct AboutLinkButtonStyle: ButtonStyle {
    let hovering: Bool
    let focused: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering || focused ? Palette.accentText : Palette.textSecondary)
            .frame(width: 40, height: 40)
            .background {
                RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                    .fill(hovering || focused ? Palette.accentWash : Palette.surfaceRaised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                    .strokeBorder(
                        focused
                            ? Palette.accent
                            : (hovering ? Palette.accent.opacity(0.34) : Palette.stroke),
                        lineWidth: focused ? Stroke.focus : Stroke.hairline
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.80 : 1)
            .animation(Motion.reduced(Motion.ui, reduceMotion), value: hovering)
            .animation(Motion.reduced(Motion.ui, reduceMotion), value: focused)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
