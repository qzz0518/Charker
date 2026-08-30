import Foundation

/// The charger's power-allocation mode: the byte `0x0206` writes into `A2`, and
/// the same byte that comes back in the `AA` settings field.
///
/// An enum on the write side while `DeviceSettings.chargingMode` stays a raw
/// `UInt8` on the read side is deliberate, not an oversight. A code arriving
/// *from* the charger has to reach a bug report exactly as the device sent it,
/// unnamed if we cannot name it; a code we are about to *transmit* is a decision
/// somebody made, and `setChargingMode(4)` reads like a number where `.custom`
/// reads like the decision it is.
///
/// Which codes are actually known differs per case, and the difference matters
/// enough to be queryable — see ``isObservedOnHardware``.
///
/// Not to be confused with `ChargingProfile`, which is the per-port vendor
/// fast-charge handshake the charger reports, not a setting anyone chooses.
public enum ChargingMode: Sendable, Equatable {
    /// `0` — the app calls it "AI mode 2.0".
    ///
    /// **Observed on verified hardware** (firmware v0.0.5.2):
    /// switching the official app from AI mode to standard moved `AA` from 0 to
    /// 1, so both ends of that one transition are first-hand.
    case ai

    /// `1` — the standard mode. Observed on this charger; same experiment as
    /// ``ai``, which is what makes it the other end of a confirmed pair.
    case standard

    /// `4` — the custom allocation mode.
    ///
    /// **Not observed here.** The code comes from the official app's
    /// `chargingProtocol` enum and nothing else: this charger has never been
    /// seen reporting it, and we have never written it. Sending it is a probe,
    /// and a UI that offers it is offering a guess.
    case custom

    /// Any other code, `2` and `3` included — the app names neither and no
    /// capture has shown either. Kept expressible for the same reason
    /// `CableCapability` keeps one: a caller probing a code on purpose should
    /// not have to go around the type, and a code we cannot name must still be
    /// nameable in a report.
    case unknown(UInt8)

    public init(code: UInt8) {
        switch code {
        case 0: self = .ai
        case 1: self = .standard
        case 4: self = .custom
        default: self = .unknown(code)
        }
    }

    public var code: UInt8 {
        switch self {
        case .ai: return 0
        case .standard: return 1
        case .custom: return 4
        case .unknown(let code): return code
        }
    }

    /// True only for the two codes this charger has actually been seen in.
    ///
    /// Exposed rather than left in a comment because it is the difference
    /// between a mode we know exists and a number out of a decompiled enum, and
    /// a caller that puts modes in front of a user needs to be able to tell
    /// those apart without reading this file.
    public var isObservedOnHardware: Bool {
        switch self {
        case .ai, .standard: return true
        case .custom, .unknown: return false
        }
    }
}

/// Values accepted by the display-language command on firmware v0.0.5.2.
public enum DeviceLanguage: UInt8, CaseIterable, Sendable {
    case english = 0
    case simplifiedChinese = 1
    case japanese = 2
    case german = 3
}

/// Values accepted by the display auto-lock command on firmware v0.0.5.2.
public enum ScreenTimeout: UInt8, CaseIterable, Sendable {
    case thirtySeconds = 0
    case oneMinute = 1
    case fiveMinutes = 2
    case thirtyMinutes = 3
    case twelveHours = 4
}

/// Values accepted by the manual display-orientation command on firmware v0.0.5.2.
public enum ScreenOrientation: UInt8, CaseIterable, Sendable {
    case up = 0
    case left = 1
    case down = 2
    case right = 3
}

/// A reversible charger display setting whose complete command was confirmed on
/// the owner's A2687 running firmware v0.0.5.2.
public enum ChargerSetting: Sendable, Equatable {
    case language(DeviceLanguage)
    case screenTimeout(ScreenTimeout)
    case brightness(UInt8)
    case orientation(ScreenOrientation)
    case gyroscope(Bool)

    public var opcode: UInt16 {
        switch self {
        case .language: return A2687.Opcode.deviceLanguage
        case .screenTimeout: return A2687.Opcode.screenTimeout
        case .brightness: return A2687.Opcode.screenBrightness
        case .orientation: return A2687.Opcode.screenOrientation
        case .gyroscope: return A2687.Opcode.gyroscope
        }
    }

    public var value: UInt8 {
        switch self {
        case .language(let language): return language.rawValue
        case .screenTimeout(let timeout): return timeout.rawValue
        case .brightness(let percent): return percent
        case .orientation(let orientation): return orientation.rawValue
        case .gyroscope(let enabled): return enabled ? 1 : 0
        }
    }

    /// Whether a fresh handshake snapshot confirms this setting. Language is
    /// the exception: no language field has been found in `0x0200`, so its ACK
    /// can be reported but not promoted to read-back confirmation.
    public func readbackMatches(_ settings: DeviceSettings?) -> Bool? {
        switch self {
        case .language:
            return nil
        case .screenTimeout(let timeout):
            return settings?.screenTimeout == timeout.rawValue
        case .brightness(let percent):
            return settings?.screenBrightness == percent
        case .orientation(let orientation):
            return settings?.screenOrientation == orientation.rawValue
        case .gyroscope(let enabled):
            return settings?.gyroscopeEnabled == enabled
        }
    }
}

/// Builders for session (group `0x0F`) messages.
///
/// Read commands and the five display-setting writes are used by the product.
/// Each write documents its own evidence and gate: the display family is
/// confirmed on firmware v0.0.5.2, while unverified or port-affecting commands
/// remain behind their explicit safety boundaries in `ChargerSession`.
public enum CommandEncoder {
    public static func timestampBytes(_ date: Date = Date()) -> [UInt8] {
        let seconds = UInt32(truncatingIfNeeded: Int(date.timeIntervalSince1970))
        return [
            UInt8(seconds & 0xFF), UInt8((seconds >> 8) & 0xFF),
            UInt8((seconds >> 16) & 0xFF), UInt8((seconds >> 24) & 0xFF),
        ]
    }

    static func session(_ opcode: UInt16, _ fields: [TLV], at date: Date) -> OutgoingMessage {
        var all: [TLV] = [TLV(id: A2687.Field.a1, value: [A2687.sessionAction])]
        all += fields
        all.append(TLV(id: A2687.Field.timestamp, value: timestampBytes(date)))
        return OutgoingMessage(
            group: Frame.sessionGroup, opcode: opcode,
            plaintext: TLVCodec.encode(all), encryption: .session, expectsResponse: true
        )
    }

    /// `0x0200` — full device state snapshot.
    public static func readAll(at date: Date = Date()) -> OutgoingMessage {
        session(A2687.Opcode.readAll, [], at: date)
    }

    /// `0x020A` — the "bluetooth bind success" getter.
    ///
    /// The official app puts the account id in `A3`. Public reference clients drop
    /// it, but they had no correct id to send: an identity that is not the bound
    /// one is worse than none. With the real account id available, matching the
    /// official app is the safer bet, so `A3` is included whenever we have one.
    public static func realtimeProbe(
        countryCode: String, ownerUserID: String? = nil, at date: Date = Date()
    ) -> OutgoingMessage {
        var fields = [TLV(id: A2687.Field.a2, value: TypedValue.bytes(Array(countryCode.utf8)).encoded)]
        if let ownerUserID, !ownerUserID.isEmpty {
            fields.append(TLV(id: A2687.Field.a3, value: TypedValue.bytes(Array(ownerUserID.utf8)).encoded))
        }
        fields.append(TLV(id: A2687.Field.a5, value: TypedValue.u8(1).encoded))
        return session(A2687.Opcode.bindSuccess, fields, at: date)
    }

    /// `0x020B` — arms the realtime stream. The `A2` block is the enable payload the
    /// official app sends; a bare action-only trigger does nothing.
    public static func realtimeTrigger(at date: Date = Date()) -> OutgoingMessage {
        session(A2687.Opcode.realtimeTrigger, [
            TLV(
                id: A2687.Field.a2,
                value: TypedValue.bytes([0x01, 0x00, 0x03, 0x15, 0x01, 0x01, 0x00, 0x00, 0x00]).encoded
            ),
        ], at: date)
    }

    /// `0x0027` — user authentication, with an explicit identity and optional
    /// password field. The official generator sends `A1`, `A2` and `A3`; the
    /// public reference implementations omit `A3`, and the correct value for it
    /// is not recovered, so this builder exists mainly to probe the firmware.
    public static func userAuth(
        userID: String, password: [UInt8]? = nil, at date: Date = Date()
    ) -> OutgoingMessage {
        var fields = [
            TLV(id: A2687.Field.a1, value: timestampBytes(date)),
            TLV(id: A2687.Field.a2, value: Array(userID.utf8)),
        ]
        if let password {
            fields.append(TLV(id: A2687.Field.a3, value: password))
        }
        return OutgoingMessage(
            group: Frame.negotiationGroup, opcode: A2687.Opcode.userAuth,
            plaintext: TLVCodec.encode(fields), encryption: .session, expectsResponse: true
        )
    }

    /// `0x0207` — turn one port on or off.
    public static func setPortOutput(_ port: A2687.Port, on: Bool, at date: Date = Date()) -> OutgoingMessage {
        session(A2687.Opcode.portOutput, [
            TLV(id: A2687.Field.a2, value: TypedValue.u8(UInt8(port.rawValue)).encoded),
            TLV(id: A2687.Field.a3, value: TypedValue.u8(on ? 1 : 0).encoded),
        ], at: date)
    }

    /// `0x0206` — switches the charger's power-allocation mode.
    ///
    /// Evidence, stated separately for the two halves, because they are not
    /// equally strong. The **opcode** is solid: recovered from the official app
    /// 3.18.0 at runtime and present in both pinned reference clients (SolixBLE
    /// `bb2d398`, WebBLE `ad4355d`). The **payload shape** is structural
    /// inference — it is the `0x0207` layout with one argument instead of two —
    /// and no decrypted capture of the official app writing this frame exists
    /// here to confirm it. Sending it and reading `AA` back is how that gap
    /// closes; see ``ChargerSession/setChargingMode(_:)``.
    ///
    /// The `FE` trailer is the bare four-byte epoch `session(_:_:at:)` appends,
    /// **not** the `FE 05 03` typed u32 every cover command carries. Both live
    /// in this protocol and they are not interchangeable — see
    /// `CoverCommands.message(_:_:at:)` for what reusing the wrong one costs.
    public static func setChargingMode(_ mode: ChargingMode, at date: Date = Date()) -> OutgoingMessage {
        session(A2687.Opcode.chargingMode, [
            TLV(id: A2687.Field.a2, value: TypedValue.u8(mode.code).encoded),
        ], at: date)
    }

    /// Writes one of the five display settings confirmed on firmware v0.0.5.2.
    /// Every command uses the same single typed-u8 `A2` shape; only its opcode
    /// and value change.
    public static func setChargerSetting(
        _ setting: ChargerSetting, at date: Date = Date()
    ) -> OutgoingMessage {
        session(setting.opcode, [
            TLV(id: A2687.Field.a2, value: TypedValue.u8(setting.value).encoded),
        ], at: date)
    }

    /// `0x0209` — auto-off countdown for one port, in seconds.
    public static func setPortTimer(_ port: A2687.Port, seconds: UInt32, at date: Date = Date()) -> OutgoingMessage {
        let value: [UInt8] = [
            UInt8(seconds & 0xFF), UInt8((seconds >> 8) & 0xFF),
            UInt8((seconds >> 16) & 0xFF), UInt8((seconds >> 24) & 0xFF),
        ]
        return session(A2687.Opcode.portTimer, [
            TLV(id: A2687.Field.a2, value: TypedValue.u8(UInt8(port.rawValue)).encoded),
            TLV(id: A2687.Field.a3, value: TypedValue.bytes(value).encoded),
        ], at: date)
    }
}
