package a2687

import (
	"encoding/binary"
	"fmt"
	"strconv"
	"time"

	"charker/internal/product"
)

// CableCapability is the cable rating reported in the port control struct.
type CableCapability uint8

const (
	// CableMax60W is code 0: a 3 A / 60 W cable.
	CableMax60W CableCapability = 0x00
	// CableMax100W is code 1: a 5 A / 100 W cable.
	CableMax100W CableCapability = 0x01
	// CableEPR240W is code 2: an EPR / 240 W cable.
	CableEPR240W CableCapability = 0x02
	// CableNone is code 3: nothing attached or not reported.
	CableNone CableCapability = 0x03
)

// ParseCableCapability maps a wire code. Unknown codes are preserved.
func ParseCableCapability(code byte) CableCapability { return CableCapability(code) }

// Code returns the wire code.
func (c CableCapability) Code() byte { return uint8(c) }

// IsNone reports whether the firmware said no cable is attached.
func (c CableCapability) IsNone() bool { return c == CableNone }

// IsEPR reports whether this is the 240 W EPR cable.
func (c CableCapability) IsEPR() bool { return c == CableEPR240W }

// Label returns the UI label and whether there is one. CableNone has no label;
// unknown codes are formatted, never invented.
func (c CableCapability) Label() (string, bool) {
	switch c {
	case CableMax60W:
		return "3A · 60 W", true
	case CableMax100W:
		return "5A · 100 W", true
	case CableEPR240W:
		return "EPR · 240 W", true
	case CableNone:
		return "", false
	default:
		return fmt.Sprintf("Unknown (0x%02X)", uint8(c)), true
	}
}

// ChargingProfile is the vendor fast-charge handshake reported alongside the
// cable capability. It is not the user-selectable charging mode.
type ChargingProfile uint8

const (
	ChargingProfileApplePD           ChargingProfile = 0x01
	ChargingProfileSamsungFast       ChargingProfile = 0x02
	ChargingProfileSamsungSuperFast  ChargingProfile = 0x03
	ChargingProfileHuaweiSCP         ChargingProfile = 0x05
	ChargingProfileXiaomiHyperCharge ChargingProfile = 0x06
)

// ParseChargingProfile maps a wire code. Code 0 means "none" and reports false;
// unknown non-zero codes are preserved.
func ParseChargingProfile(code byte) (ChargingProfile, bool) {
	if code == 0 {
		return 0, false
	}
	return ChargingProfile(code), true
}

// Code returns the wire code.
func (p ChargingProfile) Code() byte { return uint8(p) }

// Label returns the UI label; unknown codes are formatted.
func (p ChargingProfile) Label() string {
	switch p {
	case ChargingProfileApplePD:
		return "Apple PD"
	case ChargingProfileSamsungFast:
		return "Samsung Fast"
	case ChargingProfileSamsungSuperFast:
		return "Samsung Super Fast"
	case ChargingProfileHuaweiSCP:
		return "SCP"
	case ChargingProfileXiaomiHyperCharge:
		return "Xiaomi HyperCharge"
	default:
		return fmt.Sprintf("Unknown (0x%02X)", uint8(p))
	}
}

// String implements fmt.Stringer.
func (p ChargingProfile) String() string { return p.Label() }

// USB identity sentinels for the B4 block.
const (
	// USBEmptyVendorID and USBEmptyProductID form the "no identity reported"
	// sentinel FFFA:FFFB. It does not mean the port is empty.
	USBEmptyVendorID  uint16 = 0xFFFA
	USBEmptyProductID uint16 = 0xFFFB
)

// USBDeviceID is the USB identity of whatever is plugged into a port, from B4.
// There is deliberately no vendor-name lookup: a confidently wrong brand name is
// worse than a hex id the user can search.
type USBDeviceID struct {
	VendorID  uint16
	ProductID uint16
}

// IsNoIdentity reports the FFFA:FFFB sentinel: the firmware reported no USB
// identity for this slot. It says nothing about occupancy.
func (d USBDeviceID) IsNoIdentity() bool {
	return d.VendorID == USBEmptyVendorID && d.ProductID == USBEmptyProductID
}

// IsUnidentified reports 0000:0000: something is plugged in that never handed
// over a USB identity. A distinct state from IsNoIdentity.
func (d USBDeviceID) IsUnidentified() bool { return d.VendorID == 0 && d.ProductID == 0 }

// IsNamed reports an identity worth showing: neither sentinel.
func (d USBDeviceID) IsNamed() bool { return !d.IsNoIdentity() && !d.IsUnidentified() }

// HexDescription is the "VVVV:PPPP" form a USB id database is searched by.
func (d USBDeviceID) HexDescription() string {
	return fmt.Sprintf("%04X:%04X", d.VendorID, d.ProductID)
}

// String implements fmt.Stringer.
func (d USBDeviceID) String() string { return d.HexDescription() }

// idleControlPrefix is the byte pattern every captured idle control struct
// starts with: switch 1, no countdown task, 300/300 s. Kept as one constant so
// diagnostics can say "still the idle default" rather than dress up an
// unverified guess as a reading.
var idleControlPrefix = [10]byte{0x01, 0x00, 0x2C, 0x01, 0x00, 0x00, 0x2C, 0x01, 0x00, 0x00}

// IdleControlPrefix returns a copy of the idle control struct's first ten bytes.
func IdleControlPrefix() []byte {
	out := make([]byte, len(idleControlPrefix))
	copy(out, idleControlPrefix[:])
	return out
}

// PortControl is the per-port control struct carried in AC/AD/AE. Byte 0..9 are
// inferred and unverified; byte 10 (cable) is the one byte real hardware has been
// seen to change, and byte 11 is read as a charging profile.
type PortControl struct {
	// SwitchStatus is byte 0, unverified.
	SwitchStatus byte
	// CountdownTaskStatus is byte 1, unverified.
	CountdownTaskStatus byte
	// CountdownTotal is bytes 2..6, seconds, unverified.
	CountdownTotal uint32
	// CountdownRemaining is bytes 6..10, seconds, unverified.
	CountdownRemaining uint32
	// CableCode is byte 10.
	CableCode byte
	// ProfileCode is byte 11. Anker's struct calls this deviceVID, but a 16-bit
	// VID does not fit in one byte and the observed 01/02/03 line up with the
	// Apple-PD / Samsung-Fast / Samsung-Super-Fast table.
	ProfileCode byte
	// ExtraBytes is anything past byte 11, carried rather than dropped.
	ExtraBytes []byte
}

// ParsePortControl decodes the fixed-offset control struct. Short structs (under
// 12 bytes) yield no value at all rather than a guess: the decoder used to take
// the last two bytes, which produced a confident, wrong cable rating.
func ParsePortControl(data []byte) (*PortControl, bool) {
	if len(data) < 12 {
		return nil, false
	}
	extra := make([]byte, len(data)-12)
	copy(extra, data[12:])
	return &PortControl{
		SwitchStatus:        data[0],
		CountdownTaskStatus: data[1],
		CountdownTotal:      binary.LittleEndian.Uint32(data[2:6]),
		CountdownRemaining:  binary.LittleEndian.Uint32(data[6:10]),
		CableCode:           data[10],
		ProfileCode:         data[11],
		ExtraBytes:          extra,
	}, true
}

// Cable returns the decoded cable capability.
func (c PortControl) Cable() CableCapability { return CableCapability(c.CableCode) }

// ChargingProfile returns the decoded profile, false for code 0 (none).
func (c PortControl) ChargingProfile() (ChargingProfile, bool) {
	return ParseChargingProfile(c.ProfileCode)
}

// RunningCountdown returns a countdown the official home page would show, and
// whether one is running. Only trusted while the status byte says so.
func (c PortControl) RunningCountdown() (total, remaining uint32, ok bool) {
	if c.CountdownTaskStatus != 1 || c.CountdownRemaining == 0 {
		return 0, 0, false
	}
	if c.CountdownRemaining > c.CountdownTotal || c.CountdownTotal > 86400 {
		return 0, 0, false
	}
	return c.CountdownTotal, c.CountdownRemaining, true
}

// MatchesIdleDefault reports whether the first ten bytes still match the idle
// placeholder, i.e. whether the inferred countdown layout remains untested.
func (c PortControl) MatchesIdleDefault() bool {
	return c.SwitchStatus == idleControlPrefix[0] &&
		c.CountdownTaskStatus == idleControlPrefix[1] &&
		c.CountdownTotal == 300 && c.CountdownRemaining == 300
}

// PortTelemetry is one port's decoded live state.
type PortTelemetry struct {
	// Port is the port this reading belongs to.
	Port Port
	// StatusCode is the raw first byte of the port struct: 0 is off, other
	// values are output states whose enumeration is not established.
	StatusCode byte
	// Voltage is volts (mV/1000).
	Voltage float64
	// Current is amps (mA/1000).
	Current float64
	// Power is watts (cW/100).
	Power float64
	// Cable is valid only when HasCable is true; nil is not representable, so
	// HasCable carries the "reported at all" distinction.
	Cable    CableCapability
	HasCable bool
	// ChargingProfile is valid only when HasChargingProfile; it is surfaced only
	// while the port is delivering, never for an idle port.
	ChargingProfile    ChargingProfile
	HasChargingProfile bool
	// Control is the full AC/AD/AE struct, nil when absent or too short.
	Control *PortControl
	// ConnectedDevice is the B4 identity for this slot, nil when the frame
	// carried no B4 block or the block was too short to reach this port.
	ConnectedDevice *USBDeviceID
	// ExtraBytes is anything past the seven known live-struct bytes.
	ExtraBytes []byte
}

// IsOn reports whether the port's output switch is on (status byte != 0).
func (p PortTelemetry) IsOn() bool { return p.StatusCode != 0 }

// IsDelivering reports whether the port is on and actually charging: on, more
// than 0.02 A and more than 3.0 V. This answers "is it charging", nothing else.
func (p PortTelemetry) IsDelivering() bool {
	return p.IsOn() && p.Current > 0.02 && p.Voltage > 3.0
}

// HasReadings reports whether there is a real measurement worth showing. Unlike
// IsDelivering it is deliberately true for a cable-attached idle port (5.0 V /
// 0.0 A): the official app prints those numbers verbatim.
func (p PortTelemetry) HasReadings() bool {
	return p.IsOn() && (p.Voltage > 0 || p.Current > 0)
}

// IsCableAttached reports physical cable presence when the protocol says
// anything about it. The second return value is false when no cable data was
// reported at all — which is not the same as "unplugged".
func (p PortTelemetry) IsCableAttached() (attached, reported bool) {
	if p.IsDelivering() {
		return true, true
	}
	if !p.HasCable {
		return false, false
	}
	if p.Cable.IsNone() {
		return false, true
	}
	return true, true
}

// CableLabel returns the cable label when one is useful and reported.
func (p PortTelemetry) CableLabel() (string, bool) {
	if !p.HasCable {
		return "", false
	}
	return p.Cable.Label()
}

// DeviceInfo is the device identity recovered from the 0x0029 base-info
// response. Empty fields mean "not recovered", never "empty on the device".
type DeviceInfo struct {
	ProductName     string
	FirmwareVersion string
	SerialNumber    string
	MACAddress      string
}

// IsEmpty reports whether nothing was decoded.
func (d DeviceInfo) IsEmpty() bool {
	return d.ProductName == "" && d.FirmwareVersion == "" && d.SerialNumber == "" && d.MACAddress == ""
}

// DecodeDeviceInfo parses the 0x0029 base-info response. Its fields are raw
// ASCII, not typed values, and the role of each id is a content heuristic:
// anything that does not look right is left empty rather than guessed at.
func DecodeDeviceInfo(payload Payload) DeviceInfo {
	ascii := func(raw []byte, ok bool) string {
		if !ok || len(raw) == 0 {
			return ""
		}
		for _, b := range raw {
			if b < 0x20 || b >= 0x7F {
				return ""
			}
		}
		return string(raw)
	}
	var info DeviceInfo
	if raw, ok := payload.Field(FieldA2); ok {
		info.ProductName = ascii(raw, ok)
	}
	if raw, ok := payload.Field(FieldA3); ok {
		info.FirmwareVersion = ascii(raw, ok)
	}
	if serial := ascii(payload.Field(FieldA4)); len(serial) >= 8 {
		info.SerialNumber = serial
	}
	// A5 has been observed as six MAC bytes followed by an ASCII serial suffix.
	if raw, ok := payload.Field(FieldA5); ok && len(raw) >= 6 {
		mac := raw[:6]
		allPrintable := true
		for _, b := range mac {
			if b < 0x20 || b >= 0x7F {
				allPrintable = false
				break
			}
		}
		if !allPrintable {
			info.MACAddress = fmt.Sprintf("%02X:%02X:%02X:%02X:%02X:%02X",
				mac[0], mac[1], mac[2], mac[3], mac[4], mac[5])
		}
	}
	return info
}

// DeviceSettings is the charger's own settings as they stood when the link came
// up. These values do not refresh inside a session: a frame that omits them does
// not mean they changed. Keep the last non-nil snapshot of the link and clear it
// on every new handshake.
type DeviceSettings struct {
	// ScreenTimeout is A8, auto-lock enum: 0=30s, 1=1min, 2=5min, 3=30min, 4=12h.
	ScreenTimeout *byte
	// ScreenBrightness is A9, percent 0..100.
	ScreenBrightness *byte
	// ChargingMode is AA, the raw mode code: 0 AI, 1 standard, 2 custom. Kept
	// raw so an unnamed code survives to a bug report.
	ChargingMode *byte
	// ScreenOrientation is AF: 0 up, 1 left, 2 down, 3 right.
	ScreenOrientation *byte
	// GyroscopeEnabled is B2: the display's auto-rotation switch.
	GyroscopeEnabled *bool
}

// IsEmpty reports whether the frame named settings ids but none could be read.
// Distinct from ChargerTelemetry.Settings being nil, which means the frame
// carried no settings ids at all.
func (s *DeviceSettings) IsEmpty() bool {
	if s == nil {
		return true
	}
	return s.ScreenTimeout == nil && s.ScreenBrightness == nil && s.ChargingMode == nil &&
		s.ScreenOrientation == nil && s.GyroscopeEnabled == nil
}

// ScreenTimeoutCode returns A8 and whether it was readable.
func (s *DeviceSettings) ScreenTimeoutCode() (byte, bool) {
	if s == nil || s.ScreenTimeout == nil {
		return 0, false
	}
	return *s.ScreenTimeout, true
}

// BrightnessPercent returns A9 and whether it was readable.
func (s *DeviceSettings) BrightnessPercent() (byte, bool) {
	if s == nil || s.ScreenBrightness == nil {
		return 0, false
	}
	return *s.ScreenBrightness, true
}

// ModeCode returns AA and whether it was readable.
func (s *DeviceSettings) ModeCode() (byte, bool) {
	if s == nil || s.ChargingMode == nil {
		return 0, false
	}
	return *s.ChargingMode, true
}

// OrientationCode returns AF and whether it was readable.
func (s *DeviceSettings) OrientationCode() (byte, bool) {
	if s == nil || s.ScreenOrientation == nil {
		return 0, false
	}
	return *s.ScreenOrientation, true
}

// GyroEnabled returns B2 and whether it was readable.
func (s *DeviceSettings) GyroEnabled() (bool, bool) {
	if s == nil || s.GyroscopeEnabled == nil {
		return false, false
	}
	return *s.GyroscopeEnabled, true
}

// ChargerTelemetry is one immutable telemetry snapshot.
type ChargerTelemetry struct {
	// Ports are the ports the frame carried, in C1..C3 order.
	Ports []PortTelemetry
	// ReceivedAt is when the payload was decoded.
	ReceivedAt time.Time
	// SourceOpcode is the logical opcode this snapshot came from.
	SourceOpcode uint16
	// UnknownFields holds the first occurrence of every id the decoder
	// recognised the shape of but not the meaning of.
	UnknownFields map[byte][]byte
	// AllFields is every TLV in wire order, unfiltered and unmerged.
	AllFields FrameFields
	// Settings is nil when the frame carried none of the settings ids. It is a
	// handshake-time snapshot, not a live reading; see DeviceSettings.
	Settings *DeviceSettings
}

// HasPortData reports whether the frame carried any A5/A6/A7 struct. False for a
// bind ack or a trigger reply: still worth recording, but it must not replace
// the live readings.
func (t ChargerTelemetry) HasPortData() bool { return len(t.Ports) > 0 }

// TotalPower is the sum of the power of on ports. Derived locally: the A2687
// exposes no trustworthy device total, and an off port's stale numbers are not
// summed.
func (t ChargerTelemetry) TotalPower() float64 {
	var total float64
	for _, p := range t.Ports {
		if p.IsOn() {
			total += p.Power
		}
	}
	return total
}

// ActivePortCount counts ports that are actually delivering.
func (t ChargerTelemetry) ActivePortCount() int {
	count := 0
	for _, p := range t.Ports {
		if p.IsDelivering() {
			count++
		}
	}
	return count
}

// Port returns the reading of one port.
func (t ChargerTelemetry) Port(p Port) (PortTelemetry, bool) {
	for _, port := range t.Ports {
		if port.Port == p {
			return port, true
		}
	}
	return PortTelemetry{}, false
}

// settingByte reads a one-byte setting whether the firmware wrapped it in a
// TypedValue or wrote it bare. Anything wider is refused rather than squeezed
// into a byte: a field that suddenly arrives as a u16 is not what two reconnects
// said it is, and that deserves a blank.
func settingByte(payload Payload, id byte) (byte, bool) {
	raw, ok := payload.Field(id)
	if !ok || len(raw) == 0 {
		return 0, false
	}
	if len(raw) == 1 {
		return raw[0], true
	}
	switch value := DecodeTypedValue(raw); value.Kind {
	case TypedKindU8:
		return byte(value.Number), true
	case TypedKindBytes:
		if len(value.Data) == 1 {
			return value.Data[0], true
		}
	}
	return 0, false
}

// byteBlock unwraps a TypedValue byte array, falling back to the bare TLV value.
//
// The 0x04 wrapper is the norm, but B4 arrives bare, and that is not theoretical:
// the moment a port is unplugged the block starts FA FF…, and DecodeTypedValue
// would take 0xFA for a type prefix and hand back the bytes shifted by one —
// every port misread, no error.
func byteBlock(payload Payload, id byte) ([]byte, bool) {
	raw, ok := payload.Field(id)
	if !ok {
		return nil, false
	}
	if value := DecodeTypedValue(raw); value.Kind == TypedKindBytes {
		return value.Data, true
	}
	return raw, true
}

// decodeConnectedDevices decodes the B4 block: three VID(2 LE)+PID(2 LE)
// records, C1/C2/C3 in wire order. A short block yields fewer ports rather than
// a guess.
func decodeConnectedDevices(payload Payload) map[Port]USBDeviceID {
	block, ok := byteBlock(payload, FieldB4)
	if !ok || len(block) == 0 {
		return nil
	}
	out := make(map[Port]USBDeviceID, len(Ports))
	for _, port := range Ports {
		base := int(port.Index()) * 4
		if base+4 > len(block) {
			break
		}
		out[port] = USBDeviceID{
			VendorID:  binary.LittleEndian.Uint16(block[base : base+2]),
			ProductID: binary.LittleEndian.Uint16(block[base+2 : base+4]),
		}
	}
	return out
}

// decodePort decodes the seven-byte live port struct.
func decodePort(port Port, value TypedValue, ok bool) (PortTelemetry, bool) {
	if !ok || value.Kind != TypedKindBytes || len(value.Data) < 7 {
		return PortTelemetry{}, false
	}
	data := value.Data
	extra := make([]byte, len(data)-7)
	copy(extra, data[7:])
	return PortTelemetry{
		Port:       port,
		StatusCode: data[0],
		Voltage:    float64(binary.LittleEndian.Uint16(data[1:3])) / 1000.0,
		Current:    float64(binary.LittleEndian.Uint16(data[3:5])) / 1000.0,
		Power:      float64(binary.LittleEndian.Uint16(data[5:7])) / 100.0,
		ExtraBytes: extra,
	}, true
}

// knownFieldIDs are the ids whose shape and meaning are settled on this
// hardware. They gate UnknownFields only; AllFields keeps everything.
var knownFieldIDs = map[byte]bool{
	FieldA1: true, FieldA2: true, FieldA5: true, FieldA6: true, FieldA7: true,
	FieldA8: true, FieldA9: true, FieldAA: true, FieldAF: true, FieldB2: true,
	FieldAC: true, FieldAD: true, FieldAE: true, FieldB4: true, FieldFE: true,
}

// settingsFieldIDs are the ids that make a frame carry a settings snapshot.
var settingsFieldIDs = map[byte]bool{
	FieldA8: true, FieldA9: true, FieldAA: true, FieldAF: true, FieldB2: true,
}

// DecodeSettings decodes the settings snapshot. It returns nil when the frame
// mentions none of the settings ids. "Mentioned" is about the ids, not the
// values: a frame that carries A9 in a shape this decoder will not read still
// returns an empty, present snapshot.
func DecodeSettings(payload Payload) *DeviceSettings {
	mentioned := false
	for _, field := range payload.Fields {
		if settingsFieldIDs[field.ID] {
			mentioned = true
			break
		}
	}
	if !mentioned {
		return nil
	}
	settings := &DeviceSettings{}
	if value, ok := settingByte(payload, FieldA8); ok && value <= 4 {
		settings.ScreenTimeout = &value
	}
	if value, ok := settingByte(payload, FieldA9); ok && value <= 100 {
		// Above 100 it is not the percentage two cross-session samples showed,
		// so it goes unread: "137 %" on a screen is worse than a dash.
		settings.ScreenBrightness = &value
	}
	if value, ok := settingByte(payload, FieldAA); ok {
		settings.ChargingMode = &value
	}
	if value, ok := settingByte(payload, FieldAF); ok && value <= 3 {
		settings.ScreenOrientation = &value
	}
	if value, ok := settingByte(payload, FieldB2); ok && value <= 1 {
		enabled := value == 1
		settings.GyroscopeEnabled = &enabled
	}
	return settings
}

// DecodeTelemetry decodes everything the frame carries and never discards it.
// It always returns a snapshot, even for a payload with no port struct; callers
// decide what to do with it via HasPortData.
func DecodeTelemetry(payload Payload, opcode uint16, now time.Time) ChargerTelemetry {
	devices := decodeConnectedDevices(payload)
	ports := make([]PortTelemetry, 0, len(Ports))
	for _, port := range Ports {
		value, ok := payload.Typed(port.TelemetryField())
		telemetry, ok := decodePort(port, value, ok)
		if !ok {
			continue
		}
		if controlValue, ok := payload.Typed(port.CableField()); ok && controlValue.Kind == TypedKindBytes {
			if control, valid := ParsePortControl(controlValue.Data); valid {
				telemetry.Control = control
				telemetry.HasCable = true
				telemetry.Cable = control.Cable()
				if profile, hasProfile := control.ChargingProfile(); hasProfile && telemetry.IsDelivering() {
					telemetry.ChargingProfile = profile
					telemetry.HasChargingProfile = true
				}
			}
		}
		if device, ok := devices[port]; ok {
			connected := device
			telemetry.ConnectedDevice = &connected
		}
		ports = append(ports, telemetry)
	}

	unknown := make(map[byte][]byte)
	for _, field := range payload.Fields {
		if knownFieldIDs[field.ID] {
			continue
		}
		if _, seen := unknown[field.ID]; !seen {
			unknown[field.ID] = field.Value
		}
	}
	if len(unknown) == 0 {
		unknown = nil
	}
	return ChargerTelemetry{
		Ports:         ports,
		ReceivedAt:    now,
		SourceOpcode:  opcode,
		UnknownFields: unknown,
		AllFields:     NewFrameFields(payload.Fields),
		Settings:      DecodeSettings(payload),
	}
}

// ProductReading maps the telemetry to the frozen transport-neutral product
// model.
//
// The result always carries the product's three ports (C1, C2, C3) in order,
// because product.Reading.Port addresses ports by their position in
// Product.PortIDs(): a partial frame fills the slots it did not mention with zero
// readings. In practice the firmware reports all three port structs or none —
// check HasPortData (or use Link.DecodeTelemetry, which reports it as an error)
// before treating a reading as live.
//
// Off ports contribute zero volts/amps/watts, because the product contract says
// readings are zero when idle and an off port's leftover values are stale, not
// live.
func (t ChargerTelemetry) ProductReading() product.Reading {
	reading := product.Reading{
		Product:    product.ProductA2687,
		ReceivedAt: t.ReceivedAt,
		Ports:      make([]product.PortReading, len(Ports)),
	}
	for index, portID := range Ports {
		telemetry, ok := t.Port(portID)
		if !ok {
			continue
		}
		port := product.PortReading{
			Enabled: telemetry.IsOn(),
			Status:  int(telemetry.StatusCode),
		}
		if telemetry.IsOn() {
			port.Volts = telemetry.Voltage
			port.Amps = telemetry.Current
			port.Watts = telemetry.Power
		}
		if label, ok := telemetry.CableLabel(); ok {
			port.Cable = label
		}
		if telemetry.HasCable && telemetry.Cable.IsEPR() {
			port.EPR = true
		}
		if telemetry.HasChargingProfile {
			port.Protocol = telemetry.ChargingProfile.Label()
		}
		if telemetry.ConnectedDevice != nil && telemetry.ConnectedDevice.IsNamed() {
			port.VID = telemetry.ConnectedDevice.VendorID
			port.PID = telemetry.ConnectedDevice.ProductID
		}
		reading.Ports[index] = port
	}
	reading.TotalWattsOf()
	return reading
}

// ProductSettings maps the settings snapshot to the frozen product model.
//
// Mapped fields, all as the device reported them in this link's handshake
// snapshot:
//
//   - Brightness (A9) and Orientation (AF), unchanged.
//   - ScreenTimeout (A8) as the UI/session vocabulary "30s"/"1m"/"5m"/"30m"/"12h",
//     or the raw decimal code when the firmware reports one outside 0..4.
//   - ChargingMode (AA) as "ai"/"standard"/"custom" (the values the settings UI
//     and session parseSetting accept), or the raw decimal code otherwise.
//   - AutoRotate (B2) as a bool.
//
// The A2687 snapshot has no language, theme, screen-on or fixed-allocation
// read-back field, so those stay nil. AutoLock stays nil too: it is a lossy bool
// for a five-value timeout enum (session's write path treats code 4 = 12h as
// off), and ScreenTimeout carries the exact value instead.
//
// Returns nil when the frame carried no settings ids. The full raw snapshot
// stays available on DeviceSettings for the session/Devices layer.
func (t ChargerTelemetry) ProductSettings() *product.Settings {
	if t.Settings == nil {
		return nil
	}
	settings := &product.Settings{}
	if brightness, ok := t.Settings.BrightnessPercent(); ok {
		value := int(brightness)
		settings.Brightness = &value
	}
	if orientation, ok := t.Settings.OrientationCode(); ok {
		value := ScreenOrientation(orientation).String()
		settings.Orientation = &value
	}
	if timeout, ok := t.Settings.ScreenTimeoutCode(); ok {
		value := productScreenTimeout(timeout)
		settings.ScreenTimeout = &value
	}
	if mode, ok := t.Settings.ModeCode(); ok {
		value := productChargingMode(mode)
		settings.ChargingMode = &value
	}
	if autoRotate, ok := t.Settings.GyroEnabled(); ok {
		settings.AutoRotate = &autoRotate
	}
	return settings
}

// productScreenTimeout renders an A2687 A8 code in the vocabulary the settings UI
// and the session's SetSetting("screenTimeout", ...) use. Unknown codes are the
// raw decimal code, never a guessed label.
func productScreenTimeout(code byte) string {
	if code <= uint8(ScreenTimeoutTwelveHours) {
		return ScreenTimeout(code).String()
	}
	return strconv.Itoa(int(code))
}

// productChargingMode renders an A2687 AA code in the vocabulary the settings UI
// and the session's SetSetting("chargingMode", ...) use. Unnamed codes are the
// raw decimal code (e.g. "4"), never a guessed name.
func productChargingMode(code byte) string {
	switch ChargingMode(code) {
	case ChargingModeAI, ChargingModeStandard, ChargingModeCustom:
		return ChargingMode(code).String()
	default:
		return strconv.Itoa(int(code))
	}
}

// ProductPortControls maps the per-port switch state (and, only while the
// unverified countdown bytes say a countdown is running, its minutes) to the
// frozen product model. Returns nil for a frame with no port data.
//
// The countdown layout is inferred on this firmware, not confirmed: the two
// minute fields stay zero unless PortControl.RunningCountdown accepts the bytes
// (task status 1, 0 < remaining <= total <= 86400), which is the only shape the
// official app is known to trust.
func (t ChargerTelemetry) ProductPortControls() map[product.PortID]product.PortControl {
	if len(t.Ports) == 0 {
		return nil
	}
	controls := make(map[product.PortID]product.PortControl, len(t.Ports))
	for _, telemetry := range t.Ports {
		control := product.PortControl{Enabled: telemetry.IsOn()}
		if telemetry.Control != nil {
			if total, remaining, ok := telemetry.Control.RunningCountdown(); ok {
				control.TimerMinutes = int(total / 60)
				control.CountdownMinutes = int((remaining + 59) / 60)
			}
		}
		controls[productPortID(telemetry.Port)] = control
	}
	return controls
}

// productPortID maps an A2687 wire port to the shared port identity.
func productPortID(port Port) product.PortID {
	switch port {
	case PortC2:
		return product.PortC2
	case PortC3:
		return product.PortC3
	default:
		return product.PortC1
	}
}
