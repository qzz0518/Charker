package a2345

// This file ports the pure parts of CharkerCore/A2345Control.swift: write
// acknowledgement matching, the optimistic state a write leaves behind, the
// snapshot merge and the simulated charger's settings.

// WriteKey identifies one in-flight write so its acknowledgement can be
// matched. Port commands are keyed per group (and per slot for schedules)
// because the charger echoes the group in 0x0A07/0x0A09; several ports can be
// in flight at once. It is comparable and usable as a map key.
type WriteKey struct {
	MessageType uint16
	Group       PortGroup
	HasGroup    bool
	Slot        ScheduleSlot
	HasSlot     bool
}

// NewWriteKey keys a command.
func NewWriteKey(c Command) WriteKey {
	k := WriteKey{MessageType: c.MessageType()}
	if g, ok := c.Group(); ok {
		k.Group, k.HasGroup = g, true
	}
	if s, ok := c.Slot(); ok {
		k.Slot, k.HasSlot = s, true
	}
	return k
}

// AcknowledgementType is the 0x0ANN this write waits for.
func (k WriteKey) AcknowledgementType() uint16 { return 0x0A00 | k.MessageType&0x00FF }

// Matches checks the type, then whatever the acknowledgement echoes. A field
// the charger leaves out matches any key of that type.
func (k WriteKey) Matches(a WriteAcknowledgement) bool {
	if a.MessageType != k.AcknowledgementType() {
		return false
	}
	if a.Group != nil && k.HasGroup && *a.Group != k.Group {
		return false
	}
	if a.Slot != nil && k.HasSlot && *a.Slot != k.Slot {
		return false
	}
	return true
}

// DemoSettings is the simulated charger: every control available, every port
// on.
func DemoSettings() DeviceSettings {
	s := DeviceSettings{PortControls: map[PortGroup]PortControl{}}
	version := "2.1.1.6"
	s.FirmwareVersion = &version
	var zero uint16
	s.ErrorCode = &zero
	unset := PortSchedule{RawSwitch: 0xFF, Hour: 12, Minute: 0, Weekdays: 0}
	for _, g := range PortGroups {
		s.PortControls[g] = PortControl{IsOn: true, PowerOn: unset, PowerOff: unset}
	}
	s.Clock = &ClockState{IsOn: true, ThemeCode: 0, IsShowingHoliday: ptrBool(false)}
	s.ScreenTimeoutCode = ptrByte(byte(ScreenFiveMinutes))
	s.ChargingModeCode = ptrByte(byte(ModeAIPower))
	s.IsUpdatingFirmware = ptrBool(false)
	s.Brightness = ptrByte(70)
	s.KnobDirectionCode = ptrByte(byte(KnobForward))
	s.HourFormatCode = ptrByte(byte(HourFormat24))
	s.ProtocolVersion = ptrByte(1)
	caps := CapCustomChargingMode | CapClockSchedule | CapPortProtocols | CapMaxCompatibility |
		CapCustomImageTimeDisplay | CapDeviceIdentification
	s.Capabilities = &caps
	s.CustomProfile = &CustomChargingProfile{Number: 1, AutoExit: false, Watts: []byte{100, 65, 45, 20, 15}}
	s.ClockSchedule = &ClockSchedule{StartHour: 8, StartMinute: 0, EndHour: 23, EndMinute: 0, Weekdays: 0x7F}
	all := ProtoSCP | ProtoUFCS | ProtoPD12V | ProtoPPS11V | ProtoPPS16V | ProtoPPS21V
	s.PortProtocols = &PortProtocols{Ports: []ProtocolFlags{all, all, all, all}}
	s.MaxCompatibility = ptrBool(false)
	s.DeviceIdentification = ptrBool(true)
	s.CustomImageTimeDisplay = ptrBool(true)
	s.ConnectedDeviceUSB = []IdentitySlot{}
	s.ConnectedDeviceBrand = []IdentitySlot{}
	return s
}

// Applying returns the state a write leaves behind once the charger has
// applied it. The app shows this right away and lets the charger's own
// reports correct it. s is not modified.
func (s DeviceSettings) Applying(c Command) DeviceSettings {
	next := s.Clone()
	switch c.kind {
	case CmdSetPortOutput:
		next.Apply(PortOutputUpdate(c.group, c.on))
	case CmdSetPortSchedule:
		next.Apply(PortScheduleUpdate(c.group, c.slot, c.schedule))
	case CmdSetPortCountdown:
		var seconds uint32
		if c.on {
			seconds = c.seconds
		}
		next.Apply(PortCountdownUpdate(c.group, c.on, seconds, seconds))
	case CmdSetChargingMode:
		next.Apply(ChargingModeUpdate(byte(c.mode), nil, nil))
	case CmdSetCustomChargingMode:
		profile := c.profile
		next.Apply(ChargingModeUpdate(CustomModeCode, &profile, nil))
		if c.protocols != nil {
			p := c.protocols.clone()
			next.PortProtocols = &p
		}
	case CmdExitCustomChargingMode:
		// The charger falls back to AI Power; the next snapshot confirms it.
		next.ChargingModeCode = ptrByte(byte(ModeAIPower))
	case CmdSetPortPriority:
		next.Apply(PortPriorityUpdate(c.value))
	case CmdSetScreenTimeout:
		next.ScreenTimeoutCode = ptrByte(c.value)
	case CmdSetBrightness:
		next.Brightness = ptrByte(c.value)
	case CmdSetKnobDirection:
		next.KnobDirectionCode = ptrByte(c.value)
	case CmdSetHourFormat:
		next.HourFormatCode = ptrByte(c.value)
	case CmdSetClockSchedule:
		cs := c.clockSchedule
		next.ClockSchedule = &cs
	case CmdSetHolidayTheme:
		if next.Clock != nil {
			next.Clock.HolidayEnabled = c.on
		}
	case CmdSetClockTheme:
		clock := ClockState{IsOn: c.theme.ClockOn}
		if next.Clock != nil {
			clock = *next.Clock
		}
		clock.IsOn = c.theme.ClockOn
		if !c.theme.ClockOn {
			clock.HolidayEnabled = false
		}
		clock.ThemeCode = byte(c.theme.Kind)
		if c.theme.Kind.IsBuiltIn() {
			clock.ThemeID = nil
		} else {
			clock.ThemeID = copyU32(c.theme.ThemeID)
		}
		next.Clock = &clock
	case CmdSetCustomImageTimeDisplay:
		next.CustomImageTimeDisplay = ptrBool(c.on)
	case CmdSetMaxCompatibility:
		next.MaxCompatibility = ptrBool(c.on)
	case CmdSetDeviceIdentification:
		next.DeviceIdentification = ptrBool(c.on)
	case CmdSetUFCS:
		next.UFCS = ptrBool(c.on)
	}
	return next
}

// MergingSnapshot merges a fresh 0x0A00 into s. 0x0A00 carries neither the
// theme URL nor the custom-picture time display; those come from 0x0A02, so
// they are kept across the snapshot. Neither argument is modified.
func (s DeviceSettings) MergingSnapshot(incoming DeviceSettings) DeviceSettings {
	next := incoming.Clone()
	if s.Clock != nil && next.Clock != nil {
		if next.Clock.ThemeCode == s.Clock.ThemeCode && equalU32(next.Clock.ThemeID, s.Clock.ThemeID) {
			next.Clock.ThemeURL = copyString(s.Clock.ThemeURL)
		}
		next.Clock.IsShowingHoliday = copyBool(s.Clock.IsShowingHoliday)
	}
	if next.CustomImageTimeDisplay == nil {
		next.CustomImageTimeDisplay = copyBool(s.CustomImageTimeDisplay)
	}
	return next
}

func equalU32(a, b *uint32) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}
