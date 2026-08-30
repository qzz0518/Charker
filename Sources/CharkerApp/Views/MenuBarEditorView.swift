import A2687Protocol
import AppKit
import CharkerCore
import SwiftUI

// MARK: - Item presentation metadata

extension MenuBarItem {
    var typeTitle: String {
        switch kind {
        case .totalPower: return L10n.text("总功率")
        case .portPower:
            return L10n.format("%@ 功率", port.map { "C\($0 + 1)" } ?? L10n.text("端口"))
        case .portsCount: return L10n.text("输出端口数")
        case .state: return L10n.text("连接状态")
        case .deviceName: return L10n.text("设备名称")
        case .separator: return L10n.text("分隔符")
        case .text: return L10n.text("自定义文本")
        }
    }

    var typeSymbol: String {
        switch kind {
        case .totalPower: return "bolt.fill"
        case .portPower: return "powerplug"
        case .portsCount: return "number"
        case .state: return "dot.radiowaves.left.and.right"
        case .deviceName: return "tag"
        case .separator: return "circle.grid.2x1"
        case .text: return "character.cursor.ibeam"
        }
    }
}

// MARK: - The menu-bar settings page

/// The menu bar, configured by editing a live copy of it: items are added from
/// an anchored palette, dragged into order, selected for the inspector below,
/// and deleted with ⌫ — no template syntax anywhere in the main path.
struct MenuBarSettingsView: View {
    @ObservedObject var model: AppModel
    /// nil = nothing selected; `Self.iconSelection` = the pinned bolt icon.
    @State private var selection: UUID?
    @State private var showsPalette = false
    @State private var draggingID: UUID?
    @State private var chipFrames: [UUID: CGRect] = [:]
    @State private var templateDraft = ""
    @FocusState private var editorFocused: Bool
    @FocusState private var templateFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let iconSelection = UUID()

    private var items: [MenuBarItem] { model.preferences.menuBarItems }

    private var showsReadout: Binding<Bool> {
        Binding(
            get: { !model.preferences.showIconOnly },
            set: { model.preferences.showIconOnly = !$0 }
        )
    }

    var body: some View {
        SettingsPage(title: "菜单栏") {
            SettingsGroup {
                SwitchRow(
                    title: "在菜单栏显示读数",
                    subtitle: "关闭后只保留图标",
                    isOn: showsReadout
                )
                editor
                inspector
            }

            SettingsGroup(title: "显示") {
                HStack {
                    Text("默认小数位").font(Typo.body)
                    Spacer()
                    CharkerSegmentedControl(
                        label: "默认小数位",
                        selection: $model.preferences.decimals,
                        segments: (0...3).map { CharkerSegment("\($0)", value: $0) }
                    )
                    .frame(width: 168)
                }
                SwitchRow(title: "隐藏没有输出的端口", isOn: $model.preferences.hideIdlePorts)
            }

            SettingsGroup(
                title: "预设",
                footnote: "应用预设会替换当前布局。"
            ) {
                let rows = presetRows
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: Space.s) {
                            ForEach(row, id: \.name) { preset in
                                Button(preset.name) { apply(preset.items) }
                                    .buttonStyle(CharkerActionButtonStyle())
                                    .help(presetSample(preset.items))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            SettingsGroup {
                DisclosureGroup("高级：编辑模板") {
                    VStack(alignment: .leading, spacing: Space.m) {
                        Text("按回车应用；单位、标签等细项会重置为默认。")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .cjkParagraph(11, target: 1.5)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("模板", text: $templateDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(Typo.body)
                            .focused($templateFocused)
                            .onSubmit { setItems(MenuBarConfig.parse(templateDraft)) }
                        ForEach(StatusTemplate.tokens) { token in
                            HStack(alignment: .firstTextBaseline) {
                                Text(token.key)
                                    .font(.numeral(12, .medium))
                                    .foregroundStyle(Palette.accentText)
                                    .frame(width: 76, alignment: .leading)
                                Text(token.summary).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.top, Space.s)
                }
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
            }
        }
        .onAppear { templateDraft = MenuBarConfig.serialize(items) }
        .onChange(of: model.preferences.menuBarItemsJSON) {
            if !templateFocused { templateDraft = MenuBarConfig.serialize(items) }
        }
    }

    // MARK: - Mutations

    private func setItems(_ new: [MenuBarItem]) {
        model.preferences.menuBarItems = new
    }

    private var presetRows: [[(name: String, items: [MenuBarItem])]] {
        let presets = MenuBarConfig.presets
        let half = (presets.count + 1) / 2
        return [Array(presets.prefix(half)), Array(presets.dropFirst(half))]
    }

    /// Tooltip shows what the preset would say right now — pick by outcome.
    private func presetSample(_ items: [MenuBarItem]) -> String {
        let rendered = MenuBarConfig.render(
            items, snapshot: model.snapshot,
            defaultDecimals: model.preferences.decimals, hideIdlePorts: false,
            portNicknames: model.preferences.portNicknames
        )
        return rendered.isEmpty ? L10n.text("用这个组合替换当前布局") : rendered
    }

    private func apply(_ preset: [MenuBarItem]) {
        // Fresh ids per application, so re-applying a preset never aliases.
        setItems(preset.map { item in
            var copy = item
            copy.id = UUID()
            return copy
        })
        selection = nil
    }

    private func update(_ id: UUID, _ mutate: (inout MenuBarItem) -> Void) {
        var updated = items
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        mutate(&updated[index])
        setItems(updated)
    }

    private func insert(_ item: MenuBarItem) {
        var updated = items
        let at = selection
            .flatMap { id in updated.firstIndex(where: { $0.id == id }).map { $0 + 1 } }
            ?? updated.count
        updated.insert(item, at: at)
        setItems(updated)
        selection = item.id
        showsPalette = false
    }

    /// Deleting selects a neighbour, so ⌫ can walk down the row.
    private func remove(_ id: UUID) {
        var updated = items
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        updated.remove(at: index)
        setItems(updated)
        if updated.isEmpty {
            selection = nil
        } else {
            selection = updated[min(index, updated.count - 1)].id
        }
    }

    private func move(_ id: UUID, by delta: Int) {
        var updated = items
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard updated.indices.contains(target) else { return }
        updated.swapAt(index, target)
        setItems(updated)
        selection = id
    }

    // MARK: - Editor canvas

    /// A strip at real menu-bar proportions: our item on the left, neighbour
    /// glyphs on the right, everything live.
    private var editor: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    iconChip
                    if showsReadout.wrappedValue {
                        ForEach(items) { item in
                            chip(item)
                        }
                        addButton
                    }
                }
                .padding(.horizontal, Space.s)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            .coordinateSpace(name: "mbEditor")
            .onPreferenceChange(ChipFrameKey.self) { chipFrames = $0 }

            Spacer(minLength: Space.m)

            // Neighbours, for scale and truthfulness of the final look.
            HStack(spacing: Space.l) {
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text(L10n.text("周四 9:41")).font(.ui(12))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.textTertiary)
            .padding(.trailing, Space.m)
        }
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                .fill(Palette.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selection = nil
            editorFocused = true
        }
        .focusable()
        .focusEffectDisabled()
        .focused($editorFocused)
        .onKeyPress(phases: .down) { press in
            handleKey(press)
        }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: items.map(\.id))
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: showsReadout.wrappedValue)
        .accessibilityLabel(Text("菜单栏布局编辑器"))
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .delete, .deleteForward:
            guard let id = selection, id != Self.iconSelection else { return .ignored }
            remove(id)
            return .handled
        case .leftArrow, .rightArrow:
            let delta = press.key == .leftArrow ? -1 : 1
            guard let id = selection, id != Self.iconSelection else {
                // No selection: arrows enter the row from its ends.
                if let first = delta > 0 ? items.first : items.last { selection = first.id }
                return .handled
            }
            if press.modifiers.contains(.option) {
                move(id, by: delta)
            } else if let index = items.firstIndex(where: { $0.id == id }) {
                let target = index + delta
                if items.indices.contains(target) { selection = items[target].id }
            }
            return .handled
        case .escape:
            selection = nil
            return .handled
        default:
            return .ignored
        }
    }

    /// The bolt is the status item's image: always leftmost, never dragged.
    /// Selecting it opens its own inspector (show/hide).
    private var iconChip: some View {
        let isSelected = selection == Self.iconSelection
        return Image(systemName: model.statusSymbolName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(
                model.statusShowsIcon ? Palette.textPrimary : Palette.textTertiary.opacity(0.45)
            )
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? Palette.accentWash : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isSelected ? Palette.accent : .clear, lineWidth: 1.2)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selection = isSelected ? nil : Self.iconSelection
                editorFocused = true
            }
            .help("菜单栏图标（固定在最前）")
            .accessibilityLabel(Text("菜单栏图标"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func chip(_ item: MenuBarItem) -> some View {
        let isSelected = selection == item.id
        let isDragging = draggingID == item.id
        let text = MenuBarConfig.display(
            item, snapshot: model.snapshot,
            defaultDecimals: model.preferences.decimals, hideIdlePorts: false,
            portNicknames: model.preferences.portNicknames
        ) ?? item.typeTitle

        return Text(text)
            .font(.system(size: 12))
            .monospacedDigit()
            .lineLimit(1)
            // Long device names truncate like the real menu bar would, instead
            // of stretching the editor.
            .frame(maxWidth: 160)
            .foregroundStyle(Palette.textPrimary)
            .contentTransition(.numericText())
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected || isDragging ? Palette.accentWash : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isSelected ? Palette.accent : .clear, lineWidth: 1.2)
            )
            .scaleEffect(isDragging && !reduceMotion ? 1.06 : 1)
            .shadow(color: .black.opacity(isDragging ? 0.35 : 0), radius: 5, y: 2)
            .zIndex(isDragging ? 10 : 0)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ChipFrameKey.self,
                        value: [item.id: geometry.frame(in: .named("mbEditor"))]
                    )
                }
            )
            .onTapGesture {
                selection = isSelected ? nil : item.id
                editorFocused = true
            }
            .gesture(dragGesture(for: item))
            .contextMenu {
                Button("左移") { move(item.id, by: -1) }
                    .disabled(items.first?.id == item.id)
                Button("右移") { move(item.id, by: 1) }
                    .disabled(items.last?.id == item.id)
                Divider()
                Button("移除", role: .destructive) { remove(item.id) }
            }
            .accessibilityLabel(Text(L10n.format("%@，当前显示 %@", item.typeTitle, text)))
            .accessibilityHint(Text("点按选中，按住拖动排序"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction(named: "移除") { remove(item.id) }
            .accessibilityAction(named: "左移") { move(item.id, by: -1) }
            .accessibilityAction(named: "右移") { move(item.id, by: 1) }
    }

    /// Real reorder, not visual offset: the items array mutates (and persists)
    /// as the drag crosses neighbours' midpoints, the way List drags behave.
    private func dragGesture(for item: MenuBarItem) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("mbEditor"))
            .onChanged { value in
                if draggingID != item.id {
                    draggingID = item.id
                    selection = item.id
                    editorFocused = true
                }
                let x = value.location.x
                let proposed = items
                    .filter { $0.id != item.id }
                    .reduce(0) { count, other in
                        count + ((chipFrames[other.id].map { $0.midX < x }) == true ? 1 : 0)
                    }
                guard let current = items.firstIndex(where: { $0.id == item.id }),
                      proposed != current else { return }
                withAnimation(Motion.reduced(Motion.ui, reduceMotion)) {
                    var updated = items
                    let moved = updated.remove(at: current)
                    updated.insert(moved, at: proposed)
                    setItems(updated)
                }
            }
            .onEnded { _ in draggingID = nil }
    }

    private var addButton: some View {
        Button {
            showsPalette = true
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.accentText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("添加内容")
        .popover(isPresented: $showsPalette, arrowEdge: .bottom) {
            PaletteView(model: model, existing: items, insert: insert)
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        Divider().overlay(Palette.stroke)
        if selection == Self.iconSelection {
            iconInspector
        } else if let id = selection, let item = items.first(where: { $0.id == id }) {
            ItemInspector(
                item: item,
                isFirst: items.first?.id == id,
                isLast: items.last?.id == id,
                globalDecimals: model.preferences.decimals,
                portNicknames: model.preferences.portNicknames,
                update: { mutate in update(id, mutate) },
                move: { delta in move(id, by: delta) },
                remove: { remove(id) }
            )
        } else {
            Text(L10n.text(showsReadout.wrappedValue
                 ? "点选上方组件进行设置；按住可拖动排序，⌫ 删除。"
                 : "打开「在菜单栏显示读数」后即可编辑内容。"))
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private var iconInspector: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            inspectorHeader("菜单栏图标", symbol: "bolt.fill")
            SwitchRow(
                title: "显示图标",
                subtitle: model.preferences.showIconOnly || model.statusTitle.isEmpty
                    ? "读数为空时图标必须保留，否则菜单栏项目无法点击"
                    : nil,
                isOn: Binding(
                    get: { model.preferences.showsMenuBarIcon },
                    set: { model.preferences.showsMenuBarIcon = $0 }
                )
            )
            .disabled(model.preferences.showIconOnly)

            VStack(alignment: .leading, spacing: Space.s) {
                Text("图标样式").font(Typo.body)
                HStack(spacing: Space.s) {
                    ForEach(availableIconChoices, id: \.self) { symbol in
                        iconChoice(symbol)
                    }
                    Spacer(minLength: 0)
                }
                Text("连接中、数据陈旧或出错时会临时换成对应的状态图标。")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
            .opacity(model.preferences.showsMenuBarIcon || model.preferences.showIconOnly ? 1 : 0.4)
            .disabled(!(model.preferences.showsMenuBarIcon || model.preferences.showIconOnly))
        }
    }

    /// Only symbols this OS actually has — a future-named symbol renders as an
    /// empty well otherwise.
    private var availableIconChoices: [String] {
        AppModel.menuBarIconChoices.filter {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        }
    }

    private func iconChoice(_ symbol: String) -> some View {
        let isSelected = model.preferences.menuBarIconSymbol == symbol
        return Button {
            model.preferences.menuBarIconSymbol = symbol
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Palette.accentText : Palette.textSecondary)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(isSelected ? Palette.accentWash : Palette.well)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(
                            isSelected ? Palette.accent : Palette.stroke,
                            lineWidth: isSelected ? 1.2 : Stroke.hairline
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(symbol)
        .accessibilityLabel(Text(L10n.format("图标样式 %@", symbol)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func inspectorHeader(_ title: String, symbol: String) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.accentText)
            Text(L10n.text(title)).font(Typo.heading).foregroundStyle(Palette.textPrimary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Chip frame plumbing

private struct ChipFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Add palette

/// The anchored component palette: categorised, each entry with a live sample,
/// duplicates of unique items disabled with the reason spelled out.
private struct PaletteView: View {
    @ObservedObject var model: AppModel
    let existing: [MenuBarItem]
    let insert: (MenuBarItem) -> Void

    private var existingKeys: Set<String> { Set(existing.map(\.uniqueKey)) }

    private var categories: [(title: String, items: [MenuBarItem])] {
        [
            ("设备数据", [
                MenuBarItem(kind: .totalPower),
                MenuBarItem(kind: .portPower, port: 0),
                MenuBarItem(kind: .portPower, port: 1),
                MenuBarItem(kind: .portPower, port: 2),
                MenuBarItem(kind: .portsCount, systemContent: .activePortsCount),
            ]),
            ("状态", [
                MenuBarItem(kind: .state),
                MenuBarItem(kind: .deviceName),
            ]),
            ("文本与分隔符", [
                MenuBarItem(kind: .separator, label: "·"),
                MenuBarItem(kind: .separator, label: "|"),
                MenuBarItem(kind: .text, systemContent: .sampleText),
            ]),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(categories, id: \.title) { category in
                Text(L10n.text(category.title))
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, Space.s)
                    .padding(.top, Space.xs)
                ForEach(category.items) { item in
                    row(item)
                }
            }
        }
        .padding(Space.s)
        .frame(width: 240)
    }

    private func row(_ item: MenuBarItem) -> some View {
        let taken = item.isUnique && existingKeys.contains(item.uniqueKey)
        let sample = MenuBarConfig.display(
            item, snapshot: model.snapshot,
            defaultDecimals: model.preferences.decimals, hideIdlePorts: false,
            portNicknames: model.preferences.portNicknames
        )
        return Button {
            insert(item)
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: item.typeSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(taken ? Palette.textTertiary : Palette.accentText)
                    .frame(width: 16)
                Text(item.typeTitle)
                    .font(Typo.body)
                    .foregroundStyle(taken ? Palette.textTertiary : Palette.textPrimary)
                Spacer(minLength: Space.s)
                Text(taken ? L10n.text("已添加") : (sample ?? ""))
                    .font(.ui(11))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(PaletteRowStyle())
        .disabled(taken)
        .help(L10n.text(taken ? "这一项只能添加一次" : "插入到当前选中项之后"))
    }
}

private struct PaletteRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PaletteRowBody(configuration: configuration)
    }

    private struct PaletteRowBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(hovering || configuration.isPressed ? Palette.surfaceRaised : .clear)
                )
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Item inspector

/// Options for the selected component, inline below the editor — never a
/// blocking sheet. Only rows the component actually supports.
private struct ItemInspector: View {
    let item: MenuBarItem
    let isFirst: Bool
    let isLast: Bool
    let globalDecimals: Int
    let portNicknames: [String]
    let update: ((inout MenuBarItem) -> Void) -> Void
    let move: (Int) -> Void
    let remove: () -> Void

    /// What a port item shows when its own label is empty: the dashboard
    /// nickname if one exists, else the plain port name.
    private var inheritedPortName: String {
        guard let port = item.port else { return "" }
        let nickname = port < portNicknames.count ? portNicknames[port] : ""
        return nickname.isEmpty ? "C\(port + 1)" : nickname
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Image(systemName: item.typeSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.accentText)
                Text(item.typeTitle).font(Typo.heading).foregroundStyle(Palette.textPrimary)
                Spacer(minLength: Space.m)
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(isFirst)
                    .help("左移")
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(isLast)
                    .help("右移")
                Button(role: .destructive) { remove() } label: { Image(systemName: "trash") }
                    .help("移除（⌫）")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            options
        }
    }

    @ViewBuilder
    private var options: some View {
        switch item.kind {
        case .totalPower:
            labelField(placeholder: L10n.text("无前缀"))
            unitToggle
            decimalsPicker
        case .portPower:
            SwitchRow(title: "显示端口名", isOn: binding(\.showsPortName))
            labelField(placeholder: inheritedPortName)
            unitToggle
            decimalsPicker
        case .portsCount:
            labelField(placeholder: L10n.text("无前缀"))
        case .separator:
            HStack {
                Text("样式").font(Typo.body)
                Spacer()
                CharkerSegmentedControl(
                    label: "样式",
                    selection: binding(\.label, default: "·"),
                    segments: [
                        CharkerSegment("·", value: "·"),
                        CharkerSegment("|", value: "|"),
                    ]
                )
                .frame(width: 110)
            }
        case .text:
            HStack(spacing: Space.m) {
                Text("内容").font(Typo.body)
                TextField(
                    "文本",
                    text: binding(
                        \.label,
                        default: item.systemContent == .sampleText ? L10n.text("文本") : ""
                    )
                )
                    .textFieldStyle(.roundedBorder)
                    .font(Typo.body)
            }
        case .state, .deviceName:
            Text("这一项没有可调设置。")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private var unitToggle: some View {
        SwitchRow(title: "显示单位 W", isOn: binding(\.showsUnit))
    }

    private var decimalsPicker: some View {
        let selection = Binding<Int>(
            get: { item.decimals ?? -1 },
            set: { value in update { $0.decimals = value == -1 ? nil : value } }
        )
        return HStack {
            Text("小数位").font(Typo.body)
            Spacer()
            CharkerSegmentedControl(
                label: "小数位",
                selection: selection,
                segments: [CharkerSegment(L10n.format("全局（%d）", globalDecimals), value: -1)]
                    + (0...3).map { CharkerSegment("\($0)", value: $0) }
            )
            .frame(width: 240)
        }
    }

    private func labelField(placeholder: String) -> some View {
        HStack(spacing: Space.m) {
            Text("标签").font(Typo.body)
            TextField(placeholder, text: Binding(
                get: { item.label ?? "" },
                set: { value in update { $0.setUserLabel(value.isEmpty ? nil : value) } }
            ))
            .textFieldStyle(.roundedBorder)
            .font(Typo.body)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<MenuBarItem, Bool>) -> Binding<Bool> {
        Binding(
            get: { item[keyPath: keyPath] },
            set: { value in update { $0[keyPath: keyPath] = value } }
        )
    }

    private func binding(
        _ keyPath: WritableKeyPath<MenuBarItem, String?>, default fallback: String
    ) -> Binding<String> {
        Binding(
            get: { item[keyPath: keyPath] ?? fallback },
            set: { value in update { $0.setUserLabel(value) } }
        )
    }
}
