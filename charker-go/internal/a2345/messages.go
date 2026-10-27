package a2345

import (
	"fmt"
	"strings"
	"unicode/utf8"

	"charker/internal/product"
)

// Message types.
const (
	MsgRealtime       uint16 = 0x0303
	MsgVersionInfo    uint16 = 0x0830
	MsgStatusSnapshot uint16 = 0x0A00
	MsgRealtimeAck    uint16 = 0x0A0B
)

// IsRelatedAcknowledgement reports whether t is one of the fourteen-byte
// acknowledgement shapes DecodeAcknowledgement accepts.
func IsRelatedAcknowledgement(t uint16) bool {
	switch t {
	case 0x0A0A, 0x0A0B, 0x0A14:
		return true
	}
	return false
}

// Field ids.
const (
	FieldA1        byte = 0xA1
	FieldA2        byte = 0xA2
	FieldA3        byte = 0xA3
	FieldA4        byte = 0xA4
	FieldA5        byte = 0xA5
	FieldA6        byte = 0xA6
	FieldA7        byte = 0xA7
	FieldA8        byte = 0xA8
	FieldA9        byte = 0xA9
	FieldTimestamp byte = 0xFE
)

// Value-type prefixes.
const (
	ValueString   byte = 0x00
	ValueVariable byte = 0x03
	ValueBinary   byte = 0x04
)

// Port is one of the six outputs as telemetry numbers them.
type Port int

// Ports.
const (
	PortC1 Port = iota
	PortC2
	PortC3
	PortC4
	PortA1
	PortA2
)

// Ports lists every port in wire order.
var Ports = []Port{PortC1, PortC2, PortC3, PortC4, PortA1, PortA2}

// USBCPorts lists C1…C4.
var USBCPorts = []Port{PortC1, PortC2, PortC3, PortC4}

// Label returns "C1" … "A2".
func (p Port) Label() string {
	switch p {
	case PortC1:
		return "C1"
	case PortC2:
		return "C2"
	case PortC3:
		return "C3"
	case PortC4:
		return "C4"
	case PortA1:
		return "A1"
	case PortA2:
		return "A2"
	}
	return fmt.Sprintf("port%d", int(p))
}

// TelemetryField is the 0x0303 field carrying this port (A2…A7).
func (p Port) TelemetryField() byte { return FieldA2 + byte(p) }

// ProductPort maps to the shared product port id.
func (p Port) ProductPort() product.PortID { return product.PortID(p.Label()) }

// IsUSBC reports whether p is one of C1…C4.
func (p Port) IsUSBC() bool { return p >= PortC1 && p <= PortC4 }

// PortReading is one port's electrical state.
type PortReading struct {
	// Status: only 0 = inactive and 1 = active are established.
	Status     byte
	Millivolts uint16
	Milliamps  uint16
	Centiwatts uint16
	// Mainland firmware tail, as the official app 3.24.0 reads it; nil when
	// the field was too short to carry the byte.
	// Cable: 0 = 3 A, 1 = 5 A, 2 = EPR, 3 = Huawei, 4 = Xiaomi.
	Cable *byte
	// FastCharge: 0 = none, 1 = Huawei SCP, 2 = Xiaomi HyperCharge.
	FastCharge *byte
	// DeviceBrand: 0 = unknown, 1 = Huawei/Honor, 2 = Xiaomi.
	DeviceBrand *byte
}

// IsActive reports status 1.
func (r PortReading) IsActive() bool { return r.Status == 1 }

// Voltage in volts.
func (r PortReading) Voltage() float64 { return float64(r.Millivolts) * 0.001 }

// Current in amperes.
func (r PortReading) Current() float64 { return float64(r.Milliamps) * 0.001 }

// Power in watts.
func (r PortReading) Power() float64 { return float64(r.Centiwatts) * 0.01 }

// A8Slot is one of the four C1…C4 raw metadata slots in field A8. Both words
// stay deliberately unnamed until a second known-device differential test.
type A8Slot struct {
	Port  Port
	Raw   []byte
	Word0 uint16
	Word1 uint16
}

// IsAllOnesSentinel reports an all-0xFF slot.
func (s A8Slot) IsAllOnesSentinel() bool { return allBytes(s.Raw, 0xFF) }

// IsUnidentified reports an all-zero slot.
func (s A8Slot) IsUnidentified() bool { return allBytes(s.Raw, 0x00) }

// ProvisionalSlot is one four-byte C-port slot from optional field A9.
type ProvisionalSlot struct {
	Port  Port
	Raw   []byte
	Word0 uint16
	Word1 uint16
}

// IsAllOnesSentinel reports an all-0xFF slot.
func (s ProvisionalSlot) IsAllOnesSentinel() bool { return allBytes(s.Raw, 0xFF) }

// IsUnidentified reports an all-zero slot.
func (s ProvisionalSlot) IsUnidentified() bool { return allBytes(s.Raw, 0x00) }

func allBytes(b []byte, v byte) bool {
	for _, x := range b {
		if x != v {
			return false
		}
	}
	return true
}

// RealtimeTelemetry is one 0x0303 report.
type RealtimeTelemetry struct {
	ResponseMarker *byte
	Ports          map[Port]PortReading
	A8Slots        []A8Slot
	// ProvisionalSlots is nil on firmware that predates A9.
	ProvisionalSlots []ProvisionalSlot
	Timestamp        *uint32
	UnknownFields    []TLV
}

// VersionInfo is the 0x0830 message.
type VersionInfo struct {
	HardwareVersion string
	SoftwareVersion string
	ProductCode     *string
	MCUComponent    *string
	ESP32Component  *string
	UnknownFields   []TLV
}

// StatusSnapshot is the 0x0A00 full-device response. A4…A9 reuse the port
// shape and map to C1…C4, A1, A2; every other field is decoded into Settings.
// UnknownFields keeps all non-port fields in wire form.
type StatusSnapshot struct {
	Ports         map[Port]PortReading
	Settings      DeviceSettings
	UnknownFields []TLV
}

// Acknowledgement is the fourteen-byte 0x0A0A/0x0A0B/0x0A14 shape. Marker
// 0x34 is kept as a marker, not labelled success or error.
type Acknowledgement struct {
	MessageType uint16
	Increment   *byte
	Marker      byte
}

// MessageKind discriminates DecodedMessage.
type MessageKind int

// Message kinds.
const (
	MessageRealtime MessageKind = iota + 1
	MessageStatusSnapshot
	MessageVersionInfo
	MessageSettingsUpdate
	MessageAcknowledgement
	MessageUnknown
)

// DecodedMessage is one decoded frame; exactly the field matching Kind is set
// (Frame for MessageUnknown).
type DecodedMessage struct {
	Kind            MessageKind
	Realtime        *RealtimeTelemetry
	StatusSnapshot  *StatusSnapshot
	VersionInfo     *VersionInfo
	Updates         []SettingsUpdate
	Acknowledgement *WriteAcknowledgement
	Frame           *Frame
}

// MessageErrorKind discriminates MessageError.
type MessageErrorKind int

// Message error kinds.
const (
	MsgErrMissingField MessageErrorKind = iota + 1
	MsgErrDuplicateField
	MsgErrInvalidFieldLength
	MsgErrUnexpectedFieldType
	MsgErrInvalidUTF8
	MsgErrInvalidAcknowledgementLength
	MsgErrUnexpectedMessageType
)

// MessageError reports a frame whose fields do not have the expected shape.
type MessageError struct {
	Kind MessageErrorKind
	// ID is the field for field-level errors.
	ID byte
	// Expected and Actual are lengths for InvalidFieldLength;
	// Actual alone for InvalidAcknowledgementLength.
	Expected int
	Actual   int
	// ExpectedType and ActualType belong to UnexpectedFieldType; ActualType
	// is nil for an empty field.
	ExpectedType byte
	ActualType   *byte
	// ExpectedMessage and ActualMessage belong to UnexpectedMessageType.
	ExpectedMessage uint16
	ActualMessage   uint16
}

// Error implements error.
func (e *MessageError) Error() string {
	switch e.Kind {
	case MsgErrMissingField:
		return fmt.Sprintf("a2345 message: missing field 0x%02X", e.ID)
	case MsgErrDuplicateField:
		return fmt.Sprintf("a2345 message: duplicate field 0x%02X", e.ID)
	case MsgErrInvalidFieldLength:
		return fmt.Sprintf("a2345 message: field 0x%02X length %d, expected %d", e.ID, e.Actual, e.Expected)
	case MsgErrUnexpectedFieldType:
		actual := "none"
		if e.ActualType != nil {
			actual = fmt.Sprintf("0x%02X", *e.ActualType)
		}
		return fmt.Sprintf("a2345 message: field 0x%02X type %s, expected 0x%02X", e.ID, actual, e.ExpectedType)
	case MsgErrInvalidUTF8:
		return fmt.Sprintf("a2345 message: field 0x%02X is not UTF-8", e.ID)
	case MsgErrInvalidAcknowledgementLength:
		return fmt.Sprintf("a2345 message: acknowledgement length %d", e.Actual)
	case MsgErrUnexpectedMessageType:
		return fmt.Sprintf("a2345 message: type 0x%04X, expected 0x%04X", e.ActualMessage, e.ExpectedMessage)
	default:
		return "a2345 message: malformed"
	}
}

// DecodeMessage decodes one frame into the message its type names.
func DecodeMessage(f Frame) (DecodedMessage, error) {
	switch f.MessageType {
	case MsgRealtime:
		t, err := DecodeRealtime(f)
		if err != nil {
			return DecodedMessage{}, err
		}
		return DecodedMessage{Kind: MessageRealtime, Realtime: &t}, nil
	case MsgStatusSnapshot:
		s, err := DecodeStatusSnapshot(f)
		if err != nil {
			return DecodedMessage{}, err
		}
		return DecodedMessage{Kind: MessageStatusSnapshot, StatusSnapshot: &s}, nil
	case MsgVersionInfo:
		v, err := DecodeVersionInfo(f)
		if err != nil {
			return DecodedMessage{}, err
		}
		return DecodedMessage{Kind: MessageVersionInfo, VersionInfo: &v}, nil
	}
	if updates, ok := decodeUpdates(f); ok {
		return DecodedMessage{Kind: MessageSettingsUpdate, Updates: updates}, nil
	}
	if ack, ok := decodeWriteAcknowledgement(f); ok {
		return DecodedMessage{Kind: MessageAcknowledgement, Acknowledgement: &ack}, nil
	}
	frame := f
	return DecodedMessage{Kind: MessageUnknown, Frame: &frame}, nil
}

// DecodeRealtime decodes a 0x0303 report.
func DecodeRealtime(f Frame) (RealtimeTelemetry, error) {
	if f.MessageType != MsgRealtime {
		return RealtimeTelemetry{}, &MessageError{Kind: MsgErrUnexpectedMessageType, ExpectedMessage: MsgRealtime, ActualMessage: f.MessageType}
	}
	ports := make(map[Port]PortReading, len(Ports))
	for _, port := range Ports {
		field, err := requiredField(port.TelemetryField(), f)
		if err != nil {
			return RealtimeTelemetry{}, err
		}
		reading, err := decodePortReading(field)
		if err != nil {
			return RealtimeTelemetry{}, err
		}
		ports[port] = reading
	}

	// A8/A9 are metadata, not electrical readings. Firmware ships both with
	// and without A9, so a new type/length or a duplicate must not discard
	// otherwise valid six-port telemetry. A decoded optional field is marked
	// consumed; anything else stays in UnknownFields with its raw bytes.
	consumed := map[int]bool{}
	t := RealtimeTelemetry{Ports: ports, A8Slots: []A8Slot{}}

	if raw, ok := optionalSlotBytes(FieldA8, f, consumed); ok {
		for i, port := range USBCPorts {
			slot := append([]byte(nil), raw[i*4:i*4+4]...)
			t.A8Slots = append(t.A8Slots, A8Slot{Port: port, Raw: slot, Word0: le16(slot, 0), Word1: le16(slot, 2)})
		}
	}
	if raw, ok := optionalSlotBytes(FieldA9, f, consumed); ok {
		t.ProvisionalSlots = make([]ProvisionalSlot, 0, 4)
		for i, port := range USBCPorts {
			slot := append([]byte(nil), raw[i*4:i*4+4]...)
			t.ProvisionalSlots = append(t.ProvisionalSlots, ProvisionalSlot{Port: port, Raw: slot, Word0: le16(slot, 0), Word1: le16(slot, 2)})
		}
	}
	if idx := matchingIndexes(FieldA1, f); len(idx) == 1 && len(f.Fields[idx[0]].Raw) == 1 {
		consumed[idx[0]] = true
		marker := f.Fields[idx[0]].Raw[0]
		t.ResponseMarker = &marker
	}
	if idx := matchingIndexes(FieldTimestamp, f); len(idx) == 1 {
		raw := f.Fields[idx[0]].Raw
		if len(raw) == 5 && raw[0] == ValueVariable {
			consumed[idx[0]] = true
			ts := le32(raw[1:], 0)
			t.Timestamp = &ts
		}
	}

	core := map[byte]bool{}
	for _, port := range Ports {
		core[port.TelemetryField()] = true
	}
	t.UnknownFields = []TLV{}
	for i, field := range f.Fields {
		if core[field.ID] || consumed[i] {
			continue
		}
		t.UnknownFields = append(t.UnknownFields, field)
	}
	return t, nil
}

// DecodeStatusSnapshot decodes a 0x0A00 full-device response.
func DecodeStatusSnapshot(f Frame) (StatusSnapshot, error) {
	if f.MessageType != MsgStatusSnapshot {
		return StatusSnapshot{}, &MessageError{Kind: MsgErrUnexpectedMessageType, ExpectedMessage: MsgStatusSnapshot, ActualMessage: f.MessageType}
	}
	ports := make(map[Port]PortReading, len(Ports))
	known := map[byte]bool{}
	for offset, port := range Ports {
		id := FieldA4 + byte(offset)
		field, err := requiredField(id, f)
		if err != nil {
			return StatusSnapshot{}, err
		}
		reading, err := decodePortReading(field)
		if err != nil {
			return StatusSnapshot{}, err
		}
		ports[port] = reading
		known[id] = true
	}
	unknown := []TLV{}
	for _, field := range f.Fields {
		if !known[field.ID] {
			unknown = append(unknown, field)
		}
	}
	return StatusSnapshot{Ports: ports, Settings: settingsFromFrame(f), UnknownFields: unknown}, nil
}

// DecodeVersionInfo decodes a 0x0830 message.
func DecodeVersionInfo(f Frame) (VersionInfo, error) {
	if f.MessageType != MsgVersionInfo {
		return VersionInfo{}, &MessageError{Kind: MsgErrUnexpectedMessageType, ExpectedMessage: MsgVersionInfo, ActualMessage: f.MessageType}
	}
	hwField, err := requiredField(FieldA1, f)
	if err != nil {
		return VersionInfo{}, err
	}
	hardware, err := versionString(hwField)
	if err != nil {
		return VersionInfo{}, err
	}
	swField, err := requiredField(FieldA2, f)
	if err != nil {
		return VersionInfo{}, err
	}
	software, err := versionString(swField)
	if err != nil {
		return VersionInfo{}, err
	}
	software = strings.TrimPrefix(software, "v")
	v := VersionInfo{HardwareVersion: hardware, SoftwareVersion: software}
	for _, opt := range []struct {
		id  byte
		dst **string
	}{{FieldA3, &v.ProductCode}, {FieldA4, &v.MCUComponent}, {FieldA5, &v.ESP32Component}} {
		field, ok, err := optionalField(opt.id, f)
		if err != nil {
			return VersionInfo{}, err
		}
		if !ok {
			continue
		}
		s, err := versionString(field)
		if err != nil {
			return VersionInfo{}, err
		}
		*opt.dst = &s
	}
	v.UnknownFields = []TLV{}
	for _, field := range f.Fields {
		switch field.ID {
		case FieldA1, FieldA2, FieldA3, FieldA4, FieldA5:
		default:
			v.UnknownFields = append(v.UnknownFields, field)
		}
	}
	return v, nil
}

// DecodeAcknowledgement decodes the fourteen-byte 0x0A0A/0x0A0B/0x0A14 shape.
func DecodeAcknowledgement(f Frame) (Acknowledgement, error) {
	if !IsRelatedAcknowledgement(f.MessageType) {
		return Acknowledgement{}, &MessageError{Kind: MsgErrUnexpectedMessageType, ExpectedMessage: MsgRealtimeAck, ActualMessage: f.MessageType}
	}
	if f.EncodedLength != 14 {
		return Acknowledgement{}, &MessageError{Kind: MsgErrInvalidAcknowledgementLength, Actual: f.EncodedLength}
	}
	field, err := requiredField(FieldA1, f)
	if err != nil {
		return Acknowledgement{}, err
	}
	if len(field.Raw) != 1 {
		return Acknowledgement{}, &MessageError{Kind: MsgErrInvalidFieldLength, ID: field.ID, Expected: 1, Actual: len(field.Raw)}
	}
	return Acknowledgement{MessageType: f.MessageType, Increment: copyByte(f.Increment), Marker: field.Raw[0]}, nil
}

// decodePortReading reads the first seven payload bytes. Mainland firmware
// 1.4.0.2 appends cable rating, fast-charge protocol and device brand; the
// official app 3.24.0 reads both shapes by length alone.
func decodePortReading(field TLV) (PortReading, error) {
	value, err := typedPayload(field, ValueBinary, 7)
	if err != nil {
		return PortReading{}, err
	}
	r := PortReading{
		Status:     value[0],
		Millivolts: le16(value, 1),
		Milliamps:  le16(value, 3),
		Centiwatts: le16(value, 5),
	}
	// Same length gates as the official parser: cable and protocol need a
	// payload longer than 8, the brand one longer than 9.
	if len(value) > 8 {
		cable, fast := value[7], value[8]
		r.Cable, r.FastCharge = &cable, &fast
	}
	if len(value) > 9 {
		brand := value[9]
		r.DeviceBrand = &brand
	}
	return r, nil
}

func matchingIndexes(id byte, f Frame) []int {
	var out []int
	for i, field := range f.Fields {
		if field.ID == id {
			out = append(out, i)
		}
	}
	return out
}

func optionalSlotBytes(id byte, f Frame, consumed map[int]bool) ([]byte, bool) {
	idx := matchingIndexes(id, f)
	if len(idx) != 1 {
		return nil, false
	}
	raw := f.Fields[idx[0]].Raw
	if len(raw) != 17 || raw[0] != ValueBinary {
		return nil, false
	}
	consumed[idx[0]] = true
	return raw[1:], true
}

func requiredField(id byte, f Frame) (TLV, error) {
	field, ok, err := optionalField(id, f)
	if err != nil {
		return TLV{}, err
	}
	if !ok {
		return TLV{}, &MessageError{Kind: MsgErrMissingField, ID: id}
	}
	return field, nil
}

func optionalField(id byte, f Frame) (TLV, bool, error) {
	idx := matchingIndexes(id, f)
	switch len(idx) {
	case 0:
		return TLV{}, false, nil
	case 1:
		return f.Fields[idx[0]], true, nil
	}
	return TLV{}, false, &MessageError{Kind: MsgErrDuplicateField, ID: id}
}

func typedPayload(field TLV, valueType byte, minimumPayload int) ([]byte, error) {
	if len(field.Raw) == 0 || field.Raw[0] != valueType {
		var actual *byte
		if len(field.Raw) > 0 {
			actual = copyByte(&field.Raw[0])
		}
		return nil, &MessageError{Kind: MsgErrUnexpectedFieldType, ID: field.ID, ExpectedType: valueType, ActualType: actual}
	}
	if len(field.Raw) < minimumPayload+1 {
		return nil, &MessageError{Kind: MsgErrInvalidFieldLength, ID: field.ID, Expected: minimumPayload + 1, Actual: len(field.Raw)}
	}
	return field.Raw[1:], nil
}

// versionString reads version strings, which arrive both with a leading 0x00
// type byte and without one; printable first bytes are kept.
func versionString(field TLV) (string, error) {
	if len(field.Raw) == 0 || (field.Raw[0] != ValueString && field.Raw[0] < 0x20) {
		var actual *byte
		if len(field.Raw) > 0 {
			actual = copyByte(&field.Raw[0])
		}
		return "", &MessageError{Kind: MsgErrUnexpectedFieldType, ID: field.ID, ExpectedType: ValueString, ActualType: actual}
	}
	b := field.Raw
	if b[0] == ValueString {
		b = b[1:]
	}
	for len(b) > 0 && b[len(b)-1] == 0 {
		b = b[:len(b)-1]
	}
	if !utf8.Valid(b) {
		return "", &MessageError{Kind: MsgErrInvalidUTF8, ID: field.ID}
	}
	return string(b), nil
}

func le16(b []byte, at int) uint16 { return uint16(b[at]) | uint16(b[at+1])<<8 }

func le32(b []byte, at int) uint32 {
	return uint32(b[at]) | uint32(b[at+1])<<8 | uint32(b[at+2])<<16 | uint32(b[at+3])<<24
}

func copyByte(p *byte) *byte {
	if p == nil {
		return nil
	}
	v := *p
	return &v
}
