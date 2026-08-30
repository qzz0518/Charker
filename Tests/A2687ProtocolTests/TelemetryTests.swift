import XCTest
@testable import A2687Protocol

final class TelemetryTests: XCTestCase {
    private func portStruct(status: UInt8, mV: UInt16, mA: UInt16, cW: UInt16) -> [UInt8] {
        TypedValue.bytes([
            status,
            UInt8(mV & 0xFF), UInt8(mV >> 8),
            UInt8(mA & 0xFF), UInt8(mA >> 8),
            UInt8(cW & 0xFF), UInt8(cW >> 8),
        ]).encoded
    }

    /// The `AC`/`AD`/`AE` control struct in the shape real firmware sends: twelve
    /// bytes, cable and profile codes last. These fixtures used to be four bytes
    /// (`00 00 cable profile`) and only decoded because the old reader took the
    /// last two bytes of whatever length it was handed — a shape the charger has
    /// never emitted. The assertions below are unchanged; only the input is now
    /// something the device could actually produce.
    private func controlStruct(cable: UInt8, profile: UInt8) -> [UInt8] {
        TypedValue.bytes(PortControl.idleDefaultPrefix + [cable, profile]).encoded
    }

    private func report(_ fields: [TLV]) throws -> Payload {
        try Payload.parse([0x00] + TLVCodec.encode(fields))
    }

    func testDecodesThreePortsAndDerivesTheTotal() throws {
        let payload = try report([
            TLV(id: A2687.Field.a1, value: [0x21]),
            TLV(id: A2687.Field.a5, value: portStruct(status: 1, mV: 20000, mA: 3250, cW: 6500)),
            TLV(id: A2687.Field.a6, value: portStruct(status: 1, mV: 9000, mA: 2000, cW: 1800)),
            TLV(id: A2687.Field.a7, value: portStruct(status: 0, mV: 0, mA: 0, cW: 0)),
        ])
        let telemetry = try XCTUnwrap(TelemetryDecoder.decode(payload, opcode: A2687.Opcode.realtimeReport))
        XCTAssertEqual(telemetry.ports.count, 3)

        let c1 = try XCTUnwrap(telemetry.port(.c1))
        XCTAssertEqual(c1.voltage, 20.0, accuracy: 0.0001)
        XCTAssertEqual(c1.current, 3.25, accuracy: 0.0001)
        XCTAssertEqual(c1.power, 65.0, accuracy: 0.0001)
        XCTAssertTrue(c1.isDelivering)

        XCTAssertEqual(telemetry.totalPower, 83.0, accuracy: 0.0001)
        XCTAssertEqual(telemetry.activePortCount, 2)
        XCTAssertFalse(try XCTUnwrap(telemetry.port(.c3)).isOn)
        XCTAssertEqual(telemetry.sourceOpcode, A2687.Opcode.realtimeReport)
    }

    func testOffPortDoesNotContributeToTheTotal() throws {
        // A stale non-zero reading behind an off flag must not be summed.
        let payload = try report([
            TLV(id: A2687.Field.a5, value: portStruct(status: 0, mV: 20000, mA: 3250, cW: 6500)),
        ])
        let telemetry = try XCTUnwrap(TelemetryDecoder.decode(payload, opcode: A2687.Opcode.realtimeReport))
        XCTAssertEqual(telemetry.totalPower, 0)
    }

    func testDecodesCableAndChargingProfile() throws {
        let payload = try report([
            TLV(id: A2687.Field.a5, value: portStruct(status: 1, mV: 9000, mA: 2200, cW: 1980)),
            TLV(id: A2687.Field.ac, value: controlStruct(cable: 0x02, profile: 0x01)),
        ])
        let port = try XCTUnwrap(TelemetryDecoder.decode(payload, opcode: 0x0300)?.port(.c1))
        XCTAssertEqual(port.cable, .epr240W)
        XCTAssertEqual(port.chargingProfile, .applePD)
    }

    func testUnknownCableCodeIsSurfacedNotInvented() throws {
        let payload = try report([
            TLV(id: A2687.Field.a5, value: portStruct(status: 1, mV: 9000, mA: 2200, cW: 1980)),
            TLV(id: A2687.Field.ac, value: controlStruct(cable: 0x7E, profile: 0x7F)),
        ])
        let port = try XCTUnwrap(TelemetryDecoder.decode(payload, opcode: 0x0300)?.port(.c1))
        XCTAssertEqual(port.cable, .unknown(0x7E))
        XCTAssertEqual(port.cable?.label, "Unknown (0x7E)")
        XCTAssertEqual(port.chargingProfile, .unknown(0x7F))
    }

    func testIdlePortReportsNoChargingProfile() throws {
        let payload = try report([
            TLV(id: A2687.Field.a5, value: portStruct(status: 1, mV: 5000, mA: 0, cW: 0)),
            TLV(id: A2687.Field.ac, value: controlStruct(cable: 0x01, profile: 0x01)),
        ])
        let port = try XCTUnwrap(TelemetryDecoder.decode(payload, opcode: 0x0300)?.port(.c1))
        XCTAssertNil(port.chargingProfile)
        XCTAssertEqual(port.cable, .max100W)
        XCTAssertEqual(port.isCableAttached, true)
    }

    func testCablePresenceDistinguishesIdleAttachedEmptyAndUnreportedPorts() {
        let idleAttached = PortTelemetry(
            port: .c1, statusCode: 1, voltage: 0, current: 0, power: 0,
            cable: .epr240W
        )
        let knownEmpty = PortTelemetry(
            port: .c2, statusCode: 1, voltage: 0, current: 0, power: 0,
            cable: CableCapability.none
        )
        let unreportedIdle = PortTelemetry(
            port: .c3, statusCode: 1, voltage: 0, current: 0, power: 0
        )
        let unreportedButDelivering = PortTelemetry(
            port: .c3, statusCode: 1, voltage: 5, current: 1, power: 5
        )

        XCTAssertEqual(idleAttached.isCableAttached, true)
        XCTAssertEqual(knownEmpty.isCableAttached, false)
        XCTAssertNil(unreportedIdle.isCableAttached)
        XCTAssertEqual(unreportedButDelivering.isCableAttached, true)
    }

    func testShortControlStructReportsNothingRatherThanAGuess() throws {
        // The pre-12-byte reader took the tail of whatever it was given, so a
        // truncated or realigned struct produced a confident, wrong cable rating.
        let payload = try report([
            TLV(id: A2687.Field.a5, value: portStruct(status: 1, mV: 9000, mA: 2200, cW: 1980)),
            TLV(id: A2687.Field.ac, value: TypedValue.bytes([0x00, 0x00, 0x02, 0x01]).encoded),
        ])
        let port = try XCTUnwrap(TelemetryDecoder.decode(payload, opcode: 0x0300)?.port(.c1))
        XCTAssertNil(port.control)
        XCTAssertNil(port.cable)
        XCTAssertNil(port.chargingProfile)
    }

    func testPayloadWithoutPortStructIsNotASnapshot() throws {
        let payload = try report([TLV(id: A2687.Field.a1, value: [0x21])])
        XCTAssertNil(TelemetryDecoder.decode(payload, opcode: A2687.Opcode.readAll))
        // The same frame still decodes for diagnostics; only the live-reading
        // path drops it, which is what `hasPortData` is there to distinguish.
        let frame = TelemetryDecoder.decodeFrame(payload, opcode: A2687.Opcode.readAll)
        XCTAssertFalse(frame.hasPortData)
        XCTAssertEqual(frame.allFields[A2687.Field.a1], [0x21])
    }

    func testTruncatedPortStructIsRejected() throws {
        let payload = try report([
            TLV(id: A2687.Field.a5, value: TypedValue.bytes([0x01, 0x20, 0x4E]).encoded),
        ])
        XCTAssertNil(TelemetryDecoder.decode(payload, opcode: 0x0300))
    }

    func testUnknownFieldsArePreservedButUnnamed() throws {
        // 0xB3 is still unsolved on this hardware (it has been seen as 0x01 and as
        // 0xFF and nothing explains either), which is exactly what this bucket is
        // for. B4 used to stand here and no longer qualifies — it is decoded.
        let payload = try report([
            TLV(id: A2687.Field.a5, value: portStruct(status: 1, mV: 5000, mA: 1000, cW: 500)),
            TLV(id: 0xB3, value: [0x01, 0xFF]),
        ])
        let telemetry = try XCTUnwrap(TelemetryDecoder.decode(payload, opcode: 0x0300))
        XCTAssertEqual(telemetry.unknownFields[0xB3], [0x01, 0xFF])
    }

    // MARK: B4 — connected devices

    /// The exact `B4` blocks the owner's charger (v0.0.5.2) sent while cables were
    /// pulled one at a time. Bare bytes, no `TypedValue` prefix: that is how this
    /// field arrives, and the `fa` leading the unplugged captures is the byte that
    /// would shift the whole block by one if the decoder took it for a type tag.
    private enum B4Capture {
        static let c1AndC2: [UInt8] = [
            0xAC, 0x05, 0x09, 0x73, 0xAC, 0x05, 0x18, 0x75, 0xFA, 0xFF, 0xFB, 0xFF,
        ]
        static let c1Unplugged: [UInt8] = [
            0xFA, 0xFF, 0xFB, 0xFF, 0xAC, 0x05, 0x18, 0x75, 0xFA, 0xFF, 0xFB, 0xFF,
        ]
        static let allUnplugged: [UInt8] = [
            0xFA, 0xFF, 0xFB, 0xFF, 0xFA, 0xFF, 0xFB, 0xFF, 0xFA, 0xFF, 0xFB, 0xFF,
        ]
        static let allThreeOccupied: [UInt8] = [
            0xAC, 0x05, 0x19, 0x75, 0xAC, 0x05, 0x09, 0x73, 0x00, 0x00, 0x00, 0x00,
        ]
    }

    private func frame(b4 block: [UInt8]) throws -> ChargerTelemetry {
        let payload = try report([
            TLV(id: A2687.Field.a5, value: portStruct(status: 1, mV: 9000, mA: 2000, cW: 1800)),
            TLV(id: A2687.Field.a6, value: portStruct(status: 1, mV: 9000, mA: 1000, cW: 900)),
            TLV(id: A2687.Field.a7, value: portStruct(status: 1, mV: 5000, mA: 500, cW: 250)),
            TLV(id: A2687.Field.b4, value: block),
        ])
        return TelemetryDecoder.decodeFrame(payload, opcode: A2687.Opcode.readAll)
    }

    private func device(_ frame: ChargerTelemetry, _ port: A2687.Port) throws -> USBDeviceID {
        try XCTUnwrap(XCTUnwrap(frame.port(port)).connectedDevice)
    }

    func testOneTwelveByteB4CarriesAllThreePorts() throws {
        let frame = try frame(b4: B4Capture.c1AndC2)
        // Not three TLVs, not B4/B5/B6: one id, once, twelve bytes.
        XCTAssertEqual(frame.allFields.occurrences(of: A2687.Field.b4), 1)

        let c1 = try device(frame, .c1)
        XCTAssertEqual(c1.vendorID, 0x05AC)  // Apple
        XCTAssertEqual(c1.productID, 0x7309)
        XCTAssertEqual(c1.hexDescription, "05AC:7309")
        XCTAssertEqual(try device(frame, .c2).hexDescription, "05AC:7518")
        XCTAssertTrue(try device(frame, .c3).isNoIdentity)
    }

    func testUnpluggingOnePortOnlyChangesThatPortsRecord() throws {
        let oneGone = try frame(b4: B4Capture.c1Unplugged)
        // C2 holding still while C1 flipped to the sentinel is what pins the slot
        // order to C1, C2, C3 — and this block starts with 0xFA, so it also proves
        // the type-prefix fallback keeps the twelve bytes aligned.
        XCTAssertTrue(try device(oneGone, .c1).isNoIdentity)
        XCTAssertEqual(try device(oneGone, .c2).hexDescription, "05AC:7518")
        XCTAssertTrue(try device(oneGone, .c3).isNoIdentity)

        let allGone = try frame(b4: B4Capture.allUnplugged)
        XCTAssertTrue(try A2687.Port.allCases.allSatisfy { try device(allGone, $0).isNoIdentity })
    }

    func testAttachedButUnidentifiedIsNotAnEmptyPort() throws {
        // All three ports occupied, and C3 reported 00 00 00 00 the whole time it
        // was charging. Reading that as "empty" would blank an occupied port.
        let frame = try frame(b4: B4Capture.allThreeOccupied)
        let c3 = try device(frame, .c3)
        XCTAssertFalse(c3.isNoIdentity)
        XCTAssertTrue(c3.isUnidentified)
        XCTAssertEqual(c3.hexDescription, "0000:0000")

        let c1 = try device(frame, .c1)
        XCTAssertFalse(c1.isUnidentified)
        XCTAssertEqual(c1.hexDescription, "05AC:7519")
    }

    func testShortB4YieldsFewerPortsRatherThanAGuess() throws {
        let frame = try frame(b4: Array(B4Capture.c1AndC2.prefix(8)))
        XCTAssertEqual(try device(frame, .c1).hexDescription, "05AC:7309")
        XCTAssertEqual(try device(frame, .c2).hexDescription, "05AC:7518")
        XCTAssertNil(try XCTUnwrap(frame.port(.c3)).connectedDevice)
    }

    func testB4IsNoLongerFiledAsUnknown() throws {
        let frame = try frame(b4: B4Capture.c1AndC2)
        XCTAssertNil(frame.unknownFields[A2687.Field.b4])
        // Still preserved in the wire-order record for callers that need it.
        XCTAssertEqual(frame.allFields[A2687.Field.b4], B4Capture.c1AndC2)
    }

    // MARK: A8 / A9 / AA / AF / B2 — the settings snapshot

    private func settings(_ fields: [TLV]) throws -> DeviceSettings {
        let payload = try report(fields)
        return try XCTUnwrap(
            TelemetryDecoder.decodeFrame(payload, opcode: A2687.Opcode.readAll).settings
        )
    }

    func testFullSettingsSnapshotDecodes() throws {
        let decoded = try settings([
            TLV(id: A2687.Field.a8, value: TypedValue.u8(0x01).encoded),
            TLV(id: A2687.Field.a9, value: TypedValue.u8(0x50).encoded),
            TLV(id: A2687.Field.aa, value: TypedValue.u8(0x01).encoded),
            TLV(id: A2687.Field.af, value: TypedValue.u8(0x03).encoded),
            TLV(id: A2687.Field.b2, value: TypedValue.u8(0x01).encoded),
        ])
        XCTAssertEqual(decoded.screenTimeout, 1)
        XCTAssertEqual(decoded.screenBrightness, 80)
        XCTAssertEqual(decoded.chargingMode, 1)
        XCTAssertEqual(decoded.screenOrientation, 3)
        XCTAssertEqual(decoded.gyroscopeEnabled, true)
        XCTAssertFalse(decoded.isEmpty)
    }

    func testGyroscopeOffDecodesAsFalse() throws {
        let decoded = try settings([
            TLV(id: A2687.Field.b2, value: TypedValue.u8(0x00).encoded),
        ])
        XCTAssertEqual(decoded.gyroscopeEnabled, false)
    }

    func testSettingByteReadsBothTheWrappedAndTheBareShape() throws {
        let bare = try settings([TLV(id: A2687.Field.a9, value: [0x50])])
        XCTAssertEqual(bare.screenBrightness, 80)
        let wrapped = try settings([TLV(id: A2687.Field.a9, value: TypedValue.bytes([0x50]).encoded)])
        XCTAssertEqual(wrapped.screenBrightness, 80)
    }

    func testImplausibleBrightnessIsDroppedNotShown() throws {
        // 0xFF is not a percentage. Whatever A9 would be in that frame, it is not
        // what two cross-session samples showed, so it must not reach a label.
        let decoded = try settings([
            TLV(id: A2687.Field.a9, value: TypedValue.u8(0xFF).encoded),
            TLV(id: A2687.Field.aa, value: TypedValue.u8(0x04).encoded),
        ])
        XCTAssertNil(decoded.screenBrightness)
        XCTAssertEqual(decoded.chargingMode, 4)  // custom, per the official app's enum
    }

    func testWiderSettingShapeIsRefusedRatherThanTruncated() throws {
        let decoded = try settings([TLV(id: A2687.Field.a9, value: TypedValue.u16(80).encoded)])
        XCTAssertNil(decoded.screenBrightness)
        XCTAssertTrue(decoded.isEmpty)
    }

    func testOutOfRangeEnumsAreDroppedRatherThanInvented() throws {
        let decoded = try settings([
            TLV(id: A2687.Field.a8, value: TypedValue.u8(5).encoded),
            TLV(id: A2687.Field.af, value: TypedValue.u8(4).encoded),
            TLV(id: A2687.Field.b2, value: TypedValue.u8(2).encoded),
        ])
        XCTAssertNil(decoded.screenTimeout)
        XCTAssertNil(decoded.screenOrientation)
        XCTAssertNil(decoded.gyroscopeEnabled)
        XCTAssertTrue(decoded.isEmpty)
    }

    func testConfirmedSettingsAreNotFiledAsUnknown() throws {
        let payload = try report([
            TLV(id: A2687.Field.a8, value: [1]),
            TLV(id: A2687.Field.a9, value: [50]),
            TLV(id: A2687.Field.af, value: [2]),
            TLV(id: A2687.Field.b2, value: [1]),
        ])
        let frame = TelemetryDecoder.decodeFrame(payload, opcode: A2687.Opcode.readAll)
        for id in [
            A2687.Field.a8, A2687.Field.a9, A2687.Field.af, A2687.Field.b2,
        ] {
            XCTAssertNil(frame.unknownFields[id])
        }
    }

    func testFrameWithoutSettingsIDsReportsNoSnapshotAtAll() throws {
        // A realtime report says nothing about the settings; it must not be read as
        // "the settings are gone". Callers keep the last non-nil snapshot.
        let payload = try report([
            TLV(id: A2687.Field.a5, value: portStruct(status: 1, mV: 9000, mA: 2000, cW: 1800)),
        ])
        let frame = TelemetryDecoder.decodeFrame(payload, opcode: A2687.Opcode.realtimeReport)
        XCTAssertNil(frame.settings)
    }

    func testDeviceInfoLeavesImplausibleFieldsNil() {
        let info = DeviceInfo.decode(Payload(status: 0, fields: [
            TLV(id: A2687.Field.a2, value: [0xFF, 0xFE]),
            TLV(id: A2687.Field.a4, value: Array("SHORT".utf8)),
        ]))
        XCTAssertNil(info.productName)
        XCTAssertNil(info.serialNumber)
        XCTAssertNil(info.macAddress)
    }
}

final class RedactionTests: XCTestCase {
    func testSerialIsMasked() {
        XCTAssertEqual(Redact.identifier("ASHDEXAMPLE000001"), "ASHD…0001")
        XCTAssertEqual(Redact.identifier(nil), "—")
    }

    func testMacKeepsOnlyTheVendorPrefix() {
        XCTAssertEqual(Redact.mac("AA:BB:CC:DD:EE:FF"), "AA:BB:••:••:••:FF")
    }

    func testPayloadIsSummarisedUnlessRawCaptureIsOn() {
        XCTAssertEqual(Redact.payload([1, 2, 3], rawAllowed: false), "3 B")
        XCTAssertEqual(Redact.payload([1, 2, 3], rawAllowed: true), "010203")
    }
}

final class CommandTests: XCTestCase {
    func testPortOutputMatchesTheReferenceImplementations() throws {
        let message = CommandEncoder.setPortOutput(.c1, on: true, at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(message.group, Frame.sessionGroup)
        XCTAssertEqual(message.opcode, A2687.Opcode.portOutput)
        XCTAssertEqual(message.encryption, .session)
        // SolixBLE PAYLOAD_USB_C1_ON is a10121a2020100a3020101, plus the epoch trailer.
        XCTAssertTrue(message.plaintext.hexString.hasPrefix("a10121a2020100a3020101fe04"))
    }

    func testPortIndexAndStateAreEncodedPerPort() throws {
        XCTAssertTrue(
            CommandEncoder.setPortOutput(.c3, on: false).plaintext.hexString
                .hasPrefix("a10121a2020102a3020100")
        )
    }

    func testTimerUsesAFourByteLittleEndianCountdown() throws {
        let message = CommandEncoder.setPortTimer(.c2, seconds: 1800)
        // 1800 s = 0x708 -> 08 07 00 00, wrapped in typed byte-array 0x04.
        XCTAssertTrue(message.plaintext.hexString.hasPrefix("a10121a2020101a3050408070000"))
    }

    func testReadAllCarriesTheSessionActionAndEpoch() throws {
        let payload = try Payload.parse(CommandEncoder.readAll().plaintext)
        XCTAssertEqual(payload[A2687.Field.a1], [A2687.sessionAction])
        XCTAssertEqual(payload[A2687.Field.timestamp]?.count, 4)
    }
}
