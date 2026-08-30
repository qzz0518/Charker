import A2687Protocol
import Foundation

/// Wraps ``MockA2687Device`` in the ``ChargerTransport`` interface.
///
/// Optionally splits every device frame across notification chunks, which is how
/// a real radio behaves and is the only way to exercise the reassembler end to end.
public final class MockChargerTransport: ChargerTransport, @unchecked Sendable {
    public let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private let chunkSize: Int
    private let reportInterval: Duration?
    private var reportTask: Task<Void, Never>?
    private var connected = false
    private var scanning = false
    private var startScanningCalls = 0

    public let device: MockA2687Device
    public let identifier = UUID()
    private let lively: Bool
    private var tick = 0

    var startScanningCallCount: Int { lock.withLock { startScanningCalls } }

    public init(
        device: MockA2687Device = MockA2687Device(),
        chunkSize: Int = 20,
        reportInterval: Duration? = .seconds(2),
        lively: Bool = false
    ) {
        self.device = device
        self.chunkSize = max(1, chunkSize)
        self.reportInterval = reportInterval
        self.lively = lively
        var sink: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { sink = $0 }
        continuation = sink
    }

    public func start() {
        continuation.yield(.bluetoothState(.poweredOn))
    }

    public func connect(preferred: UUID?) {
        lock.lock()
        guard !connected else { lock.unlock(); return }
        connected = true
        device.reset()
        lock.unlock()

        let charger = DiscoveredCharger(id: identifier, name: "\(A2687.namePrefix)-MOCK", rssi: -52)
        continuation.yield(.discovered(charger))
        continuation.yield(.connected(charger))
        continuation.yield(.ready(maxWriteLength: 244, withResponse: true))
        startReports()
    }

    public func startScanning() {
        let shouldPublish: Bool = lock.withLock {
            startScanningCalls += 1
            guard !scanning else { return false }
            scanning = true
            return true
        }
        if shouldPublish { continuation.yield(.scanning(true)) }
    }

    public func stopScanning() {
        let shouldPublish: Bool = lock.withLock {
            guard scanning else { return false }
            scanning = false
            return true
        }
        if shouldPublish { continuation.yield(.scanning(false)) }
    }

    public func disconnect() {
        stopScanning()
        lock.lock()
        let wasConnected = connected
        connected = false
        reportTask?.cancel()
        reportTask = nil
        lock.unlock()
        if wasConnected { continuation.yield(.disconnected(reason: nil)) }
    }

    public func write(_ bytes: [UInt8]) async throws {
        let frames = try process(bytes)
        for frame in frames { emit(frame) }
    }

    private func process(_ bytes: [UInt8]) throws -> [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        guard connected else { throw TransportError.notConnected }
        return device.receive(bytes)
    }

    /// Pushes bytes straight onto the notification stream, bypassing the device.
    /// Used by tests to inject malformed or forged frames.
    public func inject(_ bytes: [UInt8]) {
        emit(bytes)
    }

    private func emit(_ frame: [UInt8]) {
        var index = 0
        while index < frame.count {
            let end = min(index + chunkSize, frame.count)
            continuation.yield(.notification(Array(frame[index..<end])))
            index = end
        }
    }

    private func startReports() {
        guard let reportInterval else { return }
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: reportInterval)
                guard let self else { return }
                // Scoped `withLock` rather than the bare `lock()`/`unlock()`
                // pair used everywhere else in this file: those two are marked
                // `noasync`, and this is the only critical section that sits
                // inside a `Task`, so it is the only one that warns (an error
                // under the Swift 6 language mode). The section never suspends,
                // so a closure is a free swap — the emit deliberately stays
                // outside, as it did before.
                let (connected, report) = self.lock.withLock {
                    let connected = self.connected
                    if connected, self.lively { self.advanceScenario() }
                    return (connected, connected ? self.device.realtimeReport() : nil)
                }
                guard connected else { return }
                if let report { self.emit(report) }
            }
        }
    }

    // MARK: - Demo liveliness
    //
    // Deterministic script, no randomness: the demo has to look alive without
    // making two screenshots of the same moment disagree. C1 is a laptop whose
    // draw breathes and slowly tapers; C2 is a phone that finishes charging and
    // drops to a trickle; C3 has a device plugged in and out on a cycle, which
    // exercises the plug-in animation path end to end. Tests construct this
    // transport with `lively: false` and never enter this code.

    /// Called with `lock` held.
    ///
    /// The script only breathes values into ports that are currently on — a port
    /// the user switched off through the (mock-honoured) write path stays off,
    /// because a demo whose only writable action visibly un-does itself two
    /// seconds later would demonstrate the opposite of the truth.
    private func advanceScenario() {
        tick += 1
        let t = Double(tick) * 2  // seconds of demo time at the 2 s cadence

        var c1 = device.ports[0]
        if c1.isOn {
            c1.voltage = 20.0
            // A laptop topping up: 3.25 A easing towards 2.4 A with a slow breath.
            let taper = 2.4 + 0.85 * exp(-t / 480)
            c1.current = round((taper + 0.12 * sin(t / 9) + 0.05 * sin(t / 3.1)) * 100) / 100
            device.ports[0] = c1
        }

        var c2 = device.ports[1]
        if c2.isOn {
            // A phone that reaches full charge two minutes in, then trickles.
            if t < 120 {
                c2.voltage = 9.0
                c2.current = round((2.0 + 0.1 * sin(t / 7)) * 100) / 100
            } else {
                c2.voltage = 5.0
                c2.current = round((0.42 + 0.04 * sin(t / 11)) * 100) / 100
            }
            device.ports[1] = c2
        }

        // C3: 24 s empty → device plugs in for 60 s → unplugged 30 s → repeat.
        // Unplugged means an *empty enabled port* (on, no draw, no cable), not a
        // switched-off one; only the plug/unplug edges assign isOn, so a user
        // "off" write survives until the next scripted plug-in.
        let cycle = t.truncatingRemainder(dividingBy: 114)
        let plugged = cycle >= 24 && cycle < 84
        var c3 = device.ports[2]
        let wasPlugged = c3.voltage > 0
        if plugged, c3.isOn || !wasPlugged {
            let sincePlug = cycle - 24
            c3.isOn = true
            c3.voltage = 20.0
            c3.cableCode = 0x02
            c3.profileCode = 0x01
            // Negotiation ramp over the first samples, then a steady 45 W draw.
            c3.current = round(min(2.25, 0.4 + sincePlug * 0.45) * 100) / 100
        } else if !plugged {
            c3 = MockA2687Device.PortState(isOn: true, voltage: 0, current: 0, cableCode: 0x03)
        }
        device.ports[2] = c3
    }
}
