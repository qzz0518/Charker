import A2687Protocol
import AppKit
import CharkerCore
import SwiftUI

enum PortCardPresentation {
    case card
    case inspector
}

/// A device is plugged in but drawing (almost) nothing: full, sleeping, or
/// between trickle bursts. Voltage held on the rail or an e-marked cable is
/// direct evidence; `graceUntil` bridges the samples where both read zero.
///
/// Shared by the port card and the menu bar strip, which had drifted into two
/// copies that no longer agreed. The grace window stays a *parameter* rather
/// than part of the predicate: it only exists in a view that watches the
/// delivering edge over time (`PortCard.attachGraceUntil`), and the popover is
/// rebuilt from scratch every time it opens, so a window tracked there would be
/// empty on the frame that matters. The card is the more forgiving of the two by
/// design, not by accident.
///
/// This picks a status word and nothing else. Whether to *print* digits is
/// `PortTelemetry.hasReadings`; conflating the two is what hid a 0.1 A device's
/// perfectly good readings.
enum PortStandby {
    static func applies(to telemetry: PortTelemetry?, graceUntil: Date = .distantPast) -> Bool {
        guard let telemetry, telemetry.isOn, !telemetry.isDelivering else { return false }
        if telemetry.voltage > 3.0 { return true }
        if let cable = telemetry.cable, cable != CableCapability.none { return true }
        return Date() < graceUntil
    }
}

/// One USB-C port. Idle is expressed by colour — an unplugged port has zero
/// chroma — never by dimming the whole card, which just looks broken. And idle
/// means *quiet*: a wall of "0.0 W / 0.00 V / 0.00 A" read as a data failure,
/// so a port with nothing to report dashes its digits out.
///
/// The three reading slots — power, volts·amps, cable — are always mounted, in
/// the same places, at the same size. An earlier build swapped the whole block
/// for a state word and let the volts row disappear, which made 已关闭 and
/// 未接入设备 render as the same collapsed card with one word changed; the
/// collapse itself read as a drawing bug. Now the structure is constant, the
/// digits carry the numbers and one status word carries the difference.
struct PortCard: View {
    let port: A2687.Port
    let telemetry: PortTelemetry?
    /// User nickname for this port, edited inline in the card header.
    @Binding var nickname: String
    var totalPower: Double?
    var isStale = false
    var canSwitch = false
    /// How long a port that stops drawing is still presented as "attached".
    /// Full or sleeping devices pull power in bursts — samples of 0 A (and even
    /// 0 V) in between are normal, and flipping to 未接入 on each one made the
    /// card flap.
    var gracePeriod: TimeInterval = 45
    var onToggle: ((Bool) -> Void)?
    /// Arms the charger's own auto-off countdown for this port, in seconds.
    ///
    /// Never called with zero: this build sets a duration and has no way to take
    /// one back — see `ChargerSession.setPortTimer(_:seconds:)` for the reason
    /// and for the hardware run that would settle it. Left nil the timer button
    /// is not mounted at all, because a control that does nothing is worse than
    /// a control that is not there.
    var onSetTimer: ((UInt32) -> Void)?
    /// Local projection of the countdown most recently accepted for this port.
    /// The charger cannot read it back, so this is an estimated display state,
    /// not a second source of control truth.
    var shutdownSchedule: PortShutdownSchedule?
    /// Digital-twin linkage with the product stage.
    var isSelected = false
    var onHoverChange: ((Bool) -> Void)?
    var onSelect: (() -> Void)?
    var presentation: PortCardPresentation = .card

    @State private var hovering = false
    @State private var confirming = false
    /// Captured when the user flips the switch, so the dialog cannot invert its
    /// meaning if telemetry changes while it is open.
    @State private var pendingTarget = false
    /// Holds the knob at the confirmed position while the write and its read-back
    /// are in flight — otherwise the switch snaps back to stale telemetry the
    /// moment the dialog closes and flips again seconds later.
    @State private var inFlightTarget: Bool?
    /// Captured when a countdown is picked, so the confirmation sentence cannot
    /// change its number under the reader — same reason as `pendingTarget`.
    @State private var pendingTimerSeconds: UInt32?
    @State private var confirmingTimer = false
    @State private var customTimerOpen = false
    /// Free text, validated by `customTimerMinutes`. A String rather than an Int
    /// so a half-typed or nonsense entry disables the button instead of silently
    /// becoming some other duration.
    @State private var customTimerMinutesText = ""
    /// Incremented when a device starts drawing power: the plug-in moment.
    @State private var plugBurst = 0
    /// nil until the first real sample — the connect flood must not fire the
    /// celebration on every port at once.
    @State private var wasDelivering: Bool?
    /// End of the "still attached" window after the draw stopped.
    @State private var attachGraceUntil = Date.distantPast
    /// 这条链路上见过 B4 没有。见过一次就一直算见过——见下面 `deviceSlot` 的注释。
    @State private var sawDeviceField = false
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Digits keep their slot and lose their value. Matches the em dash the
    /// product stage already puts in an inactive port capsule.
    private static let placeholder = "—"

    /// One dim level for stale data, used by every slot on the card. Three call
    /// sites had drifted apart — two values and two different conditions — so a
    /// dropped link left the reading crisp while the footer under it faded.
    private static let staleOpacity = 0.5

    private var isDelivering: Bool { telemetry?.isDelivering ?? false }
    private var isOn: Bool { telemetry?.isOn ?? false }
    private var watts: Double { isOn ? (telemetry?.power ?? 0) : 0 }

    /// Whether to print numbers at all. Deliberately *not* `isDelivering`: the
    /// official app shows 5.0 V / 0.1 A verbatim, while the delivering threshold
    /// blanked exactly those readings and users read the blank as a loose cable.
    /// `isDelivering` stays in charge of what the card *says* (status word, lit
    /// glyph, rail); `hasReadings` is only ever about what it *prints*.
    private var hasReadings: Bool { telemetry?.hasReadings ?? false }

    /// Picks the status word and nothing else. It used to also gate the digits,
    /// which is why a 0.1 A device fell through all three conditions and had its
    /// perfectly good readings hidden.
    private var isStandby: Bool {
        PortStandby.applies(to: telemetry, graceUntil: attachGraceUntil)
    }

    var body: some View {
        container
        .overlay {
            CardBurst(
                trigger: plugBurst,
                color: Palette.accent,
                radius: presentation == .card ? Radius.card : Radius.cardInner
            )
        }
        .overlay {
            if isSelected, presentation == .card {
                RoundedRectangle(
                    cornerRadius: Radius.card,
                    style: .continuous
                )
                    .strokeBorder(Palette.accent.opacity(0.75), lineWidth: 1.5)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .contentShape(RoundedRectangle(
            cornerRadius: presentation == .card ? Radius.card : Radius.cardInner,
            style: .continuous
        ))
        // The whole instrument row mirrors the model port hit target. Inline
        // fields remain real controls; a click on one may also select its port,
        // but the parent gesture does not dismiss or steal the field editor.
        .onTapGesture {
            onSelect?()
        }
        .focusable()
        .onKeyPress(phases: .down) { press in
            guard press.key == .return || press.characters == " " else { return .ignored }
            onSelect?()
            return .handled
        }
        // The plug-in pop: a real device landed, so the card gets the one bounce
        // the motion contract allows. `plugBurst` never increments under
        // reduce-motion, which silences both the pop and the ring.
        .keyframeAnimator(initialValue: PopValue(), trigger: plugBurst) { view, value in
            view.scaleEffect(value.scale)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(1.0, duration: 0.01)
                SpringKeyframe(1.02, duration: 0.18, spring: Spring(response: 0.28, dampingRatio: 0.75))
                SpringKeyframe(1.0, duration: 0.4, spring: Spring(response: 0.4, dampingRatio: 0.6))
            }
        }
        .onHover {
            hovering = $0
            onHoverChange?($0)
        }
        // Observed as Bool? on purpose: nil→false (first live sample, port idle)
        // arms the debounce, nil→true (the connect flood) stays suppressed, and
        // telemetry vanishing resets to nil. Watching the plain Bool missed all
        // three edges and the first real plug-in never fired.
        .onChange(of: telemetry?.isDelivering, initial: true) { _, delivering in
            defer { wasDelivering = delivering }
            if delivering == false, wasDelivering == true {
                attachGraceUntil = Date().addingTimeInterval(gracePeriod)
            }
            // Re-drawing inside the grace window is a trickle burst, not a new
            // device — no celebration for it.
            if delivering == true, wasDelivering == false,
               Date() >= attachGraceUntil, !reduceMotion {
                plugBurst += 1
            }
        }
        // 只往上锁，从不回落：B4 少报一帧（截断、或者换了条不带端口数据的回复）
        // 不该让三张卡同时抖掉一行。见 `deviceSlot`。
        .onChange(of: telemetry?.connectedDevice != nil, initial: true) { _, reported in
            if reported { sawDeviceField = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.format("%@ 端口", port.label)))
        .accessibilityValue(Text(L10n.text(isSelected ? "已选择" : "未选择")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect?() }
        .accessibilityAction(named: Text(L10n.format("选择 %@ 端口", port.label))) { onSelect?() }
    }

    @ViewBuilder
    private var container: some View {
        switch presentation {
        case .card:
            SlateCard(hovering: hovering) { cardContent }
        case .inspector:
            inspectorContent
                .background {
                    RoundedRectangle(
                        cornerRadius: Radius.cardInner - Space.xs,
                        style: .continuous
                    )
                        .fill(
                            isSelected
                                ? Palette.accentWash.opacity(0.58)
                                : (hovering ? Palette.surfaceRaised.opacity(0.58) : Color.clear)
                        )
                        .padding(.horizontal, Space.xs)
                        .padding(.vertical, Space.xxs)
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(
                            cornerRadius: Radius.cardInner - Space.xs,
                            style: .continuous
                        )
                            .strokeBorder(Palette.accent.opacity(0.64), lineWidth: 1)
                            .padding(.horizontal, Space.xs)
                            .padding(.vertical, Space.xxs)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.reduced(Motion.ui, reduceMotion), value: hovering)
                .animation(Motion.reduced(Motion.ui, reduceMotion), value: isSelected)
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            reading
            PowerRail(watts: watts, isDelivering: isDelivering, dimmed: isStale)
            // 伏安/状态和「接入设备」是同一层信息：贴得比其它区块近，变暗也归
            // 同一层管。分开各写各的 opacity 就会重演卡片上出现过的老毛病——
            // 断链之后一行清晰一行发灰。
            VStack(alignment: .leading, spacing: Space.xs) {
                footer
                deviceSlot
            }
            .opacity(isStale ? Self.staleOpacity : 1)
            .animation(.easeOut(duration: 0.2), value: isStale)
            // CJK 的墨比拉丁字母沉得更低，按拉丁行高量出来的行会切到底部。
            .padding(.bottom, Space.xxs)
        }
    }

    /// Dense enough to sit beside the device, but still preserves every control
    /// from the old card: nickname, cable capability and the guarded output switch.
    ///
    /// 带距会随「接入设备」那一行一起变：没有它是三条带子（身份 / 读数 /
    /// 功率条），照常用 `s`，这一栏的高度正好和固定 304 pt 的 3D 舞台齐平；
    /// 有它就是四条，改用 `xs` 把多出来的那行从空白里挤出来。舞台不许缩，
    /// 所以要挤只能挤留白——留白够挤，内容不够。
    private var inspectorContent: some View {
        VStack(alignment: .leading, spacing: hasInspectorAuxiliaryRow ? Space.xs : Space.s) {
            // This is the densest row in the 284 pt inspector. Four-point gaps
            // leave enough room for the fixed port badge without making SwiftUI
            // fold `C2` into two lines when the cable and timer controls are shown.
            HStack(spacing: Space.xs) {
                portSelector
                TextField("备注", text: $nickname)
                    .textFieldStyle(.plain)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .frame(minWidth: 34, maxWidth: 76, alignment: .leading)
                    .help(L10n.format("给 %@ 起个备注名，例如接的是哪台设备", port.label))
                    .accessibilityLabel(Text(L10n.format("%@ 备注名", port.label)))
                    .onSubmit(dismissFieldEditor)
                Spacer(minLength: Space.xs)
                cableSlot
                if canSwitch, telemetry != nil { portControls }
            }

            HStack(alignment: .lastTextBaseline, spacing: Space.s) {
                inspectorReading
                Spacer(minLength: Space.s)
                inspectorDetails
            }
            .frame(minHeight: 24)

            inspectorAuxiliarySlot

            PowerRail(watts: watts, isDelivering: isDelivering, dimmed: isStale)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .opacity(isStale ? Self.staleOpacity : 1)
        .animation(.easeOut(duration: 0.2), value: isStale)
    }

    private struct PopValue {
        var scale: CGFloat = 1
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            portSelector
            // Inline nickname: an unadorned field that reads as a caption until
            // clicked. Writes through to preferences on every edit.
            TextField("备注", text: $nickname)
                .textFieldStyle(.plain)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .frame(minWidth: 36, maxWidth: 96, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .help(L10n.format("给 %@ 起个备注名，例如接的是哪台设备", port.label))
                .accessibilityLabel(Text(L10n.format("%@ 备注名", port.label)))
                .onSubmit(dismissFieldEditor)
            Spacer(minLength: Space.xs)
            cableSlot
            if canSwitch, telemetry != nil {
                portControls
            }
        }
        .animation(.easeOut(duration: 0.2), value: telemetry?.cableChipText)
    }

    /// The cable slot holds its place whether or not a capability was reported.
    /// A chip that vanishes takes the row's shape with it, and the reader has no
    /// way to tell "no cable" from "this part of the card did not draw".
    ///
    /// `nil` here means *not reported* — the firmware's 0x03 also covers "nothing
    /// attached" — so the placeholder is a dash and claims nothing further.
    @ViewBuilder
    private var cableSlot: some View {
        if let cable = telemetry?.cableChipText {
            Chip(text: cable, tone: telemetry?.cableIsBottleneck == true ? .warn : .neutral)
                .transition(.opacity)
        } else {
            Text(Self.placeholder)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize()
                // Chip's own box metrics, so the row does not shift by a pixel
                // when a real capability arrives.
                .padding(.horizontal, Space.s)
                .padding(.vertical, 3)
                // A dash is silent to VoiceOver and ambiguous on a busy header
                // row; the tooltip and the label carry what it stands for.
                .help(L10n.text("线缆状态未知"))
                .accessibilityLabel(Text(L10n.text("线缆状态未知")))
        }
    }

    /// 「接入设备」——固件在 B4 里报的 USB 身份，和线缆槽位同一层信息：线缆
    /// 说的是「用什么插的」，这一行只用厂商名说「插了什么」。
    ///
    /// VID/PID 对用户没有操作价值，因此不在卡片、tooltip 或读屏里显示；原始值
    /// 仍留在协议数据和诊断视图中。认得出厂商就写名字，认不出只说明已接入。
    ///
    /// 有值没值都占着这一行，值缺了只把数字换成占位符——线缆、伏安都是这个
    /// 规矩，拔一根线就少一行会被读成「这块没画出来」。占位符盖住两种情况：
    /// 这一帧里没有 B4，和固件报了无身份哨兵；它们长得一样，差别由 tooltip 和
    /// 读屏说清楚。
    ///
    /// `0000:0000` 是第三种，绝不能并进占位符：那是真插了东西、只是没报出身份
    /// （三口满载时 C3 就是它），所以它有自己的一句话。
    ///
    /// 唯一整行不出现的时候，是这条链路从头到尾没报过 B4——演示模式的模拟充电
    /// 器、以及任何不支持这个字段的固件。那不是「值缺了」，是「这台机器没有这
    /// 项数据」，凭空挂三行破折号既没信息，又要从 3D 舞台旁边那栏偷走近 30 pt。
    /// 见过一次就锁定，之后只往上不往下：拔光所有设备时哨兵仍然是 B4，行不会
    /// 跟着消失；某一帧被截断丢了 B4，三张卡也不会一起抖掉一行。
    @ViewBuilder
    private var deviceSlot: some View {
        if sawDeviceField { deviceRow }
    }

    private var deviceRow: some View {
        let value = telemetry?.connectedDeviceText
        let help = telemetry?.connectedDeviceHelp
            ?? L10n.text("充电器没有报告这个口接的是什么")
        let label = L10n.text("接入设备")
        return HStack(spacing: Space.s) {
            Text(label)
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize()
            Text(value ?? Self.placeholder)
                .font(Typo.caption)
                .foregroundStyle(value == nil ? Palette.textTertiary : Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: value)
            Spacer(minLength: 0)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        // 占位符对读屏是哑的，所以没值时把 tooltip 那句话念出来。
        .accessibilityValue(Text(value ?? help))
    }

    /// The persistent countdown borrows the device-information band instead of
    /// creating a fifth band or a dashboard card. Port identity is already
    /// visible directly above it, so the compact timer only needs to answer
    /// “how long” and “at what clock time”.
    private var hasInspectorAuxiliaryRow: Bool {
        sawDeviceField || shutdownSchedule != nil
    }

    @ViewBuilder
    private var inspectorAuxiliarySlot: some View {
        if hasInspectorAuxiliaryRow {
            HStack(spacing: Space.s) {
                if sawDeviceField {
                    deviceRow
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let shutdownSchedule {
                    inspectorShutdownCountdown(shutdownSchedule)
                }
            }
        }
    }

    private func inspectorShutdownCountdown(_ schedule: PortShutdownSchedule) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            if schedule.isActive(at: timeline.date) {
                let remaining = Self.countdownText(schedule.remainingSeconds(at: timeline.date))
                let deadline = shutdownDeadlineLabel(schedule.deadline, relativeTo: timeline.date)

                HStack(spacing: Space.xs) {
                    Image(systemName: "timer")
                        .font(.system(size: 9, weight: .semibold))
                    Text(verbatim: remaining)
                        .font(.numeral(10, .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(verbatim: "·")
                        .foregroundStyle(Palette.textTertiary)
                    Text(verbatim: deadline)
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textSecondary)
                }
                .foregroundStyle(Palette.accentText)
                .lineLimit(1)
                .fixedSize()
                .help(L10n.text(
                    "当前固件不能回读已设定的倒计时；显示值由 Charker 根据命令被接受的时间推算。"
                ))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(L10n.format("%@ 自动断电倒计时", port.label)))
                .accessibilityValue(Text(L10n.format(
                    "剩余 %@，预计 %@ 断电", remaining, deadline
                )))
            }
        }
    }

    private static func countdownText(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainder)
    }

    /// Same-day timers only need the clock time in this already dense row.
    /// Tomorrow and later retain just enough date context to stay unambiguous.
    private func shutdownDeadlineLabel(_ deadline: Date, relativeTo now: Date) -> String {
        let time = deadline.formatted(
            .dateTime
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .locale(L10n.locale())
        )
        if calendar.isDate(deadline, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(deadline, inSameDayAs: tomorrow) {
            return L10n.format("明天 %@", time)
        }
        return deadline.formatted(
            .dateTime
                .month(.abbreviated)
                .day()
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .locale(L10n.locale())
        )
    }

    /// The two controls the official app puts on a port row: countdown on the
    /// left, output switch on the right.
    ///
    /// The countdown only sets a duration. Cancelling one is a separate,
    /// unverified write and is not offered anywhere in this build — see
    /// `ChargerSession.setPortTimer(_:seconds:)`. Because the menu therefore has
    /// no 「关闭」 item, nothing here needs a disclaimer: every item it does offer
    /// is a thing the charger has been watched doing.
    ///
    /// The button is dropped entirely when no handler is wired, rather than
    /// mounted and inert.
    private var portControls: some View {
        HStack(spacing: Space.xs) {
            if onSetTimer != nil { portTimer }
            portSwitch
        }
        .confirmationDialog(
            L10n.format(
                "让 %@ 在 %@ 后断电？",
                port.label, Self.durationText(pendingTimerSeconds ?? 0)
            ),
            isPresented: $confirmingTimer
        ) {
            Button(L10n.text("设定倒计时")) {
                if let seconds = pendingTimerSeconds { onSetTimer?(seconds) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(Self.timerConsequence(port: port))
        }
    }

    /// Presets, matching the official app's sheet minus its 「关闭」 item.
    private static let timerPresets: [UInt32] = [3600, 7200, 10800]

    /// The whole reason the confirmation exists, in one sentence: a port will go
    /// dark later, and the charger — not this Mac — is the thing holding the
    /// clock. Shared by the preset dialog and the custom popover so the two
    /// paths cannot drift into promising different things.
    private static func timerConsequence(port: A2687.Port) -> String {
        L10n.format(
            "到点后 %@ 会断电，那时正在从它取电的设备会断开。倒计时由充电器自己跑——Mac 睡眠、关机或断开蓝牙都照样生效。",
            port.label
        )
    }

    /// Shared with ``AppModel/setPortTimer(_:seconds:)`` on purpose: the
    /// confirmation says 「2 小时」 and the result that follows it must say the
    /// same thing. Two private copies would be free to drift, and the one place
    /// the drift would show is the one place the user is checking that the app
    /// did what it just asked about.
    static func durationText(_ seconds: UInt32) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds % 3600) / 60)
        if hours > 0, minutes > 0 { return L10n.format("%d 小时 %d 分钟", hours, minutes) }
        if hours > 0 { return L10n.format("%d 小时", hours) }
        return L10n.format("%d 分钟", minutes)
    }

    /// A round button that opens the duration menu, sized to sit level with the
    /// mini switch beside it.
    ///
    /// Disabled while the port is off: "C2 will cut power in two hours" is not a
    /// true sentence about a port that is already dark, and arming a countdown
    /// there has never been tried on this charger. Disabled rather than removed,
    /// so the row keeps its shape when a port is switched off.
    private var portTimer: some View {
        Menu {
            ForEach(Self.timerPresets, id: \.self) { seconds in
                Button(Self.durationText(seconds)) { askToArm(seconds) }
            }
            Divider()
            Button(L10n.text("自定义…")) {
                customTimerMinutesText = ""
                customTimerOpen = true
            }
        } label: {
            Image(systemName: "timer")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOn ? Palette.accentText : Palette.textTertiary)
                .frame(width: 18, height: 18)
                .background {
                    Circle().fill(Palette.surfaceRaised)
                }
                .overlay {
                    Circle().strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isOn)
        .help(L10n.format("让 %@ 在一段时间后自动断电", port.label))
        .accessibilityLabel(Text(L10n.format("%@ 自动断电倒计时", port.label)))
        .popover(isPresented: $customTimerOpen, arrowEdge: .bottom) { customTimerPopover }
    }

    /// The custom-duration entry. It arms the countdown itself instead of handing
    /// off to the shared confirmation dialog: chaining one presentation straight
    /// into another is how a dialog gets swallowed on macOS, and the popover has
    /// room to carry the same consequence sentence in place.
    private var customTimerPopover: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("自定义倒计时")
                .font(Typo.label)
                .foregroundStyle(Palette.textPrimary)
            HStack(spacing: Space.s) {
                TextField("", text: $customTimerMinutesText, prompt: Text(verbatim: "90"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 68)
                    .onSubmit(commitCustomTimer)
                    .accessibilityLabel(Text(L10n.text("倒计时分钟数")))
                Text("分钟")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 0)
            }
            Text("1 到 1440 分钟。")
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
            Text(Self.timerConsequence(port: port))
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s) {
                Spacer(minLength: 0)
                Button("取消") { customTimerOpen = false }
                Button(L10n.text("设定倒计时"), action: commitCustomTimer)
                    .keyboardShortcut(.defaultAction)
                    .disabled(customTimerMinutes == nil)
            }
        }
        .padding(Space.m)
        .frame(width: 268)
    }

    /// nil for anything that is not a whole number of minutes inside the range —
    /// including 0, which this build has no honest meaning for.
    private var customTimerMinutes: Int? {
        guard let value = Int(customTimerMinutesText.trimmingCharacters(in: .whitespaces)),
              (1...1440).contains(value) else { return nil }
        return value
    }

    private func commitCustomTimer() {
        guard let minutes = customTimerMinutes else { return }
        customTimerOpen = false
        onSetTimer?(UInt32(minutes) * 60)
    }

    private func askToArm(_ seconds: UInt32) {
        pendingTimerSeconds = seconds
        confirmingTimer = true
    }

    private var portSelector: some View {
        portIdentity
    }

    private var portIdentity: some View {
        HStack(spacing: Space.s) {
            USBCGlyph(lit: isDelivering)
            Text(port.label)
                .font(.numeral(13, .bold))
                .foregroundStyle(isDelivering ? Palette.accentText : Palette.textTertiary)
                .lineLimit(1)
        }
        // The glyph and `C1`/`C2`/`C3` are one identity token. Let the optional
        // nickname yield space first; splitting a two-character port name makes
        // the inspector look like it has six rows instead of three.
        .fixedSize(horizontal: true, vertical: false)
    }

    private var inspectorReading: some View {
        HStack(alignment: .lastTextBaseline, spacing: 3) {
            Text(powerText)
                .font(.numeral(22, .semibold))
                .foregroundStyle(readingTint)
                // A dash has no digits to roll; asking numericText to tween into
                // one gives a smear instead of a transition.
                .contentTransition(hasReadings ? .numericText(value: watts) : .opacity)
                .animation(Motion.reduced(Motion.value, reduceMotion), value: watts)
            Text("W")
                .font(.ui(10, .medium))
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private var inspectorDetails: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: Space.s) {
                metric(voltageText, "V")
                metric(currentText, "A")
            }
            Text(statusText)
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: statusText)
        }
    }

    /// The binding never writes through — flipping the knob only opens the
    /// dialog — but the knob shows the *pending* position while the dialog is
    /// up, instead of animating across and snapping straight back.
    private var portSwitch: some View {
        Toggle(L10n.format("%@ 输出", port.label), isOn: Binding(
            get: { confirming ? pendingTarget : (inFlightTarget ?? isOn) },
            set: { target in
                pendingTarget = target
                confirming = true
            }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .confirmationDialog(
            pendingTarget
                ? L10n.format("打开 %@？", port.label)
                : L10n.format("关闭 %@？", port.label),
            isPresented: $confirming
        ) {
            Button(
                L10n.text(pendingTarget ? "打开端口" : "关闭端口"),
                role: pendingTarget ? nil : .destructive
            ) {
                inFlightTarget = pendingTarget
                onToggle?(pendingTarget)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(pendingTarget
                 ? L10n.format("%@ 将恢复供电。", port.label)
                 : L10n.format("正在从 %@ 取电的设备会立即断电。", port.label))
        }
        .onChange(of: isOn) {
            // Telemetry has caught up (or contradicted us) — either way it is
            // the truth again.
            if inFlightTarget != nil { inFlightTarget = nil }
        }
        .task(id: inFlightTarget) {
            // Failsafe: if the charger never confirms and telemetry never moves,
            // stop showing the optimistic position after two poll cycles.
            guard inFlightTarget != nil else { return }
            try? await Task.sleep(for: .seconds(15))
            inFlightTarget = nil
        }
        .help(L10n.format("%@ 端口开关", port.label))
    }

    private var reading: some View {
        HStack(alignment: .lastTextBaseline, spacing: Space.xs) {
            // The unit never leaves. Standby therefore keeps rolling 0.5 → 0.0 →
            // 0.5 in place, and an empty port reads "— W" rather than dropping
            // the whole block for a word twice a minute.
            Text(powerText)
                .font(Typo.metric)
                .foregroundStyle(readingTint)
                .contentTransition(hasReadings ? .numericText(value: watts) : .opacity)
                .animation(Motion.reduced(Motion.value, reduceMotion), value: watts)
            Text("W")
                .font(.ui(13, .medium))
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .frame(height: 34, alignment: .bottomLeading)
        // Stale is stale, whether or not the port was charging when the link
        // dropped. `hasReadings` made the old `&& isDelivering` actively harmful:
        // a 5 V standby port now keeps printing crisp digits after the charger
        // has been gone for minutes.
        .opacity(isStale ? Self.staleOpacity : 1)
        .animation(.easeOut(duration: 0.2), value: isStale)
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: hasReadings)
    }

    private var powerText: String {
        hasReadings ? L10n.format("%.1f", watts) : Self.placeholder
    }

    private var voltageText: String {
        hasReadings ? L10n.format("%.2f", telemetry?.voltage ?? 0) : Self.placeholder
    }

    private var currentText: String {
        hasReadings ? L10n.format("%.2f", telemetry?.current ?? 0) : Self.placeholder
    }

    /// Three steps, not two: a dashed-out reading must not be as loud as a real
    /// one, and a standby reading must not be as loud as a live one.
    private var readingTint: Color {
        guard hasReadings else { return Palette.textTertiary }
        return isDelivering ? Palette.textPrimary : Palette.textSecondary
    }

    /// One line that carries every difference the layout no longer expresses.
    private var statusText: String {
        guard telemetry != nil else { return L10n.text("无数据") }
        if !isOn { return L10n.text("已关闭") }
        if isDelivering { return footerText }
        if isStandby { return L10n.text("待机") }
        return L10n.text("未接入设备")
    }

    private var footer: some View {
        HStack(spacing: Space.s) {
            metric(voltageText, "V")
            metric(currentText, "A")
            Spacer(minLength: 0)
            Text(statusText)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: statusText)
        }
        // 变暗和底部留白都交给包着它和「接入设备」的那层，两行必须同进同退。
    }

    /// Trickle first — a full device's 0.5 W with a protocol badge looked like a
    /// fault; then fast-charge protocol; then this port's share of the load.
    private var footerText: String {
        if watts < 2.5 { return L10n.text("涓流 · 已充满或休眠") }
        if let profile = telemetry?.profileText { return profile }
        if let totalPower, totalPower > 0.5, watts > 0.5 {
            return L10n.format("占 %.0f%%", min(100, watts / totalPower * 100))
        }
        return L10n.text("供电中")
    }

    /// The unit is part of the slot, not part of the value: "— V" keeps saying
    /// which quantity is missing.
    private func metric(_ value: String, _ unit: String) -> some View {
        let placeheld = value == Self.placeholder
        return HStack(spacing: 1) {
            Text(value)
                .font(.numeral(12, .medium))
                .foregroundStyle(placeheld ? Palette.textTertiary : Palette.textSecondary)
                .contentTransition(placeheld ? .opacity : .numericText())
                .animation(Motion.reduced(Motion.value, reduceMotion), value: value)
            Text(unit)
                .font(.ui(10, .medium))
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private func dismissFieldEditor() {
        // SwiftUI may restore the field editor after the TextField's submit or
        // a neighbouring button action completes. Resign on the next main-loop
        // turn so the final responder state matches the user's completed edit.
        DispatchQueue.main.async {
            (NSApp.keyWindow ?? NSApp.mainWindow)?.makeFirstResponder(nil)
        }
    }
}
