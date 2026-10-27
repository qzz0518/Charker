package a2345

import (
	"fmt"
	"math/bits"
	"sort"
	"time"
)

// EncodedField is one request TLV before encoding: tag and bare value.
type EncodedField struct {
	Tag   byte
	Value []byte
}

// EncodeFrame is the FF09 request encoder of the official app 3.24.0
// (ZXCommandTransformer._getSettingCommand / _getNormalCommand):
//
//	FF 09 | uint16LE length incl. checksum | 03 00 0F | uint16BE type
//	A1 01 22 | TLVs sorted by tag | FE 05 03 <uint32LE epoch> | XOR
//
// Each TLV is tag | length | type | value, where length counts the type byte
// and type depends only on the value length: 1 -> 01, 2 -> 02, 4 -> 03,
// anything else (including empty) -> 04. With allowsLongFields a length above
// 0x78 is written as two little-endian bytes. MQTT frames are not encrypted;
// the session prefix 22 marks the cloud path.
func EncodeFrame(messageType uint16, fields []EncodedField, allowsLongFields bool, at time.Time) []byte {
	epoch := uint32(at.Unix())
	out := []byte{
		Header[0], Header[1],
		0x00, 0x00, // total length, filled in once the frame is complete
		ProtocolVersion, 0x00, 0x0F,
		byte(messageType >> 8), byte(messageType),
		FieldA1, 0x01, 0x22,
	}
	sorted := append([]EncodedField(nil), fields...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Tag < sorted[j].Tag })
	for _, f := range sorted {
		out = append(out, f.Tag)
		length := len(f.Value) + 1
		if allowsLongFields && length > 0x78 {
			out = append(out, byte(length), byte(length>>8))
		} else {
			out = append(out, byte(length))
		}
		out = append(out, valueTypeForLength(len(f.Value)))
		out = append(out, f.Value...)
	}
	out = append(out, FieldTimestamp, 0x05, ValueVariable,
		byte(epoch), byte(epoch>>8), byte(epoch>>16), byte(epoch>>24))
	total := len(out) + 1
	out[2] = byte(total)
	out[3] = byte(total >> 8)
	return append(out, Checksum(out))
}

func valueTypeForLength(n int) byte {
	switch n {
	case 1:
		return 0x01
	case 2:
		return 0x02
	case 4:
		return 0x03
	}
	return 0x04
}

// StatusSnapshotRequest is 0x0200: one full device-state snapshot.
func StatusSnapshotRequest(at time.Time) []byte { return EncodeFrame(0x0200, nil, false, at) }

// RealtimeTriggerRequest is 0x020B: begin realtime telemetry reporting.
func RealtimeTriggerRequest(at time.Time) []byte { return EncodeFrame(0x020B, nil, false, at) }

// CommandError reports a parameter the charger would not accept.
type CommandError struct{ Parameter string }

// Error implements error.
func (e *CommandError) Error() string { return "a2345: invalid parameter: " + e.Parameter }

func invalid(p string) error { return &CommandError{Parameter: p} }

// CommandKind names one member of the closed request set.
type CommandKind int

// Command kinds. Every one maps to a setter of the official app's
// A2345DeviceController; none takes a raw message type or raw bytes.
const (
	CmdStatusSnapshot CommandKind = iota + 1
	CmdThemeStatus
	CmdRealtimeTrigger
	CmdSetPortOutput
	CmdSetPortSchedule
	CmdSetPortCountdown
	CmdSetChargingMode
	CmdSetCustomChargingMode
	CmdExitCustomChargingMode
	CmdSetPortPriority
	CmdSetScreenTimeout
	CmdSetBrightness
	CmdSetKnobDirection
	CmdSetHourFormat
	CmdSetClockSchedule
	CmdSetHolidayTheme
	CmdSetClockTheme
	CmdSetCustomImageTimeDisplay
	CmdSetMaxCompatibility
	CmdSetDeviceIdentification
	CmdSetUFCS
)

// Command is one request Charker sends to an A2345. Build it with the
// constructors; the zero value is not a valid command.
type Command struct {
	kind          CommandKind
	group         PortGroup
	on            bool
	slot          ScheduleSlot
	schedule      PortSchedule
	seconds       uint32
	mode          ChargingMode
	profile       CustomChargingProfile
	protocols     *PortProtocols
	value         byte
	clockSchedule ClockSchedule
	theme         ClockThemeRequest
}

// RequestStatusSnapshot is 0x0200. (The name StatusSnapshot belongs to the
// decoded 0x0A00 type.)
func RequestStatusSnapshot() Command { return Command{kind: CmdStatusSnapshot} }

// ThemeStatus is 0x0202: clock/theme state, answered by 0x0A02.
func ThemeStatus() Command { return Command{kind: CmdThemeStatus} }

// RealtimeTrigger is 0x020B.
func RealtimeTrigger() Command { return Command{kind: CmdRealtimeTrigger} }

// RequestThemeStatus is ThemeStatus, named like RequestStatusSnapshot.
func RequestThemeStatus() Command { return ThemeStatus() }

// RequestRealtimeTrigger is RealtimeTrigger, named like RequestStatusSnapshot.
func RequestRealtimeTrigger() Command { return RealtimeTrigger() }

// SetPortOutput is 0x0207.
func SetPortOutput(g PortGroup, on bool) Command {
	return Command{kind: CmdSetPortOutput, group: g, on: on}
}

// SetPortSchedule is 0x0208: one of the two daily slots of a port group.
func SetPortSchedule(g PortGroup, slot ScheduleSlot, s PortSchedule) Command {
	return Command{kind: CmdSetPortSchedule, group: g, slot: slot, schedule: s}
}

// SetPortCountdown is 0x0209. seconds is resent unchanged when cancelling,
// as the official app does.
func SetPortCountdown(g PortGroup, enabled bool, seconds uint32) Command {
	return Command{kind: CmdSetPortCountdown, group: g, on: enabled, seconds: seconds}
}

// SetChargingMode is 0x0206 with a preset mode 1–4.
func SetChargingMode(m ChargingMode) Command { return Command{kind: CmdSetChargingMode, mode: m} }

// SetCustomChargingMode is 0x0206 with mode 5 and the active custom profile.
func SetCustomChargingMode(p CustomChargingProfile, protocols *PortProtocols) Command {
	c := Command{kind: CmdSetCustomChargingMode, profile: p.clone()}
	if protocols != nil {
		pp := protocols.clone()
		c.protocols = &pp
	}
	return c
}

// ExitCustomChargingMode is 0x0211; the official app only ever sends "off".
func ExitCustomChargingMode() Command { return Command{kind: CmdExitCustomChargingMode} }

// SetPortPriority is 0x020C: bit0…bit3 = C1…C4, at most two bits.
func SetPortPriority(bitmap byte) Command { return Command{kind: CmdSetPortPriority, value: bitmap} }

// SetScreenTimeout is 0x0203.
func SetScreenTimeout(t ScreenTimeout) Command {
	return Command{kind: CmdSetScreenTimeout, value: byte(t)}
}

// SetBrightness is 0x0204: 20…100 in steps of 5.
func SetBrightness(percent byte) Command { return Command{kind: CmdSetBrightness, value: percent} }

// SetKnobDirection is 0x020E.
func SetKnobDirection(d KnobDirection) Command {
	return Command{kind: CmdSetKnobDirection, value: byte(d)}
}

// SetHourFormat is 0x0210.
func SetHourFormat(f HourFormat) Command { return Command{kind: CmdSetHourFormat, value: byte(f)} }

// SetClockSchedule is 0x0213.
func SetClockSchedule(s ClockSchedule) Command {
	return Command{kind: CmdSetClockSchedule, clockSchedule: s}
}

// SetHolidayTheme is 0x020F.
func SetHolidayTheme(on bool) Command { return Command{kind: CmdSetHolidayTheme, on: on} }

// SetClockTheme is 0x0205: the clock switch plus the theme it shows.
func SetClockTheme(r ClockThemeRequest) Command {
	return Command{kind: CmdSetClockTheme, theme: r.clone()}
}

// SetCustomImageTimeDisplay is 0x0222.
func SetCustomImageTimeDisplay(on bool) Command {
	return Command{kind: CmdSetCustomImageTimeDisplay, on: on}
}

// SetMaxCompatibility is 0x0214, sent inverted: 0 turns it on.
func SetMaxCompatibility(on bool) Command { return Command{kind: CmdSetMaxCompatibility, on: on} }

// SetDeviceIdentification is 0x0223.
func SetDeviceIdentification(on bool) Command {
	return Command{kind: CmdSetDeviceIdentification, on: on}
}

// SetUFCS is 0x0215 (mainland firmware without protocol management).
func SetUFCS(on bool) Command { return Command{kind: CmdSetUFCS, on: on} }

// Kind returns the command kind.
func (c Command) Kind() CommandKind { return c.kind }

// MessageType returns the 0x02NN request type.
func (c Command) MessageType() uint16 {
	switch c.kind {
	case CmdStatusSnapshot:
		return 0x0200
	case CmdThemeStatus:
		return 0x0202
	case CmdRealtimeTrigger:
		return 0x020B
	case CmdSetPortOutput:
		return 0x0207
	case CmdSetPortSchedule:
		return 0x0208
	case CmdSetPortCountdown:
		return 0x0209
	case CmdSetChargingMode, CmdSetCustomChargingMode:
		return 0x0206
	case CmdExitCustomChargingMode:
		return 0x0211
	case CmdSetPortPriority:
		return 0x020C
	case CmdSetScreenTimeout:
		return 0x0203
	case CmdSetBrightness:
		return 0x0204
	case CmdSetKnobDirection:
		return 0x020E
	case CmdSetHourFormat:
		return 0x0210
	case CmdSetClockSchedule:
		return 0x0213
	case CmdSetHolidayTheme:
		return 0x020F
	case CmdSetClockTheme:
		return 0x0205
	case CmdSetCustomImageTimeDisplay:
		return 0x0222
	case CmdSetMaxCompatibility:
		return 0x0214
	case CmdSetDeviceIdentification:
		return 0x0223
	case CmdSetUFCS:
		return 0x0215
	}
	return 0
}

// AcknowledgementType is the 0x0ANN the charger answers a 0x02NN with. Reads
// of the snapshot and theme are answered by their data message instead.
func (c Command) AcknowledgementType() (uint16, bool) {
	switch c.kind {
	case CmdStatusSnapshot, CmdThemeStatus:
		return 0, false
	}
	return 0x0A00 | c.MessageType()&0x00FF, true
}

// IsWrite reports whether the command changes the charger.
func (c Command) IsWrite() bool {
	switch c.kind {
	case CmdStatusSnapshot, CmdThemeStatus, CmdRealtimeTrigger:
		return false
	}
	return c.kind != 0
}

// Group returns the port group of a port output, schedule or countdown write.
func (c Command) Group() (PortGroup, bool) {
	switch c.kind {
	case CmdSetPortOutput, CmdSetPortSchedule, CmdSetPortCountdown:
		return c.group, true
	}
	return 0, false
}

// Slot returns the schedule slot of a port schedule write.
func (c Command) Slot() (ScheduleSlot, bool) {
	if c.kind == CmdSetPortSchedule {
		return c.slot, true
	}
	return 0, false
}

// On returns the switch value of a port output, countdown or switch write.
func (c Command) On() bool { return c.on }

// Schedule returns the schedule of a port schedule write.
func (c Command) Schedule() PortSchedule { return c.schedule }

// CountdownSeconds returns the seconds of a countdown write.
func (c Command) CountdownSeconds() uint32 { return c.seconds }

// Value returns the single-byte value of a priority, screen timeout,
// brightness, knob or hour-format write.
func (c Command) Value() byte { return c.value }

// Mode returns the preset of a charging-mode write.
func (c Command) Mode() ChargingMode { return c.mode }

// Profile returns a copy of the profile and protocols of a custom-mode write.
func (c Command) Profile() (CustomChargingProfile, *PortProtocols) {
	p := c.profile.clone()
	if c.protocols == nil {
		return p, nil
	}
	pp := c.protocols.clone()
	return p, &pp
}

// ClockScheduleValue returns the schedule of a clock-schedule write.
func (c Command) ClockScheduleValue() ClockSchedule { return c.clockSchedule }

// ClockTheme returns a copy of the request of a clock-theme write.
func (c Command) ClockTheme() (ClockThemeRequest, bool) {
	if c.kind == CmdSetClockTheme {
		return c.theme.clone(), true
	}
	return ClockThemeRequest{}, false
}

// String names the request type, e.g. "0x0207".
func (c Command) String() string { return fmt.Sprintf("0x%04X", c.MessageType()) }

// Encode validates the command and returns the request frame.
func (c Command) Encode(at time.Time) ([]byte, error) {
	if c.kind == 0 {
		return nil, invalid("command")
	}
	fields, long, err := c.encodedFields()
	if err != nil {
		return nil, err
	}
	return EncodeFrame(c.MessageType(), fields, long, at), nil
}

func boolByte(on bool) byte {
	if on {
		return 1
	}
	return 0
}

func one(tag, value byte) []EncodedField { return []EncodedField{{Tag: tag, Value: []byte{value}}} }

func (c Command) encodedFields() ([]EncodedField, bool, error) {
	switch c.kind {
	case CmdStatusSnapshot, CmdThemeStatus, CmdRealtimeTrigger:
		return nil, false, nil

	case CmdExitCustomChargingMode:
		return one(0xA2, 0x00), false, nil

	case CmdSetPortOutput:
		return []EncodedField{
			{Tag: 0xA2, Value: []byte{byte(c.group)}},
			{Tag: 0xA3, Value: []byte{boolByte(c.on)}},
		}, false, nil

	case CmdSetPortSchedule:
		if err := c.schedule.validate(); err != nil {
			return nil, false, err
		}
		return []EncodedField{
			{Tag: 0xA2, Value: []byte{byte(c.group)}},
			{Tag: 0xA3, Value: []byte{byte(c.slot)}},
			{Tag: 0xA4, Value: []byte{boolByte(c.schedule.IsEnabled()), c.schedule.Hour, c.schedule.Minute, c.schedule.Weekdays & 0x7F}},
		}, false, nil

	case CmdSetPortCountdown:
		// Cancelling echoes whatever total the charger reported.
		if c.on && c.seconds > 86_400 {
			return nil, false, invalid("countdown")
		}
		return []EncodedField{
			{Tag: 0xA2, Value: []byte{byte(c.group)}},
			{Tag: 0xA3, Value: append([]byte{boolByte(c.on)}, littleEndian32(c.seconds)...)},
		}, false, nil

	case CmdSetChargingMode:
		return one(0xA2, byte(c.mode)), false, nil

	case CmdSetCustomChargingMode:
		if err := c.profile.validate(); err != nil {
			return nil, false, err
		}
		fields := []EncodedField{
			{Tag: 0xA2, Value: []byte{CustomModeCode}},
			{Tag: 0xA3, Value: c.profile.encoded()},
		}
		if c.protocols != nil {
			fields = append(fields, EncodedField{Tag: 0xA4, Value: c.protocols.encoded()})
		}
		return fields, false, nil

	case CmdSetPortPriority:
		if c.value&0xF0 != 0 || bits.OnesCount8(c.value) > 2 {
			return nil, false, invalid("priority")
		}
		return one(0xA2, c.value), false, nil

	case CmdSetScreenTimeout, CmdSetKnobDirection, CmdSetHourFormat:
		return one(0xA2, c.value), false, nil

	case CmdSetBrightness:
		if c.value < 20 || c.value > 100 || c.value%5 != 0 {
			return nil, false, invalid("brightness")
		}
		return one(0xA2, c.value), false, nil

	case CmdSetClockSchedule:
		s := c.clockSchedule
		if err := s.validate(); err != nil {
			return nil, false, err
		}
		return []EncodedField{{Tag: 0xA2, Value: []byte{s.StartHour, s.StartMinute, s.EndHour, s.EndMinute, s.Weekdays & 0x7F}}}, false, nil

	case CmdSetClockTheme:
		return c.theme.encodedFields()

	case CmdSetHolidayTheme, CmdSetCustomImageTimeDisplay, CmdSetDeviceIdentification, CmdSetUFCS:
		return one(0xA2, boolByte(c.on)), false, nil

	case CmdSetMaxCompatibility:
		return one(0xA2, boolByte(!c.on)), false, nil
	}
	return nil, false, invalid("command")
}

func littleEndian32(v uint32) []byte {
	return []byte{byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24)}
}

// PortGroup numbers ports as the control messages do. USB-A A1 and A2 share
// one switch, one countdown and one schedule; only their telemetry is
// separate.
type PortGroup int

// Port groups.
const (
	GroupC1 PortGroup = iota
	GroupC2
	GroupC3
	GroupC4
	GroupUSBA
)

// PortGroups lists every group in wire order.
var PortGroups = []PortGroup{GroupC1, GroupC2, GroupC3, GroupC4, GroupUSBA}

// USBCGroups lists C1…C4.
var USBCGroups = []PortGroup{GroupC1, GroupC2, GroupC3, GroupC4}

// Label returns "C1" … "C4" or "A1/A2".
func (g PortGroup) Label() string {
	switch g {
	case GroupC1:
		return "C1"
	case GroupC2:
		return "C2"
	case GroupC3:
		return "C3"
	case GroupC4:
		return "C4"
	case GroupUSBA:
		return "A1/A2"
	}
	return fmt.Sprintf("group%d", int(g))
}

// Ports returns the telemetry ports of the group.
func (g PortGroup) Ports() []Port {
	switch g {
	case GroupC1:
		return []Port{PortC1}
	case GroupC2:
		return []Port{PortC2}
	case GroupC3:
		return []Port{PortC3}
	case GroupC4:
		return []Port{PortC4}
	case GroupUSBA:
		return []Port{PortA1, PortA2}
	}
	return nil
}

// GroupOf returns the control group of a telemetry port.
func GroupOf(p Port) PortGroup {
	switch p {
	case PortC1:
		return GroupC1
	case PortC2:
		return GroupC2
	case PortC3:
		return GroupC3
	case PortC4:
		return GroupC4
	}
	return GroupUSBA
}

// ScheduleSlot is one of a group's two daily schedules.
type ScheduleSlot byte

// Schedule slots.
const (
	SlotPowerOff ScheduleSlot = 0
	SlotPowerOn  ScheduleSlot = 1
)

// PortSchedule is one daily on/off time. Weekdays bit0 = Monday … bit6 =
// Sunday; zero runs once at the next occurrence. The charger reports 0xFF in
// RawSwitch for a slot that was never set.
type PortSchedule struct {
	RawSwitch byte
	Hour      byte
	Minute    byte
	Weekdays  byte
}

// NewPortSchedule builds a schedule with a plain on/off switch.
func NewPortSchedule(enabled bool, hour, minute, weekdays byte) PortSchedule {
	return PortSchedule{RawSwitch: boolByte(enabled), Hour: hour, Minute: minute, Weekdays: weekdays}
}

// IsEnabled reports switch value 1.
func (s PortSchedule) IsEnabled() bool { return s.RawSwitch == 1 }

// IsUnset reports a slot that was never set.
func (s PortSchedule) IsUnset() bool { return s.RawSwitch == 0xFF }

// RepeatDays is the weekday mask without the bit the charger sets for unset
// slots.
func (s PortSchedule) RepeatDays() byte {
	if s.IsUnset() {
		return 0
	}
	return s.Weekdays & 0x7F
}

func (s PortSchedule) validate() error {
	if s.Hour >= 24 || s.Minute >= 60 {
		return invalid("schedule")
	}
	return nil
}

// ChargingMode is a preset charging mode.
type ChargingMode byte

// Charging modes.
const (
	ModeAIPower      ChargingMode = 1
	ModePortPriority ChargingMode = 2
	ModeDualLaptop   ChargingMode = 3
	ModeLowCurrent   ChargingMode = 4
)

// ChargingModes lists the presets.
var ChargingModes = []ChargingMode{ModeAIPower, ModePortPriority, ModeDualLaptop, ModeLowCurrent}

// CustomModeCode is the charging-mode code of custom mode.
const CustomModeCode byte = 5

// CustomTotalLimit is the official app's cap on a custom profile's sum, in W.
const CustomTotalLimit = 250

// USBAWattChoices are the only limits the USB-A pair takes.
var USBAWattChoices = []byte{0, 15, 24}

// CustomChargingProfile is a set of per-port limits for custom mode, in
// watts. C ports take 0 or 15…max; the USB-A pair only 0, 15 or 24.
type CustomChargingProfile struct {
	Number   byte
	AutoExit bool
	// Watts: C1, C2, C3, C4, USB-A.
	Watts []byte
}

// MaximumWatts is the upper limit per group: C2–C4 allow 120 W on mainland
// units.
func MaximumWatts(g PortGroup, mainland bool) byte {
	switch g {
	case GroupC1:
		return 140
	case GroupUSBA:
		return 24
	}
	if mainland {
		return 120
	}
	return 100
}

func (p CustomChargingProfile) clone() CustomChargingProfile {
	if p.Watts != nil {
		p.Watts = append([]byte(nil), p.Watts...)
	}
	return p
}

func (p CustomChargingProfile) encoded() []byte {
	return append([]byte{p.Number, boolByte(p.AutoExit)}, p.Watts...)
}

func (p CustomChargingProfile) validate() error {
	if p.Number < 1 || p.Number > 4 || len(p.Watts) != 5 {
		return invalid("custom profile")
	}
	sum := 0
	for _, w := range p.Watts {
		sum += int(w)
	}
	if sum > CustomTotalLimit {
		return invalid("custom profile")
	}
	usbA := false
	for _, w := range USBAWattChoices {
		if p.Watts[4] == w {
			usbA = true
		}
	}
	if !usbA {
		return invalid("custom profile")
	}
	for _, w := range p.Watts[:4] {
		if w != 0 && (w < 15 || w > 140) {
			return invalid("custom profile")
		}
	}
	return nil
}

// ProtocolFlags are the fast-charge protocols allowed on one C port in custom
// mode. On overseas firmware bit0 = SCP; mainland units reuse bit0 for Huawei
// and add bit6 for Xiaomi.
type ProtocolFlags byte

// Protocol flags.
const (
	ProtoSCP    ProtocolFlags = 1 << 0
	ProtoUFCS   ProtocolFlags = 1 << 1
	ProtoPD12V  ProtocolFlags = 1 << 2
	ProtoPPS11V ProtocolFlags = 1 << 3
	ProtoPPS16V ProtocolFlags = 1 << 4
	ProtoPPS21V ProtocolFlags = 1 << 5
	ProtoXiaomi ProtocolFlags = 1 << 6
	// ProtoHuawei is mainland firmware's name for the SCP bit.
	ProtoHuawei ProtocolFlags = 1 << 0
)

// PortProtocols holds the flags of C1…C4.
type PortProtocols struct {
	Ports []ProtocolFlags
}

func (p PortProtocols) clone() PortProtocols {
	if p.Ports != nil {
		p.Ports = append([]ProtocolFlags(nil), p.Ports...)
	}
	return p
}

func (p PortProtocols) encoded() []byte {
	var out []byte
	for i, f := range p.Ports {
		if i == 4 {
			break
		}
		out = append(out, byte(f), 0x00, 0x00)
	}
	return out
}

// ScreenTimeout is the display's auto-off time.
type ScreenTimeout byte

// Screen timeouts.
const (
	ScreenAlwaysOn      ScreenTimeout = 0
	ScreenThirtySeconds ScreenTimeout = 1
	ScreenOneMinute     ScreenTimeout = 2
	ScreenFiveMinutes   ScreenTimeout = 3
	ScreenThirtyMinutes ScreenTimeout = 4
)

// KnobDirection is the knob's rotation sense.
type KnobDirection byte

// Knob directions.
const (
	KnobForward  KnobDirection = 0
	KnobBackward KnobDirection = 1
)

// HourFormat is the clock's 12/24-hour format.
type HourFormat byte

// Hour formats.
const (
	HourFormat12 HourFormat = 0
	HourFormat24 HourFormat = 1
)

// ClockSchedule is when the clock screensaver is shown. Weekdays bit0 =
// Monday … bit6 = Sunday.
type ClockSchedule struct {
	StartHour   byte
	StartMinute byte
	EndHour     byte
	EndMinute   byte
	Weekdays    byte
}

func (s ClockSchedule) validate() error {
	if s.StartHour >= 24 || s.EndHour >= 24 || s.StartMinute >= 60 || s.EndMinute >= 60 {
		return invalid("clock schedule")
	}
	return nil
}

// ThemeKind is a clock screensaver theme: 0–2 the built-in styles, 3 a cloud
// picture and 5 a picture the user uploaded.
type ThemeKind byte

// Theme kinds.
const (
	ThemeStyle1  ThemeKind = 0
	ThemeStyle2  ThemeKind = 1
	ThemeStyle3  ThemeKind = 2
	ThemePicture ThemeKind = 3
	ThemeCustom  ThemeKind = 5
)

// IsBuiltIn reports styles 0–2.
func (k ThemeKind) IsBuiltIn() bool { return k <= ThemeStyle3 }

// ValidThemeKind maps a theme code onto a kind.
func ValidThemeKind(b byte) (ThemeKind, bool) {
	switch k := ThemeKind(b); k {
	case ThemeStyle1, ThemeStyle2, ThemeStyle3, ThemePicture, ThemeCustom:
		return k, true
	}
	return 0, false
}

// ClockThemeRequest is everything 0x0205 carries. Switching the clock on or
// off resends the current theme unchanged; there is no separate switch.
type ClockThemeRequest struct {
	ClockOn bool
	Kind    ThemeKind
	ThemeID *uint32
	// ImageCRC is the CRC-32 of the picture file; zero for built-in styles.
	ImageCRC uint32
	// TextColor defaults to 0xFFFFFFFF (see NewClockThemeRequest).
	TextColor uint32
	// URL is image_url for cloud themes and the official app's asset path for
	// built-in styles. It goes in A6 with a one-byte length.
	URL string
	// CustomURL is the direct link of an uploaded picture. When non-empty it
	// goes in A7 and replaces A6, as the official app does over Wi-Fi.
	CustomURL string
}

// NewClockThemeRequest builds a request with the default white text colour.
func NewClockThemeRequest(clockOn bool, kind ThemeKind, themeID *uint32, imageCRC uint32, url string) ClockThemeRequest {
	return ClockThemeRequest{
		ClockOn: clockOn, Kind: kind, ThemeID: copyU32(themeID),
		ImageCRC: imageCRC, TextColor: 0xFFFF_FFFF, URL: url,
	}
}

// BuiltInStyleURL is the asset path the official app sends for style 0…2.
func BuiltInStyleURL(k ThemeKind) string {
	return fmt.Sprintf("assets/img/a2345/icl_a2345_theme%d.png", int(k)+1)
}

func (r ClockThemeRequest) clone() ClockThemeRequest {
	r.ThemeID = copyU32(r.ThemeID)
	return r
}

func (r ClockThemeRequest) encodedFields() ([]EncodedField, bool, error) {
	flags := byte(r.Kind) & 0x7F
	if r.ClockOn {
		flags |= 0x80
	}
	fields := []EncodedField{{Tag: 0xA2, Value: []byte{flags}}}
	if r.Kind == ThemePicture || r.Kind == ThemeCustom {
		if r.ThemeID == nil {
			return nil, false, invalid("theme id")
		}
		fields = append(fields, EncodedField{Tag: 0xA3, Value: littleEndian32(*r.ThemeID)})
	} else {
		fields = append(fields, EncodedField{Tag: 0xA3, Value: []byte{}})
	}
	fields = append(fields,
		EncodedField{Tag: 0xA4, Value: littleEndian32(r.ImageCRC)},
		EncodedField{Tag: 0xA5, Value: littleEndian32(r.TextColor)},
	)
	if r.CustomURL != "" {
		b := []byte(r.CustomURL)
		if len(b) > 1024 {
			return nil, false, invalid("url")
		}
		return append(fields, EncodedField{Tag: 0xA7, Value: b}), true, nil
	}
	b := []byte(r.URL)
	// A6 has a one-byte length; the official app silently truncates longer
	// values, which corrupts the frame.
	if len(b) > 254 {
		return nil, false, invalid("url")
	}
	return append(fields, EncodedField{Tag: 0xA6, Value: b}), false, nil
}
