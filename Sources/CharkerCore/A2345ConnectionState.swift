import Foundation

public enum A2345ConnectionPhase: Sendable, Equatable {
    case idle
    case signingIn
    case loadingDevices
    case connecting
    case waitingForTelemetry
    case monitoring
    case reconnecting(attempt: Int)
    case failed(String)

    public var isLive: Bool {
        switch self {
        case .waitingForTelemetry, .monitoring: return true
        default: return false
        }
    }

    public var isBusy: Bool {
        switch self {
        case .signingIn, .loadingDevices, .connecting, .reconnecting: return true
        default: return false
        }
    }

    public var shortLabel: String {
        switch self {
        case .idle: return L10n.text("未连接", table: "Core")
        case .signingIn: return L10n.text("登录中", table: "Core")
        case .loadingDevices: return L10n.text("查找设备", table: "Core")
        case .connecting: return L10n.text("连接云端", table: "Core")
        case .waitingForTelemetry: return L10n.text("等待数据", table: "Core")
        case .monitoring: return L10n.text("已连接", table: "Core")
        case .reconnecting: return L10n.text("重连中", table: "Core")
        case .failed: return L10n.text("出错", table: "Core")
        }
    }

    public var detail: String {
        switch self {
        case .idle:
            return L10n.text("使用 Anker 账号连接 A2345", table: "Core")
        case .signingIn:
            return L10n.text("正在验证 Anker 账号", table: "Core")
        case .loadingDevices:
            return L10n.text("正在读取账号下绑定的充电器", table: "Core")
        case .connecting:
            return L10n.text("正在建立加密 MQTT 订阅", table: "Core")
        case .waitingForTelemetry:
            return L10n.text("订阅已建立，正在等待充电器上报", table: "Core")
        case .monitoring:
            return L10n.text("正在接收 Wi-Fi 实时数据", table: "Core")
        case .reconnecting(let attempt):
            return L10n.format("云端连接中断，正在第 %d 次重试", attempt, table: "Core")
        case .failed(let reason):
            return reason
        }
    }
}

/// Retry budget for one A2345 cloud generation.
///
/// A valid realtime frame proves the subscription recovered, so a later
/// disconnect starts a new consecutive-failure streak instead of consuming a
/// process-lifetime attempt counter. Merely connecting or subscribing does not
/// reset the budget because a telemetry-starved socket is not healthy yet.
public struct A2345ReconnectBudget: Sendable, Equatable {
    public let maximumConsecutiveFailures: Int
    public private(set) var consecutiveFailures = 0

    public init(maximumConsecutiveFailures: Int = 5) {
        self.maximumConsecutiveFailures = max(1, maximumConsecutiveFailures)
    }

    public mutating func recordValidTelemetry() {
        consecutiveFailures = 0
    }

    /// Records one failed subscription and returns whether another attempt is
    /// still allowed.
    @discardableResult
    public mutating func recordFailure() -> Bool {
        consecutiveFailures += 1
        return consecutiveFailures < maximumConsecutiveFailures
    }

    /// Exponential retry delay capped at 16 seconds. The shift is capped too,
    /// so custom budgets cannot overflow `Int` before reaching that ceiling.
    public var retryDelaySeconds: Int {
        1 << min(max(0, consecutiveFailures - 1), 4)
    }
}

/// Public, non-secret metadata returned by the account's bound-device list.
public struct A2345DeviceSummary: Sendable, Equatable, Identifiable {
    public var id: String { serialNumber }
    public var serialNumber: String
    public var name: String
    public var firmwareVersion: String?
    public var isWiFiOnline: Bool?

    public init(
        serialNumber: String,
        name: String = "Anker Prime 250W",
        firmwareVersion: String? = nil,
        isWiFiOnline: Bool? = nil
    ) {
        self.serialNumber = serialNumber
        self.name = name
        self.firmwareVersion = firmwareVersion
        self.isWiFiOnline = isWiFiOnline
    }
}

/// Immutable A2345 state handed to SwiftUI. It intentionally contains no
/// account token, MQTT topic, client certificate or private key.
public struct A2345ConnectionSnapshot: Sendable, Equatable {
    public var phase: A2345ConnectionPhase = .idle
    public var device: A2345DeviceSummary?
    public var reading: ChargerReading?
    public var history: [PowerSample] = []
    public var isStale = false
    public var isDemo = false
    public var warning: String?

    public init() {}

    public var lastUpdate: Date? { reading?.receivedAt }
    public var totalPower: Double? { reading?.totalPower }
    public var displayName: String { device?.name ?? ChargerProduct.a2345.displayName }

    /// A subscribed socket is not yet healthy telemetry. Keep this stricter
    /// predicate at the state boundary so every surface agrees that only a
    /// current reading in the monitoring phase may light the model or mark an
    /// energy session active.
    public var hasFreshTelemetry: Bool {
        phase == .monitoring && reading != nil && !isStale
    }
}
