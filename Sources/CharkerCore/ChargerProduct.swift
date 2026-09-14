import Foundation

/// Hardware families supported by Charker.
///
/// This is deliberately a product-level description, not a transport enum:
/// A2687 is currently reached over BLE while A2345 is reached through Anker's
/// cloud MQTT service, but UI and history code should care about the charger in
/// front of the user rather than the wire carrying its readings.
public enum ChargerProduct: String, Codable, CaseIterable, Sendable, Equatable {
    case a2687 = "A2687"
    case a2345 = "A2345"

    public var displayName: String {
        switch self {
        case .a2687: return "Anker Prime 160W"
        case .a2345: return "Anker Prime 250W"
        }
    }

    public var ratedWatts: Double {
        switch self {
        case .a2687: return 160
        case .a2345: return 250
        }
    }

    public var ports: [ChargerPortID] {
        switch self {
        case .a2687: return [.c1, .c2, .c3]
        case .a2345: return ChargerPortID.allCases
        }
    }

    public var connectionLabel: String {
        switch self {
        case .a2687: return L10n.text("蓝牙直连", table: "Core")
        case .a2345: return L10n.text("Wi-Fi 云端只读", table: "Core")
        }
    }
}

/// Stable, transport-independent port identity.
///
/// Raw values are the persisted order used by nicknames, history and charts.
/// Never reorder existing cases: old three-port data occupies slots 0...2 and
/// A2345 extends that layout with C4/A1/A2 in slots 3...5.
public enum ChargerPortID: Int, Codable, CaseIterable, Sendable, Equatable, Hashable, Identifiable {
    case c1 = 0
    case c2 = 1
    case c3 = 2
    case c4 = 3
    case a1 = 4
    case a2 = 5

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .c1: return "C1"
        case .c2: return "C2"
        case .c3: return "C3"
        case .c4: return "C4"
        case .a1: return "A1"
        case .a2: return "A2"
        }
    }

    public var connectorLabel: String {
        switch self {
        case .c1, .c2, .c3, .c4: return "USB-C"
        case .a1, .a2: return "USB-A"
        }
    }

    public func maximumWatts(for product: ChargerProduct) -> Double {
        switch (product, self) {
        case (.a2687, .c1), (.a2687, .c2), (.a2687, .c3): return 160
        case (.a2345, .c1): return 140
        case (.a2345, .c2), (.a2345, .c3), (.a2345, .c4): return 100
        case (.a2345, .a1), (.a2345, .a2): return 22.5
        default: return 0
        }
    }
}

/// A read-only port value shared by transport-specific presentation code.
public struct ChargerPortReading: Sendable, Equatable, Identifiable {
    public var id: ChargerPortID { port }
    public var port: ChargerPortID
    public var statusCode: UInt8
    public var voltage: Double
    public var current: Double
    public var power: Double
    public var usbVendorID: UInt16?
    public var usbProductID: UInt16?

    public init(
        port: ChargerPortID,
        statusCode: UInt8,
        voltage: Double,
        current: Double,
        power: Double,
        usbVendorID: UInt16? = nil,
        usbProductID: UInt16? = nil
    ) {
        self.port = port
        self.statusCode = statusCode
        self.voltage = voltage.isFinite ? max(0, voltage) : 0
        self.current = current.isFinite ? max(0, current) : 0
        self.power = power.isFinite ? max(0, power) : 0
        self.usbVendorID = usbVendorID
        self.usbProductID = usbProductID
    }

    public var isOn: Bool { statusCode != 0 }
    public var isDelivering: Bool { isOn && current > 0.02 && voltage > 3 }
    public var hasReadings: Bool { isOn && (voltage > 0 || current > 0 || power > 0) }
}

/// One coherent reading from a charger, independent of BLE or MQTT framing.
public struct ChargerReading: Sendable, Equatable {
    public var product: ChargerProduct
    public var ports: [ChargerPortReading]
    public var receivedAt: Date

    public init(product: ChargerProduct, ports: [ChargerPortReading], receivedAt: Date = Date()) {
        self.product = product
        let supported = Set(product.ports)
        self.ports = ports.filter { supported.contains($0.port) }
        self.receivedAt = receivedAt
    }

    public func port(_ id: ChargerPortID) -> ChargerPortReading? {
        ports.first { $0.port == id }
    }

    public var totalPower: Double {
        ports.reduce(0) { $0 + ($1.isOn ? $1.power : 0) }
    }

    public var activePortCount: Int { ports.filter(\.isDelivering).count }

    public var orderedPortPower: [Double] {
        product.ports.map { port($0).map { $0.isOn ? $0.power : 0 } ?? 0 }
    }
}
