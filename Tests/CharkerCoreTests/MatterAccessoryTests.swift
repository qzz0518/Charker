import A2345Protocol
import A2687Protocol
@testable import CharkerCore
import XCTest

final class MatterAccessoryTests: XCTestCase {
    // MARK: Layout

    func testLayoutsMatchTheHelperContract() {
        let small = MatterAccessoryLayout(product: .a2687)
        XCTAssertEqual(small.name, "Charker 160W")
        XCTAssertEqual(small.storageName, "a2687")
        XCTAssertEqual(small.labels, ["C1", "C2", "C3"])
        XCTAssertEqual(small.targets, [.a2687(.c1), .a2687(.c2), .a2687(.c3)])

        let large = MatterAccessoryLayout(product: .a2345)
        XCTAssertEqual(large.name, "Charker 250W")
        XCTAssertEqual(large.storageName, "a2345")
        XCTAssertEqual(large.labels, ["C1", "C2", "C3", "C4", "USB-A"])
        XCTAssertEqual(large.target(at: 4), .a2345(.usbA))
        XCTAssertNil(large.target(at: 5))
        XCTAssertNil(large.target(at: -1))
    }

    func testBridgedLayoutsKeepTheTargetsUnderTheirOwnPairing() {
        let small = MatterAccessoryLayout(product: .a2687, kind: .bridged)
        // Outside the app bundle a localized name is its own key.
        XCTAssertEqual(small.name, "Charker 160W 端口")
        XCTAssertEqual(small.storageName, "a2687-ports")
        XCTAssertEqual(small.labels, ["160W C1", "160W C2", "160W C3"])
        XCTAssertEqual(small.targets, MatterAccessoryLayout(product: .a2687).targets)

        let large = MatterAccessoryLayout(product: .a2345, kind: .bridged)
        XCTAssertEqual(large.name, "Charker 250W 端口")
        XCTAssertEqual(large.storageName, "a2345-ports")
        XCTAssertEqual(large.labels, ["250W C1", "250W C2", "250W C3", "250W C4", "250W USB-A"])
        XCTAssertEqual(large.targets, MatterAccessoryLayout(product: .a2345).targets)
        XCTAssertNotEqual(large, MatterAccessoryLayout(product: .a2345))
        XCTAssertEqual(MatterAccessoryLayout(product: .a2345).udpPort, 5540)
        XCTAssertEqual(large.udpPort, 5541)
        XCTAssertEqual(small.udpPort, 5541)
    }

    /// The helper refuses a name or label over 32 bytes, in any language.
    func testNamesAndLabelsFitTheHelpersLimit() throws {
        let english = try coreStrings("en")
        let chinese = try coreStrings("zh-Hans")
        XCTAssertEqual(english["Charker 160W 端口"], "Charker 160W Ports")
        XCTAssertEqual(english["Charker 250W 端口"], "Charker 250W Ports")
        for product in ChargerProduct.allCases {
            for kind in [MatterAccessoryLayout.Kind.grouped, .bridged] {
                let layout = MatterAccessoryLayout(product: product, kind: kind)
                let names = [layout.name, english[layout.name], chinese[layout.name]].compactMap { $0 }
                for text in names + layout.labels {
                    XCTAssertLessThanOrEqual(text.utf8.count, 32, text)
                }
            }
        }
    }

    private func coreStrings(_ localization: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizations/\(localization).lproj/Core.strings")
        let value = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), options: [], format: nil
        )
        return try XCTUnwrap(value as? [String: String])
    }

    // MARK: A2687

    private func a2687Snapshot(
        phase: SessionPhase = .monitoring,
        isStale: Bool = false,
        ports: [PortTelemetry]
    ) -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.phase = phase
        snapshot.isStale = isStale
        snapshot.telemetry = ChargerTelemetry(ports: ports, receivedAt: Date(), sourceOpcode: 0x0300)
        return snapshot
    }

    func testA2687LivePortConvertsToMilliUnits() {
        let snapshot = a2687Snapshot(ports: [
            PortTelemetry(port: .c1, statusCode: 1, voltage: 20.0004, current: 1.4996, power: 29.99),
            PortTelemetry(port: .c2, statusCode: 0, voltage: 5, current: 0.3, power: 1.5),
        ])
        let states = MatterAccessoryLayout(product: .a2687)
            .portStates(a2687: snapshot, a2345: A2345ConnectionSnapshot())
        XCTAssertEqual(states, [
            MatterPortState(on: true, voltageMV: 20_000, currentMA: 1_500, powerMW: 29_990),
            // An off port's leftover numbers are not a reading.
            MatterPortState(on: false),
            // Not in the frame at all: off, nothing measured.
            MatterPortState(on: false),
        ])
    }

    func testA2687StaleOrDroppedLinkZeroesReadingsButKeepsSwitch() {
        let port = PortTelemetry(port: .c1, statusCode: 1, voltage: 20, current: 2, power: 40)
        let stale = a2687Snapshot(isStale: true, ports: [port])
        XCTAssertEqual(MatterPortState.a2687(.c1, in: stale), MatterPortState(on: true))

        let reconnecting = a2687Snapshot(phase: .reconnecting(attempt: 1, retryIn: 2), ports: [port])
        XCTAssertEqual(MatterPortState.a2687(.c1, in: reconnecting), MatterPortState(on: true))

        // Nothing describes the port any more: the last value Home saw stays.
        var empty = SessionSnapshot()
        empty.phase = .scanning
        XCTAssertEqual(MatterPortState.a2687(.c1, in: empty, previousOn: true), MatterPortState(on: true))
        XCTAssertEqual(MatterPortState.a2687(.c1, in: empty), .off)
    }

    func testNegativeAndNonFiniteValuesClampToZero() {
        XCTAssertEqual(MatterPortState.milli(-1), 0)
        XCTAssertEqual(MatterPortState.milli(.nan), 0)
        XCTAssertEqual(MatterPortState.milli(.infinity), 0)
        XCTAssertEqual(MatterPortState.milli(0.0004), 0)
        XCTAssertEqual(MatterPortState.milli(0.0005), 1)
        XCTAssertEqual(MatterPortState(on: true, voltageMV: -5, currentMA: -1, powerMW: -2), MatterPortState(on: true))
    }

    // MARK: A2345

    private func a2345Reading(_ ports: [ChargerPortReading]) -> ChargerReading {
        ChargerReading(product: .a2345, ports: ports, receivedAt: Date())
    }

    private func a2345Snapshot(
        reading: ChargerReading?,
        settings: A2345DeviceSettings? = nil,
        phase: A2345ConnectionPhase = .monitoring,
        isStale: Bool = false
    ) -> A2345ConnectionSnapshot {
        var snapshot = A2345ConnectionSnapshot()
        snapshot.phase = phase
        snapshot.reading = reading
        snapshot.settings = settings
        snapshot.isStale = isStale
        return snapshot
    }

    func testA2345UsbAAggregatesBothSockets() {
        let reading = a2345Reading([
            ChargerPortReading(port: .a1, statusCode: 1, voltage: 5.0, current: 1.2, power: 6.0),
            ChargerPortReading(port: .a2, statusCode: 1, voltage: 9.0, current: 2.0, power: 18.0),
        ])
        let state = MatterPortState.a2345(.usbA, in: a2345Snapshot(reading: reading, settings: .demo))
        XCTAssertEqual(state, MatterPortState(on: true, voltageMV: 9_000, currentMA: 3_200, powerMW: 24_000))

        // An idle socket contributes nothing, not even its voltage.
        let one = a2345Reading([
            ChargerPortReading(port: .a1, statusCode: 0, voltage: 12, current: 0, power: 0),
            ChargerPortReading(port: .a2, statusCode: 1, voltage: 5.0, current: 1.0, power: 5.0),
        ])
        XCTAssertEqual(
            MatterPortState.a2345(.usbA, in: a2345Snapshot(reading: one, settings: .demo)),
            MatterPortState(on: true, voltageMV: 5_000, currentMA: 1_000, powerMW: 5_000)
        )
    }

    func testA2345SwitchComesFromSettingsAndFallsBackToActivityOnlyWithoutThem() {
        let reading = a2345Reading([
            ChargerPortReading(port: .c1, statusCode: 1, voltage: 20, current: 3, power: 60),
            ChargerPortReading(port: .c2, statusCode: 0, voltage: 0, current: 0, power: 0),
        ])
        var settings = A2345DeviceSettings.demo
        settings.apply(.portOutput(.c1, isOn: false))
        let withSettings = a2345Snapshot(reading: reading, settings: settings)
        // The switch says off even while the last frame still shows output.
        XCTAssertEqual(MatterPortState.a2345(.c1, in: withSettings).on, false)
        // Switched on with nothing plugged in.
        XCTAssertEqual(MatterPortState.a2345(.c2, in: withSettings), MatterPortState(on: true))

        let beforeSettings = a2345Snapshot(reading: reading)
        XCTAssertEqual(
            MatterPortState.a2345(.c1, in: beforeSettings),
            MatterPortState(on: true, voltageMV: 20_000, currentMA: 3_000, powerMW: 60_000)
        )
        // No output does not prove a port off.
        XCTAssertEqual(MatterPortState.a2345(.c2, in: beforeSettings, previousOn: true), MatterPortState(on: true))
        XCTAssertEqual(MatterPortState.a2345(.c2, in: beforeSettings), .off)
    }

    func testA2345StaleZeroesReadingsAndLeavesSwitchAlone() {
        let reading = a2345Reading([
            ChargerPortReading(port: .c3, statusCode: 1, voltage: 15, current: 2, power: 30),
        ])
        let stale = a2345Snapshot(reading: reading, settings: .demo, isStale: true)
        XCTAssertEqual(MatterPortState.a2345(.c3, in: stale), MatterPortState(on: true))

        // A reconnect drops the settings; the stale frame must not decide the
        // switch, the value Home already shows does.
        let reconnecting = a2345Snapshot(
            reading: reading, phase: .reconnecting(attempt: 2), isStale: true
        )
        XCTAssertEqual(MatterPortState.a2345(.c4, in: reconnecting, previousOn: true), MatterPortState(on: true))
        XCTAssertEqual(MatterPortState.a2345(.c3, in: reconnecting, previousOn: false), .off)

        let failed = a2345Snapshot(reading: nil, phase: .failed("offline"))
        XCTAssertEqual(MatterPortState.a2345(.c1, in: failed, previousOn: true), MatterPortState(on: true))
    }

    func testLayoutStatesUsePreviousByIndex() {
        let layout = MatterAccessoryLayout(product: .a2345)
        let previous = [
            MatterPortState(on: true), .off, MatterPortState(on: true), .off, MatterPortState(on: true),
        ]
        let states = layout.portStates(
            a2687: SessionSnapshot(),
            a2345: a2345Snapshot(reading: nil, phase: .reconnecting(attempt: 1)),
            previous: previous
        )
        XCTAssertEqual(states, previous)
        XCTAssertEqual(
            layout.portStates(a2687: SessionSnapshot(), a2345: A2345ConnectionSnapshot()),
            Array(repeating: .off, count: 5)
        )
    }

    // MARK: Port sync

    func testPendingCommandKeepsRequestedSwitchUntilAnswered() {
        var sync = MatterPortSync()
        let on = MatterPortState(on: true, voltageMV: 20_000, currentMA: 1_000, powerMW: 20_000)
        sync.update([on, .off, .off])
        XCTAssertEqual(sync.connect(ports: 3), [
            MatterHelperLine.port(index: 0, on),
            MatterHelperLine.port(index: 1, .off),
            MatterHelperLine.port(index: 2, .off),
        ])

        XCTAssertTrue(sync.request(index: 0, on: false))
        XCTAssertFalse(sync.request(index: 3, on: true))
        // A reading that still says on: new numbers, requested switch.
        let reading = MatterPortState(on: true, voltageMV: 20_000, currentMA: 900, powerMW: 18_000)
        var shown = reading
        shown.on = false
        XCTAssertEqual(sync.update([reading, .off, .off]), [MatterHelperLine.port(index: 0, shown)])
        XCTAssertEqual(sync.update([reading, .off, .off]), [])

        // The answer writes the real state, even unchanged.
        XCTAssertEqual(sync.answer(index: 0), MatterHelperLine.port(index: 0, reading))
        XCTAssertEqual(sync.answer(index: 1), MatterHelperLine.port(index: 1, .off))
        XCTAssertEqual(sync.update([reading, .off, .off]), [])
    }

    func testPortSyncWritesNothingWithoutHelperAndForgetsRequestsOnReconnect() {
        var sync = MatterPortSync()
        XCTAssertEqual(sync.update([MatterPortState(on: true)]), [])
        XCTAssertNil(sync.answer(index: 0))

        _ = sync.connect(ports: 1)
        XCTAssertTrue(sync.request(index: 0, on: false))
        sync.disconnect()
        XCTAssertEqual(sync.desired, [MatterPortState(on: true)])
        XCTAssertFalse(sync.request(index: 0, on: false))
        XCTAssertEqual(sync.connect(ports: 1), [MatterHelperLine.port(index: 0, MatterPortState(on: true))])
    }

    // MARK: Line protocol

    func testHostLinesMatchTheContractExactly() throws {
        let line = MatterHelperLine.port(
            index: 0,
            MatterPortState(on: true, voltageMV: 20_000, currentMA: 1_500, powerMW: 30_000)
        )
        XCTAssertEqual(
            line,
            #"{"type":"port","index":0,"on":true,"voltage_mv":20000,"current_ma":1500,"power_mw":30000}"#
        )
        XCTAssertFalse(line.contains("\n"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "port")
        XCTAssertEqual(object["index"] as? Int, 0)
        XCTAssertEqual(object["on"] as? Bool, true)
        XCTAssertEqual(object["voltage_mv"] as? Int, 20_000)
        XCTAssertEqual(object["current_ma"] as? Int, 1_500)
        XCTAssertEqual(object["power_mw"] as? Int, 30_000)

        XCTAssertEqual(
            MatterHelperLine.port(index: 4, .off),
            #"{"type":"port","index":4,"on":false,"voltage_mv":0,"current_ma":0,"power_mw":0}"#
        )
        XCTAssertEqual(MatterHelperLine.shutdown, #"{"type":"shutdown"}"#)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(MatterHelperLine.shutdown.utf8)))
    }

    func testHelperEventsDecode() {
        XCTAssertEqual(
            MatterHelperEvent(line: #"{"type":"onboarding","qr":"MT:Y.K9042C00KA0648G00","manual_code":"34970112332"}"#),
            .onboarding(qr: "MT:Y.K9042C00KA0648G00", manualCode: "34970112332")
        )
        XCTAssertEqual(MatterHelperEvent(line: #"{"type":"fabrics","count":2}"#), .fabrics(count: 2))
        XCTAssertEqual(MatterHelperEvent(line: #"{"type":"fabrics","count":0}"#), .fabrics(count: 0))
        XCTAssertEqual(
            MatterHelperEvent(line: #"{"type":"command","index":0,"on":false}"#),
            .command(index: 0, on: false)
        )
        XCTAssertEqual(MatterHelperEvent(line: #"{"type":"mdns","ok":false}"#), .mdns(ok: false))
        XCTAssertEqual(MatterHelperEvent(line: #"{"type":"mdns","ok":true}"#), .mdns(ok: true))
        XCTAssertEqual(
            MatterHelperEvent(line: #"{"type":"error","code":"bind","message":"address in use"}"#),
            .error(code: "bind", message: "address in use")
        )
        // Field order and extra fields do not matter.
        XCTAssertEqual(
            MatterHelperEvent(line: #"{"on":true,"index":3,"type":"command","source":"home"}"#),
            .command(index: 3, on: true)
        )
    }

    func testUnknownAndMalformedLinesAreIgnored() {
        XCTAssertNil(MatterHelperEvent(line: #"{"type":"heartbeat","seq":1}"#))
        XCTAssertNil(MatterHelperEvent(line: "not json"))
        XCTAssertNil(MatterHelperEvent(line: ""))
        XCTAssertNil(MatterHelperEvent(line: #"{"index":0,"on":true}"#))
        XCTAssertNil(MatterHelperEvent(line: #"{"type":"command","index":0}"#))
        XCTAssertNil(MatterHelperEvent(line: #"{"type":"command","index":-1,"on":true}"#))
        XCTAssertNil(MatterHelperEvent(line: #"{"type":"onboarding","qr":"MT:X"}"#))
        XCTAssertNil(MatterHelperEvent(line: #"{"type":"mdns"}"#))
    }

    func testManualCodeGroupsFourThreeFour() {
        XCTAssertEqual(MatterHelperEvent.formattedManualCode("34970112332"), "3497-011-2332")
        XCTAssertEqual(MatterHelperEvent.formattedManualCode("3497011233"), "3497011233")
        XCTAssertEqual(MatterHelperEvent.formattedManualCode("3497-011-2332"), "3497-011-2332")
        XCTAssertEqual(MatterHelperEvent.formattedManualCode("3497011233a"), "3497011233a")
    }
}
