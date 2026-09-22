import Foundation
import XCTest
@testable import CharkerCore

final class SavedChargerTests: XCTestCase {
    private let home = UUID()
    private let office = UUID()

    func testAFirstConnectionIsSavedWithItsSerial() {
        var chargers: [SavedCharger] = []
        let at = Date(timeIntervalSince1970: 1_000)
        chargers.recordConnection(id: home, serialNumber: " HOME0000000000A1 ", at: at)

        XCTAssertEqual(chargers, [
            SavedCharger(id: home, serialNumber: "HOME0000000000A1", lastConnectedAt: at),
        ])
    }

    func testReconnectingRefreshesTheEntryAndKeepsItsName() {
        var chargers = [SavedCharger(id: home, nickname: "家里")]
        let at = Date(timeIntervalSince1970: 2_000)
        chargers.recordConnection(id: home, serialNumber: "HOME0000000000A1", at: at)

        XCTAssertEqual(chargers.count, 1)
        XCTAssertEqual(chargers[0].nickname, "家里")
        XCTAssertEqual(chargers[0].lastConnectedAt, at)
        XCTAssertEqual(chargers[0].serialNumber, "HOME0000000000A1")
    }

    /// The system forgetting a peripheral changes its CoreBluetooth identifier.
    /// The serial is what proves it is the same charger, so its name survives.
    func testANewIdentifierWithAKnownSerialTakesOverTheOldEntry() {
        var chargers = [
            SavedCharger(id: home, nickname: "家里", serialNumber: "HOME0000000000A1"),
            SavedCharger(id: office, nickname: "办公室", serialNumber: "OFFICE00000000B2"),
        ]
        let renewed = UUID()
        chargers.recordConnection(id: renewed, serialNumber: "HOME0000000000A1", at: Date())

        XCTAssertEqual(chargers.map(\.id), [renewed, office])
        XCTAssertEqual(chargers[0].nickname, "家里")
    }

    /// Saved first without a serial (the legacy migration), then the serial
    /// arrives on an entry that was already re-added under a new identifier.
    func testTwoEntriesForOneSerialCollapseIntoTheOneInUse() {
        let renewed = UUID()
        var chargers = [
            SavedCharger(id: home, nickname: "家里", serialNumber: "HOME0000000000A1"),
            SavedCharger(id: renewed),
        ]
        chargers.recordConnection(id: renewed, serialNumber: "HOME0000000000A1", at: Date())

        XCTAssertEqual(chargers.map(\.id), [renewed])
        XCTAssertEqual(chargers[0].nickname, "家里")
    }

    func testReconnectOrderIsMostRecentFirstWithNeverUsedLast() {
        let third = UUID()
        let chargers = [
            SavedCharger(id: third),
            SavedCharger(id: home, lastConnectedAt: Date(timeIntervalSince1970: 100)),
            SavedCharger(id: office, lastConnectedAt: Date(timeIntervalSince1970: 200)),
        ]
        XCTAssertEqual(chargers.reconnectOrder, [office, home, third])
    }

    func testRenameTrimsAndBoundsTheName() {
        var chargers = [SavedCharger(id: home)]
        chargers.rename(home, to: "  家里的书房  \n")
        XCTAssertEqual(chargers[0].nickname, "家里的书房")

        chargers.rename(home, to: String(repeating: "长", count: 60))
        XCTAssertEqual(chargers[0].nickname.count, SavedCharger.nicknameLimit)

        chargers.rename(home, to: "   ")
        XCTAssertEqual(chargers[0].nickname, "")
    }

    func testForgetRemovesOnlyThatCharger() {
        var chargers = [SavedCharger(id: home), SavedCharger(id: office)]
        chargers.forget(home)
        XCTAssertEqual(chargers.map(\.id), [office])
    }

    func testDisplayNameTellsTwoUnnamedChargersApart() {
        XCTAssertEqual(SavedCharger(id: home, nickname: "家里").displayName, "家里")
        XCTAssertEqual(
            SavedCharger(id: home, serialNumber: "HOME0000000000A1").displayName,
            "Anker Prime 160W · 00A1"
        )
        XCTAssertEqual(SavedCharger(id: home).displayName, "Anker Prime 160W")
    }

    func testTheListRoundTripsThroughJSON() throws {
        let chargers = [
            SavedCharger(
                id: home, nickname: "家里", serialNumber: "HOME0000000000A1",
                lastConnectedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            SavedCharger(id: office),
        ]
        let decoded = try XCTUnwrap(SavedCharger.decodeList(SavedCharger.encodeList(chargers)))
        XCTAssertEqual(decoded, chargers)
    }

    func testOneDamagedEntryDoesNotCostTheOthers() throws {
        let json = """
        [{"id":"\(home.uuidString)","nickname":"家里"},
         {"id":"not-a-uuid","nickname":"坏的"},
         {"id":"\(office.uuidString)"},
         {"id":"\(home.uuidString)","nickname":"重复"}]
        """
        let decoded = try XCTUnwrap(SavedCharger.decodeList(json))
        XCTAssertEqual(decoded, [
            SavedCharger(id: home, nickname: "家里"),
            SavedCharger(id: office),
        ])
        XCTAssertNil(SavedCharger.decodeList("{}"))
    }
}

final class SavedChargerPreferencesTests: XCTestCase {
    func testSavedChargersRoundTrip() {
        let store = PreferencesStore(defaults: MemoryDefaults())
        var prefs = store.load()
        prefs.savedChargers = [
            SavedCharger(id: UUID(), nickname: "家里", serialNumber: "HOME0000000000A1"),
            SavedCharger(id: UUID(), nickname: "办公室"),
        ]
        store.save(prefs)
        XCTAssertEqual(store.load(), prefs)
    }

    /// Builds before the list remembered one charger by its identifier alone.
    func testTheOnlyChargerAnOlderBuildRememberedBecomesTheFirstSavedOne() {
        let defaults = MemoryDefaults()
        let legacy = UUID()
        defaults.set(legacy.uuidString, forKey: "peripheralID")

        let prefs = PreferencesStore(defaults: defaults).load()

        XCTAssertEqual(prefs.savedChargers, [SavedCharger(id: legacy)])
        XCTAssertTrue(prefs.initialSetupCompleted)
    }

    /// Once the list exists it is authoritative: forgetting every charger must
    /// not bring the legacy one back.
    func testAnEmptySavedListIsNotRefilledFromTheLegacyKey() {
        let defaults = MemoryDefaults()
        let store = PreferencesStore(defaults: defaults)
        var prefs = store.load()
        prefs.savedChargers = []
        store.save(prefs)
        defaults.set(UUID().uuidString, forKey: "peripheralID")

        XCTAssertEqual(store.load().savedChargers, [])
    }

    func testTheListIsWrittenToTheInjectedDefaultsOnly() {
        let defaults = MemoryDefaults()
        let store = PreferencesStore(defaults: defaults)
        var prefs = store.load()
        prefs.savedChargers = [SavedCharger(id: UUID())]
        store.save(prefs)

        XCTAssertNotNil(defaults.string(forKey: "savedChargers"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "savedChargers"))
    }
}
