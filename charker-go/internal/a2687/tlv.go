package a2687

import (
	"encoding/binary"
	"fmt"
	"strings"
)

// TypedValue type prefixes (spec-protocol §2.3).
const (
	TypedTextType  byte = 0x00
	TypedU8Type    byte = 0x01
	TypedU16Type   byte = 0x02
	TypedU32Type   byte = 0x03
	TypedBytesType byte = 0x04
)

// TLV is one id|length|value record from a frame payload.
type TLV struct {
	ID    byte
	Value []byte
}

// NewTLV builds a record. The value is copied.
func NewTLV(id byte, value []byte) TLV {
	return TLV{ID: id, Value: append([]byte(nil), value...)}
}

// TLVError reports a truncated TLV record.
type TLVError struct {
	// Offset is the index at which parsing failed.
	Offset int
}

// Error implements error.
func (e *TLVError) Error() string {
	return fmt.Sprintf("tlv: truncated record at %d", e.Offset)
}

// EncodeTLVs serialises records in order. Lengths are truncated to one byte
// (UInt8(truncatingIfNeeded:)) exactly like the Swift encoder; callers must
// keep values at or below 255 bytes.
func EncodeTLVs(records []TLV) []byte {
	var out []byte
	for _, record := range records {
		out = append(out, record.ID, byte(len(record.Value)))
		out = append(out, record.Value...)
	}
	return out
}

// DecodeTLVs strictly parses a TLV buffer from the start. Any truncated record
// is an error and no partial result is returned.
func DecodeTLVs(data []byte) ([]TLV, error) {
	return DecodeTLVsFrom(data, 0)
}

// DecodeTLVsFrom parses TLVs starting at offset. It is the primitive behind the
// Payload status-byte heuristic.
func DecodeTLVsFrom(data []byte, offset int) ([]TLV, error) {
	if offset < 0 || offset > len(data) {
		return nil, &TLVError{Offset: offset}
	}
	var records []TLV
	for i := offset; i < len(data); {
		if i+2 > len(data) {
			return nil, &TLVError{Offset: i}
		}
		id := data[i]
		length := int(data[i+1])
		if i+2+length > len(data) {
			return nil, &TLVError{Offset: i}
		}
		value := make([]byte, length)
		copy(value, data[i+2:i+2+length])
		records = append(records, TLV{ID: id, Value: value})
		i += 2 + length
	}
	return records, nil
}

// TypedKind is the shape of a decoded TypedValue.
type TypedKind int

const (
	// TypedKindUnknown means the type prefix was unrecognised, or the value was
	// too short for its type. It is never guessed at.
	TypedKindUnknown TypedKind = iota
	// TypedKindText is a UTF-8 string with NULs and a trailing dot stripped.
	TypedKindText
	// TypedKindU8 is an unsigned 8-bit scalar.
	TypedKindU8
	// TypedKindU16 is an unsigned 16-bit little-endian scalar.
	TypedKindU16
	// TypedKindU32 is an unsigned 32-bit little-endian scalar.
	TypedKindU32
	// TypedKindBytes is an opaque byte block.
	TypedKindBytes
)

// TypedValue is a decoded one-byte-prefixed business value. Go has no sum type;
// Kind discriminates, and the unused fields of the other cases stay zero.
type TypedValue struct {
	// Kind is the decoded shape.
	Kind TypedKind
	// Type is the raw type prefix as received or to be emitted.
	Type byte
	// Text holds the value for TypedKindText.
	Text string
	// Number holds the value for TypedKindU8/U16/U32.
	Number uint32
	// Data holds the bytes for TypedKindBytes and the raw payload of
	// TypedKindUnknown.
	Data []byte
}

// TextValue builds a typed text value.
func TextValue(s string) TypedValue {
	return TypedValue{Kind: TypedKindText, Type: TypedTextType, Text: s}
}

// U8Value builds a typed u8 value.
func U8Value(v byte) TypedValue {
	return TypedValue{Kind: TypedKindU8, Type: TypedU8Type, Number: uint32(v)}
}

// U16Value builds a typed u16 value.
func U16Value(v uint16) TypedValue {
	return TypedValue{Kind: TypedKindU16, Type: TypedU16Type, Number: uint32(v)}
}

// U32Value builds a typed u32 value.
func U32Value(v uint32) TypedValue {
	return TypedValue{Kind: TypedKindU32, Type: TypedU32Type, Number: v}
}

// BytesValue builds a typed byte-block value. The payload is copied.
func BytesValue(b []byte) TypedValue {
	return TypedValue{Kind: TypedKindBytes, Type: TypedBytesType, Data: append([]byte(nil), b...)}
}

// DecodeTypedValue decodes one typed value. A type prefix that is unknown, or a
// value too short for its declared type, yields TypedKindUnknown with the raw
// payload: a two-byte-prefixed value with one byte is unknown, not a u8.
func DecodeTypedValue(raw []byte) TypedValue {
	if len(raw) == 0 {
		return TypedValue{Kind: TypedKindUnknown, Type: 0xFF}
	}
	typ := raw[0]
	body := raw[1:]
	switch typ {
	case TypedTextType:
		// Device strings are ASCII and are sometimes right-padded with dots or
		// NULs. Go strings may hold arbitrary bytes, so invalid UTF-8 survives;
		// in practice these fields are ASCII.
		text := strings.ReplaceAll(string(body), "\x00", "")
		text = strings.TrimRight(text, ".")
		return TypedValue{Kind: TypedKindText, Type: typ, Text: text}
	case TypedU8Type:
		if len(body) >= 1 {
			return TypedValue{Kind: TypedKindU8, Type: typ, Number: uint32(body[0])}
		}
	case TypedU16Type:
		if len(body) >= 2 {
			return TypedValue{Kind: TypedKindU16, Type: typ, Number: uint32(binary.LittleEndian.Uint16(body))}
		}
	case TypedU32Type:
		if len(body) >= 4 {
			return TypedValue{Kind: TypedKindU32, Type: typ, Number: binary.LittleEndian.Uint32(body)}
		}
	case TypedBytesType:
		return TypedValue{Kind: TypedKindBytes, Type: typ, Data: append([]byte(nil), body...)}
	}
	return TypedValue{Kind: TypedKindUnknown, Type: typ, Data: append([]byte(nil), body...)}
}

// Encoded returns the wire representation, type prefix included.
func (v TypedValue) Encoded() []byte {
	out := make([]byte, 0, 1+len(v.Data))
	out = append(out, v.Type)
	switch v.Kind {
	case TypedKindText:
		out = append(out, v.Text...)
	case TypedKindBytes, TypedKindUnknown:
		out = append(out, v.Data...)
	case TypedKindU8:
		out = append(out, byte(v.Number))
	case TypedKindU16:
		out = append(out, byte(v.Number), byte(v.Number>>8))
	case TypedKindU32:
		out = append(out, byte(v.Number), byte(v.Number>>8), byte(v.Number>>16), byte(v.Number>>24))
	}
	return out
}

// Scalar returns u8/u16/u32 as a uint32. The boolean is false for text, bytes,
// unknown and the zero value.
func (v TypedValue) Scalar() (uint32, bool) {
	switch v.Kind {
	case TypedKindU8, TypedKindU16, TypedKindU32:
		return v.Number, true
	}
	return 0, false
}

// Payload is a decrypted payload split into its optional leading status byte and
// its TLV fields.
//
// Device responses prefix the TLV list with a result code (0x00 = OK); requests
// do not. The status is the payload's leading byte: on real firmware TLV A1 is a
// constant 0x31, so reading the result code out of A1 silently treats refusals
// as success.
type Payload struct {
	// Status is nil for request-shaped payloads.
	Status *byte
	// Fields are the TLVs in wire order, repeats preserved.
	Fields []TLV
}

// NewPayload builds a payload from an explicit status and fields.
func NewPayload(status *byte, fields []TLV) Payload {
	return Payload{Status: status, Fields: fields}
}

// IsOK reports whether the device accepted the command: no status (request
// shape) or status 0.
func (p Payload) IsOK() bool { return p.Status == nil || *p.Status == 0 }

// StatusCode returns the status byte and whether one was present.
func (p Payload) StatusCode() (byte, bool) {
	if p.Status == nil {
		return 0, false
	}
	return *p.Status, true
}

// Field returns the value of the first occurrence of id.
func (p Payload) Field(id byte) ([]byte, bool) {
	for _, record := range p.Fields {
		if record.ID == id {
			return record.Value, true
		}
	}
	return nil, false
}

// Typed returns the first occurrence of id decoded as a TypedValue.
func (p Payload) Typed(id byte) (TypedValue, bool) {
	raw, ok := p.Field(id)
	if !ok {
		return TypedValue{}, false
	}
	return DecodeTypedValue(raw), true
}

// ParsePayload applies the status-byte heuristic used for every decrypted frame
// (spec-protocol §2.3):
//
//  1. leading 0x00 whose remainder parses as TLVs   -> status 0
//  2. the whole buffer parses as TLVs                -> no status (request shape)
//  3. the buffer after the first byte parses as TLVs -> status = first byte
//  4. otherwise error.
func ParsePayload(data []byte) (Payload, error) {
	if len(data) == 0 {
		return Payload{}, nil
	}
	if data[0] == 0x00 {
		if fields, err := DecodeTLVsFrom(data, 1); err == nil {
			status := byte(0)
			return Payload{Status: &status, Fields: fields}, nil
		}
	}
	if fields, err := DecodeTLVs(data); err == nil {
		return Payload{Fields: fields}, nil
	}
	if fields, err := DecodeTLVsFrom(data, 1); err == nil {
		status := data[0]
		return Payload{Status: &status, Fields: fields}, nil
	}
	return Payload{}, &TLVError{Offset: 0}
}

// FrameFields is every TLV of one frame in wire order, repeats preserved.
//
// A map was the obvious shape and the wrong one: it drops the wire order and
// every occurrence after the first. The live frames interleave port structs with
// their control structs (A1 A5 AC A6 AD A7 AE), and the occurrence count is how
// B4 was settled as one 12-byte block rather than one TLV per port.
type FrameFields struct {
	Records []TLV
}

// NewFrameFields wraps records.
func NewFrameFields(records []TLV) FrameFields { return FrameFields{Records: records} }

// IsEmpty reports whether the frame carried no TLVs.
func (f FrameFields) IsEmpty() bool { return len(f.Records) == 0 }

// IDs returns distinct ids in first-appearance order.
func (f FrameFields) IDs() []byte {
	seen := make(map[byte]bool, len(f.Records))
	ids := make([]byte, 0, len(f.Records))
	for _, record := range f.Records {
		if seen[record.ID] {
			continue
		}
		seen[record.ID] = true
		ids = append(ids, record.ID)
	}
	return ids
}

// Field returns the value of the first occurrence of id.
func (f FrameFields) Field(id byte) ([]byte, bool) {
	for _, record := range f.Records {
		if record.ID == id {
			return record.Value, true
		}
	}
	return nil, false
}

// Values returns every occurrence of id in wire order.
func (f FrameFields) Values(id byte) [][]byte {
	var out [][]byte
	for _, record := range f.Records {
		if record.ID == id {
			out = append(out, record.Value)
		}
	}
	return out
}

// Occurrences counts how many times id appeared in the frame.
func (f FrameFields) Occurrences(id byte) int {
	n := 0
	for _, record := range f.Records {
		if record.ID == id {
			n++
		}
	}
	return n
}
