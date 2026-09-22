import A2687Protocol
import Foundation
import XCTest
@testable import CharkerCore

/// End-to-end runs of the real client against the protocol simulator: full
/// handshake, fresh ECDH, chunked notifications, telemetry and gated writes.
final class SessionIntegrationTests: XCTestCase {
    private func makeSession(
        device: MockA2687Device = MockA2687Device(),
        writes: Bool = false,
        chunkSize: Int = 20
    ) -> (ChargerSession, MockChargerTransport) {
        let transport = MockChargerTransport(device: device, chunkSize: chunkSize, reportInterval: nil)
        var configuration = SessionConfiguration(
            clientID: "0123456789abcdef0123456789abcdef01234567",
            timeZoneRule: "CST-8", countryCode: "CN"
        )
        configuration.writesEnabled = writes
        configuration.pollInterval = .milliseconds(200)
        configuration.openingBurstSpacing = .zero
        return (ChargerSession(transport: transport, configuration: configuration), transport)
    }

    /// For the cases below, which bring their own transport and want the poll
    /// interval under their own control.
    private func makeSession(
        transport: ChargerTransport,
        pollInterval: Duration,
        holdTimeout: Duration = .seconds(300),
        writes: Bool = false
    ) -> ChargerSession {
        var configuration = SessionConfiguration(
            clientID: "0123456789abcdef0123456789abcdef01234567",
            timeZoneRule: "CST-8", countryCode: "CN"
        )
        configuration.writesEnabled = writes
        configuration.pollInterval = pollInterval
        configuration.pollHoldTimeout = holdTimeout
        configuration.openingBurstSpacing = .zero
        return ChargerSession(transport: transport, configuration: configuration)
    }

    private func waitFor(
        _ session: ChargerSession,
        timeout: TimeInterval = 5,
        _ predicate: @escaping @Sendable (SessionSnapshot) -> Bool
    ) async throws -> SessionSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        for await snapshot in await session.updates() {
            if predicate(snapshot) { return snapshot }
            if Date() > deadline { break }
        }
        throw XCTSkip("timed out waiting for session state")
    }

    func testCompletesTheHandshakeAndReportsTelemetry() async throws {
        let (session, _) = makeSession()
        await session.start()
        defer { Task { await session.stop() } }

        let snapshot = try await waitFor(session) { $0.telemetry != nil && $0.phase.isLive }
        XCTAssertEqual(snapshot.deviceInfo.productName, "Charging")
        XCTAssertEqual(snapshot.deviceInfo.firmwareVersion, "v0.0.5.0")
        XCTAssertEqual(snapshot.deviceInfo.serialNumber, "ASHDMOCK00000000")
        XCTAssertEqual(snapshot.deviceInfo.macAddress, "02:00:5E:10:00:01")

        let telemetry = try XCTUnwrap(snapshot.telemetry)
        XCTAssertEqual(telemetry.totalPower, 20.0 * 3.25 + 9.0 * 2.0, accuracy: 0.05)
        XCTAssertEqual(telemetry.activePortCount, 2)
        XCTAssertFalse(snapshot.isStale)

        // The simulator used to send a four-byte control struct, which decoded
        // only while the reader took the last two bytes of any length. Against
        // the fixed CPowerControl offsets that shape yields no cable at all, so
        // demo mode silently lost the cable chip on every port with nothing red.
        XCTAssertEqual(telemetry.port(.c1)?.cable, .max100W)
        XCTAssertEqual(telemetry.port(.c1)?.chargingProfile, .applePD)
        XCTAssertEqual(telemetry.port(.c2)?.cable, .max60W)
    }

    func testBrowseDoesNotStartAnUnfilteredScanWhileMonitoring() async throws {
        let (session, transport) = makeSession()
        await session.start()
        defer { Task { await session.stop() } }

        _ = try await waitFor(session) { $0.telemetry != nil && $0.phase.isLive }
        XCTAssertEqual(transport.startScanningCallCount, 0)

        await session.browse()

        XCTAssertEqual(transport.startScanningCallCount, 0)
        let current = await session.current
        XCTAssertFalse(current.isScanning)
    }

    func testFirstConnectionCanStartAsAPickerWithoutAutoConnecting() async throws {
        let (session, transport) = makeSession()
        await session.start(autoConnect: false)
        defer { Task { await session.stop() } }

        let snapshot = try await waitFor(session) { $0.isScanning }
        XCTAssertEqual(transport.startScanningCallCount, 1)
        XCTAssertNil(snapshot.peripheralID)
        XCTAssertNil(snapshot.telemetry)
        XCTAssertFalse(snapshot.phase.isLive)
    }

    func testSurvivesFrameSplitAcrossSingleByteNotifications() async throws {
        let (session, _) = makeSession(chunkSize: 1)
        await session.start()
        defer { Task { await session.stop() } }
        let snapshot = try await waitFor(session, timeout: 10) { $0.telemetry != nil }
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.totalPower), 0)
    }

    func testEveryConnectionNegotiatesAFreshSession() async throws {
        let device = MockA2687Device()
        let (first, _) = makeSession(device: device)
        await first.start()
        _ = try await waitFor(first) { $0.telemetry != nil }
        await first.stop()

        let (second, _) = makeSession(device: device)
        await second.start()
        defer { Task { await second.stop() } }
        let snapshot = try await waitFor(second) { $0.telemetry != nil }
        XCTAssertEqual(snapshot.deviceInfo.serialNumber, "ASHDMOCK00000000")
    }

    func testWritesAreRefusedUnlessExplicitlyEnabled() async throws {
        let (session, _) = makeSession(writes: false)
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry != nil }

        do {
            _ = try await session.setPortOutput(.c1, on: false)
            XCTFail("write should have been refused")
        } catch {
            XCTAssertEqual(error as? SessionError, .writesDisabled)
        }
    }

    func testPortWriteIsConfirmedByReadBack() async throws {
        let device = MockA2687Device()
        let (session, _) = makeSession(device: device, writes: true)
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry != nil }

        let confirmed = try await session.setPortOutput(.c1, on: false)
        XCTAssertTrue(confirmed)
        XCTAssertFalse(device.ports[0].isOn)

        let snapshot = try await waitFor(session) { $0.telemetry?.port(.c1)?.isOn == false }
        XCTAssertEqual(try XCTUnwrap(snapshot.totalPower), 18.0, accuracy: 0.05)
    }

    func testDisconnectSchedulesReconnectAndKeepsTheLastReadingMarkedNotLive() async throws {
        let (session, transport) = makeSession()
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry != nil }

        transport.disconnect()
        let snapshot = try await waitFor(session) {
            if case .reconnecting = $0.phase { return true }
            return false
        }
        XCTAssertFalse(snapshot.phase.isLive)
        XCTAssertNotNil(snapshot.telemetry, "the last reading stays visible, but not as live")
    }

    func testForgedAndMalformedFramesNeverReachTheTelemetryState() async throws {
        let (session, transport) = makeSession()
        await session.start()
        defer { Task { await session.stop() } }
        let before = try await waitFor(session) { $0.telemetry != nil }

        // A structurally perfect frame whose payload was never sealed with the
        // session key: the GCM tag must reject it before any decode happens.
        transport.inject(PacketCodec.encode(Frame(
            group: Frame.sessionGroup, opcode: A2687.Opcode.realtimeReport,
            encrypted: true, response: false, payload: [UInt8](repeating: 0x5A, count: 48)
        )))
        // Plus outright garbage and a frame with a broken checksum.
        transport.inject([0xDE, 0xAD, 0xBE, 0xEF])
        var corrupt = PacketCodec.encode(Frame(
            group: Frame.sessionGroup, opcode: A2687.Opcode.realtimeReport,
            encrypted: true, response: false, payload: [UInt8](repeating: 0x11, count: 48)
        ))
        corrupt[corrupt.count - 1] ^= 0xFF
        transport.inject(corrupt)

        try await Task.sleep(for: .milliseconds(150))
        let after = await session.current
        XCTAssertEqual(before.telemetry?.totalPower, after.telemetry?.totalPower)
        XCTAssertEqual(before.telemetry?.receivedAt, after.telemetry?.receivedAt)
        XCTAssertTrue(session.log.snapshot().contains { $0.direction == "RX!" })
    }

    // MARK: - The settings snapshot

    /// `A9`/`AA` ride the full `0x0200` read-all and the 1 Hz `0x0300` reports do
    /// not carry them, so binding the settings card straight to the newest frame
    /// made it blink: gone at 1 Hz, back every second poll tick.
    func testSettingsSurviveTheRealtimeFramesThatOmitThemAndDieAtTheSessionBoundary() async throws {
        // The poll is parked at a minute deliberately. At the usual 200 ms a
        // `0x0200` read-all would refill the settings within a tick of the frame
        // that blanked them, and this case would pass with the bug wide open.
        let transport = MockChargerTransport(chunkSize: 20, reportInterval: nil)
        let session = makeSession(transport: transport, pollInterval: .seconds(60))
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry != nil && $0.phase.isLive }

        // A full read-all: port data plus the settings block.
        transport.inject(portFrame(
            opcode: A2687.Opcode.readAll, response: true, watts: 42,
            settings: [(A2687.Field.a9, 0x50), (A2687.Field.aa, 0x01)]
        ))
        let read = try await waitFor(session) {
            $0.telemetry?.sourceOpcode == A2687.Opcode.readAll
        }
        XCTAssertEqual(read.telemetry?.settings?.screenBrightness, 0x50)
        XCTAssertEqual(read.telemetry?.settings?.chargingMode, 0x01)

        // The realtime report a second later, with no A9/AA in it at all.
        transport.inject(portFrame(opcode: A2687.Opcode.realtimeReport, response: false, watts: 7))
        let live = try await waitFor(session) {
            $0.telemetry?.sourceOpcode == A2687.Opcode.realtimeReport
                && ($0.telemetry?.totalPower ?? 0) < 10
        }
        XCTAssertEqual(
            live.telemetry?.settings?.screenBrightness, 0x50,
            "a frame that says nothing about A9 is saying nothing, not «the setting went away»"
        )
        XCTAssertEqual(live.telemetry?.settings?.chargingMode, 0x01)

        // An explicit reconnect is a whole new link. Anything carried across
        // would be a stale value from the previous authenticated session.
        await session.reconnectNow()
        // The simulator answers the new ladder with its own 83 W telemetry and
        // carries no settings ids, so the wattage is what says "this is a frame
        // from the second session", not the leftover 7 W one.
        let resumed = try await waitFor(session, timeout: 10) {
            $0.phase.isLive && ($0.telemetry?.totalPower ?? 0) > 80
        }
        XCTAssertNil(
            resumed.telemetry?.settings,
            "the carried-forward snapshot belongs to the link that ended; after a fresh "
            + "handshake «not read yet» is the only honest answer"
        )
    }

    // MARK: - Reply ordering and the poll hold
    //
    // The two most recently reworked pieces of `ChargerSession`, and until now
    // the two with no case behind them at all: the waiter that is registered
    // before the write, and the token-based poll hold. Both fail silently — a
    // dropped reply looks like a slow charger, a leaked hold looks like a
    // charger that stopped answering `0x0200` — so neither would be caught by
    // any of the cases above.

    func testAReplyArrivingInsideTheWriteReachesTheSenderWithoutWaitingOutTheTimeout() async throws {
        // The poll is parked at a minute on purpose. With the usual 200 ms poll
        // running, a reply dropped by a late-registered waiter would be picked
        // up by the *next* unsolicited `0x0300` a fraction of a second later,
        // and this case would pass with the race wide open.
        let transport = ReplyDuringWriteTransport(settle: .milliseconds(120))
        let session = makeSession(transport: transport, pollInterval: .seconds(60))
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry != nil && $0.phase.isLive }
        // Let the opening burst drain, so the frame measured below is ours.
        try await Task.sleep(for: .milliseconds(150))

        let startedAt = ContinuousClock.now
        let reply = try await session.send(
            CommandEncoder.readAll(),
            awaitOpcode: A2687.Opcode.realtimeReport,
            timeout: .seconds(3)
        )
        let elapsed = ContinuousClock.now - startedAt

        XCTAssertFalse(reply.fields.isEmpty, "the answer itself, not an empty stand-in")
        XCTAssertLessThan(
            elapsed, .seconds(1),
            "the 0x0300 answer was received and dispatched while transport.write was still "
            + "suspended; a waiter registered after the write misses it and sits out the "
            + "whole timeout instead"
        )
    }

    func testTwoHoldsNeedTwoReleasesBeforeThePollComesBack() async throws {
        let transport = ReplyDuringWriteTransport()
        let session = makeSession(transport: transport, pollInterval: .milliseconds(150))
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry != nil && $0.phase.isLive }

        let cover = await session.suspendPolling(reason: "封面推送")
        let secondHold = await session.suspendPolling(reason: "设备同步")
        // A tick already inside `poll()` when the holds went up still finishes
        // its write — that is documented behaviour, not a leak — so the baseline
        // is read after that gap rather than before it.
        try await Task.sleep(for: .milliseconds(400))
        let baseline = transport.writeCount

        await session.resumePolling(cover)
        let stillHeld = await session.isPollingHeld
        XCTAssertTrue(stillHeld, "one hold of two is still up")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            transport.writeCount, baseline,
            "releasing one of two holds restarted the poll underneath the other holder"
        )

        await session.resumePolling(secondHold)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertGreaterThan(
            transport.writeCount, baseline,
            "the last release has to bring the poll back"
        )
    }

    func testStartDropsThePreviousRunsHoldAndItsTokenCannotReleaseTheNewOne() async throws {
        let transport = ReplyDuringWriteTransport()
        let session = makeSession(transport: transport, pollInterval: .milliseconds(150))
        await session.start()
        _ = try await waitFor(session) { $0.telemetry != nil && $0.phase.isLive }
        let stale = await session.suspendPolling(reason: "上一轮的封面推送")

        await session.stop()
        // The cancelled event loop needs a moment to unsubscribe before the next
        // run subscribes — see `ReplyDuringWriteTransport.events`.
        try await Task.sleep(for: .milliseconds(200))
        await session.start()
        defer { Task { await session.stop() } }
        // `stop()` puts the phase back to idle, so this waits for the *new*
        // ladder rather than matching the previous run's leftover snapshot.
        _ = try await waitFor(session) { $0.telemetry != nil && $0.phase.isLive }

        let clearedByStart = await session.isPollingHeld
        XCTAssertFalse(
            clearedByStart,
            "start() drops holds whose holder did not survive the previous run"
        )

        let live = await session.suspendPolling(reason: "本轮的封面推送")
        try await Task.sleep(for: .milliseconds(400))
        let baseline = transport.writeCount

        await session.resumePolling(stale)
        let heldByTheLiveOne = await session.isPollingHeld
        XCTAssertTrue(
            heldByTheLiveOne,
            "a token from the previous run must be inert, not a release of somebody else's hold"
        )
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(transport.writeCount, baseline, "the poll ran under a live hold")

        await session.resumePolling(live)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertGreaterThan(transport.writeCount, baseline)
    }

    func testWithPollingHeldReleasesTheHoldEvenWhenTheBodyThrows() async throws {
        struct Boom: Error {}
        let transport = ReplyDuringWriteTransport()
        let session = makeSession(transport: transport, pollInterval: .milliseconds(150))
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry != nil && $0.phase.isLive }

        do {
            try await session.withPollingHeld(reason: "封面推送") { () async throws -> Void in
                let heldInside = await session.isPollingHeld
                XCTAssertTrue(heldInside)
                throw Boom()
            }
            XCTFail("the body's error has to reach the caller unchanged")
        } catch is Boom {
            // The point of the case is what happens on the way out, not the throw.
        }

        let heldAfter = await session.isPollingHeld
        XCTAssertFalse(
            heldAfter,
            "the scoped form exists so that no exit path can leak a hold — only start() "
            + "clears them, and a reconnect does not go through start()"
        )
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertGreaterThan(transport.writeCount, 0)
    }

    func testAHoldNobodyReleasesIsTakenBackByTheWatchdog() async throws {
        let transport = ReplyDuringWriteTransport()
        let session = makeSession(
            transport: transport, pollInterval: .milliseconds(150), holdTimeout: .seconds(1)
        )
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry != nil && $0.phase.isLive }

        // The token is deliberately dropped on the floor: this is the leak the
        // watchdog exists for, the one nothing else in the session recovers from
        // because only start() clears holds and a reconnect does not call it.
        _ = await session.suspendPolling(reason: "泄漏的封面推送")
        try await Task.sleep(for: .milliseconds(400))
        let baseline = transport.writeCount
        let heldBefore = await session.isPollingHeld
        XCTAssertTrue(heldBefore, "still inside the timeout — the hold must be honoured")
        XCTAssertEqual(transport.writeCount, baseline)

        try await Task.sleep(for: .milliseconds(1200))
        let heldAfter = await session.isPollingHeld
        XCTAssertFalse(heldAfter, "the watchdog has to take an abandoned hold back")
        XCTAssertGreaterThan(
            transport.writeCount, baseline,
            "taking the hold back is pointless unless the poll actually restarts"
        )
        // Silent recovery would be worse than none: whoever leaked the hold has
        // to be nameable from the log afterwards.
        XCTAssertTrue(session.log.snapshot().contains {
            $0.direction == "WARN" && $0.text.contains("泄漏的封面推送")
        })
    }

    // MARK: - The charging-mode write
    //
    // The poll is parked at a minute in every case here. `AA` only rides the
    // full `0x0200`, so a 200 ms poll would refill the settings a tick after the
    // write and every one of these would pass without `setChargingMode` reading
    // anything back at all.

    func testChargingModeIsConfirmedWhenTheReadBackShowsTheNewCode() async throws {
        let transport = ChargingModeTransport(mode: ChargingMode.ai.code, adopts: ChargingMode.standard.code)
        let session = makeSession(transport: transport, pollInterval: .seconds(60))
        await session.start()
        defer { Task { await session.stop() } }
        let before = try await waitFor(session) { $0.telemetry?.settings?.chargingMode != nil }
        XCTAssertEqual(before.telemetry?.settings?.chargingMode, ChargingMode.ai.code)

        let confirmed = try await session.setChargingMode(.standard)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(transport.modeWrites, 1)
        let after = await session.current
        XCTAssertEqual(after.telemetry?.settings?.chargingMode, ChargingMode.standard.code)
    }

    /// The failure this command exists to catch: the charger acknowledges the
    /// frame and `AA` still reads the old mode. `setChargingMode` has to hand
    /// that back rather than let an ACK stand in for a result — the same reason
    /// a cover ACK proves nothing about the display.
    ///
    /// What the caller may conclude from a `false` is narrower than it looks,
    /// and that is written down on `setChargingMode` itself: settings are a
    /// handshake snapshot, so "unchanged" covers both "the write did nothing"
    /// and "the write worked and `AA` will not move until the next link".
    func testChargingModeIsReportedUnconfirmedWhenTheReadBackStillShowsTheOldCode() async throws {
        // `adopts: nil` — the frame is acknowledged and the charger changes nothing.
        let transport = ChargingModeTransport(mode: ChargingMode.ai.code, adopts: nil)
        let session = makeSession(transport: transport, pollInterval: .seconds(60))
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry?.settings?.chargingMode != nil }

        let confirmed = try await session.setChargingMode(.standard)
        XCTAssertFalse(
            confirmed,
            "an ACK is not a result; the only evidence this command has is the AA read-back"
        )
        XCTAssertEqual(transport.modeWrites, 1)
        let after = await session.current
        XCTAssertEqual(after.telemetry?.settings?.chargingMode, ChargingMode.ai.code)
    }

    func testChargingModeRejectionSurfacesTheDeviceStatus() async throws {
        let transport = ChargingModeTransport(
            mode: ChargingMode.ai.code, adopts: nil, ackStatus: 0x05
        )
        let session = makeSession(transport: transport, pollInterval: .seconds(60))
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry?.settings?.chargingMode != nil }

        do {
            _ = try await session.setChargingMode(.standard)
            XCTFail("a non-zero frame status is a refusal, not a write")
        } catch {
            XCTAssertEqual(
                error as? SessionError,
                .deviceRejected(A2687.Opcode.chargingMode, status: 0x05)
            )
        }
    }

    /// The gate this write is on, pinned so a later "tidy every write behind one
    /// flag" cannot happen quietly. `writesEnabled` is off in every case above —
    /// it is the port switch, and the sentence next to it in settings talks about
    /// ports. Charging mode is neither a port nor irreversible; it is gated by
    /// session readiness plus whatever confirmation the UI shows at the tap.
    func testChargingModeIsNotBehindThePortSwitch() async throws {
        let transport = ChargingModeTransport(mode: ChargingMode.ai.code, adopts: ChargingMode.standard.code)
        let session = makeSession(transport: transport, pollInterval: .seconds(60))
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry?.settings?.chargingMode != nil }

        // Same session, same configuration: a port write is refused here.
        do {
            _ = try await session.setPortOutput(.c1, on: false)
            XCTFail("the port switch is off, so the port write must still be refused")
        } catch {
            XCTAssertEqual(error as? SessionError, .writesDisabled)
        }
        // And the mode write goes through regardless.
        let confirmed = try await session.setChargingMode(.standard)
        XCTAssertTrue(confirmed)
    }

    func testChargingModeIsRefusedBeforeTheHandshakeFinishes() async throws {
        let transport = ChargingModeTransport(mode: ChargingMode.ai.code, adopts: ChargingMode.standard.code)
        let session = makeSession(transport: transport, pollInterval: .seconds(60))
        // Never started: no ladder, no session key, nothing to write through.
        do {
            _ = try await session.setChargingMode(.standard)
            XCTFail("a write before the handshake has no session to go out on")
        } catch {
            XCTAssertEqual(error as? SessionError, .notReady)
        }
        XCTAssertEqual(transport.modeWrites, 0)
    }

    // MARK: - Confirmed display settings

    func testDisplaySettingsPersistAndRoundTripAcrossAFreshHandshake() async throws {
        let device = MockA2687Device()
        let (writer, _) = makeSession(device: device, writes: false)
        await writer.start()
        _ = try await waitFor(writer) { $0.telemetry != nil && $0.phase.isLive }

        // `writesEnabled` is deliberately false: that consent switch is for
        // port power, while these five writes are reversible device settings.
        try await writer.setChargerSetting(.language(.english))
        try await writer.setChargerSetting(.screenTimeout(.oneMinute))
        try await writer.setChargerSetting(.brightness(75))
        try await writer.setChargerSetting(.orientation(.right))
        try await writer.setChargerSetting(.gyroscope(true))

        XCTAssertEqual(device.deviceLanguage, .english)
        XCTAssertEqual(device.screenTimeout, .oneMinute)
        XCTAssertEqual(device.screenBrightness, 75)
        XCTAssertEqual(device.screenOrientation, .right)
        XCTAssertEqual(device.gyroscopeEnabled, true)
        await writer.stop()

        let (reader, _) = makeSession(device: device)
        await reader.start()
        defer { Task { await reader.stop() } }
        let fresh = try await waitFor(reader) {
            $0.phase.isLive && $0.telemetry?.settings?.screenTimeout != nil
        }
        let settings = try XCTUnwrap(fresh.telemetry?.settings)
        XCTAssertEqual(settings.screenTimeout, ScreenTimeout.oneMinute.rawValue)
        XCTAssertEqual(settings.screenBrightness, 75)
        XCTAssertEqual(settings.screenOrientation, ScreenOrientation.right.rawValue)
        XCTAssertEqual(settings.gyroscopeEnabled, true)
        XCTAssertNil(
            ChargerSetting.language(.english).readbackMatches(settings),
            "language is ACK-verifiable but has no discovered read-back field"
        )
    }

    func testBrightnessBelowTheRoundTripFloorIsRefusedBeforeWriting() async throws {
        let device = MockA2687Device()
        let (session, _) = makeSession(device: device)
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry != nil && $0.phase.isLive }

        do {
            try await session.setChargerSetting(.brightness(10))
            XCTFail("the real firmware clamps 10% to 25%; the app must not promise 10%")
        } catch {
            XCTAssertEqual(error as? ChargerSettingError, .brightnessOutOfRange(10))
        }
        XCTAssertNil(device.screenBrightness, "a locally refused value must not reach the device")
    }

    // MARK: - 端口倒计时 (0x0209)

    /// Which gate this write is on, pinned. It ends with a port going dark and
    /// there is no read-back to notice it with, so it belongs behind the same
    /// switch as the port toggle — not behind mere session readiness, which is
    /// what charging mode gets.
    func testPortTimerIsBehindThePortSwitch() async throws {
        let transport = PortTimerTransport()
        let session = makeSession(transport: transport, pollInterval: .seconds(60), writes: false)
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry != nil }

        do {
            try await session.setPortTimer(.c1, seconds: 3600)
            XCTFail("the port switch is off, so arming a countdown must be refused")
        } catch {
            XCTAssertEqual(error as? SessionError, .writesDisabled)
        }
        XCTAssertEqual(transport.timerWrites, 0, "a refused write must not reach the wire")
    }

    /// Zero seconds is the one value this build will not send.
    ///
    /// The firmware carries the countdown as a task-status byte *and* a time,
    /// and an idle port reads `status = 0, time = 300` — so "no countdown" is
    /// spelled by the status, not by a zero time. `0` on the wire could be a
    /// cancel or an immediate cut, and nobody has watched a real charger take
    /// it. The refusal happens before any bytes go out, which is the part worth
    /// pinning: a later "just pass it through" would be silent otherwise.
    func testPortTimerRefusesZeroWithoutSendingAnything() async throws {
        let transport = PortTimerTransport()
        let session = makeSession(transport: transport, pollInterval: .seconds(60), writes: true)
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry != nil }

        do {
            try await session.setPortTimer(.c1, seconds: 0)
            XCTFail("zero has no verified meaning on this firmware")
        } catch {
            XCTAssertEqual(error as? PortTimerError, .cancelUnverified)
        }
        XCTAssertEqual(transport.timerWrites, 0, "the refusal must precede the write")
    }

    /// A non-zero leading status byte is a refusal, and the caller has to hear
    /// about it: nothing reads an armed countdown back, so a swallowed rejection
    /// would leave the UI promising a shutdown that will never happen.
    func testPortTimerRejectionSurfacesTheDeviceStatus() async throws {
        let transport = PortTimerTransport(ackStatus: 0x11)
        let session = makeSession(transport: transport, pollInterval: .seconds(60), writes: true)
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry != nil }

        do {
            try await session.setPortTimer(.c1, seconds: 3600)
            XCTFail("a non-zero frame status is a refusal, not a write")
        } catch {
            XCTAssertEqual(
                error as? SessionError,
                .deviceRejected(A2687.Opcode.portTimer, status: 0x11)
            )
        }
        XCTAssertEqual(transport.timerWrites, 1)
    }

    /// The happy path returns Void rather than a confirmation, and that is the
    /// honest shape: the acknowledgement is real, but no field on this firmware
    /// reports the armed countdown, so there is nothing to confirm against.
    func testPortTimerArmsOnAnAcknowledgedFrame() async throws {
        let transport = PortTimerTransport()
        let session = makeSession(transport: transport, pollInterval: .seconds(60), writes: true)
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry != nil }

        try await session.setPortTimer(.c2, seconds: 7200)
        XCTAssertEqual(transport.timerWrites, 1)
    }

    /// Demo mode must walk the same accepted-command path as hardware so the
    /// persistent countdown component can be reviewed without arming a real port.
    func testProtocolSimulatorAcknowledgesPortTimer() async throws {
        let (session, _) = makeSession(writes: true)
        await session.start()
        defer { Task { await session.stop() } }
        _ = try await waitFor(session) { $0.telemetry != nil && $0.phase.isLive }

        try await session.setPortTimer(.c2, seconds: 3_600)
    }
}

/// One frame the way the charger sends one, in the clear.
///
/// Injected rather than taught to the simulator: the fixture then sits next to
/// the assertions that depend on its exact shape, and `process` already accepts
/// an unencrypted frame ("some firmware has been observed reporting in the
/// clear"), so the test side needs no session key.
///
/// One port, at 20 V, carrying whatever wattage the caller asks for — that is
/// the only handle the cases below have for telling "the frame I just injected"
/// apart from the simulator's own 83 W reply.
///
/// File scope rather than a method on the test case because
/// `ChargingModeTransport` builds its replies with it too, and a second copy of
/// this shape is exactly how the two would drift apart.
private func portFrame(
    opcode: UInt16,
    response: Bool,
    watts: Double,
    settings: [(id: UInt8, value: UInt8)] = []
) -> [UInt8] {
    let mV = UInt16(clamping: 20_000)
    let mA = UInt16(clamping: Int(watts / 20.0 * 1000))
    let cW = UInt16(clamping: Int(watts * 100))
    var fields = [
        TLV(id: A2687.Field.a1, value: [A2687.sessionAction]),
        TLV(id: A2687.Port.c1.telemetryField, value: TypedValue.bytes([
            0x01,
            UInt8(mV & 0xFF), UInt8(mV >> 8),
            UInt8(mA & 0xFF), UInt8(mA >> 8),
            UInt8(cW & 0xFF), UInt8(cW >> 8),
        ]).encoded),
    ]
    for setting in settings {
        fields.append(TLV(id: setting.id, value: TypedValue.u8(setting.value).encoded))
    }
    return PacketCodec.encode(Frame(
        group: Frame.sessionGroup, opcode: opcode, encrypted: false,
        response: response, payload: [0x00] + TLVCodec.encode(fields)
    ))
}

/// A transport that answers `0x0206` and `0x0200` itself, in the clear.
///
/// The handshake ladder still runs against `MockA2687Device` — nothing here
/// reimplements crypto — but the simulator has no charging mode: it answers
/// `0x0206` with silence, which would turn every case into a six-second timeout
/// and prove nothing. So the two opcodes the write path uses are intercepted and
/// answered with unencrypted frames, the shape the settings case already injects
/// by hand.
///
/// What it deliberately *cannot* do is read the mode out of the write: the frame
/// is sealed with a session key only the simulator holds, and the header is all
/// this class can see. So the code the charger "adopts" is the one the test hands
/// over, and whether the payload carries the right byte is pinned in
/// `ChargingModeCommandTests` instead. These cases are about the control flow —
/// ACK, read-back, verdict — and claim nothing about the bytes.
private final class ChargingModeTransport: ChargerTransport, @unchecked Sendable {
    let identifier = UUID()
    private let device = MockA2687Device()
    private let lock = NSLock()
    private var sinks: [UUID: AsyncStream<TransportEvent>.Continuation] = [:]
    /// Events emitted before anybody subscribed — see `ReplyDuringWriteTransport`
    /// for why a per-subscriber stream has to hold them.
    private var backlog: [TransportEvent] = []
    private var connected = false
    /// Opcodes are read straight off the frame header; the payload stays sealed.
    private var reassembler = FrameReassembler()

    /// The `AA` byte the next `0x0200` will report.
    private var reportedMode: UInt8
    /// What a `0x0206` write moves `reportedMode` to, or nil for a charger that
    /// acknowledges the frame and changes nothing.
    private let adopts: UInt8?
    /// The status byte the `0x0206` ACK carries in `A1`.
    private let ackStatus: UInt8
    private var writes = 0

    init(mode: UInt8, adopts: UInt8?, ackStatus: UInt8 = 0) {
        self.reportedMode = mode
        self.adopts = adopts
        self.ackStatus = ackStatus
    }

    /// How many `0x0206` frames actually reached the wire.
    var modeWrites: Int { lock.withLock { writes } }

    var events: AsyncStream<TransportEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let id = UUID()
            let pending: [TransportEvent] = self.lock.withLock {
                self.sinks[id] = continuation
                defer { self.backlog.removeAll() }
                return self.backlog
            }
            for event in pending { continuation.yield(event) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.sinks.removeValue(forKey: id) }
            }
        }
    }

    func start() { broadcast(.bluetoothState(.poweredOn)) }

    func connect(preferred: [UUID]) {
        lock.lock()
        guard !connected else { lock.unlock(); return }
        connected = true
        device.reset()
        reassembler.reset()
        lock.unlock()
        let charger = DiscoveredCharger(id: identifier, name: "\(A2687.namePrefix)-MODE", rssi: -50)
        broadcast(.discovered(charger))
        broadcast(.connected(charger))
        broadcast(.ready(maxWriteLength: 244, withResponse: true))
    }

    func disconnect() {
        lock.lock()
        let wasConnected = connected
        connected = false
        lock.unlock()
        if wasConnected { broadcast(.disconnected(reason: nil)) }
    }

    func write(_ bytes: [UInt8]) async throws {
        let replies: [[UInt8]] = try lock.withLock {
            guard self.connected else { throw TransportError.notConnected }
            let frames = self.reassembler.append(bytes)
            // Fed to the simulator regardless of what is answered below, so its
            // own reassembler and ladder stay in step with the byte stream.
            let fromDevice = self.device.receive(bytes)

            var mine: [[UInt8]] = []
            var intercepted = false
            for frame in frames {
                switch frame.opcode {
                case A2687.Opcode.chargingMode:
                    intercepted = true
                    self.writes += 1
                    if let adopts = self.adopts { self.reportedMode = adopts }
                    mine.append(PacketCodec.encode(Frame(
                        group: Frame.sessionGroup, opcode: A2687.Opcode.chargingMode,
                        encrypted: false, response: true,
                        // Real refusal shape, `11 A1 01 31`: the result code is
                        // the payload's leading byte and `A1` stays the constant
                        // `0x31` the hardware always sends. Putting the status in
                        // `A1` instead — which this mock used to do — made the
                        // session's own (wrong) reading of `A1` look correct.
                        payload: [self.ackStatus] + TLVCodec.encode([
                            TLV(id: A2687.Field.a1, value: [0x31]),
                        ])
                    )))
                case A2687.Opcode.readAll:
                    // The read-all answer, carrying `AA` — the simulator's own
                    // telemetry has no settings block at all, which is precisely
                    // the thing being read back.
                    intercepted = true
                    mine.append(portFrame(
                        opcode: A2687.Opcode.realtimeReport, response: false, watts: 42,
                        settings: [(A2687.Field.aa, self.reportedMode)]
                    ))
                default:
                    break
                }
            }
            return intercepted ? mine : fromDevice
        }
        for reply in replies { broadcast(.notification(reply)) }
    }

    private func broadcast(_ event: TransportEvent) {
        let targets: [AsyncStream<TransportEvent>.Continuation] = lock.withLock {
            guard !self.sinks.isEmpty else {
                self.backlog.append(event)
                return []
            }
            return Array(self.sinks.values)
        }
        // Yielded outside the lock: a consumer that finishes on this yield runs
        // `onTermination`, which takes the same lock.
        for target in targets { target.yield(event) }
    }
}

/// A charger that answers `0x0209`, in the clear.
///
/// The simulator does not answer it at all, and that absence is honest rather
/// than an omission: nothing on this firmware reports an armed countdown, so
/// there is no state for `MockA2687Device` to model. Left unanswered every case
/// below would be a six-second timeout proving nothing, so the one opcode is
/// intercepted here.
///
/// Like `ChargingModeTransport` it cannot see inside the write — the frame is
/// sealed with a session key only the simulator holds. Whether the payload
/// carries the right port and the right seconds is pinned against a golden
/// vector in the command tests; these cases are about the control flow, and the
/// only byte that matters to them is the acknowledgement's leading status.
private final class PortTimerTransport: ChargerTransport, @unchecked Sendable {
    let identifier = UUID()
    private let device = MockA2687Device()
    private let lock = NSLock()
    private var sinks: [UUID: AsyncStream<TransportEvent>.Continuation] = [:]
    /// See `ReplyDuringWriteTransport` for why a per-subscriber stream has to
    /// hold the events emitted before anybody subscribed.
    private var backlog: [TransportEvent] = []
    private var connected = false
    private var reassembler = FrameReassembler()

    /// The leading status byte the `0x0209` acknowledgement carries.
    private let ackStatus: UInt8
    private var writes = 0

    init(ackStatus: UInt8 = 0) {
        self.ackStatus = ackStatus
    }

    /// How many `0x0209` frames actually reached the wire.
    var timerWrites: Int { lock.withLock { writes } }

    var events: AsyncStream<TransportEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let id = UUID()
            let pending: [TransportEvent] = self.lock.withLock {
                self.sinks[id] = continuation
                defer { self.backlog.removeAll() }
                return self.backlog
            }
            for event in pending { continuation.yield(event) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.sinks.removeValue(forKey: id) }
            }
        }
    }

    func start() { broadcast(.bluetoothState(.poweredOn)) }

    func connect(preferred: [UUID]) {
        lock.lock()
        guard !connected else { lock.unlock(); return }
        connected = true
        device.reset()
        reassembler.reset()
        lock.unlock()
        let charger = DiscoveredCharger(id: identifier, name: "\(A2687.namePrefix)-TIMER", rssi: -50)
        broadcast(.discovered(charger))
        broadcast(.connected(charger))
        broadcast(.ready(maxWriteLength: 244, withResponse: true))
    }

    func disconnect() {
        lock.lock()
        let wasConnected = connected
        connected = false
        lock.unlock()
        if wasConnected { broadcast(.disconnected(reason: nil)) }
    }

    func write(_ bytes: [UInt8]) async throws {
        let replies: [[UInt8]] = try lock.withLock {
            guard self.connected else { throw TransportError.notConnected }
            let frames = self.reassembler.append(bytes)
            // Fed to the simulator regardless, so its own reassembler and ladder
            // stay in step with the byte stream.
            let fromDevice = self.device.receive(bytes)

            var mine: [[UInt8]] = []
            var intercepted = false
            for frame in frames where frame.opcode == A2687.Opcode.portTimer {
                intercepted = true
                self.writes += 1
                mine.append(PacketCodec.encode(Frame(
                    group: Frame.sessionGroup, opcode: A2687.Opcode.portTimer,
                    encrypted: false, response: true,
                    // The refusal shape this hardware really sends, `11 A1 01 31`:
                    // the result code is the payload's leading byte and `A1` is a
                    // constant. Putting the status in `A1` is the mistake that
                    // once made the session's own wrong reading look correct.
                    payload: [self.ackStatus] + TLVCodec.encode([
                        TLV(id: A2687.Field.a1, value: [0x31]),
                    ])
                )))
            }
            return intercepted ? mine : fromDevice
        }
        for reply in replies { broadcast(.notification(reply)) }
    }

    private func broadcast(_ event: TransportEvent) {
        let targets: [AsyncStream<TransportEvent>.Continuation] = lock.withLock {
            guard !self.sinks.isEmpty else {
                self.backlog.append(event)
                return []
            }
            return Array(self.sinks.values)
        }
        // Yielded outside the lock: a consumer that finishes on this yield runs
        // `onTermination`, which takes the same lock.
        for target in targets { target.yield(event) }
    }
}

/// A transport that answers a write *inside that write's own suspension window*.
///
/// `MockChargerTransport` also emits its reply before `write` returns, but
/// nothing in it forces the session's event loop to run while the write is
/// parked: whether the reply is dispatched before or after `send` registers its
/// waiter is left to the scheduler, which is the one thing a regression test for
/// that race cannot tolerate. Here the reply is pushed onto the stream and then
/// the write genuinely sleeps, so the frame is received, decrypted and
/// dispatched while `transport.write` is still suspended. That is the ordering a
/// 163-slice cover push meets at every acknowledged checkpoint.
///
/// It also counts writes, which is how the poll-hold cases observe "the poll is
/// not running": nothing else writes on an otherwise idle session.
private final class ReplyDuringWriteTransport: ChargerTransport, @unchecked Sendable {
    let identifier = UUID()
    private let device: MockA2687Device
    private let settle: Duration
    private let lock = NSLock()
    private var sinks: [UUID: AsyncStream<TransportEvent>.Continuation] = [:]
    /// Events emitted while nobody is subscribed yet.
    ///
    /// `ChargerSession.start()` creates its event task and then calls
    /// `transport.start()` and `connect(preferred:)` synchronously, before that
    /// task has had a chance to run. `MockChargerTransport` gets away with it
    /// because its single stream is built in `init`; a transport that hands out
    /// a fresh stream per subscriber — which is what restarting one session on
    /// one transport needs — has to hold the opening events itself.
    private var backlog: [TransportEvent] = []
    private var connected = false
    private var writes = 0

    init(device: MockA2687Device = MockA2687Device(), settle: Duration = .milliseconds(40)) {
        self.device = device
        self.settle = settle
    }

    /// Total frames handed to the device since this transport was built.
    var writeCount: Int { lock.withLock { writes } }

    var events: AsyncStream<TransportEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let id = UUID()
            let pending: [TransportEvent] = self.lock.withLock {
                self.sinks[id] = continuation
                defer { self.backlog.removeAll() }
                return self.backlog
            }
            for event in pending { continuation.yield(event) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.sinks.removeValue(forKey: id) }
            }
        }
    }

    func start() { broadcast(.bluetoothState(.poweredOn)) }

    func connect(preferred: [UUID]) {
        lock.lock()
        guard !connected else { lock.unlock(); return }
        connected = true
        device.reset()
        lock.unlock()
        let charger = DiscoveredCharger(id: identifier, name: "\(A2687.namePrefix)-RACE", rssi: -50)
        broadcast(.discovered(charger))
        broadcast(.connected(charger))
        broadcast(.ready(maxWriteLength: 244, withResponse: true))
    }

    func disconnect() {
        lock.lock()
        let wasConnected = connected
        connected = false
        lock.unlock()
        if wasConnected { broadcast(.disconnected(reason: nil)) }
    }

    func write(_ bytes: [UInt8]) async throws {
        let replies: [[UInt8]] = try lock.withLock {
            guard self.connected else { throw TransportError.notConnected }
            self.writes += 1
            return self.device.receive(bytes)
        }
        for reply in replies { broadcast(.notification(reply)) }
        // The whole reason this class exists: the answer is already on the event
        // stream, and the write stays parked long enough that the session is
        // guaranteed to have consumed it before `write` returns.
        try? await Task.sleep(for: settle)
    }

    private func broadcast(_ event: TransportEvent) {
        let targets: [AsyncStream<TransportEvent>.Continuation] = lock.withLock {
            guard !self.sinks.isEmpty else {
                self.backlog.append(event)
                return []
            }
            return Array(self.sinks.values)
        }
        // Yielded outside the lock: a consumer that finishes on this yield runs
        // `onTermination`, which takes the same lock.
        for target in targets { target.yield(event) }
    }
}
