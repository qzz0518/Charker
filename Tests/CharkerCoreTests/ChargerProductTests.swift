import XCTest
import A2345Protocol
@testable import CharkerCore

final class ChargerProductTests: XCTestCase {
    func testA2687KeepsOriginalThreeStablePortSlots() {
        XCTAssertEqual(ChargerProduct.a2687.ports, [.c1, .c2, .c3])
        XCTAssertEqual(ChargerProduct.a2687.ratedWatts, 160)
    }

    func testA2345UsesSixPhysicalPortsInWireOrder() {
        XCTAssertEqual(
            ChargerProduct.a2345.ports,
            [.c1, .c2, .c3, .c4, .a1, .a2]
        )
        XCTAssertEqual(ChargerProduct.a2345.ratedWatts, 250)
        XCTAssertEqual(ChargerPortID.a1.connectorLabel, "USB-A")
        XCTAssertEqual(ChargerPortID.c4.connectorLabel, "USB-C")
    }

    func testGenericReadingNormalizesInvalidNumbersAndDerivesTotal() {
        let reading = ChargerReading(
            product: .a2345,
            ports: [
                ChargerPortReading(
                    port: .c1,
                    statusCode: 1,
                    voltage: 20,
                    current: 2,
                    power: 40
                ),
                ChargerPortReading(
                    port: .a1,
                    statusCode: 1,
                    voltage: .nan,
                    current: -3,
                    power: .infinity
                ),
            ]
        )

        XCTAssertEqual(reading.totalPower, 40)
        XCTAssertEqual(reading.orderedPortPower, [40, 0, 0, 0, 0, 0])
        XCTAssertEqual(reading.port(.a1)?.voltage, 0)
        XCTAssertEqual(reading.port(.a1)?.current, 0)
        XCTAssertEqual(reading.port(.a1)?.power, 0)
    }

    func testA2345BridgeDoesNotPromoteUnknownStatusOrCandidateIdentity() {
        let port = A2345PortReading(
            status: 2,
            millivolts: 20_000,
            milliamps: 1_000,
            centiwatts: 2_000
        )
        let telemetry = A2345RealtimeTelemetry(
            responseMarker: 0x34,
            ports: [.c1: port],
            a8Slots: [A2345A8Slot(
                port: .c1,
                rawBytes: [0xAC, 0x05, 0xA8, 0x12],
                word0: 0x05AC,
                word1: 0x12A8
            )],
            provisionalSlots: nil,
            timestamp: nil,
            unknownFields: []
        )

        let reading = ChargerReading(a2345: telemetry)
        XCTAssertEqual(reading.port(.c1)?.statusCode, 0)
        XCTAssertFalse(try XCTUnwrap(reading.port(.c1)).isOn)
        XCTAssertEqual(reading.totalPower, 0)
        XCTAssertNil(reading.port(.c1)?.usbVendorID)
        XCTAssertNil(reading.port(.c1)?.usbProductID)
    }

    func testA2345StatusSnapshotBridgesSixPortElectricalValues() {
        let ports = Dictionary(uniqueKeysWithValues: A2345Port.allCases.map { port in
            (port, A2345PortReading(
                status: 1,
                millivolts: 5_000,
                milliamps: UInt16(100 + port.rawValue),
                centiwatts: UInt16(50 + port.rawValue)
            ))
        })

        let reading = ChargerReading(
            a2345: A2345StatusSnapshot(ports: ports, unknownFields: [])
        )

        XCTAssertEqual(reading.ports.count, 6)
        XCTAssertEqual(reading.port(.a2)?.current ?? 0, 0.105, accuracy: 0.000_1)
        XCTAssertEqual(reading.port(.c4)?.power ?? 0, 0.53, accuracy: 0.000_1)
    }
}
