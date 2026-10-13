import Foundation
import XCTest
@testable import A2345Protocol

/// Write frames and readback decoding for the control surface. Expected
/// frames come from the official app 3.24.0 encoder rules; the ones marked
/// "capture" are byte-for-byte frames the official app sent or the charger
/// answered with (anker-solix-api discussion #252, firmware 2.1.1.2).
final class A2345ControlTests: XCTestCase {
    private let stampA = Date(timeIntervalSince1970: TimeInterval(0x6ABD_CCE3))
    private let stampB = Date(timeIntervalSince1970: TimeInterval(0x68E7_7800))

    // MARK: - Encoder

    func testSingleByteSettingsMatchOfficialEncoder() throws {
        XCTAssertEqual(
            try A2345Command.setScreenTimeout(.thirtySeconds).encode(at: stampA).hex,
            "ff09180003000f0203a10122a2020101fe0503e3ccbd6ac1"
        )
        XCTAssertEqual(
            try A2345Command.setBrightness(50).encode(at: stampA).hex,
            "ff09180003000f0204a10122a2020132fe0503e3ccbd6af5"
        )
        XCTAssertEqual(
            try A2345Command.themeStatus.encode(at: stampA).hex,
            "ff09140003000f0202a10122fe0503e3ccbd6a6c"
        )
    }

    func testClockScheduleUsesFiveByteBinaryValue() throws {
        let schedule = A2345ClockSchedule(
            startHour: 8, startMinute: 0, endHour: 23, endMinute: 0, weekdays: 0x7F
        )
        XCTAssertEqual(
            try A2345Command.setClockSchedule(schedule).encode(at: stampA).hex,
            "ff091c0003000f0213a10122a20604080017007ffe0503e3ccbd6ab5"
        )
    }

    func testPortOutputMatchesCapturedOfficialFrameLayout() throws {
        // Capture (C1 on): ff091c0003000f0207 a10122 a2020100 a3020101 fe0503<ts> <xor>
        XCTAssertEqual(
            try A2345Command.setPortOutput(.c1, on: true).encode(at: stampB).hex,
            "ff091c0003000f0207a10122a2020100a3020101fe05030078e7686e"
        )
        let usbAOff = try A2345Command.setPortOutput(.usbA, on: false).encode(at: stampB)
        XCTAssertEqual(Array(usbAOff[12...19]), [0xA2, 0x02, 0x01, 0x04, 0xA3, 0x02, 0x01, 0x00])
    }

    func testPortScheduleCarriesFourByteVariableValue() throws {
        let schedule = A2345PortSchedule(isEnabled: true, hour: 7, minute: 30, weekdays: 0x1F)
        XCTAssertEqual(
            try A2345Command.setPortSchedule(.c2, .powerOn, schedule).encode(at: stampB).hex,
            "ff09230003000f0208a10122a2020101a3020101a4050301071e1ffe05030078e768fa"
        )
    }

    func testCountdownCarriesSwitchAndSeconds() throws {
        let frame = try A2345Command.setPortCountdown(.c1, enabled: true, seconds: 900).encode(at: stampB)
        XCTAssertEqual(
            Array(frame[12...23]).hex,
            "a2020100a306040184030000"
        )
        XCTAssertThrowsError(try A2345Command.setPortCountdown(.c1, enabled: true, seconds: 90_000).encode())
    }

    func testCustomModeMatchesCapturedProfileAndProtocols() throws {
        // Captured by ha-anker-prime-charger: a3=01000f1619140f, a4=0200000b00000b0000020000
        let profile = A2345CustomChargingProfile(number: 1, autoExit: false, watts: [15, 22, 25, 20, 15])
        let protocols = A2345PortProtocols(ports: [
            [.ufcs],
            [.scp, .ufcs, .pps11V],
            [.scp, .ufcs, .pps11V],
            [.ufcs],
        ])
        let frame = try A2345Command.setCustomChargingMode(profile, protocols: protocols).encode(at: stampB)
        let decoded = try A2345PacketCodec.decode(frame)
        XCTAssertEqual(decoded.messageType, 0x0206)
        XCTAssertEqual(decoded.fields.map(\.id), [0xA1, 0xA2, 0xA3, 0xA4, 0xFE])
        XCTAssertEqual(decoded.fields[1].rawValue, [0x01, 0x05])
        XCTAssertEqual(decoded.fields[2].rawValue.hex, "0401000f1619140f")
        XCTAssertEqual(decoded.fields[3].rawValue.hex, "040200000b00000b0000020000")
    }

    func testCustomModeRejectsValuesTheOfficialAppNeverSends() {
        let bad: [[UInt8]] = [
            [10, 0, 0, 0, 0],      // C port inside the 1…14 W gap
            [140, 100, 0, 0, 20],  // USB-A only takes 0, 15 or 24
            [140, 100, 100, 0, 0], // over 250 W in total
        ]
        for watts in bad {
            let profile = A2345CustomChargingProfile(number: 1, autoExit: false, watts: watts)
            XCTAssertThrowsError(try A2345Command.setCustomChargingMode(profile, protocols: nil).encode())
        }
    }

    func testInvertedAndPlainSwitches() throws {
        XCTAssertEqual(try A2345Command.setMaxCompatibility(true).encode(at: stampA)[15], 0x00)
        XCTAssertEqual(try A2345Command.setMaxCompatibility(false).encode(at: stampA)[15], 0x01)
        XCTAssertEqual(try A2345Command.setDeviceIdentification(true).encode(at: stampA)[15], 0x01)
        XCTAssertEqual(try A2345Command.exitCustomChargingMode.encode(at: stampA)[15], 0x00)
        XCTAssertEqual(try A2345Command.setMaxCompatibility(true).acknowledgementType, 0x0A14)
        XCTAssertNil(A2345Command.statusSnapshot.acknowledgementType)
    }

    func testCancellingEchoesAnyReportedTotal() throws {
        let frame = try A2345Command.setPortCountdown(.c3, enabled: false, seconds: 100_000).encode(at: stampA)
        let decoded = try A2345PacketCodec.decode(frame)
        XCTAssertEqual(decoded.fields[2].rawValue, [0x04, 0x00, 0xA0, 0x86, 0x01, 0x00])
    }

    func testScheduleAcknowledgementEchoesPortAndSlot() throws {
        let frame = A2345Frame(
            pattern: A2345FramePattern(version: 3, speaker: 1, group: 15),
            messageType: 0x0A08,
            increment: 0,
            fields: [
                A2345TLV(id: 0xA1, rawValue: [0x34]),
                A2345TLV(id: 0xA2, rawValue: [1, 1]),
                A2345TLV(id: 0xA3, rawValue: [1, 1]),
            ],
            encodedLength: 0,
            checksum: 0
        )
        XCTAssertEqual(
            try A2345MessageDecoder.decode(frame),
            .acknowledgement(A2345WriteAcknowledgement(messageType: 0x0A08, status: 0, group: .c2, slot: .powerOn))
        )
    }

    func testPriorityAllowsAtMostTwoCPorts() {
        XCTAssertNoThrow(try A2345Command.setPortPriority(0b0101).encode())
        XCTAssertThrowsError(try A2345Command.setPortPriority(0b0111).encode())
        XCTAssertThrowsError(try A2345Command.setPortPriority(0b1_0000).encode())
    }

    func testBuiltInThemeSendsEmptyIDAndAssetPath() throws {
        let request = A2345ClockThemeRequest(
            clockOn: true,
            kind: .style2,
            themeID: nil,
            imageCRC: 0,
            url: A2345ClockThemeRequest.builtInStyleURL(.style2)
        )
        let decoded = try A2345PacketCodec.decode(A2345Command.setClockTheme(request).encode(at: stampA))
        XCTAssertEqual(decoded.fields.map(\.id), [0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xFE])
        XCTAssertEqual(decoded.fields[1].rawValue, [0x01, 0x81])
        XCTAssertEqual(decoded.fields[2].rawValue, [0x04])
        XCTAssertEqual(decoded.fields[4].rawValue, [0x03, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(
            String(bytes: decoded.fields[5].rawValue.dropFirst(), encoding: .utf8),
            "assets/img/a2345/icl_a2345_theme2.png"
        )
    }

    func testCustomPictureUsesLongA7() throws {
        let url = "https://example.com/" + String(repeating: "x", count: 180)
        let request = A2345ClockThemeRequest(
            clockOn: true, kind: .custom, themeID: 77, imageCRC: 0x1234_5678,
            url: "", customURL: url
        )
        let frame = try A2345Command.setClockTheme(request).encode(at: stampA)
        let a7 = try XCTUnwrap(frame.firstIndex(of: 0xA7))
        let length = Int(frame[a7 + 1]) | Int(frame[a7 + 2]) << 8
        XCTAssertEqual(length, url.utf8.count + 1)
        XCTAssertEqual(frame[a7 + 3], 0x04)
        XCTAssertEqual(A2345PacketCodec.checksum(frame[0..<(frame.count - 1)]), frame.last)
    }

    // MARK: - Readback

    func testDecodesCapturedFullSnapshotSettings() throws {
        let frame = try A2345PacketCodec.decode(Self.capturedSnapshot.a2345HexBytes)
        guard case .statusSnapshot(let snapshot) = try A2345MessageDecoder.decode(frame) else {
            return XCTFail("expected snapshot")
        }
        let settings = snapshot.settings
        XCTAssertEqual(settings.firmwareVersion, "2.1.1.2")
        XCTAssertEqual(settings.errorCode, 0)
        XCTAssertFalse(settings.hasFault)
        XCTAssertEqual(settings.portControls.count, 5)

        let c1 = try XCTUnwrap(settings.portControls[.c1])
        XCTAssertFalse(c1.isOn)
        XCTAssertTrue(c1.powerOn.isUnset)
        XCTAssertEqual(c1.powerOn.hour, 12)
        XCTAssertEqual(c1.countdownTotal, 2_100)
        XCTAssertEqual(c1.priority, 0)

        let c4 = try XCTUnwrap(settings.portControls[.c4])
        XCTAssertEqual(c4.powerOn, A2345PortSchedule(rawSwitch: 0, hour: 8, minute: 0, weekdays: 2))
        XCTAssertEqual(c4.powerOff, A2345PortSchedule(rawSwitch: 0, hour: 23, minute: 0, weekdays: 2))
        XCTAssertEqual(c4.countdownTotal, 600)

        XCTAssertEqual(settings.clock, A2345ClockState(isOn: false, holidayEnabled: false, themeCode: 1))
        XCTAssertEqual(settings.screenTimeout, .thirtySeconds)
        XCTAssertEqual(settings.chargingModeCode, 5)
        XCTAssertTrue(settings.isCustomChargingMode)
        XCTAssertEqual(settings.isUpdatingFirmware, false)
        XCTAssertEqual(settings.brightness, 20)
        XCTAssertEqual(settings.knobDirection, .backward)
        XCTAssertEqual(settings.hourFormat, .twentyFourHour)
        XCTAssertEqual(settings.protocolVersion, 1)
        XCTAssertEqual(settings.capabilities?.rawValue, 0x02FF)
        XCTAssertTrue(settings.supports(.maxCompatibility))
        XCTAssertFalse(settings.supports(.ufcsSwitch))
        XCTAssertEqual(settings.customProfile, A2345CustomChargingProfile(
            number: 1, autoExit: false, watts: [15, 15, 15, 15, 15]
        ))
        XCTAssertEqual(settings.clockSchedule, A2345ClockSchedule(
            startHour: 8, startMinute: 0, endHour: 23, endMinute: 0, weekdays: 0x7F
        ))
        XCTAssertEqual(settings.portProtocols?.ports, Array(repeating: [.scp, .ufcs], count: 4))
        XCTAssertEqual(settings.maxCompatibility, false)
        // BC is present but bit 8 is clear, so the official app ignores it.
        XCTAssertNil(settings.ufcs)
        // Bit 9 is set but this firmware sends no BF.
        XCTAssertNil(settings.deviceIdentification)
        XCTAssertEqual(settings.connectedDeviceUSB.count, 4)
        XCTAssertTrue(settings.connectedDeviceUSB.allSatisfy(\.isEmpty))
    }

    func testDecodesCapturedThemeStatus() throws {
        let frame = try A2345PacketCodec.decode(
            "ff09270003010f0a0200a10164a2020101a3050400000000a40104a6020101fe050370428f693b".a2345HexBytes
        )
        XCTAssertEqual(try A2345MessageDecoder.decode(frame), .settingsUpdate([
            .themeStatus(
                A2345ClockState(isOn: false, holidayEnabled: false, themeCode: 1, isShowingHoliday: false),
                customImageTimeDisplay: true
            ),
        ]))
    }

    func testDecodesCapturedPortSwitchPushAndAcknowledgement() throws {
        let push = try A2345PacketCodec.decode(
            "ff091c0003010f0302a10164a2020100a3020101fe05034c048e6975".a2345HexBytes
        )
        XCTAssertEqual(try A2345MessageDecoder.decode(push), .settingsUpdate([.portOutput(.c1, isOn: true)]))

        let ack = try A2345PacketCodec.decode(
            "ff09190003010f0a0700a10134a2020100fe050393588e690e".a2345HexBytes
        )
        XCTAssertEqual(
            try A2345MessageDecoder.decode(ack),
            .acknowledgement(A2345WriteAcknowledgement(messageType: 0x0A07, status: 0, group: .c1))
        )

        let short = try A2345PacketCodec.decode(A2345Fixtures.realtimeAcknowledgement.a2345HexBytes)
        XCTAssertEqual(
            try A2345MessageDecoder.decode(short),
            .acknowledgement(A2345WriteAcknowledgement(messageType: 0x0A0B, status: 0))
        )
    }

    func testDecodesCapturedVersionFrameWithoutTypeBytes() throws {
        let frame = try A2345PacketCodec.decode(
            "ff093e0003000f083000a10876302e322e392e37a20876322e312e312e32a3054132333435a40941323334355f6d6375a50b41323334355f65737033320b".a2345HexBytes
        )
        let version = try A2345MessageDecoder.decodeVersionInfo(frame)
        XCTAssertEqual(version.hardwareVersion, "v0.2.9.7")
        XCTAssertEqual(version.softwareVersion, "2.1.1.2")
        XCTAssertEqual(version.productCode, "A2345")
    }

    func testPushesMergeIntoSettings() throws {
        var settings = try XCTUnwrap({
            let frame = try A2345PacketCodec.decode(Self.capturedSnapshot.a2345HexBytes)
            return try A2345MessageDecoder.decodeStatusSnapshot(frame).settings
        }())

        settings.apply(.portCountdown(.c2, enabled: true, total: 3_600, remaining: 3_000))
        XCTAssertEqual(settings.portControls[.c2]?.countdownRemaining, 3_000)
        settings.apply(.portOutput(.c2, isOn: false))
        XCTAssertEqual(settings.portControls[.c2]?.countdownEnabled, false)
        XCTAssertEqual(settings.portControls[.c2]?.countdownTotal, 0)

        settings.apply(.chargingMode(code: 2, profile: nil, priority: 0b0011))
        XCTAssertEqual(settings.chargingMode, .portPriority)
        XCTAssertEqual(settings.priorityBitmap, 0b0011)
        settings.apply(.chargingMode(code: 1, profile: nil, priority: nil))
        XCTAssertEqual(settings.priorityBitmap, 0)

        settings.apply(.errorCode(0b0100))
        XCTAssertTrue(settings.hasFault)
        XCTAssertTrue(settings.hasFault(.c2))
        XCTAssertFalse(settings.hasFault(.c1))
        settings.apply(.errorCode(1))
        XCTAssertTrue(settings.isOverTemperature)
        XCTAssertFalse(settings.hasFault(.c2))
    }

    func testDecodesChangeMessages() throws {
        func decode(_ type: UInt16, _ fields: [A2345TLV]) throws -> A2345DecodedMessage {
            try A2345MessageDecoder.decode(A2345Frame(
                pattern: A2345FramePattern(version: 3, speaker: 1, group: 15),
                messageType: type,
                increment: nil,
                fields: [A2345TLV(id: 0xA1, rawValue: [0x64])] + fields,
                encodedLength: 0,
                checksum: 0
            ))
        }
        XCTAssertEqual(
            try decode(0x0307, [
                A2345TLV(id: 0xA2, rawValue: [1, 4]),
                A2345TLV(id: 0xA3, rawValue: [4, 1, 0x84, 3, 0, 0, 0x58, 2, 0, 0]),
            ]),
            .settingsUpdate([.portCountdown(.usbA, enabled: true, total: 900, remaining: 600)])
        )
        XCTAssertEqual(
            try decode(0x0308, [
                A2345TLV(id: 0xA2, rawValue: [1, 0]),
                A2345TLV(id: 0xA3, rawValue: [1, 1]),
                A2345TLV(id: 0xA4, rawValue: [3, 1, 8, 0, 0x1F]),
            ]),
            .settingsUpdate([.portSchedule(.c1, .powerOn, A2345PortSchedule(
                isEnabled: true, hour: 8, minute: 0, weekdays: 0x1F
            ))])
        )
        XCTAssertEqual(
            try decode(0x030D, [
                A2345TLV(id: 0xA2, rawValue: [1, 5]),
                A2345TLV(id: 0xA3, rawValue: [4, 1, 0, 15, 15, 15, 15, 15]),
                A2345TLV(id: 0xA4, rawValue: [1, 3]),
            ]),
            .settingsUpdate([.chargingMode(
                code: 5,
                profile: A2345CustomChargingProfile(number: 1, autoExit: false, watts: [15, 15, 15, 15, 15]),
                priority: 3
            )])
        )
        XCTAssertEqual(
            try decode(0x0309, [A2345TLV(id: 0xA2, rawValue: [1, 0x13])]),
            .settingsUpdate([.screenTimeout(3)])
        )
        XCTAssertEqual(
            try decode(0x0311, [
                A2345TLV(id: 0xA2, rawValue: [3, 9, 0, 0, 0]),
                A2345TLV(id: 0xA3, rawValue: [1, 1]),
                A2345TLV(id: 0xA4, rawValue: [1, 3]),
            ]),
            .settingsUpdate([.themeDownload(themeID: 9, status: 1, themeCode: 3)])
        )
    }

    /// Capture of a 303-byte `0x0A00` (firmware 2.1.1.2, custom mode active).
    static let capturedSnapshot =
        "ff092f0103010f0a0000a10164a203024008a303020000a4080400000000000000a5080400000000000000a6080400000000000000a7080400000000000000a8080400000000000000a9080400000000000000aa140400ff0c0000ff0c000000340800000000000000ab140400ff0c0000ff0c000000201c00000000000000ac140400000c0000000c000000201c00000000000000ad140400000800020017000200580200000000000000ae140400ff0c0000ff0c000000701700000000000000af06040100000000b0020101b1020105b203040000b3020114b4020101b5020101b6020101b70302ff02b8080401000f0f0f0f0fb90604080017007fba0d04030000030000030000030000bb020101bc020101bd1104fafffbfffafffbfffafffbfffafffbfffe050370428f69e4"
}

private extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private extension ArraySlice where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
