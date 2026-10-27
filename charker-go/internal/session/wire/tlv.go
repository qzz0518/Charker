package wire

import (
	"encoding/binary"
	"fmt"
	"strings"
)

// Field identifiers used by the session path. The full protocol has more;
// only the ones the session decodes/serialises are listed.
const (
	FieldA1 byte = 0xA1 // action / typed blob (handshake public keys, timestamps)
	FieldA2 byte = 0xA2
	FieldA3 byte = 0xA3
	FieldA4 byte = 0xA4
	FieldA5 byte = 0xA5 // C1 port struct / bind country
	FieldA6 byte = 0xA6 // C2 port struct
	FieldA7 byte = 0xA7 // C3 port struct
	FieldA8 byte = 0xA8 // screen timeout
	FieldA9 byte = 0xA9 // screen brightness
	FieldAA byte = 0xAA // charging mode
	FieldAC byte = 0xAC // C1 control struct
	FieldAD byte = 0xAD // C2 control struct
	FieldAE byte = 0xAE // C3 control struct
	FieldAF byte = 0xAF // screen orientation
	FieldB2 byte = 0xB2 // gyroscope
	FieldB4 byte = 0xB4 // connected USB identities (bare 12 bytes)
	FieldFE byte = 0xFE // epoch timestamp
)

// TLV is one id/length/value record.
type TLV struct {
	ID    byte
	Value []byte
}

// EncodeTLVs serialises records in order.
func EncodeTLVs(fields []TLV) []byte {
	var out []byte
	for _, f := range fields {
		out = append(out, f.ID, byte(len(f.Value)))
		out = append(out, f.Value...)
	}
	return out
}

// DecodeTLVs parses a strict TLV buffer. A truncated record is an error and no
// partial result is returned.
func DecodeTLVs(b []byte) ([]TLV, error) {
	var out []TLV
	for i := 0; i < len(b); {
		if i+2 > len(b) {
			return nil, fmt.Errorf("tlv: truncated record at %d", i)
		}
		id, n := b[i], int(b[i+1])
		if i+2+n > len(b) {
			return nil, fmt.Errorf("tlv: truncated value at %d", i)
		}
		out = append(out, TLV{ID: id, Value: append([]byte(nil), b[i+2:i+2+n]...)})
		i += 2 + n
	}
	return out, nil
}

// ParsePayload applies the A2687 status heuristic (spec-protocol §2.3):
//
//  1. leading 0x00 whose remainder parses as TLVs → status 0
//  2. the whole buffer parses as TLVs → no status (request shape)
//  3. the buffer after the first byte parses as TLVs → status = first byte
//  4. otherwise an error.
func ParsePayload(b []byte) (status *byte, fields []TLV, err error) {
	if len(b) > 0 && b[0] == 0 {
		if f, e := DecodeTLVs(b[1:]); e == nil {
			s := byte(0)
			return &s, f, nil
		}
	}
	if f, e := DecodeTLVs(b); e == nil {
		return nil, f, nil
	}
	if len(b) > 0 {
		if f, e := DecodeTLVs(b[1:]); e == nil {
			s := b[0]
			return &s, f, nil
		}
	}
	return nil, nil, fmt.Errorf("payload: not a valid TLV payload (%d bytes)", len(b))
}

// Typed-value prefixes (spec-protocol §2.3).
const (
	TypedText  byte = 0x00
	TypedU8    byte = 0x01
	TypedU16   byte = 0x02
	TypedU32   byte = 0x03
	TypedBytes byte = 0x04
)

// TypedValue is a decoded typed value.
type TypedValue struct {
	Kind    byte
	Payload []byte
	Known   bool // false for an unknown/too-short prefix
}

// DecodeTyped decodes one typed value. Values with an unknown prefix or an
// implausible length are returned with Known=false (never guessed).
func DecodeTyped(b []byte) TypedValue {
	if len(b) == 0 {
		return TypedValue{}
	}
	kind := b[0]
	rest := b[1:]
	switch kind {
	case TypedText:
		return TypedValue{Kind: kind, Payload: append([]byte(nil), rest...), Known: true}
	case TypedU8:
		if len(rest) != 1 {
			return TypedValue{Kind: kind, Payload: append([]byte(nil), rest...)}
		}
		return TypedValue{Kind: kind, Payload: append([]byte(nil), rest...), Known: true}
	case TypedU16:
		if len(rest) != 2 {
			return TypedValue{Kind: kind, Payload: append([]byte(nil), rest...)}
		}
		return TypedValue{Kind: kind, Payload: append([]byte(nil), rest...), Known: true}
	case TypedU32:
		if len(rest) != 4 {
			return TypedValue{Kind: kind, Payload: append([]byte(nil), rest...)}
		}
		return TypedValue{Kind: kind, Payload: append([]byte(nil), rest...), Known: true}
	case TypedBytes:
		return TypedValue{Kind: kind, Payload: append([]byte(nil), rest...), Known: true}
	default:
		return TypedValue{Kind: kind, Payload: append([]byte(nil), rest...)}
	}
}

// Scalar returns a u8/u16/u32 typed value as a uint32.
func (v TypedValue) Scalar() (uint32, bool) {
	if !v.Known {
		return 0, false
	}
	switch v.Kind {
	case TypedU8:
		return uint32(v.Payload[0]), true
	case TypedU16:
		return uint32(binary.LittleEndian.Uint16(v.Payload)), true
	case TypedU32:
		return binary.LittleEndian.Uint32(v.Payload), true
	}
	return 0, false
}

// Bytes returns a typed-bytes payload.
func (v TypedValue) Bytes() ([]byte, bool) {
	if !v.Known || v.Kind != TypedBytes {
		return nil, false
	}
	return v.Payload, true
}

// Text returns a typed-text payload with NULs and a trailing dot stripped.
func (v TypedValue) Text() (string, bool) {
	if !v.Known || v.Kind != TypedText {
		return "", false
	}
	s := strings.TrimRight(string(v.Payload), "\x00")
	s = strings.TrimRight(s, ".")
	return s, true
}

// EncodeTyped builds a typed value with the given prefix.
func EncodeTyped(kind byte, payload []byte) []byte {
	out := make([]byte, 0, 1+len(payload))
	out = append(out, kind)
	out = append(out, payload...)
	return out
}

// FieldsByID returns the first value of each requested id, in order.
func FieldsByID(fields []TLV) map[byte][]byte {
	m := make(map[byte][]byte, len(fields))
	for _, f := range fields {
		if _, ok := m[f.ID]; !ok {
			m[f.ID] = f.Value
		}
	}
	return m
}

// TimestampLE encodes epoch seconds as the bare 4-byte little-endian blob used
// by the A2687 command trailer.
func TimestampLE(epochSeconds uint32) []byte {
	b := make([]byte, 4)
	binary.LittleEndian.PutUint32(b, epochSeconds)
	return b
}

// AppendTrailer appends the `FE 04 <ts>` epoch trailer used by session
// commands.
func AppendTrailer(dst []byte, epochSeconds uint32) []byte {
	return append(append(dst, FieldFE, 0x04), TimestampLE(epochSeconds)...)
}
