import Foundation

/// The FF09 request encoder used by the official app 3.24.0
/// (`ZXCommandTransformer._getSettingCommand` / `_getNormalCommand`).
///
///     FF 09 | uint16LE length incl. checksum | 03 00 0F | uint16BE type
///     A1 01 22 | TLVs sorted by tag | FE 05 03 <uint32LE epoch> | XOR
///
/// Each TLV is `tag | length | type | value`, where `length` counts the type
/// byte and `type` depends only on the value length: 1 → 01, 2 → 02,
/// 4 → 03, anything else (including empty) → 04. Frames sent over MQTT carry
/// no encryption; the session prefix `22` marks the cloud path.
public enum A2345FrameEncoder {
    public static func encode(
        messageType: UInt16,
        fields: [(tag: UInt8, value: [UInt8])],
        allowsLongFields: Bool = false,
        at date: Date
    ) -> [UInt8] {
        let epoch = UInt32(truncatingIfNeeded: Int(date.timeIntervalSince1970))
        var bytes: [UInt8] = [
            A2345PacketCodec.header[0], A2345PacketCodec.header[1],
            0x00, 0x00, // Total length, filled in once the frame is complete.
            A2345FramePattern.protocolVersion, 0x00, 0x0F,
            UInt8(messageType >> 8), UInt8(messageType & 0xFF),
            A2345.Field.a1, 0x01, 0x22,
        ]
        for field in fields.sorted(by: { $0.tag < $1.tag }) {
            bytes.append(field.tag)
            let length = field.value.count + 1
            if allowsLongFields, length > 0x78 {
                bytes.append(UInt8(length & 0xFF))
                bytes.append(UInt8((length >> 8) & 0xFF))
            } else {
                bytes.append(UInt8(truncatingIfNeeded: length))
            }
            bytes.append(valueType(forLength: field.value.count))
            bytes.append(contentsOf: field.value)
        }
        bytes += [
            A2345.Field.timestamp, 0x05, A2345.ValueType.variable,
            UInt8(epoch & 0xFF),
            UInt8((epoch >> 8) & 0xFF),
            UInt8((epoch >> 16) & 0xFF),
            UInt8((epoch >> 24) & 0xFF),
        ]
        let encodedLength = UInt16(bytes.count + 1)
        bytes[2] = UInt8(encodedLength & 0xFF)
        bytes[3] = UInt8(encodedLength >> 8)
        bytes.append(A2345PacketCodec.checksum(bytes[...]))
        return bytes
    }

    static func valueType(forLength length: Int) -> UInt8 {
        switch length {
        case 1: return 0x01
        case 2: return 0x02
        case 4: return 0x03
        default: return 0x04
        }
    }
}

/// Byte-exact builders for the two established A2345 read requests.
public enum A2345ReadRequestEncoder {
    /// `0x0200` — requests one full device-state snapshot.
    public static func statusSnapshot(at date: Date = Date()) -> [UInt8] {
        A2345FrameEncoder.encode(messageType: 0x0200, fields: [], at: date)
    }

    /// `0x020B` — asks the device to begin realtime telemetry reporting.
    public static func realtimeTrigger(at date: Date = Date()) -> [UInt8] {
        A2345FrameEncoder.encode(messageType: 0x020B, fields: [], at: date)
    }
}

public enum A2345CommandError: Error, Sendable, Equatable {
    case invalidParameter(String)
}

/// The closed set of requests Charker sends to an A2345. Every case maps to
/// one setter in the official app's `A2345DeviceController`; there is no case
/// that takes a raw message type or raw bytes.
public enum A2345Command: Sendable, Equatable {
    /// `0x0200`
    case statusSnapshot
    /// `0x0202` — clock/theme state, answered by `0x0A02`.
    case themeStatus
    /// `0x020B`
    case realtimeTrigger
    /// `0x0207`
    case setPortOutput(A2345PortGroup, on: Bool)
    /// `0x0208` — one of the two daily slots of a port group.
    case setPortSchedule(A2345PortGroup, A2345ScheduleSlot, A2345PortSchedule)
    /// `0x0209` — `seconds` is resent unchanged when cancelling, as the
    /// official app does.
    case setPortCountdown(A2345PortGroup, enabled: Bool, seconds: UInt32)
    /// `0x0206` with a preset mode 1–4.
    case setChargingMode(A2345ChargingMode)
    /// `0x0206` with mode 5 and the active custom profile.
    case setCustomChargingMode(A2345CustomChargingProfile, protocols: A2345PortProtocols?)
    /// `0x0211` — the official app only ever sends "off".
    case exitCustomChargingMode
    /// `0x020C` — bit0…bit3 = C1…C4, at most two bits.
    case setPortPriority(UInt8)
    /// `0x0203`
    case setScreenTimeout(A2345ScreenTimeout)
    /// `0x0204` — 20…100 in steps of 5.
    case setBrightness(UInt8)
    /// `0x020E`
    case setKnobDirection(A2345KnobDirection)
    /// `0x0210`
    case setHourFormat(A2345HourFormat)
    /// `0x0213`
    case setClockSchedule(A2345ClockSchedule)
    /// `0x020F`
    case setHolidayTheme(Bool)
    /// `0x0205` — clock switch plus the theme it shows.
    case setClockTheme(A2345ClockThemeRequest)
    /// `0x0222`
    case setCustomImageTimeDisplay(Bool)
    /// `0x0214` — sent inverted: 0 turns maximum compatibility on.
    case setMaxCompatibility(Bool)
    /// `0x0223`
    case setDeviceIdentification(Bool)
    /// `0x0215` — mainland firmware without protocol management.
    case setUFCS(Bool)

    public var messageType: UInt16 {
        switch self {
        case .statusSnapshot: return 0x0200
        case .themeStatus: return 0x0202
        case .realtimeTrigger: return 0x020B
        case .setPortOutput: return 0x0207
        case .setPortSchedule: return 0x0208
        case .setPortCountdown: return 0x0209
        case .setChargingMode, .setCustomChargingMode: return 0x0206
        case .exitCustomChargingMode: return 0x0211
        case .setPortPriority: return 0x020C
        case .setScreenTimeout: return 0x0203
        case .setBrightness: return 0x0204
        case .setKnobDirection: return 0x020E
        case .setHourFormat: return 0x0210
        case .setClockSchedule: return 0x0213
        case .setHolidayTheme: return 0x020F
        case .setClockTheme: return 0x0205
        case .setCustomImageTimeDisplay: return 0x0222
        case .setMaxCompatibility: return 0x0214
        case .setDeviceIdentification: return 0x0223
        case .setUFCS: return 0x0215
        }
    }

    /// The acknowledgement the charger answers with: `0x02NN` → `0x0ANN`.
    /// Reads are answered by their data message instead.
    public var acknowledgementType: UInt16? {
        switch self {
        case .statusSnapshot, .themeStatus: return nil
        default: return 0x0A00 | (messageType & 0x00FF)
        }
    }

    public var isWrite: Bool {
        switch self {
        case .statusSnapshot, .themeStatus, .realtimeTrigger: return false
        default: return true
        }
    }

    public func encode(at date: Date = Date()) throws -> [UInt8] {
        let (fields, longFields) = try encodedFields()
        return A2345FrameEncoder.encode(
            messageType: messageType,
            fields: fields,
            allowsLongFields: longFields,
            at: date
        )
    }

    private func encodedFields() throws -> ([(tag: UInt8, value: [UInt8])], Bool) {
        switch self {
        case .statusSnapshot, .themeStatus, .realtimeTrigger:
            return ([], false)

        case .exitCustomChargingMode:
            return ([(0xA2, [0x00])], false)

        case .setPortOutput(let group, let on):
            return ([(0xA2, [UInt8(group.rawValue)]), (0xA3, [on ? 1 : 0])], false)

        case .setPortSchedule(let group, let slot, let schedule):
            try schedule.validate()
            return ([
                (0xA2, [UInt8(group.rawValue)]),
                (0xA3, [slot.rawValue]),
                (0xA4, [
                    schedule.isEnabled ? 1 : 0,
                    schedule.hour,
                    schedule.minute,
                    schedule.weekdays & 0x7F,
                ]),
            ], false)

        case .setPortCountdown(let group, let enabled, let seconds):
            // Cancelling echoes whatever total the charger reported.
            guard !enabled || seconds <= 86_400 else {
                throw A2345CommandError.invalidParameter("countdown")
            }
            return ([
                (0xA2, [UInt8(group.rawValue)]),
                (0xA3, [enabled ? 1 : 0] + littleEndian(seconds)),
            ], false)

        case .setChargingMode(let mode):
            return ([(0xA2, [mode.rawValue])], false)

        case .setCustomChargingMode(let profile, let protocols):
            try profile.validate()
            var fields: [(tag: UInt8, value: [UInt8])] = [
                (0xA2, [A2345ChargingMode.customCode]),
                (0xA3, profile.encoded),
            ]
            if let protocols {
                fields.append((0xA4, protocols.encoded))
            }
            return (fields, false)

        case .setPortPriority(let bitmap):
            guard bitmap & 0xF0 == 0, bitmap.nonzeroBitCount <= 2 else {
                throw A2345CommandError.invalidParameter("priority")
            }
            return ([(0xA2, [bitmap])], false)

        case .setScreenTimeout(let timeout):
            return ([(0xA2, [timeout.rawValue])], false)

        case .setBrightness(let percent):
            guard (20...100).contains(percent), percent % 5 == 0 else {
                throw A2345CommandError.invalidParameter("brightness")
            }
            return ([(0xA2, [percent])], false)

        case .setKnobDirection(let direction):
            return ([(0xA2, [direction.rawValue])], false)

        case .setHourFormat(let format):
            return ([(0xA2, [format.rawValue])], false)

        case .setClockSchedule(let schedule):
            try schedule.validate()
            return ([(0xA2, [
                schedule.startHour, schedule.startMinute,
                schedule.endHour, schedule.endMinute,
                schedule.weekdays & 0x7F,
            ])], false)

        case .setHolidayTheme(let on):
            return ([(0xA2, [on ? 1 : 0])], false)

        case .setClockTheme(let request):
            return try request.encodedFields()

        case .setCustomImageTimeDisplay(let on):
            return ([(0xA2, [on ? 1 : 0])], false)

        case .setMaxCompatibility(let on):
            return ([(0xA2, [on ? 0 : 1])], false)

        case .setDeviceIdentification(let on):
            return ([(0xA2, [on ? 1 : 0])], false)

        case .setUFCS(let on):
            return ([(0xA2, [on ? 1 : 0])], false)
        }
    }
}

func littleEndian(_ value: UInt32) -> [UInt8] {
    [
        UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
    ]
}

/// Port groups as the control messages number them. USB-A A1 and A2 share one
/// switch, one countdown and one schedule; only their telemetry is separate.
public enum A2345PortGroup: Int, CaseIterable, Sendable, Hashable, Comparable {
    case c1 = 0
    case c2
    case c3
    case c4
    case usbA

    public var label: String {
        switch self {
        case .c1: "C1"
        case .c2: "C2"
        case .c3: "C3"
        case .c4: "C4"
        case .usbA: "A1/A2"
        }
    }

    public var ports: [A2345Port] {
        switch self {
        case .c1: [.c1]
        case .c2: [.c2]
        case .c3: [.c3]
        case .c4: [.c4]
        case .usbA: [.a1, .a2]
        }
    }

    public init(port: A2345Port) {
        switch port {
        case .c1: self = .c1
        case .c2: self = .c2
        case .c3: self = .c3
        case .c4: self = .c4
        case .a1, .a2: self = .usbA
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum A2345ScheduleSlot: UInt8, CaseIterable, Sendable {
    case powerOff = 0
    case powerOn = 1
}

/// One daily on/off time. `weekdays` bit0 = Monday … bit6 = Sunday; zero runs
/// once at the next occurrence. The charger reports 0xFF in `rawSwitch` for a
/// slot that was never set.
public struct A2345PortSchedule: Sendable, Equatable {
    public var rawSwitch: UInt8
    public var hour: UInt8
    public var minute: UInt8
    public var weekdays: UInt8

    public init(isEnabled: Bool, hour: UInt8, minute: UInt8, weekdays: UInt8) {
        self.rawSwitch = isEnabled ? 1 : 0
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
    }

    public init(rawSwitch: UInt8, hour: UInt8, minute: UInt8, weekdays: UInt8) {
        self.rawSwitch = rawSwitch
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
    }

    public var isEnabled: Bool { rawSwitch == 1 }
    public var isUnset: Bool { rawSwitch == 0xFF }
    /// The weekday mask without the bit the charger sets for unset slots.
    public var repeatDays: UInt8 { isUnset ? 0 : weekdays & 0x7F }

    func validate() throws {
        guard hour < 24, minute < 60 else {
            throw A2345CommandError.invalidParameter("schedule")
        }
    }
}

public enum A2345ChargingMode: UInt8, CaseIterable, Sendable {
    case aiPower = 1
    case portPriority = 2
    case dualLaptop = 3
    case lowCurrent = 4

    public static let customCode: UInt8 = 5
}

/// Per-port limits for custom mode, in watts. C ports take 0 or 15…max; the
/// USB-A pair only 0, 15 or 24. The official app also caps the sum at 250 W.
public struct A2345CustomChargingProfile: Sendable, Equatable {
    public var number: UInt8
    public var autoExit: Bool
    /// C1, C2, C3, C4, USB-A.
    public var watts: [UInt8]

    public init(number: UInt8, autoExit: Bool, watts: [UInt8]) {
        self.number = number
        self.autoExit = autoExit
        self.watts = watts
    }

    public static let totalLimit = 250
    public static let usbAChoices: [UInt8] = [0, 15, 24]

    /// Upper limits per group: C2–C4 allow 120 W on mainland units.
    public static func maximumWatts(_ group: A2345PortGroup, mainland: Bool) -> UInt8 {
        switch group {
        case .c1: return 140
        case .c2, .c3, .c4: return mainland ? 120 : 100
        case .usbA: return 24
        }
    }

    var encoded: [UInt8] {
        [number, autoExit ? 1 : 0] + watts
    }

    func validate() throws {
        guard (1...4).contains(number), watts.count == 5,
              watts.reduce(0, { $0 + Int($1) }) <= Self.totalLimit,
              Self.usbAChoices.contains(watts[4]),
              watts[0..<4].allSatisfy({ $0 == 0 || ($0 >= 15 && $0 <= 140) })
        else {
            throw A2345CommandError.invalidParameter("custom profile")
        }
    }
}

/// Fast-charge protocols allowed per C port in custom mode. On overseas
/// firmware bit0 = SCP; mainland units reuse bit0 for Huawei and add bit6 for
/// Xiaomi.
public struct A2345PortProtocols: Sendable, Equatable {
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let scp = Flags(rawValue: 1 << 0)
        public static let ufcs = Flags(rawValue: 1 << 1)
        public static let pd12V = Flags(rawValue: 1 << 2)
        public static let pps11V = Flags(rawValue: 1 << 3)
        public static let pps16V = Flags(rawValue: 1 << 4)
        public static let pps21V = Flags(rawValue: 1 << 5)
        public static let xiaomi = Flags(rawValue: 1 << 6)
        /// Mainland firmware: the same bit as SCP.
        public static let huawei = Flags(rawValue: 1 << 0)
    }

    /// C1…C4.
    public var ports: [Flags]

    public init(ports: [Flags]) {
        self.ports = ports
    }

    var encoded: [UInt8] {
        ports.prefix(4).flatMap { [$0.rawValue, 0x00, 0x00] }
    }
}

public enum A2345ScreenTimeout: UInt8, CaseIterable, Sendable {
    case alwaysOn = 0
    case thirtySeconds = 1
    case oneMinute = 2
    case fiveMinutes = 3
    case thirtyMinutes = 4
}

public enum A2345KnobDirection: UInt8, CaseIterable, Sendable {
    case forward = 0
    case backward = 1
}

public enum A2345HourFormat: UInt8, CaseIterable, Sendable {
    case twelveHour = 0
    case twentyFourHour = 1
}

/// When the clock screensaver is shown. `weekdays` bit0 = Monday … bit6 = Sunday.
public struct A2345ClockSchedule: Sendable, Equatable {
    public var startHour: UInt8
    public var startMinute: UInt8
    public var endHour: UInt8
    public var endMinute: UInt8
    public var weekdays: UInt8

    public init(startHour: UInt8, startMinute: UInt8, endHour: UInt8, endMinute: UInt8, weekdays: UInt8) {
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.weekdays = weekdays
    }

    func validate() throws {
        guard startHour < 24, endHour < 24, startMinute < 60, endMinute < 60 else {
            throw A2345CommandError.invalidParameter("clock schedule")
        }
    }
}

/// Clock screensaver themes. 0–2 are the three built-in styles, 3 a cloud
/// picture theme and 5 a picture the user uploaded.
public enum A2345ThemeKind: UInt8, Sendable, Equatable {
    case style1 = 0
    case style2 = 1
    case style3 = 2
    case picture = 3
    case custom = 5

    public var isBuiltIn: Bool { rawValue <= 2 }
}

/// Everything `0x0205` carries. Switching the clock on or off resends the
/// current theme unchanged; there is no separate switch command.
public struct A2345ClockThemeRequest: Sendable, Equatable {
    public var clockOn: Bool
    public var kind: A2345ThemeKind
    public var themeID: UInt32?
    /// CRC-32 of the picture file; zero for built-in styles.
    public var imageCRC: UInt32
    public var textColor: UInt32
    /// `image_url` for cloud themes, the official app's asset path for
    /// built-in styles. Goes in A6 with a one-byte length.
    public var url: String
    /// Direct link of an uploaded picture. When set it goes in A7 and replaces
    /// A6, as the official app does when applying a custom picture over Wi-Fi.
    public var customURL: String?

    public init(
        clockOn: Bool,
        kind: A2345ThemeKind,
        themeID: UInt32?,
        imageCRC: UInt32,
        textColor: UInt32 = 0xFFFF_FFFF,
        url: String,
        customURL: String? = nil
    ) {
        self.clockOn = clockOn
        self.kind = kind
        self.themeID = themeID
        self.imageCRC = imageCRC
        self.textColor = textColor
        self.url = url
        self.customURL = customURL
    }

    /// The asset path the official app sends for built-in style `index` 0…2.
    public static func builtInStyleURL(_ kind: A2345ThemeKind) -> String {
        "assets/img/a2345/icl_a2345_theme\(Int(kind.rawValue) + 1).png"
    }

    func encodedFields() throws -> ([(tag: UInt8, value: [UInt8])], Bool) {
        var fields: [(tag: UInt8, value: [UInt8])] = [
            (0xA2, [(clockOn ? 0x80 : 0x00) | (kind.rawValue & 0x7F)]),
        ]
        if kind == .picture || kind == .custom {
            guard let themeID else { throw A2345CommandError.invalidParameter("theme id") }
            fields.append((0xA3, littleEndian(themeID)))
        } else {
            fields.append((0xA3, []))
        }
        fields.append((0xA4, littleEndian(imageCRC)))
        fields.append((0xA5, littleEndian(textColor)))
        if let customURL, !customURL.isEmpty {
            let bytes = Array(customURL.utf8)
            guard bytes.count <= 1_024 else { throw A2345CommandError.invalidParameter("url") }
            fields.append((0xA7, bytes))
            return (fields, true)
        }
        let bytes = Array(url.utf8)
        // A6 has a one-byte length; the official app silently truncates
        // longer values, which corrupts the frame.
        guard bytes.count <= 254 else { throw A2345CommandError.invalidParameter("url") }
        fields.append((0xA6, bytes))
        return (fields, false)
    }
}
