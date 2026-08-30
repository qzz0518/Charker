import Foundation
import XCTest
@testable import A2687Protocol

/// Byte-level pins for the write commands.
///
/// `TelemetryTests.CommandTests` already pins the two port writes against the
/// reference implementations' recorded payloads. These cases exist for the
/// charging-mode write, which has no recorded payload anywhere: its layout is
/// inferred from `0x0207`, so the only thing keeping it honest is a test that
/// spells the bytes out and fails the moment somebody "tidies" the encoder.
final class ChargingModeCommandTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    /// `1_700_000_000` = `0x6553F100`, little-endian.
    private let epochHex = "00f15365"

    func testTheWholePlaintextIsPinnedByteForByte() throws {
        let message = CommandEncoder.setChargingMode(.standard, at: epoch)
        XCTAssertEqual(message.group, Frame.sessionGroup)
        XCTAssertEqual(message.opcode, A2687.Opcode.chargingMode)
        XCTAssertEqual(message.opcode, 0x0206)
        XCTAssertEqual(message.encryption, .session)
        XCTAssertTrue(message.expectsResponse)
        // a1 01 21   action, the bare 0x21 every session command carries
        // a2 02 01 01  typed u8, the mode
        // fe 04 …      the bare four-byte epoch
        XCTAssertEqual(message.plaintext.hexString, "a10121a2020101fe04" + epochHex)
    }

    func testEachModeSendsItsOwnCode() throws {
        XCTAssertEqual(
            CommandEncoder.setChargingMode(.ai, at: epoch).plaintext.hexString,
            "a10121a2020100fe04" + epochHex
        )
        XCTAssertEqual(
            CommandEncoder.setChargingMode(.standard, at: epoch).plaintext.hexString,
            "a10121a2020101fe04" + epochHex
        )
        // Never observed on this charger; the code is the official app's. It is
        // pinned so that a probe sends the number somebody actually chose.
        XCTAssertEqual(
            CommandEncoder.setChargingMode(.custom, at: epoch).plaintext.hexString,
            "a10121a2020104fe04" + epochHex
        )
        XCTAssertEqual(
            CommandEncoder.setChargingMode(.unknown(0x07), at: epoch).plaintext.hexString,
            "a10121a2020107fe04" + epochHex
        )
    }

    /// The mode argument is a *typed* u8 (`02 01 vv`), the same shape the port
    /// index uses in `0x0207`. A bare byte would encode as `a201vv` and be one
    /// byte short with no type tag.
    func testTheModeArgumentIsTypedNotBare() throws {
        let payload = try Payload.parse(CommandEncoder.setChargingMode(.standard, at: epoch).plaintext)
        XCTAssertEqual(payload[A2687.Field.a2], [0x01, 0x01])
        XCTAssertEqual(payload.typed(A2687.Field.a2)?.scalar, 1)
    }

    /// The trailer that separates this family from the cover commands: `FE 04`
    /// plus four bare bytes, never the `FE 05 03` typed u32 of `0x021F`/`0x0220`.
    /// Mixing the two up is a silent failure — see `CoverCommands.message`.
    func testTheEpochTrailerIsFourBareBytesNotATypedU32() throws {
        let payload = try Payload.parse(CommandEncoder.setChargingMode(.ai, at: epoch).plaintext)
        let trailer = try XCTUnwrap(payload[A2687.Field.timestamp])
        XCTAssertEqual(trailer.count, 4)
        XCTAssertEqual(trailer, CommandEncoder.timestampBytes(epoch))
        XCTAssertNotEqual(trailer.first, 0x03, "0x03 would be the cover commands' u32 type tag")
    }

    func testTheActionMarkerMatchesTheOtherSessionWrites() throws {
        let mode = try Payload.parse(CommandEncoder.setChargingMode(.standard, at: epoch).plaintext)
        let port = try Payload.parse(CommandEncoder.setPortOutput(.c1, on: true, at: epoch).plaintext)
        XCTAssertEqual(mode[A2687.Field.a1], [A2687.sessionAction])
        XCTAssertEqual(mode[A2687.Field.a1], port[A2687.Field.a1])
    }
}

/// The enum itself. Codes go out on the wire, so the mapping is worth its own
/// cases — and so is which of them anybody has actually seen.
final class ChargingModeTests: XCTestCase {
    func testCodesRoundTrip() {
        XCTAssertEqual(ChargingMode(code: 0), .ai)
        XCTAssertEqual(ChargingMode(code: 1), .standard)
        XCTAssertEqual(ChargingMode(code: 4), .custom)
        XCTAssertEqual(ChargingMode(code: 2), .unknown(2))
        XCTAssertEqual(ChargingMode(code: 0xFF), .unknown(0xFF))

        for code: UInt8 in [0, 1, 2, 3, 4, 5, 0xFF] {
            XCTAssertEqual(ChargingMode(code: code).code, code)
        }
    }

    /// The distinction the UI needs before it offers a mode: `0` and `1` were
    /// judged on the owner's charger, `4` came out of a decompiled enum.
    func testOnlyTheTwoModesThisChargerWasSeenInAreMarkedObserved() {
        XCTAssertTrue(ChargingMode.ai.isObservedOnHardware)
        XCTAssertTrue(ChargingMode.standard.isObservedOnHardware)
        XCTAssertFalse(ChargingMode.custom.isObservedOnHardware)
        XCTAssertFalse(ChargingMode.unknown(2).isObservedOnHardware)
    }
}

/// Byte-for-byte pins for the five display writes confirmed on the real charger.
final class ChargerSettingCommandTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let epochHex = "00f15365"

    func testEverySettingUsesTheConfirmedOpcodeAndTypedU8Shape() throws {
        let cases: [(ChargerSetting, UInt16, UInt8)] = [
            (.language(.english), 0x0202, 0),
            (.language(.simplifiedChinese), 0x0202, 1),
            (.screenTimeout(.oneMinute), 0x0203, 1),
            (.brightness(100), 0x0204, 100),
            (.orientation(.right), 0x020B, 3),
            (.gyroscope(true), 0x020D, 1),
            (.gyroscope(false), 0x020D, 0),
        ]

        for (setting, opcode, value) in cases {
            let message = CommandEncoder.setChargerSetting(setting, at: epoch)
            XCTAssertEqual(message.group, Frame.sessionGroup)
            XCTAssertEqual(message.opcode, opcode)
            XCTAssertEqual(message.encryption, .session)
            XCTAssertTrue(message.expectsResponse)
            XCTAssertEqual(
                message.plaintext.hexString,
                String(format: "a10121a20201%02xfe04", Int(value)) + epochHex
            )
            let payload = try Payload.parse(message.plaintext)
            XCTAssertEqual(payload.typed(A2687.Field.a2), .u8(value))
        }
    }

    func testLanguageCodesMatchTheOfficialApp() {
        XCTAssertEqual(DeviceLanguage.allCases.map(\.rawValue), [0, 1, 2, 3])
    }

    func testTimeoutAndOrientationCodesAreStable() {
        XCTAssertEqual(ScreenTimeout.allCases.map(\.rawValue), [0, 1, 2, 3, 4])
        XCTAssertEqual(ScreenOrientation.allCases.map(\.rawValue), [0, 1, 2, 3])
    }

    func testFreshSnapshotCanConfirmEveryReadableSetting() {
        let snapshot = DeviceSettings(
            screenTimeout: 1,
            screenBrightness: 100,
            screenOrientation: 3,
            gyroscopeEnabled: true
        )
        XCTAssertNil(ChargerSetting.language(.english).readbackMatches(snapshot))
        XCTAssertEqual(ChargerSetting.screenTimeout(.oneMinute).readbackMatches(snapshot), true)
        XCTAssertEqual(ChargerSetting.brightness(100).readbackMatches(snapshot), true)
        XCTAssertEqual(ChargerSetting.orientation(.right).readbackMatches(snapshot), true)
        XCTAssertEqual(ChargerSetting.gyroscope(true).readbackMatches(snapshot), true)
        XCTAssertEqual(ChargerSetting.brightness(25).readbackMatches(snapshot), false)
    }
}
