import A2687Protocol
import XCTest
@testable import CharkerCore

final class SessionStateTests: XCTestCase {
    func testNearbyBrowseIsOnlyAvailableWithoutALink() {
        var snapshot = SessionSnapshot()
        snapshot.bluetooth = .poweredOn

        snapshot.phase = .idle
        XCTAssertTrue(snapshot.canBrowseNearbyDevices)
        snapshot.phase = .scanning
        XCTAssertTrue(snapshot.canBrowseNearbyDevices)
        snapshot.phase = .failed("retry manually")
        XCTAssertTrue(snapshot.canBrowseNearbyDevices)

        // Waiting for a saved charger that is out of range links nothing, and
        // is exactly when the user needs to see what else is nearby.
        snapshot.phase = .connecting
        XCTAssertTrue(snapshot.canBrowseNearbyDevices)
        snapshot.phase = .reconnecting(attempt: 1, retryIn: 1)
        XCTAssertTrue(snapshot.canBrowseNearbyDevices)

        snapshot.phase = .negotiating(.capability)
        XCTAssertFalse(snapshot.canBrowseNearbyDevices)
        snapshot.phase = .monitoring
        XCTAssertFalse(snapshot.canBrowseNearbyDevices)
    }

    func testNearbyBrowseRequiresAnAvailableBluetoothPhase() {
        var snapshot = SessionSnapshot()
        snapshot.bluetooth = .poweredOff
        snapshot.phase = .bluetoothUnavailable(.poweredOff)
        XCTAssertFalse(snapshot.canBrowseNearbyDevices)
    }

    func testCoreBluetoothRSSISentinelsAreNotPresentedAsFullSignal() {
        let identifier = UUID()

        let systemRetrieved = DiscoveredCharger(id: identifier, rssi: 0)
        XCTAssertFalse(systemRetrieved.hasMeasuredRSSI)
        XCTAssertEqual(systemRetrieved.signalBars, 0)

        let unavailable = DiscoveredCharger(id: identifier, rssi: 127)
        XCTAssertFalse(unavailable.hasMeasuredRSSI)
        XCTAssertEqual(unavailable.signalBars, 0)

        let measured = DiscoveredCharger(id: identifier, rssi: -45)
        XCTAssertTrue(measured.hasMeasuredRSSI)
        XCTAssertEqual(measured.signalBars, 4)
    }

    func testCurrentDeviceStaysFirstWhenItsRetrievedRSSIIsUnavailable() {
        let currentID = UUID()
        let nearbyID = UUID()
        var snapshot = SessionSnapshot()
        snapshot.peripheralID = currentID
        snapshot.nearbyDevices = [
            DiscoveredCharger(
                id: nearbyID, name: "nearby", rssi: -40,
                matchReasons: [.advertisedService]
            ),
            DiscoveredCharger(
                id: currentID, name: "system", rssi: 0,
                matchReasons: [.systemConnected]
            ),
        ]

        XCTAssertEqual(snapshot.sortedNearbyDevices.first?.id, currentID)
    }
}
