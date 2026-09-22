import A2687Protocol
import Foundation

public enum BluetoothState: Sendable, Equatable {
    case unknown
    /// The permission dialog is on screen or has not been answered yet. Distinct
    /// from `unauthorized`: nothing is wrong, the app is simply waiting.
    case notDetermined
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn

    public var isUsable: Bool { self == .poweredOn }
}

/// Why a peripheral is believed to be an Anker Prime charger.
///
/// Discovery deliberately does not rely on any single signal: `FF09` is shared
/// across the Solix/Prime family and, depending on firmware, may appear as an
/// advertised service UUID, inside service data, or in the overflow list — or
/// not at all, leaving only the name.
public enum MatchReason: String, Sendable, Equatable, CaseIterable {
    case advertisedService
    case serviceData
    case overflowService
    case productType
    case namePrefix
    case systemConnected
    case remembered
}

public struct DiscoveredCharger: Sendable, Equatable, Identifiable {
    /// CoreBluetooth's per-Mac identifier. The BLE MAC is deliberately not used
    /// as a key: it is neither stable nor exposed on macOS.
    public var id: UUID
    public var name: String?
    public var rssi: Int
    public var serviceUUIDs: [String]
    public var serviceDataKeys: [String]
    public var hasManufacturerData: Bool
    public var isConnectable: Bool
    public var matchReasons: [MatchReason]
    public var lastSeen: Date

    public init(
        id: UUID, name: String? = nil, rssi: Int = 0,
        serviceUUIDs: [String] = [], serviceDataKeys: [String] = [],
        hasManufacturerData: Bool = false, isConnectable: Bool = true,
        matchReasons: [MatchReason] = [], lastSeen: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.serviceUUIDs = serviceUUIDs
        self.serviceDataKeys = serviceDataKeys
        self.hasManufacturerData = hasManufacturerData
        self.isConnectable = isConnectable
        self.matchReasons = matchReasons
        self.lastSeen = lastSeen
    }

    /// True when at least one signal points at an Anker Prime charger.
    public var isCandidate: Bool { !matchReasons.isEmpty }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return L10n.format(
            "未命名设备 %@", String(id.uuidString.prefix(4)),
            table: "Core"
        )
    }

    /// CoreBluetooth uses non-negative RSSI values such as `0` and `127` when a
    /// peripheral was retrieved from the system rather than measured in a scan.
    /// They are sentinels, not exceptionally strong signals.
    public var hasMeasuredRSSI: Bool { rssi < 0 }

    /// Rough distance band from RSSI, only ever used as a sorting hint.
    public var signalBars: Int {
        guard hasMeasuredRSSI else { return 0 }
        switch rssi {
        case (-55)...: return 4
        case (-67)..<(-55): return 3
        case (-80)..<(-67): return 2
        default: return 1
        }
    }
}

public enum TransportEvent: Sendable {
    case bluetoothState(BluetoothState)
    case scanning(Bool)
    case discovered(DiscoveredCharger)
    case connected(DiscoveredCharger)
    /// GATT is discovered and notifications are live.
    case ready(maxWriteLength: Int, withResponse: Bool)
    case notification([UInt8])
    case disconnected(reason: String?)
}

public enum TransportError: Error, Equatable, Sendable {
    case notConnected
    case writeFailed(String)
    case valueTooLong(Int, max: Int)
}

/// Everything the session needs from a link, so the real radio and the simulator
/// are interchangeable in tests, in demo mode and in the app.
public protocol ChargerTransport: AnyObject, Sendable {
    var events: AsyncStream<TransportEvent> { get }
    /// Begins radio setup. Events start flowing once the central powers on.
    func start()
    /// Reconnects to whichever of `preferred` shows up first — the saved chargers,
    /// most recently used first — or scans when none of them can be retrieved.
    /// An empty list attaches the first charger found.
    func connect(preferred: [UUID])
    /// Connects to this one peripheral and nothing else: a pick from the
    /// discovery list, a switch between saved chargers, a same-charger reconnect.
    func connect(to identifier: UUID)
    /// Scans without connecting, so the UI can show everything nearby.
    func startScanning()
    func stopScanning()
    func disconnect()
    func write(_ bytes: [UInt8]) async throws
}

public extension ChargerTransport {
    func startScanning() {}
    func stopScanning() {}
    func connect(to identifier: UUID) { connect(preferred: [identifier]) }
}
