import Foundation

/// TLV ids this decoder reads that `Opcodes.swift` does not name, because they
/// were found by diffing live frames rather than in either pinned reference
/// implementation.
///
/// Every id here was settled on the owner's own A2687 (firmware v0.0.5.2) through
/// controlled cross-session comparisons. What each one is taken to mean, and on
/// how much evidence, is stated per field.
extension A2687.Field {
    /// Screen brightness, one byte, percent.
    ///
    /// Confirmed on this charger: with the display at 80 % the byte read `0x50`,
    /// and after setting the display to 50 % it read `0x32`. Two independent
    /// cross-session samples, both exact. Same quantity the official app writes
    /// as `lcdBacklightBrightness` (`0x0204`, 0–100).
    ///
    /// A settings snapshot, not a live reading — see `DeviceSettings`.
    public static let a9: UInt8 = 0xA9

    /// Charging mode, one byte: `0` = AI, `1` = standard, `4` = custom.
    ///
    /// Confirmed on this charger: switching it from "AI mode 2.0" to standard
    /// moved this byte 0 → 1, matching the official app's own enum
    /// (`chargingProtocol`, written with `0x0206`).
    ///
    /// A settings snapshot, not a live reading — see `DeviceSettings`.
    public static let aa: UInt8 = 0xAA

    /// Gyroscope auto-rotation switch, one byte: `0` off, `1` on. Confirmed by
    /// writing `0x020D`, reconnecting, and observing `B2` move from 0 to 1 while
    /// the physical display began rotating with the charger.
    public static let b2: UInt8 = 0xB2

    /// Connected-device identity: three `VID(2 LE) + PID(2 LE)` records packed
    /// into one 12-byte TLV, C1/C2/C3 in order. Confirmed on this charger by
    /// unplugging one port at a time — see
    /// `TelemetryDecoder.decodeConnectedDevices` for the byte sequences.
    public static let b4: UInt8 = 0xB4

    // Ruled out on this charger. Written down because this is a guess the next
    // reader will make again from the official app's field names.
    //
    // **`AB` is not the protocol-management state.** The official app showed C1
    // with all six protocols off while `AB[5]` was `0x0b` (three bits set), and
    // `AB` did not move by a single byte when the charging mode was switched.
    // `AB[2..4]` is `14 28 64` = 20 / 40 / 100 W, which sums to this charger's
    // 160 W and stayed put with every port unplugged — a configured allocation
    // table, not a live reading. Best remaining guess is the custom-mode profile
    // (`0x0206`); protocol management itself goes through the cloud (`0x021D`).
}

/// Cable capability reported in the port control struct.
/// (Evidence: WebBLE `A17A5_CABLE_CAPABILITY_LABELS` @ ad4355d.)
public enum CableCapability: Sendable, Equatable {
    case max60W       // 0x00, 3A
    case max100W      // 0x01, 5A
    case epr240W      // 0x02
    case none         // 0x03, nothing attached / not reported
    case unknown(UInt8)

    public init(code: UInt8) {
        switch code {
        case 0x00: self = .max60W
        case 0x01: self = .max100W
        case 0x02: self = .epr240W
        case 0x03: self = .none
        default: self = .unknown(code)
        }
    }

    public var label: String? {
        switch self {
        case .max60W: return "3A · 60 W"
        case .max100W: return "5A · 100 W"
        case .epr240W: return "EPR · 240 W"
        case .none: return nil
        case .unknown(let code): return String(format: "Unknown (0x%02X)", code)
        }
    }
}

/// Vendor fast-charge handshake reported alongside the cable capability.
public enum ChargingProfile: Sendable, Equatable {
    case applePD
    case samsungFast
    case samsungSuperFast
    case unknown(UInt8)

    public init?(code: UInt8) {
        switch code {
        case 0x00: return nil
        case 0x01: self = .applePD
        case 0x02: self = .samsungFast
        case 0x03: self = .samsungSuperFast
        default: self = .unknown(code)
        }
    }

    public var label: String {
        switch self {
        case .applePD: return "Apple PD"
        case .samsungFast: return "Samsung Fast"
        case .samsungSuperFast: return "Samsung Super Fast"
        case .unknown(let code): return String(format: "Unknown (0x%02X)", code)
        }
    }
}

/// USB identity of whatever is plugged into a port, from the `B4` block.
///
/// Deliberately no vendor-name lookup here: the name is presentation, and a
/// confidently wrong "Samsung" is worse than a hex id the user can search.
public struct USBDeviceID: Sendable, Equatable {
    /// An empty port is written as `FFFA:FFFB`, not as zeros.
    ///
    /// Confirmed on the owner's charger, not borrowed: unplugging C1 turned its
    /// four bytes into `fa ff fb ff` while C2's record sat untouched, and
    /// unplugging C2 as well left all three records reading the sentinel. The
    /// `fa ff fb ff` in SolixBLE's `tests/test_devices.py` fixture is now
    /// corroboration from a second unit rather than the only evidence there was.
    public static let emptyVendorID: UInt16 = 0xFFFA
    public static let emptyProductID: UInt16 = 0xFFFB

    public var vendorID: UInt16
    public var productID: UInt16

    public init(vendorID: UInt16, productID: UInt16) {
        self.vendorID = vendorID
        self.productID = productID
    }

    /// The firmware reported no USB identity for this slot.
    ///
    /// **Not** "the port is empty" — this says nothing about occupancy. In the
    /// owner's own capture (charker-tlv3-mode.swift, session #7) all three
    /// slots read `fa ff fb ff` while the ports were drawing 9.4 W, 21.2 W and
    /// 19.6 W. Whether anything is plugged in is `PortTelemetry.isOn` and the
    /// live volts and amps beside it, never this.
    public var isNoIdentity: Bool {
        vendorID == Self.emptyVendorID && productID == Self.emptyProductID
    }

    /// Something is plugged in that never handed over a USB identity.
    ///
    /// A distinct state from `isNoIdentity`, and both were seen on this charger in the
    /// same session: with all three ports occupied, C1/C2 reported Apple ids
    /// while C3 read `00 00 00 00` the whole time it was charging. Collapsing the
    /// two into one "unknown" would have the UI call an occupied port empty.
    public var isUnidentified: Bool { vendorID == 0 && productID == 0 }

    /// `04E8:6860` — the form a USB id database is searched by.
    public var hexDescription: String { String(format: "%04X:%04X", vendorID, productID) }
}

/// The per-port control struct carried in `AC`/`AD`/`AE`.
///
/// This is Anker's own `CPowerControl` (WebBLE names the struct in a comment
/// @ ad4355d), but only the last two bytes have ever been *observed* to change.
/// Every captured frame shows the first ten as `01 00 2c 01 00 00 2c 01 00 00`
/// — an idle 300 s placeholder — so the split below is inferred from the field
/// names and is NOT verified on hardware. Nothing but `cable`/`chargingProfile`
/// may reach the UI until it is.
///
/// How to settle it: write one `0x0209` port timer with a distinctive value
/// (1234 s = `d2 04 00 00`), read `AC` back, and see which four bytes take that
/// value and which of the two counts down.
public struct PortControl: Sendable, Equatable {
    /// The byte pattern every fixture shows for an idle port. Kept as a constant
    /// so the diagnostics view can say "still the idle default" instead of
    /// dressing up an unverified guess as a reading.
    public static let idleDefaultPrefix: [UInt8] = [
        0x01, 0x00, 0x2C, 0x01, 0x00, 0x00, 0x2C, 0x01, 0x00, 0x00,
    ]

    /// Byte 0, `cSwitchStatus`. Unverified.
    public var switchStatus: UInt8
    /// Byte 1, `countdownTaskStatus`. Unverified.
    public var countdownTaskStatus: UInt8
    /// Bytes 2..5, `countdownTime`, seconds. Unverified.
    public var countdownTotal: UInt32
    /// Bytes 6..9, `countdownRemainTime`, seconds. Unverified.
    public var countdownRemaining: UInt32
    /// Byte 10, `cableInfo`. The one byte here that real hardware has been seen
    /// to change.
    public var cableCode: UInt8
    /// Byte 11. Anker's struct calls this `deviceVID`, but a 16-bit USB VID does
    /// not fit in one byte and the observed 01/02/03 line up exactly with the
    /// Apple-PD / Samsung-Fast / Samsung-Super-Fast table, so this build reads it
    /// as a charging profile. That is our call, not Anker's — the real VID
    /// arrives separately in `B4`, and the naming disagreement is unresolved.
    ///
    /// Unlike the countdown bytes above, this reading *is* confirmed on the
    /// owner's own charger: docs/real-device-findings.md 4.6 records C1 and C3
    /// both identified as Apple PD alongside a correctly read EPR/240 W cable.
    /// That is why it is allowed on the port card while bytes 0..9 are not.
    public var profileCode: UInt8
    /// Anything past byte 11. Real firmware has only ever sent 12, but a longer
    /// struct silently truncated is the kind of drift that goes unnoticed for
    /// months, so the tail is carried rather than dropped.
    public var extraBytes: [UInt8]

    public init(
        switchStatus: UInt8, countdownTaskStatus: UInt8,
        countdownTotal: UInt32, countdownRemaining: UInt32,
        cableCode: UInt8, profileCode: UInt8, extraBytes: [UInt8] = []
    ) {
        self.switchStatus = switchStatus
        self.countdownTaskStatus = countdownTaskStatus
        self.countdownTotal = countdownTotal
        self.countdownRemaining = countdownRemaining
        self.cableCode = cableCode
        self.profileCode = profileCode
        self.extraBytes = extraBytes
    }

    /// Fixed offsets, and nil below 12 bytes rather than a guess. The decoder used
    /// to take the last two bytes, which equals offsets 10/11 only by accident of
    /// the length; on anything else it read the wrong fields and reported a
    /// plausible cable rating that was simply false.
    public init?(bytes p: [UInt8]) {
        guard p.count >= 12 else { return nil }
        func u32(_ i: Int) -> UInt32 {
            UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
        }
        self.init(
            switchStatus: p[0],
            countdownTaskStatus: p[1],
            countdownTotal: u32(2),
            countdownRemaining: u32(6),
            cableCode: p[10],
            profileCode: p[11],
            extraBytes: Array(p.dropFirst(12))
        )
    }

    public var cable: CableCapability { CableCapability(code: cableCode) }
    public var chargingProfile: ChargingProfile? { ChargingProfile(code: profileCode) }

    /// True while the first ten bytes still match the placeholder — i.e. while the
    /// inferred countdown layout remains untested.
    public var matchesIdleDefault: Bool {
        let prefix = Self.idleDefaultPrefix
        return switchStatus == prefix[0] && countdownTaskStatus == prefix[1]
            && countdownTotal == 300 && countdownRemaining == 300
    }
}

public struct PortTelemetry: Sendable, Equatable {
    public var port: A2687.Port
    /// Raw first byte of the port struct. `0` is off; other values are outputs
    /// whose full enumeration is not yet established on real hardware.
    public var statusCode: UInt8
    public var voltage: Double   // V
    public var current: Double   // A
    public var power: Double     // W
    public var cable: CableCapability?
    public var chargingProfile: ChargingProfile?
    /// Full `AC`/`AD`/`AE` struct this port's `cable`/`chargingProfile` came from.
    /// nil when the field was absent or shorter than the 12 bytes the layout needs.
    /// Everything in it except cable/profile is unverified — see `PortControl`.
    public var control: PortControl?
    /// USB identity of whatever is on this port, from `B4`. Three states, all
    /// three seen on this charger and none of them interchangeable: nil when the
    /// frame carried no `B4` at all, `isNoIdentity` (`FFFA:FFFB`) when the
    /// firmware reported no identity for the slot, and `isUnidentified`
    /// (`0000:0000`) when it reported a device that gave no id.
    ///
    /// None of the three means the port is empty. `B4` answers "did a USB
    /// identity come through", and that is all it answers.
    ///
    /// The block layout behind this is confirmed on the owner's own unit now —
    /// see `TelemetryDecoder.decodeConnectedDevices` — so a port card may show it.
    /// The vendor *name* is still not ours to state: `05AC` is a USB VID, and the
    /// brand table recovered from the official app is a different numbering
    /// (`0x01` Apple, `0x02` Samsung, …) that arrives elsewhere. Print the hex.
    public var connectedDevice: USBDeviceID?
    /// Bytes past the 7 the live struct is known to use. Always empty on current
    /// firmware; a non-empty tail is the signal that the struct grew and the
    /// decoder needs revisiting, which silent truncation would have hidden.
    public var extraBytes: [UInt8]

    public var isOn: Bool { statusCode != 0 }
    /// A port can be on with a cable attached but drawing nothing. This answers
    /// "is it charging" — port counts, status words — and nothing else.
    public var isDelivering: Bool { isOn && current > 0.02 && voltage > 3.0 }
    /// Whether there is a real measurement worth putting on screen.
    ///
    /// Deliberately not `isDelivering`: the official app prints 5.0 V / 0.1 A
    /// verbatim, while the delivering threshold blanks those digits and the user
    /// reads the blank as a loose cable. Using one predicate for both jobs also
    /// let the same screen show a nonzero total next to a port showing nothing.
    /// `isOn` still gates it — an off port's leftover reading is stale, not small.
    public var hasReadings: Bool { isOn && (voltage > 0 || current > 0) }
    /// Physical cable presence is separate from output power. A negotiated cable
    /// capability is authoritative even while the attached device is idle; live
    /// voltage/current is a safe fallback when a firmware report omits the cable
    /// tail. `nil` deliberately means "not reported", not "unplugged".
    public var isCableAttached: Bool? {
        if isDelivering { return true }
        guard let cable else { return nil }
        if case .none = cable { return false }
        return true
    }

    public init(
        port: A2687.Port, statusCode: UInt8, voltage: Double, current: Double, power: Double,
        cable: CableCapability? = nil, chargingProfile: ChargingProfile? = nil,
        control: PortControl? = nil, connectedDevice: USBDeviceID? = nil,
        extraBytes: [UInt8] = []
    ) {
        self.port = port
        self.statusCode = statusCode
        self.voltage = voltage
        self.current = current
        self.power = power
        self.cable = cable
        self.chargingProfile = chargingProfile
        self.control = control
        self.connectedDevice = connectedDevice
        self.extraBytes = extraBytes
    }
}

/// Device identity recovered from the `0x0029` base-info response.
public struct DeviceInfo: Sendable, Equatable {
    public var productName: String?
    public var firmwareVersion: String?
    public var serialNumber: String?
    public var macAddress: String?

    public init(
        productName: String? = nil, firmwareVersion: String? = nil,
        serialNumber: String? = nil, macAddress: String? = nil
    ) {
        self.productName = productName
        self.firmwareVersion = firmwareVersion
        self.serialNumber = serialNumber
        self.macAddress = macAddress
    }

    /// Parses the `0x0029` base-info response. Its fields are raw ASCII, not typed
    /// values, and the role of each id is a content heuristic — anything that does
    /// not look right is left nil rather than guessed at.
    public static func decode(_ payload: Payload) -> DeviceInfo {
        func ascii(_ raw: [UInt8]?) -> String? {
            guard let raw, !raw.isEmpty, raw.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
            return String(decoding: raw, as: UTF8.self)
        }
        var info = DeviceInfo()
        info.productName = ascii(payload[A2687.Field.a2])
        info.firmwareVersion = ascii(payload[A2687.Field.a3])
        if let serial = ascii(payload[A2687.Field.a4]), serial.count >= 8 {
            info.serialNumber = serial
        }
        // A5 has been observed as 6 MAC bytes followed by an ASCII serial suffix.
        if let raw = payload[A2687.Field.a5], raw.count >= 6 {
            let mac = Array(raw[0..<6])
            if !mac.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
                info.macAddress = mac.map { String(format: "%02X", $0) }.joined(separator: ":")
            }
        }
        return info
    }
}

/// Every TLV of one frame, in the order it arrived, with repeated ids kept.
///
/// A `[UInt8: [UInt8]]` was the obvious shape and the wrong one: it drops both
/// the wire order and every occurrence after the first. The live frames show
/// `a1 a5 ac a6 ad a7 ae` — the interleaving of the port structs with their
/// control structs is information, and so is the count next to each id. That
/// count is what settled `B4`: had it repeated once per port, `occurrences(of:)`
/// would have read 3. It reads 1, twelve bytes wide, in every capture.
public struct FrameFields: Sendable, Equatable {
    /// Wire order, unfiltered, repeats included.
    public var records: [TLV]

    public init(_ records: [TLV] = []) {
        self.records = records
    }

    public var isEmpty: Bool { records.isEmpty }

    /// Distinct ids, in the order each first appears on the wire.
    public var ids: [UInt8] {
        var seen: Set<UInt8> = []
        return records.compactMap { seen.insert($0.id).inserted ? $0.id : nil }
    }

    /// First occurrence, matching `Payload`'s subscript. Use `values(of:)` when a
    /// repeat would change the answer.
    public subscript(id: UInt8) -> [UInt8]? {
        records.first(where: { $0.id == id })?.value
    }

    /// Every occurrence of one id, in wire order. Empty when the id is absent.
    public func values(of id: UInt8) -> [[UInt8]] {
        records.filter { $0.id == id }.map(\.value)
    }

    /// How many times an id appeared in this frame.
    public func occurrences(of id: UInt8) -> Int {
        records.reduce(0) { $0 + ($1.id == id ? 1 : 0) }
    }
}

/// The charger's own settings, as they stood **when the link came up**.
///
/// Read this before putting any of it on screen: *these values do not refresh
/// inside a session.* Turning the brightness down on the charger's own screen
/// left `A9` frozen at its old value for the entire connection; the new value
/// only appeared after dropping the link and connecting again. Same for the
/// charging mode. So every field here is a snapshot from handshake time, and it
/// silently goes stale the moment the user touches the device.
///
/// Two consequences, neither optional:
///
/// - **The UI must date it.** "Brightness 80 %" is a lie the instant the user
///   turns the dial; "brightness 80 % (as of the last connection)" is not. Every
///   other number on `ChargerTelemetry` is a live ~1 Hz reading, and nothing in
///   the data itself tells the reader which kind they are looking at.
/// - Confirming anything new about these fields needs *two sessions* — capture,
///   disconnect, change one thing, reconnect, capture, diff. Watching one
///   connection will show a byte that never moves and prove nothing.
///
/// Language is the one confirmed display write that is not represented here:
/// no language field has been found in `0x0200`. An absent field means "not
/// found", never "not set".
public struct DeviceSettings: Sendable, Equatable {
    /// `A8`, auto-lock enum: 0 = 30 s, 1 = 1 min, 2 = 5 min, 3 = 30 min,
    /// 4 = 12 h. Confirmed by a 30 s → 1 min write and fresh handshake.
    public var screenTimeout: UInt8?

    /// `A9`, percent 0…100. Confirmed twice on this charger: 80 % → `0x50`,
    /// 50 % → `0x32`. The official app writes the same value as
    /// `lcdBacklightBrightness`.
    public var screenBrightness: UInt8?

    /// `AA`, the raw mode code: `0` = AI ("AI mode 2.0"), `1` = standard,
    /// `4` = custom. Confirmed on this charger — switching AI → standard moved it
    /// 0 → 1 — and the codes match the official app's `chargingProtocol` enum
    /// (`0x0206`). `2` and `3` have never been seen and the app names neither.
    ///
    /// Kept as the raw byte rather than an enum: every consumer has to localise
    /// the mode name anyway, and an unnamed code must survive the trip to a bug
    /// report intact. Not to be confused with `ChargingProfile`, which is the
    /// per-port vendor fast-charge handshake, not a user setting.
    public var chargingMode: UInt8?

    /// `AF`, orientation enum: 0 up, 1 left, 2 down, 3 right. Confirmed by a
    /// left → right write and fresh handshake.
    public var screenOrientation: UInt8?

    /// `B2`, gyroscope auto-rotation switch. Confirmed off → on on hardware.
    public var gyroscopeEnabled: Bool?

    public init(
        screenTimeout: UInt8? = nil,
        screenBrightness: UInt8? = nil,
        chargingMode: UInt8? = nil,
        screenOrientation: UInt8? = nil,
        gyroscopeEnabled: Bool? = nil
    ) {
        self.screenTimeout = screenTimeout
        self.screenBrightness = screenBrightness
        self.chargingMode = chargingMode
        self.screenOrientation = screenOrientation
        self.gyroscopeEnabled = gyroscopeEnabled
    }

    /// True when the frame named one of these ids but none of them could be read
    /// — distinct from `ChargerTelemetry.settings` being nil, which means the
    /// frame carried no settings ids at all.
    public var isEmpty: Bool {
        screenTimeout == nil && screenBrightness == nil && chargingMode == nil
            && screenOrientation == nil && gyroscopeEnabled == nil
    }
}

/// One immutable telemetry snapshot handed to the UI.
public struct ChargerTelemetry: Sendable, Equatable {
    public var ports: [PortTelemetry]
    public var receivedAt: Date
    /// Logical opcode this snapshot came from, for diagnostics.
    public var sourceOpcode: UInt16
    /// Fields the decoder recognised the shape of but not the meaning of.
    ///
    /// A lookup, not evidence: a repeated id keeps only its first occurrence here,
    /// the same as `Payload`'s subscript. `allFields` is where the repeats live.
    public var unknownFields: [UInt8: [UInt8]]
    /// Every TLV in the frame, in wire order, nothing filtered and nothing merged
    /// — the already-decoded `A5`-`A7`/`AC`-`AE` included, and `A1`/`A2` which
    /// used to fall through both the model and `unknownFields` and vanish.
    ///
    /// Values are the TLV value exactly as received, so they still carry the
    /// one-byte `TypedValue` prefix (`0x04` for the port structs, `0x02` for the
    /// u16s).
    ///
    /// This is the record the one experiment worth running is built on. The
    /// charger takes a single client, so it cannot be watched while the official
    /// app changes something: capture a frame, drop the link, change one setting
    /// in the official app, quit it, reconnect and capture again, then compare
    /// the two captures. Two *sessions*, not two consecutive frames — between
    /// consecutive frames nothing moves but mV/mA jitter.
    ///
    /// That experiment has since paid for itself: `A8`, `A9`, `AA`, `AF`, `B2`
    /// and the `B4` port layout were all settled this way; `AB` was ruled out as
    /// protocol-management state the same way. It stays the only method that
    /// works here.
    public var allFields: FrameFields
    /// Device settings carried by this frame, nil when it carried none of their
    /// ids. **A handshake-time snapshot, not a live reading** — `DeviceSettings`
    /// spells out what that costs the UI, and the answer is not "nothing".
    ///
    /// nil is common and does not mean the settings changed or went away: the
    /// full `0x0200` read-all carries them, a `0x0300` realtime report need not,
    /// and every frame with port data replaces this whole snapshot. A view that
    /// binds straight to the newest frame would blink the settings out twice a
    /// second.
    ///
    /// Handled at the session layer: `ChargerSession` remembers the last non-nil
    /// snapshot of the current link and fills it back in here, clearing it at each
    /// handshake so nothing crosses a session boundary. So a `ChargerTelemetry`
    /// that came out of a live session already carries the carry-forward value,
    /// and nil there means "not read yet on this link". A `ChargerTelemetry`
    /// decoded straight off a frame still means exactly what this paragraph says
    /// — any other consumer of `decodeFrame` owes itself the same treatment.
    public var settings: DeviceSettings?

    public init(
        ports: [PortTelemetry], receivedAt: Date, sourceOpcode: UInt16,
        unknownFields: [UInt8: [UInt8]] = [:],
        allFields: FrameFields = FrameFields(),
        settings: DeviceSettings? = nil
    ) {
        self.ports = ports
        self.receivedAt = receivedAt
        self.sourceOpcode = sourceOpcode
        self.unknownFields = unknownFields
        self.allFields = allFields
        self.settings = settings
    }

    /// False for a frame that carried no `A5`/`A6`/`A7` at all — a `0x020A` bind
    /// ack, a `0x020B` trigger reply, a future `0x020C` history page. Such a frame
    /// is still worth recording; it just must not replace the live readings.
    public var hasPortData: Bool { !ports.isEmpty }

    /// Derived, not read from the device: the A2687 exposes no trustworthy total.
    public var totalPower: Double {
        ports.reduce(0) { $0 + ($1.isOn ? $1.power : 0) }
    }

    public var activePortCount: Int {
        ports.filter(\.isDelivering).count
    }

    public func port(_ port: A2687.Port) -> PortTelemetry? {
        ports.first { $0.port == port }
    }
}

public enum TelemetryDecoder {
    /// Per-port live struct: `[status(1), mV(2 LE), mA(2 LE), cW(2 LE)]`,
    /// wrapped in typed value `0x04`.
    static func decodePort(_ port: A2687.Port, from value: TypedValue?) -> PortTelemetry? {
        guard case .bytes(let p)? = value, p.count >= 7 else { return nil }
        return PortTelemetry(
            port: port,
            statusCode: p[0],
            voltage: Double(UInt16(p[1]) | UInt16(p[2]) << 8) / 1000.0,
            current: Double(UInt16(p[3]) | UInt16(p[4]) << 8) / 1000.0,
            power: Double(UInt16(p[5]) | UInt16(p[6]) << 8) / 100.0,
            extraBytes: Array(p.dropFirst(7))
        )
    }

    /// Full `CPowerControl` struct, at fixed offsets. See `PortControl` for what
    /// is and is not verified, and why a short struct yields nothing at all.
    static func decodeControl(from value: TypedValue?) -> PortControl? {
        guard case .bytes(let p)? = value else { return nil }
        return PortControl(bytes: p)
    }

    /// Unwraps a `TypedValue` byte array, falling back to the bare TLV value.
    ///
    /// The `0x04` wrapper is the norm, but `B4` arrives bare, and this is not a
    /// theoretical worry: the moment C1 is unplugged the block starts `fa ff …`,
    /// and `TypedValue.decode` would take that `0xFA` for a type prefix and hand
    /// back the twelve bytes shifted by one — every port misread, no error. The
    /// fallback costs a line.
    static func byteBlock(_ payload: Payload, _ id: UInt8) -> [UInt8]? {
        guard let raw = payload[id] else { return nil }
        if case .bytes(let body) = TypedValue.decode(raw) { return body }
        return raw
    }

    /// `B4` = three `VID(2 LE) PID(2 LE)` records in one 12-byte TLV, C1, C2, C3
    /// in wire order.
    ///
    /// Confirmed on the owner's charger by pulling one cable at a time and
    /// watching which four bytes turned into the empty-port sentinel:
    ///
    /// ```text
    /// C1 + C2 occupied   ac 05 09 73 | ac 05 18 75 | fa ff fb ff
    /// C1 unplugged       fa ff fb ff | ac 05 18 75 | fa ff fb ff
    /// C2 unplugged too   fa ff fb ff | fa ff fb ff | fa ff fb ff
    /// all three occupied ac 05 19 75 | ac 05 09 73 | 00 00 00 00
    /// ```
    ///
    /// C2's record holding still while C1's flipped is what pins the slot order;
    /// `0x05AC` is Apple's USB VID, and the PIDs (`7309`, `7518`, `7519`) tracked
    /// the individual cables as they moved. The two rival layouts this comment
    /// used to keep open are both dead: the id never repeated
    /// (`occurrences(of: b4) == 1` in every capture, so it is not one TLV per
    /// port), and `B4` was never empty with bytes in `B5`/`B6`.
    ///
    /// A short block yields fewer ports rather than a guess — firmware has only
    /// ever sent twelve bytes, and a nine-byte one would mean the layout moved.
    static func decodeConnectedDevices(_ payload: Payload) -> [A2687.Port: USBDeviceID] {
        guard let block = byteBlock(payload, A2687.Field.b4) else { return [:] }
        var out: [A2687.Port: USBDeviceID] = [:]
        for port in A2687.Port.allCases {
            let base = port.rawValue * 4
            guard base + 4 <= block.count else { break }
            out[port] = USBDeviceID(
                vendorID: UInt16(block[base]) | UInt16(block[base + 1]) << 8,
                productID: UInt16(block[base + 2]) | UInt16(block[base + 3]) << 8
            )
        }
        return out
    }

    /// One-byte setting, whether the firmware wrapped it in a `TypedValue` or
    /// wrote the byte bare (`A1` shows it does both).
    ///
    /// Anything wider is refused rather than squeezed into a byte: a `A9` that
    /// suddenly arrives as a u16 means the field is not what two reconnects said
    /// it is, and that deserves a blank plus the raw bytes in `allFields`, not a
    /// number that looks fine.
    static func settingByte(_ payload: Payload, _ id: UInt8) -> UInt8? {
        guard let raw = payload[id], !raw.isEmpty else { return nil }
        if raw.count == 1 { return raw[0] }
        switch TypedValue.decode(raw) {
        case .u8(let value): return value
        case .bytes(let body) where body.count == 1: return body[0]
        default: return nil
        }
    }

    /// Settings snapshot, nil when the frame mentioned none of these ids. See
    /// `DeviceSettings` — none of this is live.
    ///
    /// "Mentioned" is deliberately about the ids, not about the values: a frame
    /// that carries `A9` in a shape this decoder will not read still returns a
    /// snapshot, an empty one. Silence and an unreadable field are different
    /// facts, and only the second one is a bug in here.
    static func decodeSettings(_ payload: Payload) -> DeviceSettings? {
        let ids: Set<UInt8> = [
            A2687.Field.a8, A2687.Field.a9, A2687.Field.aa,
            A2687.Field.af, A2687.Field.b2,
        ]
        guard payload.fields.contains(where: { ids.contains($0.id) }) else { return nil }
        var settings = DeviceSettings()
        if let byte = settingByte(payload, A2687.Field.a8), byte <= 4 {
            settings.screenTimeout = byte
        }
        if let byte = settingByte(payload, A2687.Field.a9), byte <= 100 {
            // Above 100 it is not the percentage two cross-session samples showed,
            // so it goes unread. "137 %" on a screen is worse than a dash.
            settings.screenBrightness = byte
        }
        settings.chargingMode = settingByte(payload, A2687.Field.aa)
        if let byte = settingByte(payload, A2687.Field.af), byte <= 3 {
            settings.screenOrientation = byte
        }
        if let byte = settingByte(payload, A2687.Field.b2), byte <= 1 {
            settings.gyroscopeEnabled = byte == 1
        }
        return settings
    }

    /// Decodes everything the frame carries and never discards it.
    ///
    /// Always returns a snapshot, even for a payload with no port struct — a
    /// `0x020A` bind ack or a `0x020B` trigger reply used to return nil whole,
    /// which is why "what is 0x020A actually" could not be answered from a
    /// running build. Callers decide what to do with it via `hasPortData`.
    public static func decodeFrame(
        _ payload: Payload, opcode: UInt16, now: Date = Date()
    ) -> ChargerTelemetry {
        let devices = decodeConnectedDevices(payload)
        var ports: [PortTelemetry] = []
        for port in A2687.Port.allCases {
            guard var telemetry = decodePort(port, from: payload.typed(port.telemetryField)) else { continue }
            if let control = decodeControl(from: payload.typed(port.cableField)) {
                telemetry.control = control
                telemetry.cable = control.cable
                telemetry.chargingProfile = telemetry.isDelivering ? control.chargingProfile : nil
            }
            telemetry.connectedDevice = devices[port]
            ports.append(telemetry)
        }

        // `known` gates `unknownFields` only: "shape recognised, meaning settled
        // on this hardware". A8/A9/AA/AF/B2/B4 are all settled by cross-session
        // hardware experiments.
        let known: Set<UInt8> = [
            A2687.Field.a1, A2687.Field.a2, A2687.Field.a5, A2687.Field.a6, A2687.Field.a7,
            A2687.Field.a8, A2687.Field.a9, A2687.Field.aa, A2687.Field.af, A2687.Field.b2,
            A2687.Field.ac, A2687.Field.ad, A2687.Field.ae, A2687.Field.b4,
            A2687.Field.timestamp,
        ]
        var unknown: [UInt8: [UInt8]] = [:]
        for field in payload.fields where !known.contains(field.id) {
            if unknown[field.id] == nil { unknown[field.id] = field.value }
        }
        return ChargerTelemetry(
            ports: ports, receivedAt: now, sourceOpcode: opcode,
            unknownFields: unknown, allFields: FrameFields(payload.fields),
            settings: decodeSettings(payload)
        )
    }

    /// Returns nil when the payload carries no port struct at all, so callers can
    /// keep the previous snapshot instead of publishing an empty one. Use
    /// `decodeFrame` instead when the frame is wanted for diagnostics too.
    public static func decode(_ payload: Payload, opcode: UInt16, now: Date = Date()) -> ChargerTelemetry? {
        let frame = decodeFrame(payload, opcode: opcode, now: now)
        return frame.hasPortData ? frame : nil
    }
}
