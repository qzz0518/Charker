import Foundation

/// The switch, schedules, countdown and priority of one port group, as the
/// 19-byte AA…AE blocks of `0x0A00` carry them.
public struct A2345PortControl: Sendable, Equatable {
    public var isOn: Bool
    public var powerOn: A2345PortSchedule
    public var powerOff: A2345PortSchedule
    public var countdownEnabled: Bool
    public var countdownTotal: UInt32
    public var countdownRemaining: UInt32
    /// 0 outside port-priority mode, 1 normal, 2 preferred.
    public var priority: UInt8

    public init(
        isOn: Bool,
        powerOn: A2345PortSchedule,
        powerOff: A2345PortSchedule,
        countdownEnabled: Bool,
        countdownTotal: UInt32,
        countdownRemaining: UInt32,
        priority: UInt8
    ) {
        self.isOn = isOn
        self.powerOn = powerOn
        self.powerOff = powerOff
        self.countdownEnabled = countdownEnabled
        self.countdownTotal = countdownTotal
        self.countdownRemaining = countdownRemaining
        self.priority = priority
    }

    public func schedule(_ slot: A2345ScheduleSlot) -> A2345PortSchedule {
        slot == .powerOn ? powerOn : powerOff
    }
}

/// Feature bits from `0x0A00` B7. The official app hides a control when its
/// bit is clear and skips the matching readback field.
public struct A2345Capabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let customChargingMode = Self(rawValue: 1 << 0)
    public static let clockSchedule = Self(rawValue: 1 << 1)
    public static let bluetoothFirmwareUpdate = Self(rawValue: 1 << 2)
    public static let dualLogChannel = Self(rawValue: 1 << 3)
    public static let portProtocols = Self(rawValue: 1 << 4)
    public static let maxCompatibility = Self(rawValue: 1 << 5)
    public static let customImageTimeDisplay = Self(rawValue: 1 << 6)
    public static let pictureThemesOverBluetooth = Self(rawValue: 1 << 7)
    public static let ufcsSwitch = Self(rawValue: 1 << 8)
    public static let deviceIdentification = Self(rawValue: 1 << 9)
    public static let brandModelCodes = Self(rawValue: 1 << 10)
    public static let protocolManagement = Self(rawValue: 1 << 11)
}

public struct A2345ClockState: Sendable, Equatable {
    public var isOn: Bool
    public var holidayEnabled: Bool
    /// Theme number (`& 0x3F`): 0–2 built-in styles, 3 cloud picture, 5 custom.
    public var themeCode: UInt8
    public var themeID: UInt32?
    public var themeURL: String?
    /// Whether a holiday theme is on screen right now (`0x0A02`/`0x030B` A5).
    public var isShowingHoliday: Bool?

    public init(
        isOn: Bool,
        holidayEnabled: Bool,
        themeCode: UInt8,
        themeID: UInt32? = nil,
        themeURL: String? = nil,
        isShowingHoliday: Bool? = nil
    ) {
        self.isOn = isOn
        self.holidayEnabled = holidayEnabled
        self.themeCode = themeCode
        self.themeID = themeID
        self.themeURL = themeURL
        self.isShowingHoliday = isShowingHoliday
    }

    public var themeKind: A2345ThemeKind? { A2345ThemeKind(rawValue: themeCode) }

    init(flags: UInt8) {
        self.init(
            isOn: flags & 0x80 != 0,
            holidayEnabled: flags & 0x40 != 0,
            themeCode: flags & 0x3F
        )
    }
}

/// One C-port slot of BD (USB vendor/product id) or BE (brand/model code).
public struct A2345IdentitySlot: Sendable, Equatable {
    public var group: A2345PortGroup
    public var first: UInt16
    public var second: UInt16

    public init(group: A2345PortGroup, first: UInt16, second: UInt16) {
        self.group = group
        self.first = first
        self.second = second
    }

    /// `FFFA:FFFB` is what the charger reports with nothing identified;
    /// all-zero and all-ones slots carry no identity either.
    public var isEmpty: Bool {
        (first == 0xFFFA && second == 0xFFFB)
            || (first == 0 && second == 0)
            || (first == 0xFFFF && second == 0xFFFF)
    }
}

/// Everything controllable the charger reports, merged from `0x0A00`,
/// `0x0A02` and the `0x03xx` change messages. Nil means "not reported yet" —
/// or, for capability-gated fields, "this firmware does not have it".
public struct A2345DeviceSettings: Sendable, Equatable {
    public var firmwareVersion: String?
    public var errorCode: UInt16?
    public var portControls: [A2345PortGroup: A2345PortControl] = [:]
    public var clock: A2345ClockState?
    public var screenTimeoutCode: UInt8?
    public var chargingModeCode: UInt8?
    public var isUpdatingFirmware: Bool?
    public var brightness: UInt8?
    public var knobDirectionCode: UInt8?
    public var hourFormatCode: UInt8?
    public var protocolVersion: UInt8?
    public var capabilities: A2345Capabilities?
    public var customProfile: A2345CustomChargingProfile?
    public var clockSchedule: A2345ClockSchedule?
    public var portProtocols: A2345PortProtocols?
    public var maxCompatibility: Bool?
    public var ufcs: Bool?
    public var deviceIdentification: Bool?
    public var connectedDeviceUSB: [A2345IdentitySlot] = []
    public var connectedDeviceBrand: [A2345IdentitySlot] = []
    public var customImageTimeDisplay: Bool?

    public init() {}

    public var screenTimeout: A2345ScreenTimeout? {
        screenTimeoutCode.flatMap(A2345ScreenTimeout.init(rawValue:))
    }
    public var knobDirection: A2345KnobDirection? {
        knobDirectionCode.flatMap(A2345KnobDirection.init(rawValue:))
    }
    public var hourFormat: A2345HourFormat? {
        hourFormatCode.flatMap(A2345HourFormat.init(rawValue:))
    }
    public var chargingMode: A2345ChargingMode? {
        chargingModeCode.flatMap(A2345ChargingMode.init(rawValue:))
    }
    public var isCustomChargingMode: Bool { chargingModeCode == A2345ChargingMode.customCode }

    public func supports(_ capability: A2345Capabilities) -> Bool {
        capabilities?.contains(capability) ?? false
    }

    /// Bit0…bit3 = C1…C4 for every group marked preferred.
    public var priorityBitmap: UInt8 {
        var bitmap: UInt8 = 0
        for group in [A2345PortGroup.c1, .c2, .c3, .c4] where portControls[group]?.priority == 2 {
            bitmap |= 1 << UInt8(group.rawValue)
        }
        return bitmap
    }

    /// Error bits: 1 = over-temperature, bit1…bit4 = C1…C4, bit5 = USB-A.
    /// Zero and values from 64 up mean no fault, as in the official app.
    public var hasFault: Bool {
        guard let errorCode else { return false }
        return (1...63).contains(errorCode)
    }

    public var isOverTemperature: Bool { errorCode == 1 }

    public func hasFault(_ group: A2345PortGroup) -> Bool {
        guard hasFault, !isOverTemperature, let errorCode else { return false }
        return errorCode & (1 << UInt16(group.rawValue + 1)) != 0
    }

    /// Merges one change message. Fields the message does not carry keep
    /// their current value.
    public mutating func apply(_ update: A2345SettingsUpdate) {
        switch update {
        case .portOutput(let group, let isOn):
            guard var control = portControls[group] else { return }
            control.isOn = isOn
            if !isOn {
                // The charger cancels a running countdown with the port.
                control.countdownEnabled = false
                control.countdownTotal = 0
                control.countdownRemaining = 0
            }
            portControls[group] = control

        case .portCountdown(let group, let enabled, let total, let remaining):
            guard var control = portControls[group] else { return }
            control.countdownEnabled = enabled
            control.countdownTotal = total
            control.countdownRemaining = remaining
            portControls[group] = control

        case .portSchedule(let group, let slot, let schedule):
            guard var control = portControls[group] else { return }
            switch slot {
            case .powerOn: control.powerOn = schedule
            case .powerOff: control.powerOff = schedule
            }
            portControls[group] = control

        case .errorCode(let code):
            errorCode = code

        case .screenTimeout(let code):
            screenTimeoutCode = code

        case .brightness(let value):
            brightness = value

        case .knobDirection(let code):
            knobDirectionCode = code

        case .clock(var state):
            if state.themeURL == nil { state.themeURL = clock?.themeURL }
            clock = state

        case .themeStatus(let state, let timeDisplay):
            clock = state
            customImageTimeDisplay = timeDisplay

        case .chargingMode(let code, let profile, let priority):
            chargingModeCode = code
            if let profile { customProfile = profile }
            if let priority { applyPriorityBitmap(priority) }
            if code != A2345ChargingMode.portPriority.rawValue {
                for group in [A2345PortGroup.c1, .c2, .c3, .c4] {
                    portControls[group]?.priority = 0
                }
            }

        case .portPriority(let bitmap):
            applyPriorityBitmap(bitmap)

        case .singlePortPriority(let group, let preferred):
            portControls[group]?.priority = preferred ? 2 : 1

        case .themeDownload(let themeID, let status, let code):
            guard status == 1 else { return }
            var state = clock ?? A2345ClockState(isOn: true, holidayEnabled: false, themeCode: 0)
            if let themeID { state.themeID = themeID }
            if let code, code == 3 || code == 5 { state.themeCode = code }
            clock = state

        case .firmwareVersion(let version):
            firmwareVersion = version
        }
    }

    private mutating func applyPriorityBitmap(_ bitmap: UInt8) {
        for group in [A2345PortGroup.c1, .c2, .c3, .c4] {
            portControls[group]?.priority = bitmap & (1 << UInt8(group.rawValue)) != 0 ? 2 : 1
        }
    }
}

/// One change message (`0x03xx`, `0x0A02`) reduced to the setting it touches.
public enum A2345SettingsUpdate: Sendable, Equatable {
    case portOutput(A2345PortGroup, isOn: Bool)
    case portCountdown(A2345PortGroup, enabled: Bool, total: UInt32, remaining: UInt32)
    case portSchedule(A2345PortGroup, A2345ScheduleSlot, A2345PortSchedule)
    case errorCode(UInt16)
    case screenTimeout(UInt8)
    case brightness(UInt8)
    case knobDirection(UInt8)
    case clock(A2345ClockState)
    case themeStatus(A2345ClockState, customImageTimeDisplay: Bool)
    case chargingMode(code: UInt8, profile: A2345CustomChargingProfile?, priority: UInt8?)
    case portPriority(UInt8)
    case singlePortPriority(A2345PortGroup, preferred: Bool)
    case themeDownload(themeID: UInt32?, status: UInt8, themeCode: UInt8?)
    case firmwareVersion(String)
}

/// A write acknowledgement (`0x0A01`…`0x0A23`). `status` is the byte after
/// the message type: 0 = accepted, 4 = parameter rejected.
public struct A2345WriteAcknowledgement: Sendable, Equatable {
    public var messageType: UInt16
    public var status: UInt8?
    public var group: A2345PortGroup?
    public var slot: A2345ScheduleSlot?

    public init(
        messageType: UInt16,
        status: UInt8?,
        group: A2345PortGroup? = nil,
        slot: A2345ScheduleSlot? = nil
    ) {
        self.messageType = messageType
        self.status = status
        self.group = group
        self.slot = slot
    }

    public var isRejected: Bool { (status ?? 0) != 0 }
}

/// Reading of TLV values as the official parser does it: the first field (A1)
/// is taken as-is, every other value loses its leading type byte, whatever
/// that byte is.
struct A2345FieldReader {
    let frame: A2345Frame

    func value(_ id: UInt8) -> [UInt8]? {
        guard let field = frame.fields.first(where: { $0.id == id }) else { return nil }
        guard field.rawValue.count > 1 else { return nil }
        return Array(field.rawValue.dropFirst())
    }

    func byte(_ id: UInt8) -> UInt8? { value(id)?.first }

    func integer(_ id: UInt8) -> UInt32? {
        guard let bytes = value(id), !bytes.isEmpty, bytes.count <= 4 else { return nil }
        var result: UInt32 = 0
        for (index, byte) in bytes.enumerated() {
            result |= UInt32(byte) << (8 * UInt32(index))
        }
        return result
    }

    func string(_ id: UInt8) -> String? {
        guard frame.fields.contains(where: { $0.id == id }) else { return nil }
        var bytes = value(id) ?? []
        while bytes.last == 0 { bytes.removeLast() }
        return String(bytes: bytes, encoding: .utf8)
    }
}

enum A2345SettingsDecoder {
    static func group(_ value: UInt32?) -> A2345PortGroup? {
        value.flatMap { A2345PortGroup(rawValue: Int($0)) }
    }

    /// `0x0A00` A2: decimal digits joined by dots, 0x0840 = 2112 → 2.1.1.2.
    static func version(_ value: UInt32) -> String? {
        guard value > 0 else { return nil }
        return String(value).map(String.init).joined(separator: ".")
    }

    static func portControl(_ bytes: [UInt8]) -> A2345PortControl? {
        guard bytes.count >= 19 else { return nil }
        return A2345PortControl(
            isOn: bytes[0] == 1,
            powerOn: A2345PortSchedule(rawSwitch: bytes[1], hour: bytes[2], minute: bytes[3], weekdays: bytes[4]),
            powerOff: A2345PortSchedule(rawSwitch: bytes[5], hour: bytes[6], minute: bytes[7], weekdays: bytes[8]),
            countdownEnabled: bytes[9] == 1,
            countdownTotal: uint32(bytes, at: 10),
            countdownRemaining: uint32(bytes, at: 14),
            priority: bytes[18]
        )
    }

    static func customProfile(_ bytes: [UInt8]?) -> A2345CustomChargingProfile? {
        guard let bytes, bytes.count >= 7 else { return nil }
        return A2345CustomChargingProfile(
            number: bytes[0],
            autoExit: bytes[1] == 1,
            watts: Array(bytes[2..<7])
        )
    }

    static func identities(_ bytes: [UInt8]?) -> [A2345IdentitySlot] {
        guard let bytes, bytes.count >= 16 else { return [] }
        return [A2345PortGroup.c1, .c2, .c3, .c4].enumerated().map { index, group in
            A2345IdentitySlot(
                group: group,
                first: uint16(bytes, at: index * 4),
                second: uint16(bytes, at: index * 4 + 2)
            )
        }
    }

    static func settings(from frame: A2345Frame) -> A2345DeviceSettings {
        let reader = A2345FieldReader(frame: frame)
        var settings = A2345DeviceSettings()
        settings.firmwareVersion = reader.integer(0xA2).flatMap(version)
        settings.errorCode = reader.integer(0xA3).map { UInt16(truncatingIfNeeded: $0) }
        for group in A2345PortGroup.allCases {
            if let bytes = reader.value(UInt8(0xAA + group.rawValue)),
               let control = portControl(bytes) {
                settings.portControls[group] = control
            }
        }
        if let af = reader.value(0xAF), let flags = af.first {
            var clock = A2345ClockState(flags: flags)
            if (clock.themeCode == 3 || clock.themeCode == 5), af.count >= 5 {
                clock.themeID = uint32(af, at: 1)
            }
            settings.clock = clock
        }
        settings.screenTimeoutCode = reader.byte(0xB0).map { $0 & 0x0F }
        settings.chargingModeCode = reader.byte(0xB1)
        settings.isUpdatingFirmware = reader.byte(0xB2).map { $0 == 1 }
        settings.brightness = reader.byte(0xB3)
        settings.knobDirectionCode = reader.byte(0xB4)
        settings.hourFormatCode = reader.byte(0xB5)
        settings.protocolVersion = reader.byte(0xB6)
        let capabilities = A2345Capabilities(
            rawValue: UInt16(truncatingIfNeeded: reader.integer(0xB7) ?? 0)
        )
        settings.capabilities = capabilities
        if capabilities.contains(.customChargingMode) {
            settings.customProfile = customProfile(reader.value(0xB8))
        }
        if capabilities.contains(.clockSchedule), let b9 = reader.value(0xB9), b9.count >= 5 {
            settings.clockSchedule = A2345ClockSchedule(
                startHour: b9[0], startMinute: b9[1],
                endHour: b9[2], endMinute: b9[3],
                weekdays: b9[4]
            )
        }
        if capabilities.contains(.portProtocols), let ba = reader.value(0xBA), ba.count >= 12 {
            settings.portProtocols = A2345PortProtocols(ports: (0..<4).map {
                A2345PortProtocols.Flags(rawValue: ba[$0 * 3] & 0x3F)
            })
        }
        if capabilities.contains(.maxCompatibility), let bb = reader.byte(0xBB) {
            settings.maxCompatibility = bb == 0
        }
        if capabilities.contains(.ufcsSwitch), let bc = reader.byte(0xBC) {
            settings.ufcs = bc == 1
        }
        if capabilities.contains(.deviceIdentification), let bf = reader.byte(0xBF) {
            settings.deviceIdentification = bf == 1
        }
        settings.connectedDeviceUSB = identities(reader.value(0xBD))
        settings.connectedDeviceBrand = identities(reader.value(0xBE))
        return settings
    }

    static func clockState(_ reader: A2345FieldReader) -> A2345ClockState? {
        guard let flags = reader.byte(0xA2) else { return nil }
        var clock = A2345ClockState(flags: flags)
        if clock.themeCode == 3 || clock.themeCode == 5 {
            clock.themeID = reader.integer(0xA3)
        }
        if let url = reader.string(0xA4), !url.isEmpty {
            clock.themeURL = url
        }
        clock.isShowingHoliday = reader.byte(0xA5) == 1
        return clock
    }

    /// Decodes the change messages; nil for anything else.
    static func updates(from frame: A2345Frame) -> [A2345SettingsUpdate]? {
        let reader = A2345FieldReader(frame: frame)
        switch frame.messageType {
        case 0x0301:
            guard let version = reader.integer(0xA2).flatMap(version) else { return [] }
            return [.firmwareVersion(version)]

        case 0x0302:
            guard let group = group(reader.integer(0xA2)), let state = reader.byte(0xA3) else { return [] }
            return [.portOutput(group, isOn: state == 1)]

        case 0x0304:
            guard let code = reader.integer(0xA2) else { return [] }
            return [.errorCode(UInt16(truncatingIfNeeded: code))]

        case 0x0307:
            guard let group = group(reader.integer(0xA2)),
                  let bytes = reader.value(0xA3), bytes.count >= 9 else { return [] }
            return [.portCountdown(
                group,
                enabled: bytes[0] == 1,
                total: uint32(bytes, at: 1),
                remaining: uint32(bytes, at: 5)
            )]

        case 0x0308:
            guard let group = group(reader.integer(0xA2)),
                  let slot = reader.byte(0xA3).flatMap(A2345ScheduleSlot.init(rawValue:)),
                  let bytes = reader.value(0xA4), bytes.count >= 4 else { return [] }
            return [.portSchedule(group, slot, A2345PortSchedule(
                rawSwitch: bytes[0], hour: bytes[1], minute: bytes[2], weekdays: bytes[3]
            ))]

        case 0x0309:
            guard let code = reader.byte(0xA2) else { return [] }
            return [.screenTimeout(code & 0x0F)]

        case 0x030A:
            guard let value = reader.byte(0xA2) else { return [] }
            return [.brightness(value)]

        case 0x030B:
            guard let clock = clockState(reader) else { return [] }
            return [.clock(clock)]

        case 0x0A02:
            guard let clock = clockState(reader) else { return [] }
            return [.themeStatus(clock, customImageTimeDisplay: reader.byte(0xA6) == 1)]

        case 0x030D:
            guard let code = reader.byte(0xA2) else { return [] }
            return [.chargingMode(
                code: code,
                profile: customProfile(reader.value(0xA3)),
                priority: reader.byte(0xA4)
            )]

        case 0x030F:
            if let bitmap = reader.byte(0xA3) {
                return [.portPriority(bitmap)]
            }
            if let bytes = reader.value(0xA2), bytes.count >= 2,
               let group = group(UInt32(bytes[0])), group != .usbA {
                return [.singlePortPriority(group, preferred: bytes[1] == 1)]
            }
            return []

        case 0x0310:
            guard let code = reader.byte(0xA2) else { return [] }
            return [.knobDirection(code)]

        case 0x0311:
            guard let status = reader.integer(0xA3) else { return [] }
            return [.themeDownload(
                themeID: reader.integer(0xA2),
                status: UInt8(truncatingIfNeeded: status),
                themeCode: reader.byte(0xA4)
            )]

        default:
            return nil
        }
    }

    static func acknowledgement(from frame: A2345Frame) -> A2345WriteAcknowledgement? {
        let type = frame.messageType
        guard type & 0xFF00 == 0x0A00, type != 0x0A00, type != 0x0A02 else { return nil }
        let reader = A2345FieldReader(frame: frame)
        var acknowledgement = A2345WriteAcknowledgement(messageType: type, status: frame.increment)
        switch type {
        case 0x0A07, 0x0A09:
            acknowledgement.group = group(reader.integer(0xA2))
        case 0x0A08:
            acknowledgement.group = group(reader.integer(0xA2))
            acknowledgement.slot = reader.byte(0xA3).flatMap(A2345ScheduleSlot.init(rawValue:))
        default:
            break
        }
        return acknowledgement
    }

    static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
