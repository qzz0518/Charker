import A2345Protocol
import Foundation

/// Identifies one in-flight A2345 write so its acknowledgement can be matched.
/// Port commands are keyed per group (and per slot for schedules) because the
/// charger echoes the group in `0x0A07`/`0x0A09`; several ports can be in
/// flight at once.
public struct A2345WriteKey: Hashable, Sendable {
    public let messageType: UInt16
    public let group: A2345PortGroup?
    public let slot: A2345ScheduleSlot?

    public init(messageType: UInt16, group: A2345PortGroup? = nil, slot: A2345ScheduleSlot? = nil) {
        self.messageType = messageType
        self.group = group
        self.slot = slot
    }

    public init(_ command: A2345Command) {
        switch command {
        case .setPortOutput(let group, _):
            self.init(messageType: command.messageType, group: group)
        case .setPortCountdown(let group, _, _):
            self.init(messageType: command.messageType, group: group)
        case .setPortSchedule(let group, let slot, _):
            self.init(messageType: command.messageType, group: group, slot: slot)
        default:
            self.init(messageType: command.messageType)
        }
    }

    /// The `0x0ANN` acknowledgement this write waits for.
    public var acknowledgementType: UInt16 { 0x0A00 | (messageType & 0x00FF) }

    /// Matches on type, then on whatever the acknowledgement echoes. A field
    /// the charger leaves out matches any key of that type.
    public func matches(_ acknowledgement: A2345WriteAcknowledgement) -> Bool {
        guard acknowledgement.messageType == acknowledgementType else { return false }
        if let echoed = acknowledgement.group, let group, echoed != group { return false }
        if let echoed = acknowledgement.slot, let slot, echoed != slot { return false }
        return true
    }
}

public extension A2345DeviceSettings {
    /// The simulated charger: every control available, every port on.
    static var demo: A2345DeviceSettings {
        var settings = A2345DeviceSettings()
        settings.firmwareVersion = "2.1.1.6"
        settings.errorCode = 0
        let unset = A2345PortSchedule(rawSwitch: 0xFF, hour: 12, minute: 0, weekdays: 0)
        for group in A2345PortGroup.allCases {
            settings.portControls[group] = A2345PortControl(
                isOn: true,
                powerOn: unset,
                powerOff: unset,
                countdownEnabled: false,
                countdownTotal: 0,
                countdownRemaining: 0,
                priority: 0
            )
        }
        settings.clock = A2345ClockState(
            isOn: true, holidayEnabled: false, themeCode: 0, isShowingHoliday: false
        )
        settings.screenTimeoutCode = A2345ScreenTimeout.fiveMinutes.rawValue
        settings.chargingModeCode = A2345ChargingMode.aiPower.rawValue
        settings.isUpdatingFirmware = false
        settings.brightness = 70
        settings.knobDirectionCode = A2345KnobDirection.forward.rawValue
        settings.hourFormatCode = A2345HourFormat.twentyFourHour.rawValue
        settings.protocolVersion = 1
        settings.capabilities = [
            .customChargingMode, .clockSchedule, .portProtocols, .maxCompatibility,
            .customImageTimeDisplay, .deviceIdentification,
        ]
        settings.customProfile = A2345CustomChargingProfile(
            number: 1, autoExit: false, watts: [100, 65, 45, 20, 15]
        )
        settings.clockSchedule = A2345ClockSchedule(
            startHour: 8, startMinute: 0, endHour: 23, endMinute: 0, weekdays: 0x7F
        )
        settings.portProtocols = A2345PortProtocols(ports: Array(
            repeating: [.scp, .ufcs, .pd12V, .pps11V, .pps16V, .pps21V], count: 4
        ))
        settings.maxCompatibility = false
        settings.deviceIdentification = true
        settings.customImageTimeDisplay = true
        return settings
    }

    /// The state a write leaves behind once the charger has applied it. The
    /// app shows this right away and lets the charger's own reports correct it.
    func applying(_ command: A2345Command) -> A2345DeviceSettings {
        var next = self
        switch command {
        case .setPortOutput(let group, let on):
            next.apply(.portOutput(group, isOn: on))
        case .setPortSchedule(let group, let slot, let schedule):
            next.apply(.portSchedule(group, slot, schedule))
        case .setPortCountdown(let group, let enabled, let seconds):
            next.apply(.portCountdown(
                group,
                enabled: enabled,
                total: enabled ? seconds : 0,
                remaining: enabled ? seconds : 0
            ))
        case .setChargingMode(let mode):
            next.apply(.chargingMode(code: mode.rawValue, profile: nil, priority: nil))
        case .setCustomChargingMode(let profile, let protocols):
            next.apply(.chargingMode(code: A2345ChargingMode.customCode, profile: profile, priority: nil))
            if let protocols { next.portProtocols = protocols }
        case .exitCustomChargingMode:
            // The charger falls back to AI Power; the next snapshot confirms it.
            next.chargingModeCode = A2345ChargingMode.aiPower.rawValue
        case .setPortPriority(let bitmap):
            next.apply(.portPriority(bitmap))
        case .setScreenTimeout(let timeout):
            next.screenTimeoutCode = timeout.rawValue
        case .setBrightness(let percent):
            next.brightness = percent
        case .setKnobDirection(let direction):
            next.knobDirectionCode = direction.rawValue
        case .setHourFormat(let format):
            next.hourFormatCode = format.rawValue
        case .setClockSchedule(let schedule):
            next.clockSchedule = schedule
        case .setHolidayTheme(let on):
            next.clock?.holidayEnabled = on
        case .setClockTheme(let request):
            var clock = next.clock ?? A2345ClockState(isOn: request.clockOn, holidayEnabled: false, themeCode: 0)
            clock.isOn = request.clockOn
            if !request.clockOn { clock.holidayEnabled = false }
            clock.themeCode = request.kind.rawValue
            clock.themeID = request.kind.isBuiltIn ? nil : request.themeID
            next.clock = clock
        case .setCustomImageTimeDisplay(let on):
            next.customImageTimeDisplay = on
        case .setMaxCompatibility(let on):
            next.maxCompatibility = on
        case .setDeviceIdentification(let on):
            next.deviceIdentification = on
        case .setUFCS(let on):
            next.ufcs = on
        case .statusSnapshot, .themeStatus, .realtimeTrigger:
            break
        }
        return next
    }

    /// `0x0A00` carries neither the theme URL nor the custom-picture time
    /// display; those come from `0x0A02`. Keep them across a fresh snapshot.
    func mergingSnapshot(_ snapshot: A2345DeviceSettings) -> A2345DeviceSettings {
        var next = snapshot
        if let previous = clock, var incoming = next.clock {
            if incoming.themeCode == previous.themeCode, incoming.themeID == previous.themeID {
                incoming.themeURL = previous.themeURL
            }
            incoming.isShowingHoliday = previous.isShowingHoliday
            next.clock = incoming
        }
        if next.customImageTimeDisplay == nil {
            next.customImageTimeDisplay = customImageTimeDisplay
        }
        return next
    }
}

/// Account-side A2345 operations that can be in flight; the UI disables the
/// matching control meanwhile.
public enum A2345CloudWork: Hashable, Sendable {
    /// Maximum compatibility and device identification exclude each other,
    /// so they share one slot.
    case labExclusive
    case customModeSwitch
    case chargingModes
    case pictures
}

public extension ChargerPortID {
    /// The A2345 control group this port belongs to.
    var a2345Group: A2345PortGroup? {
        A2345Port(rawValue: rawValue).map(A2345PortGroup.init(port:))
    }
}
