import A2345Protocol
import CharkerCore
import SwiftUI

/// Countdown menu and output switch for one A2345 port group, laid out like
/// the A2687 port row. A1 and A2 share one group, so both rows drive the
/// same switch.
struct A2345PortControls: View {
    @ObservedObject var model: AppModel
    let group: A2345PortGroup

    @State private var confirmingSwitch = false
    @State private var pendingTarget = false
    @State private var pendingTimerSeconds: UInt32?
    @State private var confirmingTimer = false
    @State private var customTimerOpen = false
    @State private var customTimerMinutesText = ""
    @State private var scheduleOpen = false

    private var control: A2345PortControl? { model.a2345Snapshot.settings?.portControls[group] }
    private var isOn: Bool { control?.isOn ?? false }
    private var blocker: String? { model.a2345PortControlBlocker }
    private var isSwitchPending: Bool {
        model.isA2345WritePending(A2345WriteKey(messageType: 0x0207, group: group))
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            timerMenu
            outputSwitch
        }
        .disabled(blocker != nil || control == nil)
        .help(blocker ?? L10n.format("%@ 端口开关", group.label))
        .confirmationDialog(
            L10n.format("让 %@ 在 %@ 后断电？", group.label, PortCard.durationText(pendingTimerSeconds ?? 0)),
            isPresented: $confirmingTimer
        ) {
            Button(L10n.text("设定倒计时")) {
                if let seconds = pendingTimerSeconds {
                    model.setA2345PortCountdown(group, seconds: seconds)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(Self.timerConsequence(group))
        }
    }

    // MARK: Switch

    private var outputSwitch: some View {
        Toggle(L10n.format("%@ 输出", group.label), isOn: Binding(
            get: { confirmingSwitch ? pendingTarget : isOn },
            set: { target in
                pendingTarget = target
                confirmingSwitch = true
            }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .opacity(isSwitchPending ? 0.6 : 1)
        .confirmationDialog(
            pendingTarget
                ? L10n.format("打开 %@？", group.label)
                : L10n.format("关闭 %@？", group.label),
            isPresented: $confirmingSwitch
        ) {
            Button(
                L10n.text(pendingTarget ? "打开端口" : "关闭端口"),
                role: pendingTarget ? nil : .destructive
            ) {
                model.setA2345PortOutput(group, on: pendingTarget)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(pendingTarget
                 ? L10n.format("%@ 将恢复供电。", group.label)
                 : L10n.format("正在从 %@ 取电的设备会立即断电。", group.label))
        }
    }

    // MARK: Countdown and schedule

    /// The official presets, then a custom duration, cancel, and the two
    /// daily on/off times.
    private static let timerPresets: [UInt32] = [3_600, 7_200, 10_800]

    private var timerMenu: some View {
        Menu {
            Section {
                ForEach(Self.timerPresets, id: \.self) { seconds in
                    Button(PortCard.durationText(seconds)) {
                        pendingTimerSeconds = seconds
                        confirmingTimer = true
                    }
                    .disabled(!isOn)
                }
                Button(L10n.text("自定义…")) {
                    customTimerMinutesText = ""
                    customTimerOpen = true
                }
                .disabled(!isOn)
                if control?.countdownEnabled == true {
                    Button(L10n.text("关闭倒计时")) {
                        model.setA2345PortCountdown(group, seconds: nil)
                    }
                }
            }
            Section {
                Button(L10n.text("定时开关…")) { scheduleOpen = true }
            }
        } label: {
            Image(systemName: hasTimer ? "timer.circle.fill" : "timer")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hasTimer ? Palette.accentText : Palette.textTertiary)
                .frame(width: 18, height: 18)
                .background { Circle().fill(Palette.surfaceRaised) }
                .overlay { Circle().strokeBorder(Palette.stroke, lineWidth: Stroke.hairline) }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.format("让 %@ 在一段时间后自动断电", group.label))
        .accessibilityLabel(Text(L10n.format("%@ 自动断电倒计时", group.label)))
        .popover(isPresented: $customTimerOpen, arrowEdge: .bottom) { customTimerPopover }
        .popover(isPresented: $scheduleOpen, arrowEdge: .bottom) {
            A2345ScheduleEditor(model: model, group: group) { scheduleOpen = false }
        }
    }

    private var hasTimer: Bool {
        guard let control else { return false }
        return control.countdownEnabled || control.powerOn.isEnabled || control.powerOff.isEnabled
    }

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
            Text("5 到 1435 分钟，5 的倍数。")
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
            Text(Self.timerConsequence(group))
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

    /// The official picker offers 5-minute steps up to 23 h 55 min.
    private var customTimerMinutes: Int? {
        guard let value = Int(customTimerMinutesText.trimmingCharacters(in: .whitespaces)),
              (5...1_435).contains(value), value % 5 == 0 else { return nil }
        return value
    }

    private func commitCustomTimer() {
        guard let minutes = customTimerMinutes else { return }
        customTimerOpen = false
        model.setA2345PortCountdown(group, seconds: UInt32(minutes) * 60)
    }

    static func timerConsequence(_ group: A2345PortGroup) -> String {
        L10n.format("到点后 %@ 会断电，那时正在从它取电的设备会断开。", group.label)
    }
}

/// The countdown and daily times of one group as a single short line, or
/// nothing when none is set.
struct A2345PortTimerLine: View {
    @ObservedObject var model: AppModel
    let group: A2345PortGroup

    var body: some View {
        if let control = model.a2345Snapshot.settings?.portControls[group],
           control.countdownEnabled || control.powerOn.isEnabled || control.powerOff.isEnabled {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                HStack(spacing: Space.xs) {
                    Image(systemName: "timer")
                        .font(.system(size: 9, weight: .semibold))
                    Text(verbatim: summary(control, at: timeline.date))
                        .font(Typo.micro)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(Palette.accentText)
            }
        }
    }

    private func summary(_ control: A2345PortControl, at date: Date) -> String {
        var parts: [String] = []
        if let remaining = model.a2345Snapshot.countdownRemaining(group, at: date) {
            let seconds = Int(remaining)
            parts.append(String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60))
        }
        if control.powerOn.isEnabled {
            parts.append(L10n.format("%@ 开", A2345ScheduleText.time(control.powerOn)))
        }
        if control.powerOff.isEnabled {
            parts.append(L10n.format("%@ 关", A2345ScheduleText.time(control.powerOff)))
        }
        return parts.joined(separator: " · ")
    }
}

enum A2345ScheduleText {
    static func time(_ schedule: A2345PortSchedule) -> String {
        String(format: "%02d:%02d", Int(schedule.hour), Int(schedule.minute))
    }

    /// Monday first, as the charger numbers the bits.
    static let weekdaySymbols: [String] = [
        L10n.text("一"), L10n.text("二"), L10n.text("三"), L10n.text("四"),
        L10n.text("五"), L10n.text("六"), L10n.text("日"),
    ]

    /// Unambiguous names for summaries and VoiceOver.
    static let weekdayNames: [String] = [
        L10n.text("周一"), L10n.text("周二"), L10n.text("周三"), L10n.text("周四"),
        L10n.text("周五"), L10n.text("周六"), L10n.text("周日"),
    ]

    static func days(_ mask: UInt8) -> String {
        switch mask & 0x7F {
        case 0: return L10n.text("仅一次")
        case 0x7F: return L10n.text("每天")
        case 0x1F: return L10n.text("工作日")
        case 0x60: return L10n.text("周末")
        default:
            return (0..<7).filter { mask & (1 << $0) != 0 }
                .map { weekdayNames[$0] }
                .joined(separator: " ")
        }
    }
}

/// Seven toggle chips for a weekday mask, Monday first.
struct A2345WeekdayPicker: View {
    @Binding var mask: UInt8

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                let bit = UInt8(1 << index)
                let on = mask & bit != 0
                Button {
                    mask ^= bit
                } label: {
                    Text(A2345ScheduleText.weekdaySymbols[index])
                        .font(.ui(11, on ? .semibold : .regular))
                        .frame(width: 24, height: 22)
                        .foregroundStyle(on ? Palette.accentText : Palette.textSecondary)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(on ? Palette.accentWash : Palette.surfaceRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(on ? Palette.accent.opacity(0.6) : Palette.stroke, lineWidth: Stroke.hairline)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(A2345ScheduleText.weekdayNames[index]))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// The two daily slots of one group. Changes are sent together on 保存, one
/// write per slot that changed.
struct A2345ScheduleEditor: View {
    @ObservedObject var model: AppModel
    let group: A2345PortGroup
    let close: () -> Void

    @State private var powerOn = Slot()
    @State private var powerOff = Slot()
    /// What the slots held when the editor opened. Only slots the user
    /// changed against these are sent.
    @State private var baseOn = Slot()
    @State private var baseOff = Slot()
    @State private var loaded = false

    struct Slot: Equatable {
        var enabled = false
        var time = Calendar.current.date(from: DateComponents(hour: 8, minute: 0)) ?? Date()
        var days: UInt8 = 0x7F

        init() {}

        init(_ schedule: A2345PortSchedule) {
            enabled = schedule.isEnabled
            time = Calendar.current.date(
                from: DateComponents(hour: Int(min(schedule.hour, 23)), minute: Int(min(schedule.minute, 59)))
            ) ?? Date()
            days = schedule.isUnset ? 0x7F : schedule.weekdays & 0x7F
        }

        var schedule: A2345PortSchedule {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            return A2345PortSchedule(
                isEnabled: enabled,
                hour: UInt8(parts.hour ?? 0),
                minute: UInt8(parts.minute ?? 0),
                weekdays: days
            )
        }
    }

    private var control: A2345PortControl? { model.a2345Snapshot.settings?.portControls[group] }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(L10n.format("%@ 定时开关", group.label))
                .font(Typo.label)
                .foregroundStyle(Palette.textPrimary)
            slotEditor(L10n.text("定时开启"), $powerOn)
            Divider().overlay(Palette.stroke)
            slotEditor(L10n.text("定时关闭"), $powerOff)
            if conflicts {
                Text("开和关不能设在同一时间。")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.warnText)
            }
            HStack(spacing: Space.s) {
                Spacer(minLength: 0)
                Button("取消", action: close)
                Button(L10n.text("保存"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(conflicts || !changed || model.a2345PortControlBlocker != nil)
            }
        }
        .padding(Space.m)
        .frame(width: 292)
        .onAppear(perform: load)
    }

    private func slotEditor(_ title: String, _ slot: Binding<Slot>) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text(title).font(Typo.body).foregroundStyle(Palette.textPrimary)
                Spacer()
                Toggle(title, isOn: slot.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            HStack(spacing: Space.s) {
                // The system time field with its stepper, as System Settings
                // uses for Night Shift and Downtime.
                DatePicker(title, selection: slot.time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                Spacer(minLength: 0)
                A2345WeekdayPicker(mask: slot.days)
            }
            .disabled(!slot.wrappedValue.enabled)
            .opacity(slot.wrappedValue.enabled ? 1 : 0.5)
            Text(A2345ScheduleText.days(slot.wrappedValue.days))
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private func load() {
        guard !loaded, let control else { return }
        loaded = true
        powerOn = Slot(control.powerOn)
        powerOff = Slot(control.powerOff)
        baseOn = powerOn
        baseOff = powerOff
    }

    private var changed: Bool {
        guard loaded else { return false }
        return powerOn.schedule != baseOn.schedule || powerOff.schedule != baseOff.schedule
    }

    /// The official app refuses an on and an off time at the same minute on a
    /// shared day.
    private var conflicts: Bool {
        let on = powerOn.schedule
        let off = powerOff.schedule
        guard on.isEnabled, off.isEnabled, on.hour == off.hour, on.minute == off.minute else { return false }
        if on.weekdays == 0 || off.weekdays == 0 { return true }
        return on.weekdays & off.weekdays != 0
    }

    private func save() {
        guard loaded else { return }
        if powerOn.schedule != baseOn.schedule {
            model.setA2345PortSchedule(group, .powerOn, powerOn.schedule)
        }
        if powerOff.schedule != baseOff.schedule {
            model.setA2345PortSchedule(group, .powerOff, powerOff.schedule)
        }
        close()
    }
}
