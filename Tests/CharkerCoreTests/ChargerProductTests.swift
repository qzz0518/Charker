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

    func testMainlandPortTailOnlyDescribesActivePorts() {
        func port(status: UInt8, cable: UInt8?, fastCharge: UInt8?, brand: UInt8?) -> A2345PortReading {
            A2345PortReading(
                status: status, millivolts: 10_000, milliamps: 2_000, centiwatts: 2_000,
                cable: cable, fastCharge: fastCharge, deviceBrand: brand
            )
        }
        let reading = ChargerReading(a2345: A2345StatusSnapshot(ports: [
            .c1: port(status: 1, cable: 1, fastCharge: 1, brand: 1),
            .c2: port(status: 0, cable: 0, fastCharge: 0, brand: 0),
            .c3: port(status: 1, cable: 0, fastCharge: 0, brand: 0),
            .c4: port(status: 1, cable: 9, fastCharge: 9, brand: 9),
            .a1: port(status: 1, cable: 1, fastCharge: 2, brand: 2),
            .a2: port(status: 1, cable: nil, fastCharge: nil, brand: nil),
        ], unknownFields: []))

        XCTAssertEqual(reading.port(.c1)?.cable, .fiveAmp)
        XCTAssertEqual(reading.port(.c1)?.fastCharge, .huaweiSCP)
        XCTAssertEqual(reading.port(.c1)?.deviceBrand, .huaweiHonor)
        XCTAssertNil(reading.port(.c2)?.cable)
        XCTAssertEqual(reading.port(.c3)?.cable, .threeAmp)
        XCTAssertNil(reading.port(.c3)?.fastCharge)
        XCTAssertNil(reading.port(.c3)?.deviceBrand)
        XCTAssertNil(reading.port(.c4)?.cable)
        XCTAssertNil(reading.port(.c4)?.fastCharge)
        XCTAssertNil(reading.port(.a1)?.cable)
        XCTAssertEqual(reading.port(.a1)?.fastCharge, .xiaomiHyperCharge)
        XCTAssertEqual(reading.port(.a1)?.deviceBrand, .xiaomi)
        XCTAssertNil(reading.port(.a2)?.cable)
    }
}
