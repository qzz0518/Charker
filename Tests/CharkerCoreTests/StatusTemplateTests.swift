import A2687Protocol
import XCTest
@testable import CharkerCore

final class StatusTemplateTests: XCTestCase {
    private func snapshot(
        c1: Double = 65, c2: Double = 18, c3: Double? = nil, phase: SessionPhase = .monitoring
    ) -> SessionSnapshot {
        func port(_ port: A2687.Port, _ watts: Double?) -> PortTelemetry {
            guard let watts else {
                return PortTelemetry(port: port, statusCode: 0, voltage: 0, current: 0, power: 0)
            }
            return PortTelemetry(
                port: port, statusCode: 1, voltage: 20, current: watts / 20, power: watts
            )
        }
        var snapshot = SessionSnapshot()
        snapshot.phase = phase
        snapshot.telemetry = ChargerTelemetry(
            ports: [port(.c1, c1), port(.c2, c2), port(.c3, c3)],
            receivedAt: Date(), sourceOpcode: A2687.Opcode.realtimeReport
        )
        return snapshot
    }

    func testDefaultTemplate() {
        // No emoji bolt: the status item's image already carries the identity.
        XCTAssertEqual(StatusTemplate.render(StatusTemplate.default, snapshot: snapshot()), "83.0 W")
    }

    func testPerPortTemplateAndDecimals() {
        XCTAssertEqual(
            StatusTemplate.render("C1 {c1} · C2 {c2}", snapshot: snapshot(), decimals: 0),
            "C1 65 W · C2 18 W"
        )
    }

    func testUnknownTokensAreLeftAloneAndNeverEvaluated() {
        XCTAssertEqual(
            StatusTemplate.render("{total} {rm -rf} {exec}", snapshot: snapshot(), decimals: 0),
            "83 W {rm -rf} {exec}"
        )
    }

    func testActivePortCountAndState() {
        XCTAssertEqual(StatusTemplate.render("{ports} · {state}", snapshot: snapshot()), "2 · 已连接")
    }

    func testHidingIdlePortsCollapsesSeparators() {
        let rendered = StatusTemplate.render(
            "{c1} · {c3}", snapshot: snapshot(c3: nil), hideIdlePorts: true
        )
        XCTAssertEqual(rendered, "65.0 W")
    }

    func testNeverRendersEmpty() {
        XCTAssertEqual(StatusTemplate.render("{c3}", snapshot: snapshot(c3: nil), hideIdlePorts: true), "Charker")
    }

    func testMissingTelemetryShowsAPlaceholderNotAZero() {
        XCTAssertEqual(StatusTemplate.render("{total}", snapshot: SessionSnapshot()), "—")
    }

    func testOfflineTitleDistinguishesTransientFromBroken() {
        var snapshot = SessionSnapshot()
        snapshot.phase = .scanning
        XCTAssertEqual(StatusTemplate.offlineTitle(snapshot), "搜索中")
        snapshot.phase = .reconnecting(attempt: 1, retryIn: 3)
        XCTAssertEqual(StatusTemplate.offlineTitle(snapshot), "重连中")
        snapshot.phase = .failed("nope")
        XCTAssertEqual(StatusTemplate.offlineTitle(snapshot), "离线")
        snapshot.phase = .monitoring
        XCTAssertEqual(StatusTemplate.offlineTitle(snapshot), "")
    }

    func testHidingAnIdlePortTakesItsLabelWithIt() {
        // The written-out label must elide together with the value — otherwise
        // the title dangles: "C1 65.0 W · C2".
        XCTAssertEqual(
            StatusTemplate.render("C1 {c1} · C2 {c2}", snapshot: snapshot(c2: 0), hideIdlePorts: true),
            "C1 65.0 W"
        )
        XCTAssertEqual(
            StatusTemplate.render("C1 {c1} · C2 {c2}", snapshot: snapshot(c1: 0), hideIdlePorts: true),
            "C2 18.0 W"
        )
    }

    func testDecimalsAreClamped() {
        XCTAssertEqual(StatusTemplate.render("{total}", snapshot: snapshot(), decimals: 99), "83.000 W")
    }
}

final class PreferencesTests: XCTestCase {
    private func store() throws -> (PreferencesStore, UserDefaults) {
        let defaults = MemoryDefaults()
        return (PreferencesStore(defaults: defaults), defaults)
    }

    /// The double must not reach the real defaults. Every key the store writes
    /// goes through here; one that slipped past an override would land in the
    /// test process's own domain instead, which this catches.
    func testTheDoubleNeverTouchesTheRealDefaults() throws {
        let key = "charkerIsolationProbe-\(UUID().uuidString)"
        let (store, defaults) = try store()
        defaults.set("sentinel", forKey: key)
        var prefs = store.load()
        prefs.ownerUserID = String(repeating: "a", count: 40)
        prefs.pollSeconds = 19
        store.save(prefs)
        _ = store.clientID()

        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        XCTAssertNil(UserDefaults.standard.object(forKey: "statusTemplate"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "clientID"))
    }

    func testDefaultsAreConservative() throws {
        let (store, _) = try store()
        let prefs = store.load()
        XCTAssertEqual(prefs.template, StatusTemplate.default)
        XCTAssertFalse(prefs.writesEnabled, "writes must be opt-in")
        XCTAssertFalse(prefs.captureRawPayloads, "raw capture must be opt-in")
        XCTAssertFalse(prefs.demoMode)
        XCTAssertEqual(prefs.modelScreenStyle, .ankerPrime)
        XCTAssertEqual(prefs.energyPricePerKWh, 0)
        XCTAssertEqual(prefs.energyCurrencyCode.count, 3)
    }

    func testRoundTrip() throws {
        let (store, _) = try store()
        var prefs = store.load()
        prefs.template = "{c1}|{c2}"
        prefs.decimals = 2
        prefs.writesEnabled = true
        prefs.pollSeconds = 25
        prefs.dashboardEnergyScope = "month"
        prefs.energyCurrencyCode = "USD"
        prefs.energyPricePerKWh = 0.31
        prefs.modelHomeCamera = ModelCameraPose(theta: -42.5, phi: 78, distance: 0.21)
        prefs.modelScreenStyle = .custom
        prefs.modelScreenCustomSlot = 2
        store.save(prefs)
        XCTAssertEqual(store.load(), prefs)
    }

    func testInvalidElectricityRateFallsBackWithoutProducingANonFiniteCost() throws {
        let (store, defaults) = try store()
        defaults.set("not-money", forKey: "energyCurrencyCode")
        defaults.set(Double.nan, forKey: "energyPricePerKWh")

        let prefs = store.load()
        XCTAssertEqual(prefs.energyPricePerKWh, 0)
        XCTAssertEqual(prefs.energyCurrencyCode.count, 3)
        XCTAssertNil(prefs.estimatedEnergyCost(wattHours: 1_000))
    }

    func testElectricityCostUsesKilowattHours() throws {
        var prefs = Preferences()
        prefs.energyCurrencyCode = "EUR"
        prefs.energyPricePerKWh = 0.42

        XCTAssertEqual(
            try XCTUnwrap(prefs.estimatedEnergyCost(wattHours: 2_500)),
            1.05,
            accuracy: 0.000_001
        )
        XCTAssertNil(prefs.estimatedEnergyCost(wattHours: .infinity))
    }

    func testInvalidModelHomeCameraFallsBackToBuiltInView() throws {
        let (store, defaults) = try store()
        defaults.set(32.0, forKey: "modelHomeCameraTheta")
        defaults.set(Double.nan, forKey: "modelHomeCameraPhi")
        defaults.set(0.18, forKey: "modelHomeCameraDistance")

        XCTAssertNil(store.load().modelHomeCamera)
    }

    func testUnknownModelScreenStyleFallsBackToAnkerPrime() throws {
        let (store, defaults) = try store()
        defaults.set("future-style", forKey: "modelScreenStyle")
        XCTAssertEqual(store.load().modelScreenStyle, .ankerPrime)
    }

    func testInvalidModelScreenCustomSlotFallsBackToFirstSlot() throws {
        let (store, defaults) = try store()
        defaults.set(9, forKey: "modelScreenCustomSlot")
        XCTAssertEqual(store.load().modelScreenCustomSlot, 0)
    }

    func testUnknownDashboardEnergyScopeFallsBackToCurrentSession() throws {
        let (store, defaults) = try store()
        defaults.set("future-scope", forKey: "dashboardEnergyScope")
        XCTAssertEqual(store.load().dashboardEnergyScope, "session")
    }

    func testClientIDIsStableAndInTheFormatTheFirmwareAccepts() throws {
        let (store, _) = try store()
        let first = store.clientID()
        // 40 lowercase hex characters. A UUID string here is refused with 0x09.
        XCTAssertEqual(first.count, 40)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit && !$0.isUppercase }, first)
        XCTAssertEqual(first, store.clientID())
    }

    func testLegacyUUIDClientIDIsReplaced() throws {
        let (store, defaults) = try store()
        defaults.set(UUID().uuidString.lowercased(), forKey: "clientID")
        let migrated = store.clientID()
        XCTAssertEqual(migrated.count, 40)
        XCTAssertFalse(migrated.contains("-"))
    }

    func testPeripheralIDPersists() throws {
        let (store, _) = try store()
        XCTAssertNil(store.peripheralID)
        let id = UUID()
        store.peripheralID = id
        XCTAssertEqual(store.peripheralID, id)
    }

    func testPollIntervalHasAFloor() throws {
        let (store, defaults) = try store()
        defaults.set(1, forKey: "pollSeconds")
        XCTAssertEqual(store.load().pollSeconds, 3)
    }
}

final class PosixTimeZoneTests: XCTestCase {
    func testUTC() {
        XCTAssertEqual(PosixTimeZone.current(TimeZone(identifier: "UTC")!), "UTC0")
    }

    func testSignIsInvertedRelativeToUTCOffset() {
        // Asia/Shanghai is UTC+8, which POSIX writes with the opposite sign.
        // The zone name itself is arbitrary and locale dependent.
        let rule = PosixTimeZone.current(TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertTrue(rule.hasSuffix("-8"), rule)
        XCTAssertTrue(rule.dropLast(2).allSatisfy(\.isLetter), rule)
    }

    func testHalfHourZone() {
        let rule = PosixTimeZone.current(TimeZone(identifier: "Asia/Kolkata")!)
        XCTAssertTrue(rule.hasSuffix("-5:30"), rule)
    }
}
