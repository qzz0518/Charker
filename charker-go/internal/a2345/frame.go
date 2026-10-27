package a2345

import "fmt"

// Framing constants.
const (
	// ProtocolVersion is the only pattern byte validated on decode.
	ProtocolVersion byte = 0x03
	// MinFrameLength is a header without increment or fields, plus the
	// checksum byte.
	MinFrameLength = 10
	// MaxFrameLength is a defensive ceiling; observed messages are below 300
	// bytes.
	MaxFrameLength = 2048
)

// Header is the fixed FF 09 marker.
var Header = [2]byte{0xFF, 0x09}

// FramePattern is the three-byte pattern after the length.
type FramePattern struct {
	Version byte
	Speaker byte
	Group   byte
}

// TLV is one wire-order field. Raw includes a value-type prefix when the
// field has one; no interpretation is discarded at the framing boundary.
type TLV struct {
	ID  byte
	Raw []byte
}

// ValueType returns the common value-type prefix. Single-byte marker fields
// have none.
func (t TLV) ValueType() (byte, bool) {
	if len(t.Raw) > 1 {
		return t.Raw[0], true
	}
	return 0, false
}

// Frame is one decoded FF09 message.
//
// Layout:
//
//	FF 09                  marker
//	uint16LE totalLength   includes the trailing checksum
//	version speaker group  three-byte pattern
//	uint16BE messageType
//	[increment]            present when the next byte is not a TLV id
//	TLVs                   id | uint8 length | value
//	xorChecksum            XOR of all previous bytes
type Frame struct {
	Pattern       FramePattern
	MessageType   uint16
	Increment     *byte
	Fields        []TLV
	EncodedLength int
	Checksum      byte
}

// FrameErrorKind discriminates FrameError like the Swift A2345FrameError
// cases.
type FrameErrorKind int

// Frame error kinds.
const (
	FrameErrTooShort FrameErrorKind = iota + 1
	FrameErrTooLarge
	FrameErrBadHeader
	FrameErrInvalidLength
	FrameErrLengthMismatch
	FrameErrUnsupportedVersion
	FrameErrBadChecksum
	FrameErrTruncatedTLV
)

// FrameError is returned by Decode. Decode never repairs input, so every
// error is terminal for that candidate.
type FrameError struct {
	Kind FrameErrorKind
	// Size is the byte count for TooShort and TooLarge.
	Size int
	// Length is the declared length for InvalidLength.
	Length int
	// Encoded and Actual belong to LengthMismatch.
	Encoded int
	Actual  int
	// EncodedChecksum and ComputedChecksum belong to BadChecksum.
	EncodedChecksum  byte
	ComputedChecksum byte
	// Version belongs to UnsupportedVersion.
	Version byte
	// At is the offset of the truncated TLV.
	At int
}

// Error implements error.
func (e *FrameError) Error() string {
	switch e.Kind {
	case FrameErrTooShort:
		return fmt.Sprintf("a2345 frame: too short (%d bytes)", e.Size)
	case FrameErrTooLarge:
		return fmt.Sprintf("a2345 frame: too large (%d bytes)", e.Size)
	case FrameErrBadHeader:
		return "a2345 frame: bad header"
	case FrameErrInvalidLength:
		return fmt.Sprintf("a2345 frame: invalid length %d", e.Length)
	case FrameErrLengthMismatch:
		return fmt.Sprintf("a2345 frame: length mismatch (declared %d, actual %d)", e.Encoded, e.Actual)
	case FrameErrUnsupportedVersion:
		return fmt.Sprintf("a2345 frame: unsupported version 0x%02X", e.Version)
	case FrameErrBadChecksum:
		return fmt.Sprintf("a2345 frame: bad checksum (encoded 0x%02X, computed 0x%02X)", e.EncodedChecksum, e.ComputedChecksum)
	case FrameErrTruncatedTLV:
		return fmt.Sprintf("a2345 frame: truncated TLV at %d", e.At)
	default:
		return "a2345 frame: malformed"
	}
}

// Checksum is the XOR of every byte.
func Checksum(b []byte) byte {
	var c byte
	for _, v := range b {
		c ^= v
	}
	return c
}

// Decode strictly validates and decodes one complete frame. It never repairs
// length, checksum or TLV boundary errors and never returns partial fields.
func Decode(b []byte) (Frame, error) {
	if len(b) < MinFrameLength {
		return Frame{}, &FrameError{Kind: FrameErrTooShort, Size: len(b)}
	}
	if len(b) > MaxFrameLength {
		return Frame{}, &FrameError{Kind: FrameErrTooLarge, Size: len(b)}
	}
	if b[0] != Header[0] || b[1] != Header[1] {
		return Frame{}, &FrameError{Kind: FrameErrBadHeader}
	}
	encodedLength := int(b[2]) | int(b[3])<<8
	if encodedLength < MinFrameLength || encodedLength > MaxFrameLength {
		return Frame{}, &FrameError{Kind: FrameErrInvalidLength, Length: encodedLength}
	}
	if encodedLength != len(b) {
		return Frame{}, &FrameError{Kind: FrameErrLengthMismatch, Encoded: encodedLength, Actual: len(b)}
	}
	if b[4] != ProtocolVersion {
		return Frame{}, &FrameError{Kind: FrameErrUnsupportedVersion, Version: b[4]}
	}
	computed := Checksum(b[:len(b)-1])
	if computed != b[len(b)-1] {
		return Frame{}, &FrameError{Kind: FrameErrBadChecksum, EncodedChecksum: b[len(b)-1], ComputedChecksum: computed}
	}

	frame := Frame{
		Pattern:       FramePattern{Version: b[4], Speaker: b[5], Group: b[6]},
		MessageType:   uint16(b[7])<<8 | uint16(b[8]),
		EncodedLength: encodedLength,
		Checksum:      b[len(b)-1],
	}
	fieldsEnd := len(b) - 1
	offset := 9
	// Every field observed on A2345 is in the A0…FF namespace. An earlier
	// byte is the optional message increment, not a guessed TLV id.
	if offset < fieldsEnd && b[offset] < 0xA0 {
		inc := b[offset]
		frame.Increment = &inc
		offset++
	}
	fields := []TLV{}
	for offset < fieldsEnd {
		if offset+2 > fieldsEnd {
			return Frame{}, &FrameError{Kind: FrameErrTruncatedTLV, At: offset}
		}
		id := b[offset]
		valueStart := offset + 2
		valueEnd := valueStart + int(b[offset+1])
		if valueEnd > fieldsEnd {
			return Frame{}, &FrameError{Kind: FrameErrTruncatedTLV, At: offset}
		}
		fields = append(fields, TLV{ID: id, Raw: append([]byte(nil), b[valueStart:valueEnd]...)})
		offset = valueEnd
	}
	frame.Fields = fields
	return frame, nil
}
