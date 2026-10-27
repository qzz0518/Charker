package a2345

import (
	"strconv"
	"strings"
	"unicode/utf8"
)

// PortControl is the switch, schedules, countdown and priority of one port
// group, as the 19-byte AA…AE blocks of 0x0A00 carry them.
type PortControl struct {
	IsOn               bool
	PowerOn            PortSchedule
	PowerOff           PortSchedule
	CountdownEnabled   bool
	CountdownTotal     uint32
	CountdownRemaining uint32
	// Priority: 0 outside port-priority mode, 1 normal, 2 preferred.
	Priority byte
}

// Schedule returns the schedule of one slot.
func (c PortControl) Schedule(slot ScheduleSlot) PortSchedule {
	if slot == SlotPowerOn {
		return c.PowerOn
	}
	return c.PowerOff
}

// Capabilities are the feature bits of 0x0A00 B7. The official app hides a
// control when its bit is clear and skips the matching readback field.
type Capabilities uint16

// Capability bits.
const (
	CapCustomChargingMode Capabilities = 1 << iota
	CapClockSchedule
	CapBluetoothFirmwareUpdate
	CapDualLogChannel
	CapPortProtocols
	CapMaxCompatibility
	CapCustomImageTimeDisplay
	CapPictureThemesOverBluetooth
	CapUFCSSwitch
	CapDeviceIdentification
	CapBrandModelCodes
	CapProtocolManagement
)

// Has reports whether every bit of x is set.
func (c Capabilities) Has(x Capabilities) bool { return c&x == x }

// ClockState is the clock screensaver state.
type ClockState struct {
	IsOn           bool
	HolidayEnabled bool
	// ThemeCode (& 0x3F): 0–2 built-in styles, 3 cloud picture, 5 custom.
	ThemeCode byte
	ThemeID   *uint32
	ThemeURL  *string
	// IsShowingHoliday: whether a holiday theme is on screen now (0x0A02 /
	// 0x030B A5).
	IsShowingHoliday *bool
}

// ThemeKind returns the theme kind when ThemeCode names one.
func (c ClockState) ThemeKind() (ThemeKind, bool) { return ValidThemeKind(c.ThemeCode) }

func clockFromFlags(flags byte) ClockState {
	return ClockState{IsOn: flags&0x80 != 0, HolidayEnabled: flags&0x40 != 0, ThemeCode: flags & 0x3F}
}

func (c ClockState) clone() ClockState {
	c.ThemeID = copyU32(c.ThemeID)
	c.ThemeURL = copyString(c.ThemeURL)
	c.IsShowingHoliday = copyBool(c.IsShowingHoliday)
	return c
}

// IdentitySlot is one C-port slot of BD (USB vendor/product id) or BE
// (brand/model code).
type IdentitySlot struct {
	Group  PortGroup
	First  uint16
	Second uint16
}

// IsEmpty: FFFA:FFFB is what the charger reports with nothing identified;
// all-zero and all-ones slots carry no identity either.
func (s IdentitySlot) IsEmpty() bool {
	return (s.First == 0xFFFA && s.Second == 0xFFFB) ||
		(s.First == 0 && s.Second == 0) ||
		(s.First == 0xFFFF && s.Second == 0xFFFF)
}

// DeviceSettings is everything controllable the charger reports, merged from
// 0x0A00, 0x0A02 and the 0x03xx change messages. Nil means "not reported
// yet" or, for capability-gated fields, "this firmware does not have it".
type DeviceSettings struct {
	FirmwareVersion        *string
	ErrorCode              *uint16
	PortControls           map[PortGroup]PortControl
	Clock                  *ClockState
	ScreenTimeoutCode      *byte
	ChargingModeCode       *byte
	IsUpdatingFirmware     *bool
	Brightness             *byte
	KnobDirectionCode      *byte
	HourFormatCode         *byte
	ProtocolVersion        *byte
	Capabilities           *Capabilities
	CustomProfile          *CustomChargingProfile
	ClockSchedule          *ClockSchedule
	PortProtocols          *PortProtocols
	MaxCompatibility       *bool
	UFCS                   *bool
	DeviceIdentification   *bool
	ConnectedDeviceUSB     []IdentitySlot
	ConnectedDeviceBrand   []IdentitySlot
	CustomImageTimeDisplay *bool
}

// Clone returns a deep copy: the map, every pointer and every slice.
func (s DeviceSettings) Clone() DeviceSettings {
	out := s
	out.FirmwareVersion = copyString(s.FirmwareVersion)
	if s.ErrorCode != nil {
		v := *s.ErrorCode
		out.ErrorCode = &v
	}
	if s.PortControls != nil {
		out.PortControls = make(map[PortGroup]PortControl, len(s.PortControls))
		for k, v := range s.PortControls {
			out.PortControls[k] = v
		}
	}
	if s.Clock != nil {
		c := s.Clock.clone()
		out.Clock = &c
	}
	out.ScreenTimeoutCode = copyByte(s.ScreenTimeoutCode)
	out.ChargingModeCode = copyByte(s.ChargingModeCode)
	out.IsUpdatingFirmware = copyBool(s.IsUpdatingFirmware)
	out.Brightness = copyByte(s.Brightness)
	out.KnobDirectionCode = copyByte(s.KnobDirectionCode)
	out.HourFormatCode = copyByte(s.HourFormatCode)
	out.ProtocolVersion = copyByte(s.ProtocolVersion)
	if s.Capabilities != nil {
		c := *s.Capabilities
		out.Capabilities = &c
	}
	if s.CustomProfile != nil {
		p := s.CustomProfile.clone()
		out.CustomProfile = &p
	}
	if s.ClockSchedule != nil {
		c := *s.ClockSchedule
		out.ClockSchedule = &c
	}
	if s.PortProtocols != nil {
		p := s.PortProtocols.clone()
		out.PortProtocols = &p
	}
	out.MaxCompatibility = copyBool(s.MaxCompatibility)
	out.UFCS = copyBool(s.UFCS)
	out.DeviceIdentification = copyBool(s.DeviceIdentification)
	if s.ConnectedDeviceUSB != nil {
		out.ConnectedDeviceUSB = append([]IdentitySlot{}, s.ConnectedDeviceUSB...)
	}
	if s.ConnectedDeviceBrand != nil {
		out.ConnectedDeviceBrand = append([]IdentitySlot{}, s.ConnectedDeviceBrand...)
	}
	out.CustomImageTimeDisplay = copyBool(s.CustomImageTimeDisplay)
	return out
}

// ScreenTimeout returns the timeout when the code names one.
func (s DeviceSettings) ScreenTimeout() (ScreenTimeout, bool) {
	if s.ScreenTimeoutCode == nil || *s.ScreenTimeoutCode > byte(ScreenThirtyMinutes) {
		return 0, false
	}
	return ScreenTimeout(*s.ScreenTimeoutCode), true
}

// KnobDirection returns the direction when the code names one.
func (s DeviceSettings) KnobDirection() (KnobDirection, bool) {
	if s.KnobDirectionCode == nil || *s.KnobDirectionCode > byte(KnobBackward) {
		return 0, false
	}
	return KnobDirection(*s.KnobDirectionCode), true
}

// HourFormat returns the format when the code names one.
func (s DeviceSettings) HourFormat() (HourFormat, bool) {
	if s.HourFormatCode == nil || *s.HourFormatCode > byte(HourFormat24) {
		return 0, false
	}
	return HourFormat(*s.HourFormatCode), true
}

// ChargingMode returns the preset mode when the code names one (custom mode
// 5 is not a preset; see IsCustomChargingMode).
func (s DeviceSettings) ChargingMode() (ChargingMode, bool) {
	if s.ChargingModeCode == nil {
		return 0, false
	}
	switch m := ChargingMode(*s.ChargingModeCode); m {
	case ModeAIPower, ModePortPriority, ModeDualLaptop, ModeLowCurrent:
		return m, true
	}
	return 0, false
}

// IsCustomChargingMode reports charging-mode code 5.
func (s DeviceSettings) IsCustomChargingMode() bool {
	return s.ChargingModeCode != nil && *s.ChargingModeCode == CustomModeCode
}

// Supports reports a capability bit; false before B7 was reported.
func (s DeviceSettings) Supports(c Capabilities) bool {
	return s.Capabilities != nil && s.Capabilities.Has(c)
}

// PriorityBitmap: bit0…bit3 = C1…C4 for every group marked preferred.
func (s DeviceSettings) PriorityBitmap() byte {
	var bitmap byte
	for _, g := range USBCGroups {
		if c, ok := s.PortControls[g]; ok && c.Priority == 2 {
			bitmap |= 1 << byte(g)
		}
	}
	return bitmap
}

// HasFault: error bits 1 = over-temperature, bit1…bit4 = C1…C4, bit5 =
// USB-A. Zero and values from 64 up mean no fault, as in the official app.
func (s DeviceSettings) HasFault() bool {
	return s.ErrorCode != nil && *s.ErrorCode >= 1 && *s.ErrorCode <= 63
}

// IsOverTemperature reports error code 1.
func (s DeviceSettings) IsOverTemperature() bool { return s.ErrorCode != nil && *s.ErrorCode == 1 }

// HasGroupFault reports a fault on one port group.
func (s DeviceSettings) HasGroupFault(g PortGroup) bool {
	if !s.HasFault() || s.IsOverTemperature() {
		return false
	}
	return *s.ErrorCode&(1<<uint16(g+1)) != 0
}

// Apply merges one change message. Fields the message does not carry keep
// their current value. Nothing of u is aliased into s.
func (s *DeviceSettings) Apply(u SettingsUpdate) {
	switch u.Kind {
	case UpdatePortOutput:
		control, ok := s.PortControls[u.Group]
		if !ok {
			return
		}
		control.IsOn = u.IsOn
		if !u.IsOn {
			// The charger cancels a running countdown with the port.
			control.CountdownEnabled = false
			control.CountdownTotal = 0
			control.CountdownRemaining = 0
		}
		s.PortControls[u.Group] = control

	case UpdatePortCountdown:
		control, ok := s.PortControls[u.Group]
		if !ok {
			return
		}
		control.CountdownEnabled = u.Enabled
		control.CountdownTotal = u.Total
		control.CountdownRemaining = u.Remaining
		s.PortControls[u.Group] = control

	case UpdatePortSchedule:
		control, ok := s.PortControls[u.Group]
		if !ok {
			return
		}
		if u.Slot == SlotPowerOn {
			control.PowerOn = u.Schedule
		} else {
			control.PowerOff = u.Schedule
		}
		s.PortControls[u.Group] = control

	case UpdateErrorCode:
		v := u.ErrorCode
		s.ErrorCode = &v

	case UpdateScreenTimeout:
		s.ScreenTimeoutCode = ptrByte(u.Code)

	case UpdateBrightness:
		s.Brightness = ptrByte(u.Code)

	case UpdateKnobDirection:
		s.KnobDirectionCode = ptrByte(u.Code)

	case UpdateClock:
		state := u.Clock.clone()
		if state.ThemeURL == nil && s.Clock != nil {
			state.ThemeURL = copyString(s.Clock.ThemeURL)
		}
		s.Clock = &state

	case UpdateThemeStatus:
		state := u.Clock.clone()
		s.Clock = &state
		s.CustomImageTimeDisplay = ptrBool(u.CustomImageTimeDisplay)

	case UpdateChargingMode:
		s.ChargingModeCode = ptrByte(u.Code)
		if u.Profile != nil {
			p := u.Profile.clone()
			s.CustomProfile = &p
		}
		if u.Priority != nil {
			s.applyPriorityBitmap(*u.Priority)
		}
		if u.Code != byte(ModePortPriority) {
			for _, g := range USBCGroups {
				if c, ok := s.PortControls[g]; ok {
					c.Priority = 0
					s.PortControls[g] = c
				}
			}
		}

	case UpdatePortPriority:
		s.applyPriorityBitmap(u.Code)

	case UpdateSinglePortPriority:
		if c, ok := s.PortControls[u.Group]; ok {
			if u.Preferred {
				c.Priority = 2
			} else {
				c.Priority = 1
			}
			s.PortControls[u.Group] = c
		}

	case UpdateThemeDownload:
		if u.Status != 1 {
			return
		}
		state := ClockState{IsOn: true}
		if s.Clock != nil {
			state = s.Clock.clone()
		}
		if u.ThemeID != nil {
			state.ThemeID = copyU32(u.ThemeID)
		}
		if u.ThemeCode != nil && (*u.ThemeCode == 3 || *u.ThemeCode == 5) {
			state.ThemeCode = *u.ThemeCode
		}
		s.Clock = &state

	case UpdateFirmwareVersion:
		v := u.FirmwareVersion
		s.FirmwareVersion = &v
	}
}

func (s *DeviceSettings) applyPriorityBitmap(bitmap byte) {
	for _, g := range USBCGroups {
		c, ok := s.PortControls[g]
		if !ok {
			continue
		}
		if bitmap&(1<<byte(g)) != 0 {
			c.Priority = 2
		} else {
			c.Priority = 1
		}
		s.PortControls[g] = c
	}
}

// UpdateKind discriminates SettingsUpdate.
type UpdateKind int

// Update kinds.
const (
	UpdatePortOutput UpdateKind = iota + 1
	UpdatePortCountdown
	UpdatePortSchedule
	UpdateErrorCode
	UpdateScreenTimeout
	UpdateBrightness
	UpdateKnobDirection
	UpdateClock
	UpdateThemeStatus
	UpdateChargingMode
	UpdatePortPriority
	UpdateSinglePortPriority
	UpdateThemeDownload
	UpdateFirmwareVersion
)

// SettingsUpdate is one change message (0x03xx, 0x0A02) reduced to the
// setting it touches. Only the fields of Kind are meaningful; build it with
// the constructors below.
type SettingsUpdate struct {
	Kind      UpdateKind
	Group     PortGroup
	IsOn      bool
	Enabled   bool
	Total     uint32
	Remaining uint32
	Slot      ScheduleSlot
	Schedule  PortSchedule
	ErrorCode uint16
	// Code is the screen-timeout code, brightness value, knob code,
	// charging-mode code or priority bitmap, depending on Kind.
	Code                   byte
	Clock                  ClockState
	CustomImageTimeDisplay bool
	Profile                *CustomChargingProfile
	Priority               *byte
	Preferred              bool
	ThemeID                *uint32
	Status                 byte
	ThemeCode              *byte
	FirmwareVersion        string
}

// PortOutputUpdate is 0x0302.
func PortOutputUpdate(g PortGroup, on bool) SettingsUpdate {
	return SettingsUpdate{Kind: UpdatePortOutput, Group: g, IsOn: on}
}

// PortCountdownUpdate is 0x0307.
func PortCountdownUpdate(g PortGroup, enabled bool, total, remaining uint32) SettingsUpdate {
	return SettingsUpdate{Kind: UpdatePortCountdown, Group: g, Enabled: enabled, Total: total, Remaining: remaining}
}

// PortScheduleUpdate is 0x0308.
func PortScheduleUpdate(g PortGroup, slot ScheduleSlot, schedule PortSchedule) SettingsUpdate {
	return SettingsUpdate{Kind: UpdatePortSchedule, Group: g, Slot: slot, Schedule: schedule}
}

// ErrorCodeUpdate is 0x0304.
func ErrorCodeUpdate(code uint16) SettingsUpdate {
	return SettingsUpdate{Kind: UpdateErrorCode, ErrorCode: code}
}

// ScreenTimeoutUpdate is 0x0309.
func ScreenTimeoutUpdate(code byte) SettingsUpdate {
	return SettingsUpdate{Kind: UpdateScreenTimeout, Code: code}
}

// BrightnessUpdate is 0x030A.
func BrightnessUpdate(value byte) SettingsUpdate {
	return SettingsUpdate{Kind: UpdateBrightness, Code: value}
}

// KnobDirectionUpdate is 0x0310.
func KnobDirectionUpdate(code byte) SettingsUpdate {
	return SettingsUpdate{Kind: UpdateKnobDirection, Code: code}
}

// ClockUpdate is 0x030B.
func ClockUpdate(state ClockState) SettingsUpdate {
	return SettingsUpdate{Kind: UpdateClock, Clock: state.clone()}
}

// ThemeStatusUpdate is 0x0A02.
func ThemeStatusUpdate(state ClockState, customImageTimeDisplay bool) SettingsUpdate {
	return SettingsUpdate{Kind: UpdateThemeStatus, Clock: state.clone(), CustomImageTimeDisplay: customImageTimeDisplay}
}

// ChargingModeUpdate is 0x030D.
func ChargingModeUpdate(code byte, profile *CustomChargingProfile, priority *byte) SettingsUpdate {
	u := SettingsUpdate{Kind: UpdateChargingMode, Code: code, Priority: copyByte(priority)}
	if profile != nil {
		p := profile.clone()
		u.Profile = &p
	}
	return u
}

// PortPriorityUpdate is 0x030F with a bitmap.
func PortPriorityUpdate(bitmap byte) SettingsUpdate {
	return SettingsUpdate{Kind: UpdatePortPriority, Code: bitmap}
}

// SinglePortPriorityUpdate is 0x030F for one port.
func SinglePortPriorityUpdate(g PortGroup, preferred bool) SettingsUpdate {
	return SettingsUpdate{Kind: UpdateSinglePortPriority, Group: g, Preferred: preferred}
}

// ThemeDownloadUpdate is 0x0311.
func ThemeDownloadUpdate(themeID *uint32, status byte, themeCode *byte) SettingsUpdate {
	return SettingsUpdate{Kind: UpdateThemeDownload, ThemeID: copyU32(themeID), Status: status, ThemeCode: copyByte(themeCode)}
}

// FirmwareVersionUpdate is 0x0301.
func FirmwareVersionUpdate(version string) SettingsUpdate {
	return SettingsUpdate{Kind: UpdateFirmwareVersion, FirmwareVersion: version}
}

// WriteAcknowledgement is a write acknowledgement (0x0A01…0x0A23). Status is
// the byte after the message type: 0 = accepted, 4 = parameter rejected.
type WriteAcknowledgement struct {
	MessageType uint16
	Status      *byte
	Group       *PortGroup
	Slot        *ScheduleSlot
}

// IsRejected reports a non-zero status.
func (a WriteAcknowledgement) IsRejected() bool { return a.Status != nil && *a.Status != 0 }

// fieldReader reads TLV values as the official parser does: every value loses
// its leading type byte, whatever that byte is.
type fieldReader struct{ frame Frame }

func (r fieldReader) field(id byte) (TLV, bool) {
	for _, f := range r.frame.Fields {
		if f.ID == id {
			return f, true
		}
	}
	return TLV{}, false
}

func (r fieldReader) value(id byte) ([]byte, bool) {
	f, ok := r.field(id)
	if !ok || len(f.Raw) <= 1 {
		return nil, false
	}
	return f.Raw[1:], true
}

func (r fieldReader) byte(id byte) (byte, bool) {
	v, ok := r.value(id)
	if !ok {
		return 0, false
	}
	return v[0], true
}

func (r fieldReader) integer(id byte) (uint32, bool) {
	v, ok := r.value(id)
	if !ok || len(v) == 0 || len(v) > 4 {
		return 0, false
	}
	var out uint32
	for i, b := range v {
		out |= uint32(b) << (8 * uint32(i))
	}
	return out, true
}

func (r fieldReader) string(id byte) (string, bool) {
	if _, ok := r.field(id); !ok {
		return "", false
	}
	v, _ := r.value(id)
	for len(v) > 0 && v[len(v)-1] == 0 {
		v = v[:len(v)-1]
	}
	if !utf8.Valid(v) {
		return "", false
	}
	return string(v), true
}

func groupOfValue(v uint32, ok bool) (PortGroup, bool) {
	if !ok || v > uint32(GroupUSBA) {
		return 0, false
	}
	return PortGroup(v), true
}

// decimalVersion renders 0x0A00 A2: decimal digits joined by dots,
// 0x0840 = 2112 -> 2.1.1.2.
func decimalVersion(v uint32) (string, bool) {
	if v == 0 {
		return "", false
	}
	digits := strconv.FormatUint(uint64(v), 10)
	return strings.Join(strings.Split(digits, ""), "."), true
}

func decodePortControl(b []byte) (PortControl, bool) {
	if len(b) < 19 {
		return PortControl{}, false
	}
	return PortControl{
		IsOn:               b[0] == 1,
		PowerOn:            PortSchedule{RawSwitch: b[1], Hour: b[2], Minute: b[3], Weekdays: b[4]},
		PowerOff:           PortSchedule{RawSwitch: b[5], Hour: b[6], Minute: b[7], Weekdays: b[8]},
		CountdownEnabled:   b[9] == 1,
		CountdownTotal:     le32(b, 10),
		CountdownRemaining: le32(b, 14),
		Priority:           b[18],
	}, true
}

func decodeCustomProfile(b []byte, ok bool) *CustomChargingProfile {
	if !ok || len(b) < 7 {
		return nil
	}
	return &CustomChargingProfile{Number: b[0], AutoExit: b[1] == 1, Watts: append([]byte(nil), b[2:7]...)}
}

func decodeIdentities(b []byte, ok bool) []IdentitySlot {
	if !ok || len(b) < 16 {
		return []IdentitySlot{}
	}
	out := make([]IdentitySlot, 0, 4)
	for i, g := range USBCGroups {
		out = append(out, IdentitySlot{Group: g, First: le16(b, i*4), Second: le16(b, i*4+2)})
	}
	return out
}

func settingsFromFrame(f Frame) DeviceSettings {
	r := fieldReader{frame: f}
	s := DeviceSettings{PortControls: map[PortGroup]PortControl{}}
	if v, ok := r.integer(0xA2); ok {
		if version, ok := decimalVersion(v); ok {
			s.FirmwareVersion = &version
		}
	}
	if v, ok := r.integer(0xA3); ok {
		code := uint16(v)
		s.ErrorCode = &code
	}
	for _, g := range PortGroups {
		if b, ok := r.value(0xAA + byte(g)); ok {
			if c, ok := decodePortControl(b); ok {
				s.PortControls[g] = c
			}
		}
	}
	if af, ok := r.value(0xAF); ok {
		clock := clockFromFlags(af[0])
		if (clock.ThemeCode == 3 || clock.ThemeCode == 5) && len(af) >= 5 {
			id := le32(af, 1)
			clock.ThemeID = &id
		}
		s.Clock = &clock
	}
	if v, ok := r.byte(0xB0); ok {
		s.ScreenTimeoutCode = ptrByte(v & 0x0F)
	}
	if v, ok := r.byte(0xB1); ok {
		s.ChargingModeCode = ptrByte(v)
	}
	if v, ok := r.byte(0xB2); ok {
		s.IsUpdatingFirmware = ptrBool(v == 1)
	}
	if v, ok := r.byte(0xB3); ok {
		s.Brightness = ptrByte(v)
	}
	if v, ok := r.byte(0xB4); ok {
		s.KnobDirectionCode = ptrByte(v)
	}
	if v, ok := r.byte(0xB5); ok {
		s.HourFormatCode = ptrByte(v)
	}
	if v, ok := r.byte(0xB6); ok {
		s.ProtocolVersion = ptrByte(v)
	}
	raw, _ := r.integer(0xB7)
	caps := Capabilities(uint16(raw))
	s.Capabilities = &caps
	if caps.Has(CapCustomChargingMode) {
		s.CustomProfile = decodeCustomProfile(r.value(0xB8))
	}
	if caps.Has(CapClockSchedule) {
		if b, ok := r.value(0xB9); ok && len(b) >= 5 {
			s.ClockSchedule = &ClockSchedule{StartHour: b[0], StartMinute: b[1], EndHour: b[2], EndMinute: b[3], Weekdays: b[4]}
		}
	}
	if caps.Has(CapPortProtocols) {
		if b, ok := r.value(0xBA); ok && len(b) >= 12 {
			ports := make([]ProtocolFlags, 4)
			for i := range ports {
				ports[i] = ProtocolFlags(b[i*3] & 0x3F)
			}
			s.PortProtocols = &PortProtocols{Ports: ports}
		}
	}
	if caps.Has(CapMaxCompatibility) {
		if v, ok := r.byte(0xBB); ok {
			s.MaxCompatibility = ptrBool(v == 0)
		}
	}
	if caps.Has(CapUFCSSwitch) {
		if v, ok := r.byte(0xBC); ok {
			s.UFCS = ptrBool(v == 1)
		}
	}
	if caps.Has(CapDeviceIdentification) {
		if v, ok := r.byte(0xBF); ok {
			s.DeviceIdentification = ptrBool(v == 1)
		}
	}
	s.ConnectedDeviceUSB = decodeIdentities(r.value(0xBD))
	s.ConnectedDeviceBrand = decodeIdentities(r.value(0xBE))
	return s
}

func clockFromReader(r fieldReader) (ClockState, bool) {
	flags, ok := r.byte(0xA2)
	if !ok {
		return ClockState{}, false
	}
	clock := clockFromFlags(flags)
	if clock.ThemeCode == 3 || clock.ThemeCode == 5 {
		if id, ok := r.integer(0xA3); ok {
			clock.ThemeID = &id
		}
	}
	if url, ok := r.string(0xA4); ok && url != "" {
		clock.ThemeURL = &url
	}
	holiday, ok := r.byte(0xA5)
	clock.IsShowingHoliday = ptrBool(ok && holiday == 1)
	return clock, true
}

// decodeUpdates decodes the change messages; ok is false for any other type.
// A recognised type whose fields do not parse yields an empty list.
func decodeUpdates(f Frame) ([]SettingsUpdate, bool) {
	r := fieldReader{frame: f}
	none := []SettingsUpdate{}
	switch f.MessageType {
	case 0x0301:
		v, ok := r.integer(0xA2)
		if !ok {
			return none, true
		}
		version, ok := decimalVersion(v)
		if !ok {
			return none, true
		}
		return []SettingsUpdate{FirmwareVersionUpdate(version)}, true

	case 0x0302:
		g, ok := groupOfValue(r.integer(0xA2))
		state, ok2 := r.byte(0xA3)
		if !ok || !ok2 {
			return none, true
		}
		return []SettingsUpdate{PortOutputUpdate(g, state == 1)}, true

	case 0x0304:
		code, ok := r.integer(0xA2)
		if !ok {
			return none, true
		}
		return []SettingsUpdate{ErrorCodeUpdate(uint16(code))}, true

	case 0x0307:
		g, ok := groupOfValue(r.integer(0xA2))
		b, ok2 := r.value(0xA3)
		if !ok || !ok2 || len(b) < 9 {
			return none, true
		}
		return []SettingsUpdate{PortCountdownUpdate(g, b[0] == 1, le32(b, 1), le32(b, 5))}, true

	case 0x0308:
		g, ok := groupOfValue(r.integer(0xA2))
		slotByte, ok2 := r.byte(0xA3)
		b, ok3 := r.value(0xA4)
		if !ok || !ok2 || slotByte > byte(SlotPowerOn) || !ok3 || len(b) < 4 {
			return none, true
		}
		return []SettingsUpdate{PortScheduleUpdate(g, ScheduleSlot(slotByte), PortSchedule{
			RawSwitch: b[0], Hour: b[1], Minute: b[2], Weekdays: b[3],
		})}, true

	case 0x0309:
		code, ok := r.byte(0xA2)
		if !ok {
			return none, true
		}
		return []SettingsUpdate{ScreenTimeoutUpdate(code & 0x0F)}, true

	case 0x030A:
		v, ok := r.byte(0xA2)
		if !ok {
			return none, true
		}
		return []SettingsUpdate{BrightnessUpdate(v)}, true

	case 0x030B:
		clock, ok := clockFromReader(r)
		if !ok {
			return none, true
		}
		return []SettingsUpdate{ClockUpdate(clock)}, true

	case 0x0A02:
		clock, ok := clockFromReader(r)
		if !ok {
			return none, true
		}
		display, ok := r.byte(0xA6)
		return []SettingsUpdate{ThemeStatusUpdate(clock, ok && display == 1)}, true

	case 0x030D:
		code, ok := r.byte(0xA2)
		if !ok {
			return none, true
		}
		var priority *byte
		if p, ok := r.byte(0xA4); ok {
			priority = &p
		}
		return []SettingsUpdate{ChargingModeUpdate(code, decodeCustomProfile(r.value(0xA3)), priority)}, true

	case 0x030F:
		if bitmap, ok := r.byte(0xA3); ok {
			return []SettingsUpdate{PortPriorityUpdate(bitmap)}, true
		}
		if b, ok := r.value(0xA2); ok && len(b) >= 2 {
			if g, ok := groupOfValue(uint32(b[0]), true); ok && g != GroupUSBA {
				return []SettingsUpdate{SinglePortPriorityUpdate(g, b[1] == 1)}, true
			}
		}
		return none, true

	case 0x0310:
		code, ok := r.byte(0xA2)
		if !ok {
			return none, true
		}
		return []SettingsUpdate{KnobDirectionUpdate(code)}, true

	case 0x0311:
		status, ok := r.integer(0xA3)
		if !ok {
			return none, true
		}
		var themeID *uint32
		if id, ok := r.integer(0xA2); ok {
			themeID = &id
		}
		var themeCode *byte
		if c, ok := r.byte(0xA4); ok {
			themeCode = &c
		}
		return []SettingsUpdate{ThemeDownloadUpdate(themeID, byte(status), themeCode)}, true
	}
	return nil, false
}

func decodeWriteAcknowledgement(f Frame) (WriteAcknowledgement, bool) {
	t := f.MessageType
	if t&0xFF00 != 0x0A00 || t == 0x0A00 || t == 0x0A02 {
		return WriteAcknowledgement{}, false
	}
	r := fieldReader{frame: f}
	ack := WriteAcknowledgement{MessageType: t, Status: copyByte(f.Increment)}
	switch t {
	case 0x0A07, 0x0A09, 0x0A08:
		if g, ok := groupOfValue(r.integer(0xA2)); ok {
			ack.Group = &g
		}
		if t == 0x0A08 {
			if b, ok := r.byte(0xA3); ok && b <= byte(SlotPowerOn) {
				slot := ScheduleSlot(b)
				ack.Slot = &slot
			}
		}
	}
	return ack, true
}

func ptrByte(v byte) *byte { return &v }
func ptrBool(v bool) *bool { return &v }

func copyBool(p *bool) *bool {
	if p == nil {
		return nil
	}
	v := *p
	return &v
}

func copyU32(p *uint32) *uint32 {
	if p == nil {
		return nil
	}
	v := *p
	return &v
}

func copyString(p *string) *string {
	if p == nil {
		return nil
	}
	v := *p
	return &v
}
