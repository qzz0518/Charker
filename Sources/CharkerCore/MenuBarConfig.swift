import A2687Protocol
import Foundation

/// One ordered building block of the menu-bar readout.
///
/// This is the authoritative editing model: the settings editor mutates an
/// ordered `[MenuBarItem]`, the status item and the preview both render it
/// through ``MenuBarConfig/render(_:snapshot:defaultDecimals:hideIdlePorts:)``,
/// and the legacy template string is a derived artifact kept only for
/// backward/forward compatibility and the advanced raw editor.
public struct MenuBarItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case totalPower, portPower, portsCount, state, deviceName, separator, text
    }

    /// Stable provenance for copy supplied by Charker rather than the user.
    ///
    /// The enum value is persisted, while its visible text is resolved against
    /// the current bundle at render time. `label` remains strictly verbatim
    /// user content and always wins when both fields are present.
    public enum SystemContent: String, Codable, Sendable {
        case activePortsCount
        case sampleText
    }

    public var id: UUID
    public var kind: Kind
    /// Stable `ChargerPortID.rawValue` (0…5), only for `.portPower`.
    public var port: Int?
    /// Meaning depends on kind: label prefix for value items, the mark for
    /// `.separator` ("·"/"|"), the content for `.text`.
    public var label: String?
    /// Built-in copy that follows the current app language. Nil for all legacy
    /// JSON and for user-authored content.
    public var systemContent: SystemContent?
    /// Value items only: whether the "W" unit is appended.
    public var showsUnit: Bool
    /// `.portPower` only: whether the port name (C1…C4/A1/A2) prefixes the value.
    public var showsPortName: Bool
    /// Per-item override of the global decimal places.
    public var decimals: Int?

    public init(
        id: UUID = UUID(), kind: Kind, port: Int? = nil, label: String? = nil,
        systemContent: SystemContent? = nil, showsUnit: Bool = true,
        showsPortName: Bool = true, decimals: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.port = port
        self.label = label
        self.systemContent = systemContent
        self.showsUnit = showsUnit
        self.showsPortName = showsPortName
        self.decimals = decimals
    }

    /// Decoding tolerates fields added by future versions; an unknown `kind`
    /// fails the single item, which `MenuBarConfig.decode` turns into "keep the
    /// rest", never "lose the whole configuration".
    private enum CodingKeys: String, CodingKey {
        case id, kind, port, label, systemContent, showsUnit, showsPortName, decimals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(Kind.self, forKey: .kind)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        // A future system-content role must not make an otherwise valid item
        // disappear through MenuBarConfig's item-tolerant decoder.
        if let rawSystemContent = try? container.decode(String.self, forKey: .systemContent) {
            systemContent = SystemContent(rawValue: rawSystemContent)
        } else {
            systemContent = nil
        }
        showsUnit = try container.decodeIfPresent(Bool.self, forKey: .showsUnit) ?? true
        showsPortName = try container.decodeIfPresent(Bool.self, forKey: .showsPortName) ?? true
        decimals = try container.decodeIfPresent(Int.self, forKey: .decimals)
    }

    /// Converts built-in copy into literal user content. Clearing the field is
    /// also an explicit edit, so it must not resurrect the system default.
    public mutating func setUserLabel(_ value: String?) {
        label = value
        systemContent = nil
    }

    /// True for items that only make sense once (adding a second 总功率 is a
    /// configuration error, adding a second separator is not).
    public var isUnique: Bool {
        switch kind {
        case .separator, .text: return false
        default: return true
        }
    }

    /// Identity for uniqueness checks: portPower is unique per port.
    public var uniqueKey: String {
        kind == .portPower ? "portPower.\(port ?? -1)" : kind.rawValue
    }
}

public enum MenuBarConfig {
    // MARK: - Rendering

    /// Formats ONE item against live data. The preview chips and the real
    /// status-item title both go through here — same input, same function,
    /// same output, so the preview can never lie.
    ///
    /// Returns nil when the item elides entirely (an idle port under
    /// hideIdlePorts). `forceValues` disables elision for per-chip previews.
    public static func display(
        _ item: MenuBarItem,
        snapshot: SessionSnapshot,
        defaultDecimals: Int,
        hideIdlePorts: Bool,
        portNicknames: [String] = [],
        placeholder: String = "—",
        bundle: Bundle = .main
    ) -> String? {
        func format(_ watts: Double) -> String {
            let decimals = max(0, min(3, item.decimals ?? defaultDecimals))
            let number = String(format: "%.\(decimals)f", watts)
            return item.showsUnit ? "\(number) W" : number
        }
        func prefixed(_ value: String, with label: String?) -> String {
            guard let label, !label.isEmpty else { return value }
            return "\(label) \(value)"
        }

        switch item.kind {
        case .totalPower:
            let value = snapshot.totalPower.map(format) ?? placeholder
            return prefixed(value, with: item.label)
        case .portPower:
            guard let index = item.port, let port = A2687.Port(rawValue: index) else { return nil }
            // The item's own label wins; otherwise the dashboard nickname
            // carries over ("MacBook 66.2 W"); otherwise the plain port name.
            let nickname = index < portNicknames.count ? portNicknames[index] : ""
            let name = item.label ?? (nickname.isEmpty ? port.label : nickname)
            guard let telemetry = snapshot.telemetry?.port(port) else {
                return prefixed(placeholder, with: item.showsPortName ? name : nil)
            }
            if hideIdlePorts && !telemetry.isDelivering { return nil }
            let value = format(telemetry.isOn ? telemetry.power : 0)
            return prefixed(value, with: item.showsPortName ? name : nil)
        case .portsCount:
            let count = snapshot.telemetry?.activePortCount ?? 0
            if let label = item.label {
                return prefixed("\(count)", with: label)
            }
            if item.systemContent == .activePortsCount {
                return L10n.format("%d 口", count, table: "Core", bundle: bundle)
            }
            return "\(count)"
        case .state:
            return snapshot.statusLabel
        case .deviceName:
            return snapshot.displayName ?? "Charker"
        case .separator:
            return item.label ?? "·"
        case .text:
            if let text = item.label {
                return text.isEmpty ? nil : text
            }
            let text = item.systemContent == .sampleText
                ? L10n.text("文本", table: "Core", bundle: bundle)
                : ""
            return text.isEmpty ? nil : text
        }
    }

    /// Transport-independent renderer used by A2345 and by product-aware
    /// previews. The legacy `SessionSnapshot` overload above remains untouched
    /// for the A2687 BLE path and older call sites.
    public static func display(
        _ item: MenuBarItem,
        reading: ChargerReading?,
        stateLabel: String,
        deviceName: String?,
        defaultDecimals: Int,
        hideIdlePorts: Bool,
        portNicknames: [String] = [],
        placeholder: String = "—",
        bundle: Bundle = .main
    ) -> String? {
        func format(_ watts: Double) -> String {
            let decimals = max(0, min(3, item.decimals ?? defaultDecimals))
            let number = String(format: "%.\(decimals)f", watts)
            return item.showsUnit ? "\(number) W" : number
        }
        func prefixed(_ value: String, with label: String?) -> String {
            guard let label, !label.isEmpty else { return value }
            return "\(label) \(value)"
        }

        switch item.kind {
        case .totalPower:
            return prefixed(reading.map { format($0.totalPower) } ?? placeholder, with: item.label)
        case .portPower:
            guard let index = item.port,
                  let port = ChargerPortID(rawValue: index),
                  reading?.product.ports.contains(port) != false else { return nil }
            let nickname = index < portNicknames.count ? portNicknames[index] : ""
            let name = item.label ?? (nickname.isEmpty ? port.label : nickname)
            guard let value = reading?.port(port) else {
                return prefixed(placeholder, with: item.showsPortName ? name : nil)
            }
            if hideIdlePorts && !value.isDelivering { return nil }
            return prefixed(
                format(value.isOn ? value.power : 0),
                with: item.showsPortName ? name : nil
            )
        case .portsCount:
            let count = reading?.activePortCount ?? 0
            if let label = item.label { return prefixed("\(count)", with: label) }
            if item.systemContent == .activePortsCount {
                return L10n.format("%d 口", count, table: "Core", bundle: bundle)
            }
            return "\(count)"
        case .state:
            return stateLabel
        case .deviceName:
            return deviceName ?? "Charker"
        case .separator:
            return item.label ?? "·"
        case .text:
            if let text = item.label { return text.isEmpty ? nil : text }
            let text = item.systemContent == .sampleText
                ? L10n.text("文本", table: "Core", bundle: bundle)
                : ""
            return text.isEmpty ? nil : text
        }
    }

    /// The whole title. Separator-delimited runs collapse exactly the way the
    /// template renderer always has: hiding an idle port takes its labels and,
    /// when the whole run goes, the run's separator with it.
    public static func render(
        _ items: [MenuBarItem],
        snapshot: SessionSnapshot,
        defaultDecimals: Int,
        hideIdlePorts: Bool,
        portNicknames: [String] = [],
        bundle: Bundle = .main
    ) -> String {
        struct Run {
            var parts: [String] = []
            var portItems = 0
            var elidedPortItems = 0
            var separatorAfter: String?
            var isEmpty: Bool { parts.isEmpty }
            var allPortsElided: Bool { portItems > 0 && portItems == elidedPortItems }
        }

        var runs: [Run] = []
        var current = Run()
        for item in items {
            if item.kind == .separator {
                current.separatorAfter = item.label ?? "·"
                runs.append(current)
                current = Run()
                continue
            }
            if item.kind == .portPower { current.portItems += 1 }
            if let text = display(
                item, snapshot: snapshot,
                defaultDecimals: defaultDecimals, hideIdlePorts: hideIdlePorts,
                portNicknames: portNicknames, bundle: bundle
            ) {
                current.parts.append(text)
            } else if item.kind == .portPower {
                current.elidedPortItems += 1
            }
        }
        runs.append(current)

        let kept = runs.filter { !$0.isEmpty && !$0.allPortsElided }
        var out = ""
        for (index, run) in kept.enumerated() {
            out += run.parts.joined(separator: " ")
            if index < kept.count - 1 {
                out += " \(run.separatorAfter ?? "·") "
            }
        }
        return out
    }

    public static func render(
        _ items: [MenuBarItem],
        reading: ChargerReading?,
        stateLabel: String,
        deviceName: String?,
        defaultDecimals: Int,
        hideIdlePorts: Bool,
        portNicknames: [String] = [],
        bundle: Bundle = .main
    ) -> String {
        struct Run {
            var parts: [String] = []
            var portItems = 0
            var elidedPortItems = 0
            var separatorAfter: String?
            var isEmpty: Bool { parts.isEmpty }
            var allPortsElided: Bool { portItems > 0 && portItems == elidedPortItems }
        }

        var runs: [Run] = []
        var current = Run()
        for item in items {
            if item.kind == .separator {
                current.separatorAfter = item.label ?? "·"
                runs.append(current)
                current = Run()
                continue
            }
            if item.kind == .portPower { current.portItems += 1 }
            if let text = display(
                item,
                reading: reading,
                stateLabel: stateLabel,
                deviceName: deviceName,
                defaultDecimals: defaultDecimals,
                hideIdlePorts: hideIdlePorts,
                portNicknames: portNicknames,
                bundle: bundle
            ) {
                current.parts.append(text)
            } else if item.kind == .portPower {
                current.elidedPortItems += 1
            }
        }
        runs.append(current)

        let kept = runs.filter { !$0.isEmpty && !$0.allPortsElided }
        var output = ""
        for (index, run) in kept.enumerated() {
            output += run.parts.joined(separator: " ")
            if index < kept.count - 1 {
                output += " \(run.separatorAfter ?? "·") "
            }
        }
        return output
    }

    // MARK: - Persistence

    public static func encode(_ items: [MenuBarItem]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(items) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Item-tolerant decoding: one corrupt entry drops that entry, not the
    /// user's whole layout. Nil means "no stored configuration" — the caller
    /// falls back to parsing the legacy template.
    public static func decode(_ json: String) -> [MenuBarItem]? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        struct Lenient: Decodable {
            let item: MenuBarItem?
            init(from decoder: Decoder) throws {
                item = try? MenuBarItem(from: decoder)
            }
        }
        guard let wrapped = try? JSONDecoder().decode([Lenient].self, from: data) else { return nil }
        return wrapped.compactMap(\.item)
    }

    // MARK: - Template bridge (compatibility + advanced editor)

    /// Structured → template. Lossy by design (per-item options have no string
    /// form); exists so older builds and the raw editor keep working.
    public static func serialize(_ items: [MenuBarItem], bundle: Bundle = .main) -> String {
        items.compactMap { item -> String? in
            switch item.kind {
            case .totalPower: return "{total}"
            case .portPower:
                guard let port = item.port,
                      let identity = ChargerPortID(rawValue: port) else { return nil }
                let token = "{\(portToken(identity))}"
                return item.showsPortName ? "\(item.label ?? identity.label) \(token)" : token
            case .portsCount:
                if item.label == nil, item.systemContent == .activePortsCount {
                    return "{ports} \(L10n.text("口", table: "Core", bundle: bundle))"
                }
                return "{ports}"
            case .state: return "{state}"
            case .deviceName: return "{device}"
            case .separator: return item.label ?? "·"
            case .text:
                if let label = item.label { return label }
                if item.systemContent == .sampleText {
                    return L10n.text("文本", table: "Core", bundle: bundle)
                }
                return nil
            }
        }.joined(separator: " ")
    }

    /// Template → structured. Handles unknown tokens (kept as literal text),
    /// merges a "C1"-style literal into the port item that follows it, and is
    /// the migration path for configurations saved before items existed.
    public static func parse(_ template: String) -> [MenuBarItem] {
        let tokenMap: [String: MenuBarItem.Kind] = [
            "{total}": .totalPower, "{ports}": .portsCount,
            "{state}": .state, "{device}": .deviceName,
        ]
        var items: [MenuBarItem] = []
        var buffer = ""
        func flushText() {
            let trimmed = buffer.trimmingCharacters(in: .whitespaces)
            buffer = ""
            guard !trimmed.isEmpty else { return }
            items.append(MenuBarItem(kind: .text, label: trimmed))
        }
        var rest = Substring(template)
        while let character = rest.first {
            if character == "·" || character == "|" {
                flushText()
                items.append(MenuBarItem(kind: .separator, label: String(character)))
                rest.removeFirst()
            } else if character == "{",
                      let kind = tokenMap.first(where: { rest.hasPrefix($0.key) }) {
                flushText()
                items.append(MenuBarItem(kind: kind.value))
                rest.removeFirst(kind.key.count)
            } else if character == "{",
                      let port = ChargerPortID.allCases.first(where: {
                          rest.hasPrefix("{\(portToken($0))}")
                      }) {
                // "C1 {c1}" / "A1 {a1}" is one item wearing its default
                // name, not two separate text and value items.
                let trimmed = buffer.trimmingCharacters(in: .whitespaces)
                if trimmed.caseInsensitiveCompare(port.label) == .orderedSame {
                    buffer = ""
                    items.append(MenuBarItem(
                        kind: .portPower,
                        port: port.rawValue,
                        showsPortName: true
                    ))
                } else {
                    flushText()
                    items.append(MenuBarItem(
                        kind: .portPower,
                        port: port.rawValue,
                        showsPortName: false
                    ))
                }
                rest.removeFirst("{\(portToken(port))}".count)
            } else {
                buffer.append(character)
                rest.removeFirst()
            }
        }
        flushText()
        return items
    }

    /// Starting layouts for the presets row. Presets seed the items; the user
    /// keeps editing from there.
    public static let presets: [(name: String, items: [MenuBarItem])] = [
        (L10n.text("总功率", table: "Core"), [MenuBarItem(kind: .totalPower)]),
        (
            L10n.text("纯数字", table: "Core"),
            [MenuBarItem(kind: .totalPower, showsUnit: false, decimals: 0)]
        ),
        (L10n.text("总功率 · 端口数", table: "Core"), [
            MenuBarItem(kind: .totalPower),
            MenuBarItem(kind: .separator, label: "·"),
            MenuBarItem(
                kind: .portsCount,
                systemContent: .activePortsCount
            ),
        ]),
        (L10n.text("C1 · C2", table: "Core"), [
            MenuBarItem(kind: .portPower, port: 0),
            MenuBarItem(kind: .separator, label: "·"),
            MenuBarItem(kind: .portPower, port: 1),
        ]),
        (L10n.text("三口功率", table: "Core"), [
            MenuBarItem(kind: .portPower, port: 0),
            MenuBarItem(kind: .separator, label: "·"),
            MenuBarItem(kind: .portPower, port: 1),
            MenuBarItem(kind: .separator, label: "·"),
            MenuBarItem(kind: .portPower, port: 2),
        ]),
        (L10n.text("总功率｜状态", table: "Core"), [
            MenuBarItem(kind: .totalPower),
            MenuBarItem(kind: .separator, label: "|"),
            MenuBarItem(kind: .state),
        ]),
        (L10n.text("设备名 · 总功率", table: "Core"), [
            MenuBarItem(kind: .deviceName),
            MenuBarItem(kind: .separator, label: "·"),
            MenuBarItem(kind: .totalPower),
        ]),
        (L10n.text("极简三口", table: "Core"), [
            MenuBarItem(kind: .portPower, port: 0, showsUnit: false, showsPortName: false, decimals: 0),
            MenuBarItem(kind: .separator, label: "|"),
            MenuBarItem(kind: .portPower, port: 1, showsUnit: false, showsPortName: false, decimals: 0),
            MenuBarItem(kind: .separator, label: "|"),
            MenuBarItem(kind: .portPower, port: 2, showsUnit: false, showsPortName: false, decimals: 0),
        ]),
    ]

    private static func portToken(_ port: ChargerPortID) -> String {
        port.label.lowercased()
    }
}
