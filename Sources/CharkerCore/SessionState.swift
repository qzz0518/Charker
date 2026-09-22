import A2687Protocol
import Foundation

public enum SessionPhase: Sendable, Equatable {
    case idle
    case bluetoothUnavailable(BluetoothState)
    case scanning
    case connecting
    case negotiating(HandshakeStage)
    case monitoring
    case reconnecting(attempt: Int, retryIn: TimeInterval)
    case failed(String)

    public var isLive: Bool {
        if case .monitoring = self { return true }
        return false
    }

    /// True while the app is actively trying to get to `monitoring`.
    public var isBusy: Bool {
        switch self {
        case .scanning, .connecting, .negotiating, .reconnecting: return true
        default: return false
        }
    }

    public var shortLabel: String {
        switch self {
        case .idle: return L10n.text("未启动", table: "Core")
        case .bluetoothUnavailable(let state):
            return state == .notDetermined
                ? L10n.text("等待授权", table: "Core")
                : L10n.text("蓝牙不可用", table: "Core")
        case .scanning: return L10n.text("搜索中", table: "Core")
        case .connecting: return L10n.text("连接中", table: "Core")
        case .negotiating: return L10n.text("握手中", table: "Core")
        case .monitoring: return L10n.text("已连接", table: "Core")
        case .reconnecting: return L10n.text("重连中", table: "Core")
        case .failed: return L10n.text("出错", table: "Core")
        }
    }

    public var detail: String {
        switch self {
        case .idle:
            return L10n.text("尚未开始", table: "Core")
        case .bluetoothUnavailable(let state):
            switch state {
            case .notDetermined:
                return L10n.text(
                    "等待蓝牙授权——请在弹出的对话框中点「允许」。",
                    table: "Core"
                )
            case .poweredOff:
                return L10n.text("蓝牙已关闭", table: "Core")
            case .unauthorized:
                return L10n.text(
                    "需要在「系统设置 › 隐私与安全性 › 蓝牙」中允许 Charker",
                    table: "Core"
                )
            case .unsupported:
                return L10n.text("这台 Mac 没有可用的低功耗蓝牙", table: "Core")
            case .unknown, .poweredOn:
                return L10n.text("蓝牙状态未知", table: "Core")
            }
        case .scanning:
            return L10n.text("正在搜索附近的 Anker Prime 充电器", table: "Core")
        case .connecting:
            return L10n.text("正在连接充电器", table: "Core")
        case .negotiating(let stage):
            return L10n.format("协商会话中 · %@", stage.label, table: "Core")
        case .monitoring:
            return L10n.text("正在接收实时数据", table: "Core")
        case .reconnecting(let attempt, let retryIn):
            return L10n.format("第 %d 次重试 · %.0f 秒后继续", attempt, retryIn, table: "Core")
        case .failed(let reason):
            return reason
        }
    }

    /// Progress through the handshake ladder, for the connecting UI. Nil when
    /// there is nothing meaningful to show progress for.
    public var negotiationProgress: Double? {
        switch self {
        case .connecting: return 0.05
        case .negotiating(let stage):
            let total = Double(HandshakeStage.sessionReady.rawValue)
            return 0.1 + 0.9 * (Double(stage.rawValue) / total)
        case .monitoring: return 1
        default: return nil
        }
    }
}

public extension HandshakeStage {
    var label: String {
        switch self {
        case .idle: return L10n.text("空闲", table: "Core")
        case .initialConnect: return L10n.text("初始握手", table: "Core")
        case .capability: return L10n.text("能力协商", table: "Core")
        case .baseInfo: return L10n.text("读取设备信息", table: "Core")
        case .setCapability: return L10n.text("确认能力", table: "Core")
        case .publicKeyExchange: return L10n.text("交换公钥", table: "Core")
        case .sharedSecretDerived: return L10n.text("派生会话密钥", table: "Core")
        case .aesMetadata: return L10n.text("同步会话参数", table: "Core")
        case .userAuth: return L10n.text("身份认证", table: "Core")
        case .sessionReady: return L10n.text("会话就绪", table: "Core")
        }
    }
}

/// Immutable view of the session handed to the UI. Never contains key material.
public struct SessionSnapshot: Sendable, Equatable {
    public var phase: SessionPhase = .idle
    public var bluetooth: BluetoothState = .unknown
    public var deviceInfo = DeviceInfo()
    public var advertisedName: String?
    public var peripheralID: UUID?
    public var telemetry: ChargerTelemetry?
    /// Rolling power history for the chart, oldest first.
    public var history: [PowerSample] = []
    /// Everything the radio has seen this session, newest signal first.
    public var nearbyDevices: [DiscoveredCharger] = []
    public var isScanning = false
    /// True once the last telemetry is older than the staleness budget. The last
    /// numbers stay visible but must be presented as no longer live.
    public var isStale = false
    public var writesEnabled = false
    public var lastError: String?
    /// Non-fatal note, e.g. the charger refused the optional identity step but
    /// the encrypted session still works for reads.
    public var warning: String?
    /// The charger refused `0x0027`. Kept separate from `warning` because the UI
    /// needs to explain the consequence, not just repeat the status code.
    public var authRejected = false
    /// Explains a long fruitless scan. The most common cause is not distance but
    /// another client holding the charger, which silences its advertising.
    public var scanHint: String?
    public var isDemo = false
    public init() {}

    public var lastUpdate: Date? { telemetry?.receivedAt }

    public var statusLabel: String { phase.shortLabel }
    public var statusDetail: String { phase.detail }

    /// The one device name every surface shows. The A2687 reports an internal
    /// string ("Charging"), not a product name, so known values map to the
    /// marketing name; anything unrecognised is shown verbatim rather than lied
    /// about. Nil means nothing is connected and nothing has been advertised.
    public var displayName: String? {
        if let product = deviceInfo.productName, !product.isEmpty {
            return product == "Charging" ? "Anker Prime 160W" : product
        }
        return advertisedName
    }

    /// Total is a local sum over the three ports; the A2687 exposes no trustworthy
    /// device-side total. Nil when nothing has been received yet.
    public var totalPower: Double? { telemetry?.totalPower }

    /// Whether a picker scan may take over the radio right now.
    ///
    /// Discovery is useful whenever nothing is linked — including while the
    /// session waits for a saved charger that is not in range, which is exactly
    /// when the user needs to see what *is* nearby. Starting it during a
    /// handshake or beside live telemetry would put an unfiltered
    /// duplicate-advertisement stream next to the link; the transport also
    /// refuses to scan once a peripheral is connected, which covers the short
    /// GATT setup inside `.connecting`. Keep this rule on the snapshot so the
    /// actor and every UI entry point make the same decision.
    public var canBrowseNearbyDevices: Bool {
        switch phase {
        case .idle, .scanning, .connecting, .reconnecting, .failed:
            return true
        case .bluetoothUnavailable, .negotiating, .monitoring:
            return false
        }
    }

    /// The current device first, then candidates, coarse signal band and finally
    /// identifier. RSSI ticks every advertisement, so ordering by the raw value
    /// makes rows swap under the cursor; the 4-band bucket keeps the list
    /// near-stable while the displayed dBm updates in place.
    public var sortedNearbyDevices: [DiscoveredCharger] {
        nearbyDevices.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.id == peripheralID
            let rhsIsCurrent = rhs.id == peripheralID
            if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            if lhs.isCandidate != rhs.isCandidate { return lhs.isCandidate }
            if lhs.signalBars != rhs.signalBars { return lhs.signalBars > rhs.signalBars }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public var chargerCandidates: [DiscoveredCharger] {
        nearbyDevices.filter(\.isCandidate).sorted { $0.rssi > $1.rssi }
    }
}

/// One point on the power history chart.
public struct PowerSample: Sendable, Equatable, Identifiable {
    public var id: Date { at }
    public var at: Date
    public var total: Double
    public var perPort: [Double]

    public init(at: Date, total: Double, perPort: [Double]) {
        self.at = at
        self.total = total
        self.perPort = perPort
    }

    /// Thins a long history down to something a 700 pt-wide plot can actually
    /// show, on a bucket grid fixed in absolute time.
    ///
    /// Index striding is wrong here: the history is a sliding, capacity-capped
    /// window, so striding re-elects a different point on every append and the
    /// curve shimmers under itself — the same apparent motion the chart's fixed
    /// y-domain exists to avoid. Bucketing relative to the *first* sample has
    /// the same defect one step removed, because the first sample moves. The
    /// grid is therefore anchored to the reference date and its width snapped
    /// to a round interval, so a new reading disturbs only the buckets at the
    /// two ends.
    ///
    /// Each bucket contributes its minimum and its maximum in time order:
    /// keeping only maxima would draw an upper envelope and lift the whole
    /// curve off its floor. The exact last reading is always appended so the
    /// trailing point marker stays welded to the end of the line.
    public static func decimated(_ samples: [PowerSample], budget: Int = 180) -> [PowerSample] {
        guard samples.count > budget,
              let first = samples.first,
              let last = samples.last else { return samples }
        let span = last.at.timeIntervalSince(first.at)
        guard span > 0 else { return samples }

        let bucketCount = max(2, budget / 2)
        let width = roundedInterval(atLeast: span / Double(bucketCount))
        var output: [PowerSample] = []
        output.reserveCapacity(bucketCount * 2 + 1)

        var low: PowerSample?
        var high: PowerSample?
        var bucket: Int?

        func flush() {
            guard let low, let high else { return }
            if low.at == high.at {
                output.append(low)
            } else if low.at < high.at {
                output.append(low)
                output.append(high)
            } else {
                output.append(high)
                output.append(low)
            }
        }

        for sample in samples {
            let index = Int(
                (sample.at.timeIntervalSinceReferenceDate / width).rounded(.down)
            )
            if index != bucket {
                flush()
                low = nil
                high = nil
                bucket = index
            }
            if low == nil || sample.total < low!.total { low = sample }
            if high == nil || sample.total > high!.total { high = sample }
        }
        flush()
        if output.last?.at != last.at { output.append(last) }
        return output
    }

    /// Snaps a bucket width up to a round interval so the grid stays put while
    /// the window slides and the span wobbles by a sample or two.
    private static func roundedInterval(atLeast minimum: TimeInterval) -> TimeInterval {
        guard minimum > 0 else { return 1 }
        let steps: [TimeInterval] = [
            1, 2, 5, 10, 15, 20, 30, 60, 120, 300, 600, 900, 1800, 3600,
        ]
        if let step = steps.first(where: { $0 >= minimum }) { return step }
        var step: TimeInterval = 3600
        while step < minimum { step *= 2 }
        return step
    }
}
