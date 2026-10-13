import A2345Protocol
import CharkerCore
import SwiftUI

/// Up to four custom charging profiles stored in the Anker account. Using one
/// writes its limits to the charger; every port drops out for a few seconds
/// while it renegotiates.
struct A2345CustomModeSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: A2345CloudChargingMode?
    @State private var editingIsNew = false
    @State private var confirmingUse: A2345CloudChargingMode?
    @State private var confirmingDelete: A2345CloudChargingMode?

    private var settings: A2345DeviceSettings? { model.a2345Snapshot.settings }
    private var disabled: Bool {
        model.a2345ControlBlocker != nil
            || model.a2345CloudWork.contains(.chargingModes)
            || model.isA2345WritePending(A2345WriteKey(messageType: 0x0211))
            || model.isA2345WritePending(A2345WriteKey(messageType: 0x0206))
    }

    var body: some View {
        Group {
            if let editing {
                A2345CustomModeEditor(
                    model: model,
                    draft: editing,
                    isNew: editingIsNew,
                    isActive: isActive(editing),
                    close: { self.editing = nil }
                )
            } else {
                list
            }
        }
        .frame(width: 520, height: 560)
        .background(Palette.bg)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("自定义模式")
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                if model.a2345CloudWork.contains(.chargingModes) {
                    ProgressView().controlSize(.small)
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Space.l)
            Divider().overlay(Palette.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    if let modes = model.a2345ChargingModes {
                        ForEach(modes) { mode in row(mode) }
                        if let number = model.a2345NextChargingModeNumber {
                            Button {
                                editingIsNew = true
                                editing = A2345CloudChargingMode.template(
                                    number: number,
                                    name: L10n.format("模式 %d", number),
                                    mainland: model.a2345IsMainland
                                )
                            } label: {
                                Label(L10n.text("新建"), systemImage: "plus")
                            }
                            .buttonStyle(CharkerActionButtonStyle())
                            .disabled(disabled)
                        }
                    } else {
                        Text("自定义模式没有读到。")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                .padding(Space.l)
            }
        }
        .confirmationDialog(
            L10n.format("切换到「%@」？", confirmingUse?.name ?? ""),
            isPresented: Binding(get: { confirmingUse != nil }, set: { if !$0 { confirmingUse = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.text("切换")) {
                if let mode = confirmingUse { model.applyA2345ChargingMode(mode) }
                confirmingUse = nil
            }
            Button("取消", role: .cancel) { confirmingUse = nil }
        } message: {
            Text("所有端口会断电几秒后恢复。")
        }
        .confirmationDialog(
            L10n.format("删除「%@」？", confirmingDelete?.name ?? ""),
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.text("删除"), role: .destructive) {
                if let mode = confirmingDelete { model.deleteA2345ChargingMode(mode) }
                confirmingDelete = nil
            }
            Button("取消", role: .cancel) { confirmingDelete = nil }
        } message: {
            if let mode = confirmingDelete, isActive(mode) {
                Text("充电器会退出自定义模式。")
            }
        }
    }

    private func row(_ mode: A2345CloudChargingMode) -> some View {
        SlateCard(padding: Space.m) {
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Space.xs) {
                        Text(mode.name)
                            .font(Typo.label)
                            .foregroundStyle(Palette.textPrimary)
                        if isActive(mode) {
                            Chip(text: L10n.text("使用中"), tone: .accent)
                        }
                    }
                    Text(summary(mode))
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: Space.s)
                Button(L10n.text("使用")) { confirmingUse = mode }
                    .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                    .disabled(disabled || isActive(mode))
                Button(L10n.text("编辑")) {
                    editingIsNew = false
                    editing = mode
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(disabled)
                Button {
                    confirmingDelete = mode
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(disabled)
                .accessibilityLabel(Text(L10n.text("删除")))
            }
        }
    }

    private func summary(_ mode: A2345CloudChargingMode) -> String {
        let ports = A2345PortGroup.allCases.map { group -> String in
            let label = group == .usbA ? "A" : group.label
            return "\(label) \(mode.setting(group)?.power ?? 0)W"
        }
        return ports.joined(separator: " · ")
    }

    private func isActive(_ mode: A2345CloudChargingMode) -> Bool {
        settings?.isCustomChargingMode == true && Int(settings?.customProfile?.number ?? 0) == mode.number
    }
}

private struct A2345CustomModeEditor: View {
    @ObservedObject var model: AppModel
    @State var draft: A2345CloudChargingMode
    let isNew: Bool
    let isActive: Bool
    let close: () -> Void
    @State private var confirmingSave = false

    private var mainland: Bool { model.a2345IsMainland }
    private var showsProtocols: Bool {
        guard let settings = model.a2345Snapshot.settings else { return false }
        return settings.supports(.portProtocols) && !settings.supports(.protocolManagement)
    }
    private var total: Int { draft.powerSettings.reduce(0) { $0 + $1.power } }
    private var valid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && total <= A2345CustomChargingProfile.totalLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    close()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(GhostButtonStyle())
                Text(isNew ? L10n.text("新建自定义模式") : L10n.text("编辑自定义模式"))
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Button(L10n.text("保存")) {
                    if isActive { confirmingSave = true } else { save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid || model.a2345ControlBlocker != nil)
            }
            .padding(Space.l)
            Divider().overlay(Palette.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    HStack(spacing: Space.m) {
                        Text("名称")
                            .font(Typo.body)
                            .foregroundStyle(Palette.textSecondary)
                        TextField("", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: draft.name) { _, name in
                                if name.count > 20 { draft.name = String(name.prefix(20)) }
                            }
                    }
                    ForEach(Array(draft.powerSettings.indices), id: \.self) { index in
                        portEditor(index)
                    }
                    HStack {
                        Text("合计")
                            .font(Typo.body)
                            .foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Text(L10n.format("%d / %d W", total, A2345CustomChargingProfile.totalLimit))
                            .font(.numeral(13, .semibold))
                            .foregroundStyle(total > A2345CustomChargingProfile.totalLimit ? Palette.dangerText : Palette.textPrimary)
                            .monospacedDigit()
                    }
                    SwitchRow(
                        title: "自动退出",
                        subtitle: "有设备插到设为 0 W 的端口时，切回智能动态分配。",
                        isOn: $draft.autoExit
                    )
                }
                .padding(Space.l)
            }
        }
        .confirmationDialog(
            L10n.text("保存并应用到充电器？"),
            isPresented: $confirmingSave,
            titleVisibility: .visible
        ) {
            Button(L10n.text("保存")) { save() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有端口会断电几秒后恢复。")
        }
    }

    private func group(_ index: Int) -> A2345PortGroup {
        let name = draft.powerSettings[index].name.uppercased()
        return A2345PortGroup.allCases.first {
            A2345CloudChargingMode.portNames[$0.rawValue] == name
        } ?? A2345PortGroup(rawValue: index) ?? .c1
    }

    @ViewBuilder
    private func portEditor(_ index: Int) -> some View {
        let group = group(index)
        let maximum = Int(A2345CustomChargingProfile.maximumWatts(group, mainland: mainland))
        SlateCard(padding: Space.m) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.m) {
                    Text(group.label)
                        .font(.numeral(13, .bold))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 44, alignment: .leading)
                    if group == .usbA {
                        CharkerSegmentedControl(
                            label: group.label,
                            selection: Binding(
                                get: { draft.powerSettings[index].power },
                                set: { draft.powerSettings[index].power = $0 }
                            ),
                            segments: A2345CustomChargingProfile.usbAChoices.map {
                                CharkerSegment("\($0) W", value: Int($0))
                            }
                        )
                        .frame(width: 180)
                        Spacer()
                    } else {
                        Slider(
                            value: Binding(
                                get: { Double(draft.powerSettings[index].power) },
                                set: { draft.powerSettings[index].power = Self.snap(Int($0.rounded()), maximum: maximum) }
                            ),
                            in: 0...Double(maximum)
                        )
                        Stepper(
                            "",
                            onIncrement: { step(index, by: 1, maximum: maximum) },
                            onDecrement: { step(index, by: -1, maximum: maximum) }
                        )
                        .labelsHidden()
                        Text("\(draft.powerSettings[index].power) W")
                            .font(.numeral(12, .medium))
                            .foregroundStyle(Palette.textPrimary)
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                if showsProtocols, group != .usbA {
                    protocolChips(index)
                }
            }
        }
    }

    /// C ports take 0 or 15 W and up; the official editor jumps over 1–14.
    private static func snap(_ value: Int, maximum: Int) -> Int {
        if value <= 0 { return 0 }
        if value < 15 { return value < 8 ? 0 : 15 }
        return min(maximum, value)
    }

    private func step(_ index: Int, by delta: Int, maximum: Int) {
        let current = draft.powerSettings[index].power
        var next = current + delta
        if delta > 0, next > 0, next < 15 { next = 15 }
        if delta < 0, next < 15 { next = 0 }
        draft.powerSettings[index].power = min(maximum, max(0, next))
    }

    private struct ProtocolChip {
        let title: String
        let keyPath: WritableKeyPath<A2345CloudChargingMode.PortSetting, Bool>
        let isVoltageProfile: Bool
    }

    private var chips: [ProtocolChip] {
        var list: [ProtocolChip] = [
            ProtocolChip(title: mainland ? L10n.text("华为 SCP") : "SCP",
                         keyPath: mainland ? \.huawei : \.scp, isVoltageProfile: false),
            ProtocolChip(title: "UFCS", keyPath: \.ufcs, isVoltageProfile: false),
            ProtocolChip(title: "PD 12V", keyPath: \.pd12V, isVoltageProfile: true),
            ProtocolChip(title: "5-11V PPS", keyPath: \.pps11V, isVoltageProfile: true),
            ProtocolChip(title: "5-16V PPS", keyPath: \.pps16V, isVoltageProfile: true),
            ProtocolChip(title: "4.5-21V PPS", keyPath: \.pps21V, isVoltageProfile: true),
        ]
        if mainland {
            list.append(ProtocolChip(title: L10n.text("小米澎湃秒充"), keyPath: \.xiaomi, isVoltageProfile: false))
        }
        return list
    }

    private func protocolChips(_ index: Int) -> some View {
        let setting = draft.powerSettings[index]
        let voltageCount = chips.filter { $0.isVoltageProfile && setting[keyPath: $0.keyPath] }.count
        return FlowChips(items: chips.map { chip in
            let on = setting[keyPath: chip.keyPath]
            // At most three of PD 12V and the PPS ranges; PD 12V and Xiaomi
            // exclude each other — the official protocol rules.
            var blocked = !on && chip.isVoltageProfile && voltageCount >= 3
            if mainland, !on, chip.keyPath == \.pd12V, setting.xiaomi { blocked = true }
            if mainland, !on, chip.keyPath == \.xiaomi, setting.pd12V { blocked = true }
            return FlowChips.Item(title: chip.title, on: on, enabled: !blocked) {
                draft.powerSettings[index][keyPath: chip.keyPath].toggle()
            }
        })
    }

    private func save() {
        var mode = draft
        mode.name = mode.name.trimmingCharacters(in: .whitespaces)
        mode.hasChargeProtocol = true
        mode.maxTotalPower = A2345CustomChargingProfile.totalLimit
        for index in mode.powerSettings.indices {
            let group = group(index)
            mode.powerSettings[index].maxPower = Int(A2345CustomChargingProfile.maximumWatts(group, mainland: mainland))
            // The official overseas editor drops SCP on ports limited to 15–20 W.
            if !mainland, (15...20).contains(mode.powerSettings[index].power) {
                mode.powerSettings[index].scp = false
            }
        }
        model.saveA2345ChargingMode(mode, isNew: isNew)
        close()
    }
}

/// Small toggle chips that wrap onto several lines.
private struct FlowChips: View {
    struct Item {
        let title: String
        let on: Bool
        let enabled: Bool
        let action: () -> Void
    }

    let items: [Item]

    var body: some View {
        ChipFlowLayout(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button(action: item.action) {
                    Text(item.title)
                        .font(.ui(11, item.on ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .foregroundStyle(item.on ? Palette.accentText : Palette.textSecondary)
                        .background(
                            Capsule().fill(item.on ? Palette.accentWash : Palette.surfaceRaised)
                        )
                        .overlay(
                            Capsule().strokeBorder(item.on ? Palette.accent.opacity(0.6) : Palette.stroke, lineWidth: Stroke.hairline)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!item.enabled)
                .opacity(item.enabled ? 1 : 0.45)
                .accessibilityAddTraits(item.on ? .isSelected : [])
            }
        }
    }
}

private struct ChipFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
