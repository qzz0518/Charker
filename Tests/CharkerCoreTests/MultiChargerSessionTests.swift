import A2687Protocol
import Foundation
import XCTest
@testable import CharkerCore

/// Several chargers behind one radio, each in or out of range — the shape
/// CoreBluetooth presents when every saved charger is requested at once and
/// whichever is nearby answers. Like the real transport, `disconnect()` reports
/// nothing back: the session asked for it.
private final class MultiChargerTransport: ChargerTransport, @unchecked Sendable {
    enum Call: Equatable {
        case preferred([UUID])
        case exclusive(UUID)
        case disconnect
        case startScanning
    }

    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private let devices: [UUID: MockA2687Device]
    private var inRange: Set<UUID>
    private var wanted: [UUID] = []
    private var linked: UUID?
    private var scanning = false
    private var log: [Call] = []

    init(devices: [UUID: MockA2687Device], inRange: Set<UUID>) {
        self.devices = devices
        self.inRange = inRange
        var sink: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { sink = $0 }
        continuation = sink
    }

    var calls: [Call] { lock.withLock { log } }
    var connectCalls: [Call] {
        calls.filter {
            switch $0 {
            case .preferred, .exclusive: return true
            case .disconnect, .startScanning: return false
            }
        }
    }
    var linkedID: UUID? { lock.withLock { linked } }

    func start() {
        continuation.yield(.bluetoothState(.poweredOn))
    }

    func connect(preferred: [UUID]) {
        request(preferred, call: .preferred(preferred))
    }

    func connect(to identifier: UUID) {
        request([identifier], call: .exclusive(identifier))
    }

    private func request(_ identifiers: [UUID], call: Call) {
        let target: UUID? = lock.withLock {
            log.append(call)
            guard linked == nil else { return nil }
            wanted = identifiers
            return identifiers.first(where: inRange.contains)
        }
        if let target { link(target) }
    }

    private func link(_ id: UUID) {
        let charger: DiscoveredCharger? = lock.withLock {
            guard linked == nil, wanted.contains(id), let device = devices[id] else { return nil }
            linked = id
            wanted = []
            device.reset()
            return DiscoveredCharger(id: id, name: device.serialNumber)
        }
        guard let charger else { return }
        continuation.yield(.connected(charger))
        continuation.yield(.ready(maxWriteLength: 244, withResponse: true))
    }

    /// The one outstanding request failed (`didFailToConnect`), which the real
    /// transport reports as a disconnect so the session's backoff retries.
    func failOutstandingRequest() {
        let failed: Bool = lock.withLock {
            guard linked == nil, !wanted.isEmpty else { return false }
            wanted = []
            return true
        }
        if failed { continuation.yield(.disconnected(reason: "connect failed")) }
    }

    /// The link drops while the charger stays in range: a blip, a sleep.
    func dropLink() {
        let dropped: Bool = lock.withLock {
            guard linked != nil else { return false }
            linked = nil
            return true
        }
        if dropped { continuation.yield(.disconnected(reason: "link lost")) }
    }

    /// The radio going off drops every request and the link, in the order the
    /// real transport reports it: the state first, then the lost link.
    func setBluetooth(on: Bool) {
        guard !on else {
            continuation.yield(.bluetoothState(.poweredOn))
            return
        }
        let hadLink: Bool = lock.withLock {
            defer { linked = nil; wanted = [] }
            return linked != nil || !wanted.isEmpty
        }
        continuation.yield(.bluetoothState(.poweredOff))
        if hadLink { continuation.yield(.disconnected(reason: nil)) }
    }

    /// A drop the session already stopped caring about, reported late.
    func injectStaleDisconnect() {
        continuation.yield(.disconnected(reason: "late"))
    }

    /// A charger coming into range answers an outstanding request; one leaving
    /// range drops its link the way a real radio does.
    func setInRange(_ id: UUID, _ present: Bool) {
        enum Effect { case none, link, drop }
        let effect: Effect = lock.withLock {
            if present {
                inRange.insert(id)
                return linked == nil && wanted.contains(id) ? .link : .none
            }
            inRange.remove(id)
            guard linked == id else { return .none }
            linked = nil
            return .drop
        }
        switch effect {
        case .link: link(id)
        case .drop: continuation.yield(.disconnected(reason: "out of range"))
        case .none: break
        }
    }

    func startScanning() {
        let publish: Bool = lock.withLock {
            log.append(.startScanning)
            guard !scanning else { return false }
            scanning = true
            return true
        }
        if publish { continuation.yield(.scanning(true)) }
    }

    func stopScanning() {
        let publish: Bool = lock.withLock {
            guard scanning else { return false }
            scanning = false
            return true
        }
        if publish { continuation.yield(.scanning(false)) }
    }

    func disconnect() {
        let wasScanning: Bool = lock.withLock {
            log.append(.disconnect)
            linked = nil
            wanted = []
            defer { scanning = false }
            return scanning
        }
        if wasScanning { continuation.yield(.scanning(false)) }
    }

    func write(_ bytes: [UInt8]) async throws {
        let frames: [[UInt8]] = try lock.withLock {
            guard let linked, let device = devices[linked] else { throw TransportError.notConnected }
            return device.receive(bytes)
        }
        for frame in frames { continuation.yield(.notification(frame)) }
    }
}

private struct TimedOut: Error {}

final class MultiChargerSessionTests: XCTestCase {
    private let home = UUID()
    private let office = UUID()
    private static let homeSerial = "HOME0000000000A1"
    private static let officeSerial = "OFFICE00000000B2"

    private func makeTransport(inRange: Set<UUID>) -> MultiChargerTransport {
        let homeDevice = MockA2687Device()
        homeDevice.serialNumber = Self.homeSerial
        let officeDevice = MockA2687Device()
        officeDevice.serialNumber = Self.officeSerial
        return MultiChargerTransport(
            devices: [home: homeDevice, office: officeDevice],
            inRange: inRange
        )
    }

    /// Backoff and the lost-charger head start are shortened so a drop and
    /// its retry fit in a test; their order is what is under test, not length.
    private func makeSession(
        _ transport: MultiChargerTransport,
        remembered: [UUID],
        headStart: Duration = .milliseconds(600)
    ) -> ChargerSession {
        var configuration = SessionConfiguration(
            clientID: "0123456789abcdef0123456789abcdef01234567",
            timeZoneRule: "CST-8", countryCode: "CN"
        )
        configuration.pollInterval = .milliseconds(200)
        configuration.openingBurstSpacing = .zero
        configuration.maxBackoff = 0.2
        configuration.lostChargerHeadStart = headStart
        configuration.rememberedPeripherals = remembered
        return ChargerSession(transport: transport, configuration: configuration)
    }

    /// Fails rather than skips on timeout: every state waited for here is one
    /// the feature promises to reach. The clock races the subscription, so a
    /// session that goes quiet in the wrong state still ends the wait.
    private func waitFor(
        _ session: ChargerSession,
        timeout: TimeInterval = 5,
        _ predicate: @escaping @Sendable (SessionSnapshot) -> Bool
    ) async throws -> SessionSnapshot {
        let found = await withTaskGroup(of: SessionSnapshot?.self) { group in
            group.addTask {
                for await snapshot in await session.updates() where predicate(snapshot) {
                    return snapshot
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let found else {
            XCTFail("timed out waiting for session state")
            throw TimedOut()
        }
        return found
    }

    /// Waits for the transport to have been asked something.
    private func waitForCall(
        _ transport: MultiChargerTransport,
        timeout: TimeInterval = 5,
        _ predicate: @escaping ([MultiChargerTransport.Call]) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(transport.connectCalls) {
            guard Date() < deadline else {
                XCTFail("timed out waiting for a transport call")
                throw TimedOut()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func live(on id: UUID) -> @Sendable (SessionSnapshot) -> Bool {
        { $0.phase.isLive && $0.telemetry != nil && $0.peripheralID == id }
    }

    func testWaitingForSavedChargersConnectsWhicheverIsInRange() async throws {
        let transport = makeTransport(inRange: [office])
        let session = makeSession(transport, remembered: [home, office])
        await session.start(preferred: home)
        defer { Task { await session.stop() } }

        let snapshot = try await waitFor(session, live(on: office))
        XCTAssertEqual(snapshot.deviceInfo.serialNumber, Self.officeSerial)
        XCTAssertEqual(transport.connectCalls.first, .preferred([home, office]))
    }

    /// The feature in one test: carried from home to the office, the session
    /// lands on the office charger with no action, and nothing of home's —
    /// curve, serial — carries over onto it.
    func testLeavingOneChargerFallsOverToTheOtherOnItsOwn() async throws {
        let transport = makeTransport(inRange: [home])
        let session = makeSession(transport, remembered: [home, office])
        await session.start(preferred: home)
        defer { Task { await session.stop() } }

        let atHome = try await waitFor(session) {
            $0.phase.isLive && $0.peripheralID == self.home && !$0.history.isEmpty
        }
        XCTAssertEqual(atHome.deviceInfo.serialNumber, Self.homeSerial)

        let leftHome = Date()
        transport.setInRange(home, false)
        transport.setInRange(office, true)

        // Home gets its head start first, then every saved charger is raced.
        try await waitForCall(transport) { $0.last == .exclusive(self.home) }
        let atOffice = try await waitFor(session, timeout: 8, live(on: office))
        XCTAssertEqual(transport.connectCalls.last, .preferred([home, office]))
        XCTAssertEqual(atOffice.deviceInfo.serialNumber, Self.officeSerial)
        XCTAssertTrue(
            atOffice.history.allSatisfy { $0.at > leftHome },
            "home's power curve must not continue into the office charger's"
        )
    }

    func testSwitchingByHandLetsGoOfTheLiveChargerFirst() async throws {
        let transport = makeTransport(inRange: [home, office])
        let session = makeSession(transport, remembered: [home, office])
        await session.start(preferred: home)
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) {
            $0.phase.isLive && $0.peripheralID == self.home && !$0.history.isEmpty
        }

        let switchedAt = Date()
        await session.connect(to: office)

        let snapshot = try await waitFor(session, live(on: office))
        XCTAssertEqual(snapshot.deviceInfo.serialNumber, Self.officeSerial)
        XCTAssertTrue(snapshot.history.allSatisfy { $0.at > switchedAt })
        XCTAssertEqual(transport.linkedID, office)
        let calls = transport.calls
        let disconnect = try XCTUnwrap(calls.lastIndex(of: .disconnect))
        let pick = try XCTUnwrap(calls.lastIndex(of: .exclusive(office)))
        XCTAssertLessThan(disconnect, pick, "the old link must be let go before the new request")
    }

    /// A pick waits for its charger. Another saved one in range must not win
    /// in the meantime — not on the retry after a failed request, not when the
    /// saved list changes — or switching away from it would be impossible.
    func testAPickIsNotOvertakenByAnotherSavedCharger() async throws {
        let transport = makeTransport(inRange: [home])
        let session = makeSession(transport, remembered: [home, office])
        await session.start(preferred: home)
        defer { Task { await session.stop() } }
        _ = try await waitFor(session, live(on: home))

        await session.connect(to: office)
        let waiting = await session.current
        XCTAssertEqual(waiting.peripheralID, office)
        XCTAssertNil(waiting.telemetry, "home's last reading is not the office charger's")

        let asked = transport.connectCalls.count
        transport.failOutstandingRequest()
        try await waitForCall(transport) { $0.count > asked }
        XCTAssertEqual(transport.connectCalls.last, .exclusive(office))

        await session.setRememberedPeripherals([home, office, UUID()])
        XCTAssertEqual(transport.connectCalls.last, .exclusive(office))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(transport.linkedID)

        transport.setInRange(office, true)
        _ = try await waitFor(session, live(on: office))
    }

    /// Two chargers on one desk: after a blip, the one the user chose comes
    /// back rather than whichever advertises first.
    func testALinkThatDropsComesBackOnItsOwnChargerFirst() async throws {
        let transport = makeTransport(inRange: [home, office])
        let session = makeSession(transport, remembered: [home, office], headStart: .seconds(5))
        await session.start(preferred: home)
        defer { Task { await session.stop() } }
        _ = try await waitFor(session, live(on: home))
        await session.connect(to: office)
        _ = try await waitFor(session, live(on: office))

        let asked = transport.connectCalls.count
        transport.dropLink()

        try await waitForCall(transport) { $0.count > asked }
        XCTAssertEqual(transport.connectCalls.last, .exclusive(office))
        _ = try await waitFor(session, live(on: office))
    }

    /// The display-setting read-back reconnects on purpose; it has to come back
    /// on the charger it wrote to.
    func testReconnectNowComesBackOnTheSameCharger() async throws {
        let transport = makeTransport(inRange: [home, office])
        let session = makeSession(transport, remembered: [home, office])
        await session.start(preferred: home)
        defer { Task { await session.stop() } }
        _ = try await waitFor(session, live(on: home))

        await session.reconnectNow()

        XCTAssertEqual(transport.connectCalls.last, .exclusive(home))
        let snapshot = try await waitFor(session, live(on: home))
        XCTAssertEqual(snapshot.deviceInfo.serialNumber, Self.homeSerial)
    }

    /// With nothing linked, retrying means waiting for every saved charger
    /// again — which is also how a pick that never showed up is abandoned.
    func testReconnectNowWithoutALinkWaitsForEverySavedCharger() async throws {
        let transport = makeTransport(inRange: [])
        let session = makeSession(transport, remembered: [home, office])
        await session.start(preferred: home)
        defer { Task { await session.stop() } }

        await session.connect(to: office)
        await session.reconnectNow()

        XCTAssertEqual(transport.connectCalls.last, .preferred([office, home]))
    }

    func testForgettingTheChargerInUseMovesOnToTheOthers() async throws {
        let transport = makeTransport(inRange: [home, office])
        let session = makeSession(transport, remembered: [home, office])
        await session.start(preferred: home)
        defer { Task { await session.stop() } }
        _ = try await waitFor(session, live(on: home))

        await session.forget(home)

        XCTAssertEqual(transport.connectCalls.last, .preferred([office]))
        let snapshot = try await waitFor(session, live(on: office))
        XCTAssertEqual(snapshot.deviceInfo.serialNumber, Self.officeSerial)
    }

    /// With no saved charger left, attaching the next one in range could hand
    /// the user someone else's. The session lists instead.
    func testForgettingTheLastSavedChargerOnlyLists() async throws {
        let transport = makeTransport(inRange: [home, office])
        let session = makeSession(transport, remembered: [home])
        await session.start(preferred: home)
        defer { Task { await session.stop() } }
        _ = try await waitFor(session, live(on: home))
        let connectsBefore = transport.connectCalls.count

        await session.forget(home)
        let snapshot = try await waitFor(session) { $0.isScanning }

        XCTAssertNil(snapshot.peripheralID)
        XCTAssertNil(snapshot.telemetry)
        XCTAssertEqual(snapshot.deviceInfo, DeviceInfo())
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(transport.linkedID)
        XCTAssertEqual(transport.connectCalls.count, connectsBefore)
    }

    func testForgettingAnotherChargerWithdrawsItFromTheWait() async throws {
        let transport = makeTransport(inRange: [])
        let session = makeSession(transport, remembered: [home, office])
        await session.start(preferred: home)
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.phase == .scanning }

        await session.forget(office)
        XCTAssertEqual(transport.connectCalls.last, .preferred([home]))

        transport.setInRange(office, true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(transport.linkedID, "a forgotten charger must not connect")
    }

    func testAddingAChargerLetsGoAndConnectsOnlyToThePick() async throws {
        let transport = makeTransport(inRange: [home, office])
        let session = makeSession(transport, remembered: [home])
        await session.start(preferred: home)
        defer { Task { await session.stop() } }
        _ = try await waitFor(session, live(on: home))
        let connectsBefore = transport.connectCalls.count

        await session.browseForNewCharger()
        _ = try await waitFor(session) { $0.isScanning }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(transport.linkedID)
        XCTAssertEqual(transport.connectCalls.count, connectsBefore)

        await session.connect(to: office)
        let snapshot = try await waitFor(session, live(on: office))
        XCTAssertEqual(snapshot.deviceInfo.serialNumber, Self.officeSerial)
    }

    func testANewSavedListReplacesAWaitInProgress() async throws {
        let third = UUID()
        let transport = makeTransport(inRange: [])
        let session = makeSession(transport, remembered: [home, office])
        await session.start(preferred: home)
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.phase == .scanning }

        await session.setRememberedPeripherals([home, office, third])
        XCTAssertEqual(transport.connectCalls.last, .preferred([home, office, third]))
    }

    /// While waiting for a saved charger that is not here, the nearby list is
    /// what shows the user the one that is.
    func testTheNearbyListCanBeBrowsedWhileWaitingForSavedChargers() async throws {
        let transport = makeTransport(inRange: [])
        let session = makeSession(transport, remembered: [home, office])
        await session.start(preferred: home)
        defer { Task { await session.stop() } }
        await session.reconnectNow()

        await session.browse()

        let snapshot = try await waitFor(session) { $0.isScanning }
        XCTAssertEqual(snapshot.phase, .connecting)
    }

    /// Turning Bluetooth off cancels the retry and the head start that were
    /// pending. Coming back, the session must ask again — or the office charger
    /// is never requested.
    func testBluetoothComingBackResumesTheWaitForSavedChargers() async throws {
        let transport = makeTransport(inRange: [home])
        let session = makeSession(transport, remembered: [home, office])
        await session.start(preferred: home)
        defer { Task { await session.stop() } }
        _ = try await waitFor(session, live(on: home))

        transport.setInRange(home, false)
        transport.setBluetooth(on: false)
        _ = try await waitFor(session) { $0.phase == .bluetoothUnavailable(.poweredOff) }
        transport.setInRange(office, true)
        transport.setBluetooth(on: true)

        _ = try await waitFor(session, live(on: office))
    }

    func testForgettingWhileBluetoothIsOffSaysSoAndScansWhenItReturns() async throws {
        let transport = makeTransport(inRange: [home])
        let session = makeSession(transport, remembered: [home])
        await session.start(preferred: home)
        defer { Task { await session.stop() } }
        _ = try await waitFor(session, live(on: home))

        transport.setBluetooth(on: false)
        _ = try await waitFor(session) {
            if case .reconnecting = $0.phase { return true }
            return false
        }
        await session.forget(home)
        let off = await session.current
        XCTAssertEqual(off.phase, .bluetoothUnavailable(.poweredOff))

        let connectsBefore = transport.connectCalls.count
        transport.setBluetooth(on: true)
        _ = try await waitFor(session) { $0.phase == .scanning }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(transport.connectCalls.count, connectsBefore, "nothing is saved; only list")
    }

    /// Leaving the add-charger sheet gives back the charger it let go of,
    /// rather than whichever saved charger answers first.
    func testCancellingAnAddGivesTheReleasedChargerItsTurnFirst() async throws {
        let transport = makeTransport(inRange: [home, office])
        let session = makeSession(transport, remembered: [office, home], headStart: .seconds(5))
        await session.start(preferred: home)
        defer { Task { await session.stop() } }
        _ = try await waitFor(session, live(on: home))

        await session.browseForNewCharger()
        await session.cancelBrowseForNewCharger()

        XCTAssertEqual(transport.connectCalls.last, .exclusive(home))
        _ = try await waitFor(session, live(on: home))
    }

    func testALateDropDuringAnAddDoesNotReconnect() async throws {
        let transport = makeTransport(inRange: [home, office])
        let session = makeSession(transport, remembered: [home])
        await session.start(preferred: home)
        defer { Task { await session.stop() } }
        _ = try await waitFor(session, live(on: home))
        await session.browseForNewCharger()
        let connectsBefore = transport.connectCalls.count

        transport.injectStaleDisconnect()
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(transport.connectCalls.count, connectsBefore)
        XCTAssertNil(transport.linkedID)
        let snapshot = await session.current
        XCTAssertEqual(snapshot.phase, .scanning)
    }
}
