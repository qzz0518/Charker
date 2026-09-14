import XCTest
@testable import A2345Protocol

final class A2345MessageTests: XCTestCase {
    func testDecodesSixPortRealtimeTelemetryAndScaling() throws {
        let frame = try A2345PacketCodec.decode(A2345Fixtures.realtimeOldFirmware.a2345HexBytes)
        let telemetry = try A2345MessageDecoder.decodeRealtime(frame)

        XCTAssertEqual(telemetry.responseMarker, 0x34)
        XCTAssertEqual(telemetry.ports.count, 6)
        XCTAssertEqual(telemetry.ports[.c1]?.status, 1)
        XCTAssertEqual(telemetry.ports[.c1]?.millivolts, 14_984)
        XCTAssertEqual(telemetry.ports[.c1]?.milliamps, 1_632)
        XCTAssertEqual(telemetry.ports[.c1]?.centiwatts, 2_384)
        XCTAssertEqual(telemetry.ports[.c1]?.voltage ?? 0, 14.984, accuracy: 0.000_1)
        XCTAssertEqual(telemetry.ports[.c1]?.current ?? 0, 1.632, accuracy: 0.000_1)
        XCTAssertEqual(telemetry.ports[.c1]?.power ?? 0, 23.84, accuracy: 0.000_1)
        XCTAssertEqual(telemetry.ports[.c3]?.voltage ?? 0, 5.0, accuracy: 0.000_1)
        XCTAssertEqual(telemetry.ports[.a1]?.power, 0)
        XCTAssertEqual(telemetry.ports[.a2]?.power, 0)
        XCTAssertEqual(telemetry.timestamp, 0x12345678)
    }

    func testOldFirmwareWithoutA9RemainsValid() throws {
        let frame = try A2345PacketCodec.decode(A2345Fixtures.realtimeOldFirmware.a2345HexBytes)
        let telemetry = try A2345MessageDecoder.decodeRealtime(frame)

        XCTAssertNil(telemetry.provisionalSlots)
        XCTAssertEqual(telemetry.a8Slots.count, 4)
    }

    func testPreservesA8RawWordsAndSentinelsWithoutNamingSemantics() throws {
        let frame = try A2345PacketCodec.decode(A2345Fixtures.realtimeOldFirmware.a2345HexBytes)
        let slots = try A2345MessageDecoder.decodeRealtime(frame).a8Slots

        XCTAssertEqual(slots[0].port, .c1)
        XCTAssertEqual(slots[0].word0, 0x05AC)
        XCTAssertEqual(slots[0].word1, 0x12A8)
        XCTAssertEqual(slots[0].rawBytes, [0xAC, 0x05, 0xA8, 0x12])
        XCTAssertTrue(slots[1].isUnidentified)
        XCTAssertTrue(slots[2].isUnidentified)
        XCTAssertTrue(slots[3].isAllOnesSentinel)
        XCTAssertEqual(slots[3].rawBytes, [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(slots[3].word0, 0xFFFF)
        XCTAssertEqual(slots[3].word1, 0xFFFF)
    }

    func testNewFirmwarePreservesProvisionalA9RawWords() throws {
        let frame = try A2345PacketCodec.decode(A2345Fixtures.realtimeNewFirmware.a2345HexBytes)
        let slots = try XCTUnwrap(A2345MessageDecoder.decodeRealtime(frame).provisionalSlots)

        XCTAssertEqual(slots.count, 4)
        XCTAssertEqual(slots[0].port, .c1)
        XCTAssertEqual(slots[0].word0, 1)
        XCTAssertEqual(slots[0].word1, 31)
        XCTAssertEqual(slots[0].rawBytes, [0x01, 0x00, 0x1F, 0x00])
        XCTAssertTrue(slots[1].isAllOnesSentinel)
        XCTAssertTrue(slots[2].isUnidentified)
        XCTAssertTrue(slots[3].isAllOnesSentinel)
    }

    func testRejectsShortPortStruct() throws {
        var frame = try A2345PacketCodec.decode(A2345Fixtures.realtimeOldFirmware.a2345HexBytes)
        let index = try XCTUnwrap(frame.fields.firstIndex { $0.id == A2345.Field.a2 })
        frame.fields[index].rawValue.removeLast()

        XCTAssertThrowsError(try A2345MessageDecoder.decodeRealtime(frame)) { error in
            XCTAssertEqual(
                error as? A2345MessageError,
                .invalidFieldLength(id: A2345.Field.a2, expected: 8, actual: 7)
            )
        }
    }

    func testRejectsWrongPortValueType() throws {
        var frame = try A2345PacketCodec.decode(A2345Fixtures.realtimeOldFirmware.a2345HexBytes)
        let index = try XCTUnwrap(frame.fields.firstIndex { $0.id == A2345.Field.a2 })
        frame.fields[index].rawValue[0] = 0x03

        XCTAssertThrowsError(try A2345MessageDecoder.decodeRealtime(frame)) { error in
            XCTAssertEqual(
                error as? A2345MessageError,
                .unexpectedFieldType(id: A2345.Field.a2, expected: 0x04, actual: 0x03)
            )
        }
    }

    func testUnknownPortStatusIsNotExpandedIntoActive() {
        let reading = A2345PortReading(
            status: 2,
            millivolts: 5_000,
            milliamps: 1_000,
            centiwatts: 500
        )

        XCTAssertFalse(reading.isActive)
        XCTAssertEqual(reading.status, 2)
    }

    func testRejectsMissingCoreFieldButKeepsDuplicateMetadataAsUnknown() throws {
        var missing = try A2345PacketCodec.decode(A2345Fixtures.realtimeOldFirmware.a2345HexBytes)
        missing.fields.removeAll { $0.id == A2345.Field.a7 }
        XCTAssertThrowsError(try A2345MessageDecoder.decodeRealtime(missing)) { error in
            XCTAssertEqual(error as? A2345MessageError, .missingField(A2345.Field.a7))
        }

        var duplicate = try A2345PacketCodec.decode(A2345Fixtures.realtimeOldFirmware.a2345HexBytes)
        duplicate.fields.append(try XCTUnwrap(duplicate.fields.first { $0.id == A2345.Field.a8 }))
        let telemetry = try A2345MessageDecoder.decodeRealtime(duplicate)
        XCTAssertEqual(telemetry.ports.count, 6)
        XCTAssertTrue(telemetry.a8Slots.isEmpty)
        XCTAssertEqual(telemetry.unknownFields.filter { $0.id == A2345.Field.a8 }.count, 2)
    }

    func testMalformedOptionalA9DoesNotDiscardCoreTelemetry() throws {
        var frame = try A2345PacketCodec.decode(A2345Fixtures.realtimeNewFirmware.a2345HexBytes)
        let index = try XCTUnwrap(frame.fields.firstIndex { $0.id == A2345.Field.a9 })
        frame.fields[index].rawValue.removeLast()

        let telemetry = try A2345MessageDecoder.decodeRealtime(frame)
        XCTAssertEqual(telemetry.ports.count, 6)
        XCTAssertNil(telemetry.provisionalSlots)
        XCTAssertEqual(telemetry.unknownFields.filter { $0.id == A2345.Field.a9 }.count, 1)
    }

    func testWrongTypeOptionalA9DoesNotDiscardCoreTelemetry() throws {
        var frame = try A2345PacketCodec.decode(A2345Fixtures.realtimeNewFirmware.a2345HexBytes)
        let index = try XCTUnwrap(frame.fields.firstIndex { $0.id == A2345.Field.a9 })
        frame.fields[index].rawValue[0] = A2345.ValueType.variable

        let telemetry = try A2345MessageDecoder.decodeRealtime(frame)
        XCTAssertEqual(telemetry.ports.count, 6)
        XCTAssertNil(telemetry.provisionalSlots)
        XCTAssertEqual(telemetry.unknownFields.filter { $0.id == A2345.Field.a9 }.count, 1)
    }

    func testDecodesVersionAndComponentFields() throws {
        let frame = try A2345PacketCodec.decode(A2345Fixtures.versionInfo.a2345HexBytes)
        let version = try A2345MessageDecoder.decodeVersionInfo(frame)

        XCTAssertEqual(version.hardwareVersion, "1.0.0")
        XCTAssertEqual(version.softwareVersion, "2.1.1.6")
        XCTAssertEqual(version.productCode, "A2345")
        XCTAssertEqual(version.mcuComponent, "A2345_mcu")
        XCTAssertEqual(version.esp32Component, "A2345_esp32")
    }

    func testDecodesElectricalSubsetOfSyntheticStatusSnapshot() throws {
        let portFields = A2345Port.allCases.enumerated().map { offset, port in
            let base = UInt16(1_000 + offset * 100)
            return A2345TLV(
                id: UInt8(Int(A2345.Field.a4) + offset),
                rawValue: [
                    A2345.ValueType.binary,
                    port == .a2 ? 0 : 1,
                    UInt8(base & 0xFF), UInt8(base >> 8),
                    UInt8((base + 1) & 0xFF), UInt8((base + 1) >> 8),
                    UInt8((base + 2) & 0xFF), UInt8((base + 2) >> 8),
                ]
            )
        }
        let preservedSetting = A2345TLV(id: 0xB3, rawValue: [70])
        let frame = A2345Frame(
            pattern: A2345FramePattern(version: 3, speaker: 1, group: 15),
            messageType: A2345.MessageType.statusSnapshot,
            increment: nil,
            fields: portFields + [preservedSetting],
            encodedLength: 0,
            checksum: 0
        )

        let snapshot = try A2345MessageDecoder.decodeStatusSnapshot(frame)
        XCTAssertEqual(snapshot.ports.count, 6)
        XCTAssertEqual(snapshot.ports[.c1]?.millivolts, 1_000)
        XCTAssertEqual(snapshot.ports[.a2]?.centiwatts, 1_502)
        XCTAssertFalse(try XCTUnwrap(snapshot.ports[.a2]).isActive)
        XCTAssertEqual(snapshot.unknownFields, [preservedSetting])
        XCTAssertEqual(
            try A2345MessageDecoder.decode(frame),
            .statusSnapshot(snapshot)
        )
    }

    func testRejectsInvalidUTF8InVersionField() throws {
        var frame = try A2345PacketCodec.decode(A2345Fixtures.versionInfo.a2345HexBytes)
        let index = try XCTUnwrap(frame.fields.firstIndex { $0.id == A2345.Field.a1 })
        frame.fields[index].rawValue = [A2345.ValueType.string, 0xFF]

        XCTAssertThrowsError(try A2345MessageDecoder.decodeVersionInfo(frame)) { error in
            XCTAssertEqual(error as? A2345MessageError, .invalidUTF8(A2345.Field.a1))
        }
    }

    func testDecodesFourteenByteAcknowledgementAsOpaqueMarker() throws {
        let frame = try A2345PacketCodec.decode(A2345Fixtures.realtimeAcknowledgement.a2345HexBytes)
        XCTAssertEqual(frame.encodedLength, 14)

        let acknowledgement = try A2345MessageDecoder.decodeAcknowledgement(frame)
        XCTAssertEqual(acknowledgement.messageType, A2345.MessageType.realtimeAcknowledgement)
        XCTAssertEqual(acknowledgement.increment, 0)
        XCTAssertEqual(acknowledgement.marker, 0x34)
    }

    func testUnknownMessageTypeIsPreserved() throws {
        var frame = try A2345PacketCodec.decode(A2345Fixtures.versionInfo.a2345HexBytes)
        frame.messageType = 0x7777

        XCTAssertEqual(try A2345MessageDecoder.decode(frame), .unknown(frame))
    }
}
