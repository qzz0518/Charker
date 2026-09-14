import A2687Protocol
import Foundation

/// Renders the menu bar title from a user template.
///
/// The template is a fixed token whitelist, not an expression language: nothing
/// the user types is ever evaluated.
public enum StatusTemplate {
    public struct Token: Sendable, Identifiable {
        public var id: String { key }
        public let key: String
        public let summary: String
    }

    public static let tokens: [Token] = [
        Token(key: "{total}", summary: L10n.text("总功率", table: "Core")),
        Token(key: "{c1}", summary: L10n.text("C1 口功率", table: "Core")),
        Token(key: "{c2}", summary: L10n.text("C2 口功率", table: "Core")),
        Token(key: "{c3}", summary: L10n.text("C3 口功率", table: "Core")),
        Token(key: "{c4}", summary: L10n.text("C4 口功率", table: "Core")),
        Token(key: "{a1}", summary: L10n.text("A1 口功率", table: "Core")),
        Token(key: "{a2}", summary: L10n.text("A2 口功率", table: "Core")),
        Token(key: "{ports}", summary: L10n.text("正在输出的端口数", table: "Core")),
        Token(
            key: "{state}",
            summary: L10n.text("连接状态，例如「已连接」", table: "Core")
        ),
        Token(key: "{device}", summary: L10n.text("充电器名称", table: "Core")),
    ]

    // No ⚡ in the templates: the status item always draws the bolt as its
    // image, and an emoji bolt in the title doubled it up.
    public static let `default` = "{total}"
    public static let presets = ["{total}", "C1 {c1} · C2 {c2}", "{total} | {state}", "{total} ({ports})"]

    public static func render(
        _ template: String,
        snapshot: SessionSnapshot,
        decimals: Int = 1,
        hideIdlePorts: Bool = false,
        placeholder: String = "—"
    ) -> String {
        func format(_ value: Double) -> String {
            String(format: "%.\(max(0, min(3, decimals)))f W", value)
        }

        // Hiding an idle port must take its written-out label with it: eliding
        // only the value turns "C1 {c1} · C2 {c2}" into "C1 65.0 W · C2". The
        // template is therefore rendered per separator-delimited segment, and a
        // segment whose port tokens all elided is dropped whole.
        func renderSegment(_ segment: String) -> String? {
            var out = segment
            var portTokens = 0
            var elided = 0
            for (token, port) in [("{c1}", A2687.Port.c1), ("{c2}", .c2), ("{c3}", .c3)] {
                guard out.contains(token) else { continue }
                portTokens += 1
                if let telemetry = snapshot.telemetry?.port(port) {
                    if hideIdlePorts && !telemetry.isDelivering {
                        elided += 1
                        out = out.replacingOccurrences(of: token, with: "")
                    } else {
                        out = out.replacingOccurrences(of: token, with: format(telemetry.isOn ? telemetry.power : 0))
                    }
                } else {
                    out = out.replacingOccurrences(of: token, with: placeholder)
                }
            }
            if portTokens > 0 && portTokens == elided { return nil }
            out = out.replacingOccurrences(of: "{total}", with: snapshot.totalPower.map(format) ?? placeholder)
            out = out.replacingOccurrences(of: "{ports}", with: "\(snapshot.telemetry?.activePortCount ?? 0)")
            out = out.replacingOccurrences(of: "{state}", with: snapshot.statusLabel)
            out = out.replacingOccurrences(of: "{device}", with: snapshot.displayName ?? "Charker")
            while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
            let trimmed = out.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }

        var segments: [(text: String, separator: Character?)] = []
        var current = ""
        for character in template {
            if character == "·" || character == "|" {
                segments.append((current, character))
                current = ""
            } else {
                current.append(character)
            }
        }
        segments.append((current, nil))

        let rendered = segments.compactMap { segment -> (String, Character?)? in
            renderSegment(segment.text).map { ($0, segment.separator) }
        }
        var out = ""
        for (index, item) in rendered.enumerated() {
            out += item.0
            if index < rendered.count - 1 { out += " \(item.1 ?? "·") " }
        }
        return out.isEmpty ? "Charker" : out
    }

    /// What the title should be when there is nothing live to show. Words, not
    /// punctuation: "Charker …" required the user to guess what the ellipsis
    /// meant. The status-item icon already carries the app identity.
    public static func offlineTitle(_ snapshot: SessionSnapshot) -> String {
        switch snapshot.phase {
        case .monitoring: return ""
        case .reconnecting: return L10n.text("重连中", table: "Core")
        case .idle, .scanning, .connecting, .negotiating:
            return L10n.text("搜索中", table: "Core")
        case .bluetoothUnavailable, .failed:
            return L10n.text("离线", table: "Core")
        }
    }
}
