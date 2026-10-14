import A2345Protocol
import A2687Protocol
import Foundation

/// One outlet as the `charker-matter` helper exposes it to Apple Home: an
/// On/Off switch plus electrical measurement, in the integer units of the
/// helper's line protocol.
public struct MatterPortState: Sendable, Equatable {
    public var on: Bool
    public var voltageMV: Int
    public var currentMA: Int
    public var powerMW: Int

    public init(on: Bool, voltageMV: Int = 0, currentMA: Int = 0, powerMW: Int = 0) {
        self.on = on
        self.voltageMV = max(0, voltageMV)
        self.currentMA = max(0, currentMA)
        self.powerMW = max(0, powerMW)
    }

    /// What the helper reports for a port it has not been told about yet.
    public static let off = MatterPortState(on: false)

    /// V, A or W to the helper's milli-units. Non-finite and negative readings
    /// become 0; the ceiling only keeps a corrupt frame from trapping `Int(_:)`.
    static func milli(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return Int(min(value * 1000, Double(Int32.max)).rounded())
    }
}

/// An accessory Charker publishes for one charger family: its name, the
/// helper's port labels and which charger control each port index drives.
/// Each family is published twice, once per ``Kind``, each paired on its own.
public struct MatterAccessoryLayout: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// One accessory with the ports as its endpoints; Home shows the
        /// charger's total power.
        case grouped
        /// A bridge with every port as an accessory of its own, so each gets
        /// its own tile with watts.
        case bridged
    }

    public enum Target: Sendable, Equatable, Hashable {
        case a2687(A2687.Port)
        /// A1 and A2 share one switch on the A2345, so USB-A is one outlet.
        case a2345(A2345PortGroup)

        public var label: String {
            switch self {
            case .a2687(let port): return port.label
            case .a2345(.usbA): return "USB-A"
            case .a2345(let group): return group.label
            }
        }
    }

    public let product: ChargerProduct
    public let kind: Kind
    public let targets: [Target]

    public init(product: ChargerProduct, kind: Kind = .grouped) {
        self.product = product
        self.kind = kind
        switch product {
        case .a2687: targets = A2687.Port.allCases.map(Target.a2687)
        case .a2345: targets = A2345PortGroup.allCases.map(Target.a2345)
        }
    }

    /// BasicInformation ProductName and the mDNS instance name. The helper
    /// takes at most 32 bytes.
    public var name: String {
        switch (product, kind) {
        case (.a2687, .grouped): return "Charker 160W"
        case (.a2345, .grouped): return "Charker 250W"
        case (.a2687, .bridged): return L10n.text("Charker 160W 端口", table: "Core")
        case (.a2345, .bridged): return L10n.text("Charker 250W 端口", table: "Core")
        }
    }

    /// Each family and kind keeps its own pairing, so switching products
    /// never hands one charger's Home accessory to the other.
    public var storageName: String {
        let family: String
        switch product {
        case .a2687: family = "a2687"
        case .a2345: family = "a2345"
        }
        return kind == .grouped ? family : family + "-ports"
    }

    /// Fixed per kind, so the two accessories never swap ports across
    /// restarts and leave a controller dialing the wrong one. The helper
    /// falls back to a free port only if this one is taken.
    public var udpPort: UInt16 {
        kind == .grouped ? 5540 : 5541
    }

    /// A bridged port's label is its tile name in Home, so it says which
    /// charger it is on. The helper takes at most 32 bytes.
    public var labels: [String] {
        switch kind {
        case .grouped: return targets.map(\.label)
        case .bridged: return targets.map { "\(Int(product.ratedWatts))W \($0.label)" }
        }
    }

    public func target(at index: Int) -> Target? {
        targets.indices.contains(index) ? targets[index] : nil
    }

    /// Every endpoint's state, in index order. `previous` is the last list
    /// sent; it supplies `on` for a port nothing currently describes, so a
    /// dropped connection does not flip switches in Home.
    public func portStates(
        a2687 snapshot: SessionSnapshot,
        a2345 a2345Snapshot: A2345ConnectionSnapshot,
        previous: [MatterPortState] = []
    ) -> [MatterPortState] {
        targets.enumerated().map { index, target in
            let earlier = previous.indices.contains(index) ? previous[index].on : false
            switch target {
            case .a2687(let port):
                return MatterPortState.a2687(port, in: snapshot, previousOn: earlier)
            case .a2345(let group):
                return MatterPortState.a2345(group, in: a2345Snapshot, previousOn: earlier)
            }
        }
    }
}

public extension MatterPortState {
    /// Readings only count while they are live; a stale or dropped link zeroes
    /// V/I/P and leaves `on` alone.
    static func a2687(
        _ port: A2687.Port,
        in snapshot: SessionSnapshot,
        previousOn: Bool = false
    ) -> MatterPortState {
        let telemetry = snapshot.telemetry?.port(port)
        // `isOn` is the status byte being non-zero, which on this firmware may
        // mean "something is plugged in" rather than "the output is switched
        // on". It is what the dashboard shows, so Home shows the same.
        let on = telemetry?.isOn ?? previousOn
        let isLive = snapshot.phase.isLive && !snapshot.isStale
        guard isLive, let telemetry, telemetry.isOn else { return MatterPortState(on: on) }
        return MatterPortState(
            on: on,
            voltageMV: milli(telemetry.voltage),
            currentMA: milli(telemetry.current),
            powerMW: milli(telemetry.power)
        )
    }

    /// The switch comes from the charger's own port control. Before the first
    /// full settings snapshot, live output proves a port on; no output does
    /// not prove it off.
    static func a2345(
        _ group: A2345PortGroup,
        in snapshot: A2345ConnectionSnapshot,
        previousOn: Bool = false
    ) -> MatterPortState {
        let isLive = snapshot.hasFreshTelemetry
        let ports = group.ports
            .compactMap { ChargerPortID(rawValue: $0.rawValue) }
            .compactMap { snapshot.reading?.port($0) }
            .filter(\.isOn)
        let on: Bool
        if let settings = snapshot.settings {
            on = settings.portControls[group]?.isOn ?? previousOn
        } else if isLive {
            on = previousOn || !ports.isEmpty
        } else {
            on = previousOn
        }
        guard isLive, !ports.isEmpty else { return MatterPortState(on: on) }
        // USB-A: one switch over two sockets, so the outlet reads as their sum
        // at the higher of the two voltages.
        return MatterPortState(
            on: on,
            voltageMV: ports.map { milli($0.voltage) }.max() ?? 0,
            currentMA: ports.reduce(0) { $0 + milli($1.current) },
            powerMW: ports.reduce(0) { $0 + milli($1.power) }
        )
    }
}

// MARK: - Helper line protocol

/// Lines Charker writes to the helper's stdin, without the trailing newline.
public enum MatterHelperLine {
    public static func port(index: Int, _ state: MatterPortState) -> String {
        // Built by hand: integers and a Bool need no escaping, and a fixed key
        // order keeps the log readable and the tests exact.
        "{\"type\":\"port\",\"index\":\(max(0, index)),\"on\":\(state.on),"
            + "\"voltage_mv\":\(state.voltageMV),\"current_ma\":\(state.currentMA),"
            + "\"power_mw\":\(state.powerMW)}"
    }

    public static let shutdown = "{\"type\":\"shutdown\"}"
}

/// What the helper has been told per port and what it still has to hear.
///
/// A Home request stays open until the host answers it. Meanwhile readings
/// keep flowing but the port keeps the requested `on`, so Home's switch does
/// not flip back to the old value before the real answer arrives.
public struct MatterPortSync: Sendable {
    /// The latest state of every port, as the host sees it.
    public private(set) var desired: [MatterPortState] = []
    /// Per port, what the running helper was last told; empty while none runs.
    private var sent: [MatterPortState?] = []
    /// Requested `on` per port index, until answered.
    private var requested: [Int: Bool] = [:]

    public init() {}

    /// A freshly launched helper with `count` ports hears every one of them.
    public mutating func connect(ports count: Int) -> [String] {
        requested = [:]
        sent = Array(repeating: nil, count: count)
        return sent.indices.map { write($0) }
    }

    /// No helper is listening any more. `desired` stays for the next one.
    public mutating func disconnect() {
        requested = [:]
        sent = []
    }

    /// Lines for the ports that changed since they were last written.
    @discardableResult
    public mutating func update(_ states: [MatterPortState]) -> [String] {
        desired = states
        return sent.indices.filter { sent[$0] != state(at: $0) }.map { write($0) }
    }

    /// Home switched a port; the helper already shows `on`. False for a port
    /// the helper does not have.
    public mutating func request(index: Int, on: Bool) -> Bool {
        guard sent.indices.contains(index) else { return false }
        sent[index]?.on = on
        requested[index] = on
        return true
    }

    /// The answer to a request: the port's real state, written even when
    /// nothing changed, because only this turns a refused switch back.
    public mutating func answer(index: Int) -> String? {
        guard sent.indices.contains(index) else { return nil }
        requested[index] = nil
        return write(index)
    }

    private func state(at index: Int) -> MatterPortState {
        var state = desired.indices.contains(index) ? desired[index] : .off
        if let on = requested[index] { state.on = on }
        return state
    }

    private mutating func write(_ index: Int) -> String {
        let state = state(at: index)
        sent[index] = state
        return MatterHelperLine.port(index: index, state)
    }
}

/// One line the helper printed on stdout.
public enum MatterHelperEvent: Sendable, Equatable {
    case onboarding(qr: String, manualCode: String)
    case fabrics(count: Int)
    case command(index: Int, on: Bool)
    /// The mDNS advertisement failed (`false`, once per failure streak) or
    /// came back after one (`true`). The helper keeps running and retrying.
    case mdns(ok: Bool)
    /// Fatal; the helper exits non-zero next.
    case error(code: String, message: String)

    private struct Raw: Decodable {
        var type: String
        var qr: String?
        var manualCode: String?
        var count: Int?
        var index: Int?
        var on: Bool?
        var ok: Bool?
        var code: String?
        var message: String?

        enum CodingKeys: String, CodingKey {
            case type, qr, count, index, on, ok, code, message
            case manualCode = "manual_code"
        }
    }

    /// Nil for a malformed line, a known type missing its fields, or a type
    /// this build does not know — a newer helper must not break an older app.
    public init?(line: String) {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(line.utf8)) else { return nil }
        switch raw.type {
        case "onboarding":
            guard let qr = raw.qr, let code = raw.manualCode else { return nil }
            self = .onboarding(qr: qr, manualCode: code)
        case "fabrics":
            guard let count = raw.count, count >= 0 else { return nil }
            self = .fabrics(count: count)
        case "command":
            guard let index = raw.index, index >= 0, let on = raw.on else { return nil }
            self = .command(index: index, on: on)
        case "mdns":
            guard let ok = raw.ok else { return nil }
            self = .mdns(ok: ok)
        case "error":
            self = .error(code: raw.code ?? "internal", message: raw.message ?? "")
        default:
            return nil
        }
    }

    /// `34970112332` → `3497-011-2332`, the grouping Home and printed Matter
    /// labels use. Anything that is not 11 digits is returned untouched.
    public static func formattedManualCode(_ code: String) -> String {
        let digits = Array(code)
        guard digits.count == 11, digits.allSatisfy(\.isASCIIDigit) else { return code }
        return String(digits[0..<4]) + "-" + String(digits[4..<7]) + "-" + String(digits[7..<11])
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
