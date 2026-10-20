import A2345Protocol
import AppKit
import CharkerCore
import SwiftUI

/// Names the official app uses for the four preset modes and custom mode.
enum A2345Labels {
    static func mode(_ mode: A2345ChargingMode) -> String {
        switch mode {
        case .aiPower: return L10n.text("智能动态分配")
        case .portPriority: return L10n.text("端口优先分配")
        case .dualLaptop: return L10n.text("双笔电模式")
        case .lowCurrent: return L10n.text("涓流模式")
        }
    }

    static func timeout(_ timeout: A2345ScreenTimeout) -> String {
        switch timeout {
        case .alwaysOn: return L10n.text("常亮")
        case .thirtySeconds: return L10n.text("30 秒")
        case .oneMinute: return L10n.text("1 分钟")
        case .fiveMinutes: return L10n.text("5 分钟")
        case .thirtyMinutes: return L10n.text("30 分钟")
        }
    }

    static func knob(_ direction: A2345KnobDirection) -> String {
        switch direction {
        case .forward: return L10n.text("正向")
        case .backward: return L10n.text("反向")
        }
    }

    static func builtInStyle(_ kind: A2345ThemeKind) -> String {
        L10n.format("样式 %d", Int(kind.rawValue) + 1)
    }

    static func priority(_ bitmap: UInt8) -> String {
        let ports = [A2345PortGroup.c1, .c2, .c3, .c4]
            .filter { bitmap & (1 << UInt8($0.rawValue)) != 0 }
            .map(\.label)
        return ports.isEmpty ? L10n.text("无") : ports.joined(separator: L10n.text("、"))
    }

    static func clockSchedule(_ schedule: A2345ClockSchedule) -> String {
        String(
            format: "%02d:%02d–%02d:%02d",
            Int(schedule.startHour), Int(schedule.startMinute),
            Int(schedule.endHour), Int(schedule.endMinute)
        ) + " · " + A2345ScheduleText.days(schedule.weekdays)
    }
}

/// One labelled row of a settings card.
private struct A2345Row<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Space.m) {
            Text(title)
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: Space.m)
            trailing
        }
        .frame(minHeight: 24)
    }
}

private func a2345MenuLabel(_ text: String) -> some View {
    HStack(spacing: Space.xs) {
        Text(text).font(Typo.label)
        Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Palette.textTertiary)
    }
}

private extension View {
    func a2345MenuStyle() -> some View {
        self
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .buttonStyle(GhostButtonStyle())
            .fixedSize()
    }
}

// MARK: - Device settings

struct A2345DeviceSettingsCard: View {
    @ObservedObject var model: AppModel
    @Binding var showsCustomModes: Bool
    @State private var brightnessDraft: Double = 60
    @State private var brightnessEditing = false
    @State private var confirmingProfile: A2345CloudChargingMode?

    private var settings: A2345DeviceSettings? { model.a2345Snapshot.settings }
    private var blocker: String? { model.a2345ControlBlocker }
    private var disabled: Bool { blocker != nil }

    var body: some View {
        SlateCard {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("设备设置")
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)
                chargingModeRow
                if settings?.chargingMode == .portPriority {
                    priorityRow
                }
                Text(L10n.text("切换时正在充电的设备可能短暂断电。"))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                Divider().overlay(Palette.stroke)
                timeoutRow
                brightnessRow
                knobRow
                if let blocker {
                    Text(blocker)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.bottom, Space.xxs)
        }
        .onAppear { syncBrightness(settings?.brightness) }
        .onChange(of: settings?.brightness) { _, value in syncBrightness(value) }
        .confirmationDialog(
            L10n.format("切换到「%@」？", confirmingProfile?.name ?? ""),
            isPresented: Binding(
                get: { confirmingProfile != nil },
                set: { if !$0 { confirmingProfile = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("切换")) {
                if let profile = confirmingProfile { model.applyA2345ChargingMode(profile) }
                confirmingProfile = nil
            }
            Button("取消", role: .cancel) { confirmingProfile = nil }
        } message: {
            Text("所有端口会断电几秒后恢复。")
        }
    }

    private var modeText: String {
        guard let settings else { return "—" }
        if settings.isCustomChargingMode {
            let number = Int(settings.customProfile?.number ?? 0)
            if let profile = model.a2345ChargingModes?.first(where: { $0.number == number }), !profile.name.isEmpty {
                return profile.name
            }
            return L10n.text("自定义模式")
        }
        return settings.chargingMode.map(A2345Labels.mode) ?? "—"
    }

    private var customModeAvailable: Bool {
        model.a2345SupportsCustomMode && (model.a2345CloudSettings?.customModeEnabled ?? false)
    }

    private var chargingModeRow: some View {
        A2345Row(title: L10n.text("充电模式")) {
            if model.isA2345WritePending(A2345WriteKey(messageType: 0x0206)) {
                ProgressView().controlSize(.small)
            }
            if settings?.chargingModeCode == nil {
                Text(modeText).font(Typo.label).foregroundStyle(Palette.textPrimary)
            } else {
                Menu {
                    Section {
                        ForEach(A2345ChargingMode.allCases, id: \.rawValue) { mode in
                            Button {
                                model.setA2345ChargingMode(mode)
                            } label: {
                                if settings?.chargingMode == mode {
                                    Label(A2345Labels.mode(mode), systemImage: "checkmark")
                                } else {
                                    Text(A2345Labels.mode(mode))
                                }
                            }
                            .disabled(settings?.chargingMode == mode)
                        }
                    }
                    if customModeAvailable {
                        Section(L10n.text("自定义模式")) {
                            ForEach(model.a2345ChargingModes ?? []) { profile in
                                Button {
                                    confirmingProfile = profile
                                } label: {
                                    if isActive(profile) {
                                        Label(profile.name, systemImage: "checkmark")
                                    } else {
                                        Text(profile.name)
                                    }
                                }
                                .disabled(isActive(profile))
                            }
                            Button(L10n.text("管理自定义模式…")) { showsCustomModes = true }
                        }
                    }
                } label: {
                    a2345MenuLabel(modeText)
                }
                .a2345MenuStyle()
                .disabled(disabled)
                .accessibilityLabel(Text(L10n.text("充电模式")))
                .accessibilityValue(Text(modeText))
            }
        }
    }

    private func isActive(_ profile: A2345CloudChargingMode) -> Bool {
        settings?.isCustomChargingMode == true && Int(settings?.customProfile?.number ?? 0) == profile.number
    }

    private var priorityRow: some View {
        let bitmap = settings?.priorityBitmap ?? 0
        return A2345Row(title: L10n.text("优先端口")) {
            Menu {
                ForEach([A2345PortGroup.c1, .c2, .c3, .c4], id: \.self) { group in
                    let bit = UInt8(1 << group.rawValue)
                    let chosen = bitmap & bit != 0
                    Button {
                        model.setA2345PortPriority(bitmap ^ bit)
                    } label: {
                        if chosen {
                            Label(group.label, systemImage: "checkmark")
                        } else {
                            Text(group.label)
                        }
                    }
                    .disabled(!chosen && bitmap.nonzeroBitCount >= 2)
                }
            } label: {
                a2345MenuLabel(A2345Labels.priority(bitmap))
            }
            .a2345MenuStyle()
            .disabled(disabled)
            .help(L10n.text("最多两个端口。"))
        }
    }

    private var timeoutRow: some View {
        A2345Row(title: L10n.text("熄屏时间")) {
            if let current = settings?.screenTimeout {
                Menu {
                    ForEach(A2345ScreenTimeout.allCases, id: \.rawValue) { timeout in
                        Button {
                            model.setA2345ScreenTimeout(timeout)
                        } label: {
                            if current == timeout {
                                Label(A2345Labels.timeout(timeout), systemImage: "checkmark")
                            } else {
                                Text(A2345Labels.timeout(timeout))
                            }
                        }
                        .disabled(current == timeout)
                    }
                } label: {
                    a2345MenuLabel(A2345Labels.timeout(current))
                }
                .a2345MenuStyle()
                .disabled(disabled)
            } else {
                Text("—").font(Typo.label).foregroundStyle(Palette.textPrimary)
            }
        }
    }

    private var brightnessRow: some View {
        HStack(spacing: Space.m) {
            Text(L10n.text("屏幕亮度"))
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 76, alignment: .leading)
            Slider(value: $brightnessDraft, in: 20...100, onEditingChanged: { brightnessEditing = $0 })
                .frame(minWidth: 150)
                .disabled(disabled || settings?.brightness == nil)
                .accessibilityLabel(Text(L10n.text("屏幕亮度")))
            Text("\(brightnessPercent)%")
                .font(.numeral(12, .medium))
                .foregroundStyle(Palette.textPrimary)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
            Button(L10n.text("应用")) {
                model.setA2345Brightness(UInt8(brightnessPercent))
            }
            .buttonStyle(CharkerActionButtonStyle(emphasis: .secondary))
            .disabled(disabled || settings?.brightness == nil || settings?.brightness.map(Int.init) == brightnessPercent)
        }
    }

    /// The charger takes 20…100 in steps of five.
    private var brightnessPercent: Int {
        min(100, max(20, Int((brightnessDraft / 5).rounded()) * 5))
    }

    private func syncBrightness(_ value: UInt8?) {
        guard !brightnessEditing, let value else { return }
        brightnessDraft = Double(min(100, max(20, value)))
    }

    private var knobRow: some View {
        A2345Row(title: L10n.text("旋钮方向")) {
            if let current = settings?.knobDirection {
                Menu {
                    ForEach(A2345KnobDirection.allCases, id: \.rawValue) { direction in
                        Button {
                            model.setA2345KnobDirection(direction)
                        } label: {
                            if current == direction {
                                Label(A2345Labels.knob(direction), systemImage: "checkmark")
                            } else {
                                Text(A2345Labels.knob(direction))
                            }
                        }
                        .disabled(current == direction)
                    }
                } label: {
                    a2345MenuLabel(A2345Labels.knob(current))
                }
                .a2345MenuStyle()
                .disabled(disabled)
            } else {
                Text("—").font(Typo.label).foregroundStyle(Palette.textPrimary)
            }
        }
    }
}

// MARK: - Clock screensaver

struct A2345ClockCard: View {
    @ObservedObject var model: AppModel
    @Binding var showsThemes: Bool
    @State private var editingSchedule = false

    private var settings: A2345DeviceSettings? { model.a2345Snapshot.settings }
    private var clock: A2345ClockState? { settings?.clock }
    private var disabled: Bool { model.a2345ControlBlocker != nil }
    private var clockOn: Bool { clock?.isOn ?? false }
    /// The official app shows hour format and holiday themes on firmware that
    /// reports protocol version 1 or the clock-schedule capability.
    private var hasClockExtras: Bool {
        settings?.protocolVersion == 1 || settings?.supports(.clockSchedule) == true
    }

    var body: some View {
        SlateCard {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack {
                    Text("时钟屏保")
                        .font(Typo.heading)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    Toggle(L10n.text("时钟屏保"), isOn: Binding(
                        get: { clockOn },
                        set: { model.setA2345ClockEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(disabled || clock == nil || !model.a2345CanToggleClock)
                }
                A2345Row(title: L10n.text("主题")) {
                    if model.a2345ThemeDownload != nil {
                        ProgressView().controlSize(.small)
                    }
                    Text(themeName)
                        .font(Typo.label)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Button(L10n.text("更换…")) { showsThemes = true }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(disabled || clock == nil || !clockOn)
                        .help(clockOn ? "" : L10n.text("先打开时钟屏保。"))
                }
                if hasClockExtras {
                    A2345Row(title: L10n.text("时间格式")) {
                        CharkerSegmentedControl(
                            label: L10n.text("时间格式"),
                            selection: Binding(
                                get: { settings?.hourFormat ?? .twentyFourHour },
                                set: { model.setA2345HourFormat($0) }
                            ),
                            segments: [
                                CharkerSegment(L10n.text("12 小时制"), value: A2345HourFormat.twelveHour),
                                CharkerSegment(L10n.text("24 小时制"), value: A2345HourFormat.twentyFourHour),
                            ]
                        )
                        .frame(width: 180)
                        .disabled(disabled || !clockOn || settings?.hourFormat == nil)
                    }
                }
                if settings?.supports(.clockSchedule) == true, let schedule = settings?.clockSchedule {
                    A2345Row(title: L10n.text("显示时段")) {
                        Text(A2345Labels.clockSchedule(schedule))
                            .font(Typo.label)
                            .foregroundStyle(Palette.textPrimary)
                            .monospacedDigit()
                            .lineLimit(1)
                        Button(L10n.text("编辑…")) { editingSchedule = true }
                            .buttonStyle(GhostButtonStyle())
                            .disabled(disabled || !clockOn)
                            .popover(isPresented: $editingSchedule, arrowEdge: .bottom) {
                                A2345ClockScheduleEditor(model: model, initial: schedule) {
                                    editingSchedule = false
                                }
                            }
                    }
                }
                if hasClockExtras {
                    A2345Row(title: L10n.text("节日屏保")) {
                        Toggle(L10n.text("节日屏保"), isOn: Binding(
                            get: { clock?.holidayEnabled ?? false },
                            set: { model.setA2345HolidayTheme($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(disabled || !clockOn)
                    }
                }
                if clock?.themeKind == .custom, settings?.supports(.customImageTimeDisplay) == true {
                    A2345Row(title: L10n.text("显示时间")) {
                        Toggle(L10n.text("显示时间"), isOn: Binding(
                            get: { settings?.customImageTimeDisplay ?? true },
                            set: { model.setA2345CustomImageTimeDisplay($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(disabled)
                    }
                }
            }
            .padding(.bottom, Space.xxs)
        }
    }

    private var themeName: String {
        guard let clock else { return "—" }
        if let kind = clock.themeKind, kind.isBuiltIn { return A2345Labels.builtInStyle(kind) }
        if let theme = model.a2345CurrentPictureTheme {
            if theme.kind == .custom { return L10n.text("我的图片") }
            return theme.title.isEmpty ? L10n.text("云端主题") : theme.title
        }
        return clock.themeKind == .custom ? L10n.text("我的图片") : L10n.text("云端主题")
    }
}

struct A2345ClockScheduleEditor: View {
    @ObservedObject var model: AppModel
    let initial: A2345ClockSchedule
    let close: () -> Void

    @State private var start = Date()
    @State private var end = Date()
    @State private var days: UInt8 = 0x7F
    /// Seeded once per opening, as ``A2345ScheduleEditor`` does.
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("显示时段")
                .font(Typo.label)
                .foregroundStyle(Palette.textPrimary)
            HStack(spacing: Space.s) {
                ScheduleTimeField(label: L10n.text("开始时间"), time: $start)
                Text(verbatim: "–").foregroundStyle(Palette.textTertiary)
                ScheduleTimeField(label: L10n.text("结束时间"), time: $end, endOfDay: true)
            }
            A2345WeekdayPicker(mask: $days)
            Text(A2345ScheduleText.days(days))
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
            HStack(spacing: Space.s) {
                Spacer(minLength: 0)
                Button("取消", action: close)
                Button(L10n.text("保存")) {
                    model.setA2345ClockSchedule(schedule)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(schedule == initial)
            }
        }
        .padding(Space.m)
        .frame(width: 268)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let calendar = Calendar.current
            start = calendar.date(from: DateComponents(hour: Int(initial.startHour), minute: Int(initial.startMinute))) ?? Date()
            end = calendar.date(from: DateComponents(hour: Int(initial.endHour), minute: Int(initial.endMinute))) ?? Date()
            days = initial.weekdays & 0x7F
        }
    }

    private var schedule: A2345ClockSchedule {
        let calendar = Calendar.current
        let s = calendar.dateComponents([.hour, .minute], from: start)
        let e = calendar.dateComponents([.hour, .minute], from: end)
        return A2345ClockSchedule(
            startHour: UInt8(s.hour ?? 0), startMinute: UInt8(s.minute ?? 0),
            endHour: UInt8(e.hour ?? 0), endMinute: UInt8(e.minute ?? 0),
            weekdays: days
        )
    }
}

/// The system time field with its stepper, as System Settings uses for Night
/// Shift and Downtime: type, use the arrow keys, or click the arrows. Built
/// directly on NSDatePicker so the end of the range can take one liberty.
private struct ScheduleTimeField: NSViewRepresentable {
    let label: String
    @Binding var time: Date
    /// An hour typed past 23 means the end of the day, 23:59. The field
    /// itself turns 24 into 02 without a word.
    var endOfDay = false

    func makeCoordinator() -> Coordinator { Coordinator(time: $time) }

    func makeNSView(context: Context) -> ScheduleDatePicker {
        let picker = ScheduleDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.isBezeled = true
        picker.drawsBackground = false
        picker.font = .systemFont(ofSize: NSFont.systemFontSize)
        picker.calendar = context.environment.calendar
        picker.locale = context.environment.locale
        picker.timeZone = context.environment.timeZone
        picker.endOfDay = endOfDay
        picker.delegate = picker
        picker.dateValue = time
        picker.setAccessibilityLabel(label)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }

    /// As wide as the field and its stepper, like the SwiftUI picker.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ScheduleDatePicker, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    func updateNSView(_ picker: ScheduleDatePicker, context: Context) {
        context.coordinator.time = $time
        if picker.dateValue != time { picker.dateValue = time }
        picker.isEnabled = context.environment.isEnabled
    }

    final class Coordinator: NSObject {
        var time: Binding<Date>

        init(time: Binding<Date>) { self.time = time }

        @objc func changed(_ sender: NSDatePicker) {
            time.wrappedValue = sender.dateValue
        }
    }
}

private final class ScheduleDatePicker: NSDatePicker, NSDatePickerCellDelegate {
    var endOfDay = false
    /// The last two digits typed, when, and the value before each.
    private var digits: [(digit: Character, at: Date, before: Date)] = []
    /// A valid two-digit entry commits inside its second keystroke; an hour
    /// past 23 is refused, and the lone 2 commits later on a timer.
    private var inKeystroke = false

    override func keyDown(with event: NSEvent) {
        if let key = event.charactersIgnoringModifiers?.first, key.isASCII, key.isNumber {
            digits = Array((digits + [(key, Date(), dateValue)]).suffix(2))
        } else {
            digits.removeAll()
        }
        inKeystroke = true
        defer { inKeystroke = false }
        super.keyDown(with: event)
    }

    func datePickerCell(
        _ cell: NSDatePickerCell,
        validateProposedDateValue value: AutoreleasingUnsafeMutablePointer<NSDate>,
        timeInterval: UnsafeMutablePointer<TimeInterval>?
    ) {
        let typed = digits
        digits.removeAll()
        guard endOfDay, !inKeystroke, typed.count == 2,
              typed[0].digit == "2", ("4"..."9").contains(typed[1].digit),
              typed[1].at.timeIntervalSince(typed[0].at) < 1.5,
              Date().timeIntervalSince(typed[1].at) < 2 else { return }
        let calendar = self.calendar ?? .current
        let proposed = calendar.dateComponents([.hour, .minute], from: value.pointee as Date)
        let before = calendar.dateComponents([.hour, .minute], from: typed[0].before)
        // The refused hour leaves its 2 behind and the minutes alone.
        guard proposed.hour == 2, proposed.minute == before.minute,
              let endOfDay = calendar.date(from: DateComponents(hour: 23, minute: 59)) else { return }
        value.pointee = endOfDay as NSDate
    }
}

// MARK: - Laboratory

struct A2345LabCard: View {
    @ObservedObject var model: AppModel
    @Binding var showsCustomModes: Bool

    private var settings: A2345DeviceSettings? { model.a2345Snapshot.settings }
    private var cloud: A2345CloudSettings? { model.a2345CloudSettings }
    private var disabled: Bool { model.a2345ControlBlocker != nil }

    var body: some View {
        if let settings, hasAnyRow(settings) {
            SlateCard {
                VStack(alignment: .leading, spacing: Space.m) {
                    Text("实验室")
                        .font(Typo.heading)
                        .foregroundStyle(Palette.textPrimary)
                    if settings.supports(.customChargingMode) {
                        A2345Row(title: L10n.text("自定义充电模式")) {
                            Button(L10n.text("管理…")) { showsCustomModes = true }
                                .buttonStyle(GhostButtonStyle())
                                .disabled(disabled || cloud?.customModeEnabled != true)
                            labToggle(
                                L10n.text("自定义充电模式"),
                                value: cloud?.customModeEnabled,
                                work: .customModeSwitch
                            ) { model.setA2345CustomModeEnabled($0) }
                        }
                    }
                    if settings.supports(.maxCompatibility) {
                        A2345Row(title: L10n.text("最大兼容性")) {
                            labToggle(
                                L10n.text("最大兼容性"),
                                value: cloud?.maxCompatibility ?? settings.maxCompatibility,
                                work: .labExclusive
                            ) { model.setA2345MaxCompatibility($0) }
                        }
                        .help(L10n.text("部分无人机的电池仓会充得更快。和充电设备识别不能同时打开。"))
                    }
                    if settings.supports(.deviceIdentification) {
                        A2345Row(title: L10n.text("充电设备识别")) {
                            labToggle(
                                L10n.text("充电设备识别"),
                                value: cloud?.deviceIdentification ?? settings.deviceIdentification,
                                work: .labExclusive
                            ) { model.setA2345DeviceIdentification($0) }
                        }
                        .help(L10n.text("充电器屏幕显示正在充电的设备型号。和最大兼容性不能同时打开。"))
                    }
                    if settings.supports(.ufcsSwitch), !settings.supports(.protocolManagement) {
                        A2345Row(title: "UFCS") {
                            Toggle("UFCS", isOn: Binding(
                                get: { settings.ufcs ?? false },
                                set: { model.setA2345UFCS($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(disabled || settings.ufcs == nil)
                        }
                    }
                }
                .padding(.bottom, Space.xxs)
            }
        }
    }

    private func hasAnyRow(_ settings: A2345DeviceSettings) -> Bool {
        settings.supports(.customChargingMode)
            || settings.supports(.maxCompatibility)
            || settings.supports(.deviceIdentification)
            || (settings.supports(.ufcsSwitch) && !settings.supports(.protocolManagement))
    }

    private func labToggle(
        _ title: String,
        value: Bool?,
        work: A2345CloudWork,
        set: @escaping (Bool) -> Void
    ) -> some View {
        HStack(spacing: Space.s) {
            if model.a2345CloudWork.contains(work) {
                ProgressView().controlSize(.small)
            }
            Toggle(title, isOn: Binding(get: { value ?? false }, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled || value == nil || model.a2345CloudWork.contains(work))
        }
    }
}
