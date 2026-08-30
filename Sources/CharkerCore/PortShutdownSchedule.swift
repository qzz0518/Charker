import A2687Protocol
import Foundation

/// Charker's local projection of one countdown the charger accepted.
///
/// The A2687 acknowledges `0x0209`, but this firmware exposes no verified timer
/// read-back. Keeping the accepted duration and its wall-clock deadline lets the
/// UI remain useful after its short success notice disappears without claiming
/// that the value was subsequently confirmed by the device.
public struct PortShutdownSchedule: Codable, Equatable, Identifiable, Sendable {
    public let peripheralID: UUID
    public let portRawValue: Int
    public let armedAt: Date
    public let durationSeconds: UInt32

    public init(
        peripheralID: UUID,
        port: A2687.Port,
        durationSeconds: UInt32,
        armedAt: Date = Date()
    ) {
        self.peripheralID = peripheralID
        portRawValue = port.rawValue
        self.armedAt = armedAt
        self.durationSeconds = durationSeconds
    }

    public var id: String { "\(peripheralID.uuidString):\(portRawValue)" }
    public var port: A2687.Port? { A2687.Port(rawValue: portRawValue) }
    public var deadline: Date {
        armedAt.addingTimeInterval(TimeInterval(durationSeconds))
    }

    public func isActive(at date: Date) -> Bool {
        isValid && deadline > date
    }

    public func remainingSeconds(at date: Date) -> Int {
        max(0, Int(ceil(deadline.timeIntervalSince(date))))
    }

    public func remainingFraction(at date: Date) -> Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, max(0, deadline.timeIntervalSince(date) / Double(durationSeconds)))
    }

    /// The current UI accepts at most 1,440 minutes. Treat anything beyond that
    /// (or an unknown port index) as damaged/foreign persisted data rather than
    /// leaving an implausible countdown on screen for weeks.
    fileprivate var isValid: Bool {
        port != nil && (1...86_400).contains(durationSeconds)
    }
}

/// Persists accepted countdowns separately from user preferences: this is a
/// record of an action this Mac performed, not a setting the user chose.
public final class PortShutdownScheduleStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        key: String = "portShutdownSchedulesV1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load(activeAt date: Date = Date()) -> [PortShutdownSchedule] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.object(forKey: key) as? Data,
              let decoded = try? JSONDecoder().decode([PortShutdownSchedule].self, from: data)
        else { return [] }
        return Self.sanitized(decoded, activeAt: date)
    }

    public func save(
        _ schedules: [PortShutdownSchedule],
        activeAt date: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        let active = Self.sanitized(schedules, activeAt: date)
        guard let data = try? JSONEncoder().encode(active) else { return }
        defaults.set(data, forKey: key)
    }

    private static func sanitized(
        _ schedules: [PortShutdownSchedule],
        activeAt date: Date
    ) -> [PortShutdownSchedule] {
        var latestByPort: [String: PortShutdownSchedule] = [:]
        for schedule in schedules where schedule.isActive(at: date) {
            if let previous = latestByPort[schedule.id], previous.armedAt >= schedule.armedAt {
                continue
            }
            latestByPort[schedule.id] = schedule
        }
        return latestByPort.values.sorted {
            if $0.deadline != $1.deadline { return $0.deadline < $1.deadline }
            return $0.id < $1.id
        }
    }
}
