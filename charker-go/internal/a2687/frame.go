package a2687

import (
	"errors"
	"fmt"
)

// Framing constants (spec-protocol §2.2).
const (
	// Header0 and Header1 are the fixed FF 09 frame header.
	Header0 byte = 0xFF
	Header1 byte = 0x09
	// ProtocolVersion is the only pattern byte validated on decode. The speaker
	// and group bytes legitimately differ between a request and its reply and
	// are carried, never asserted.
	ProtocolVersion byte = 0x03
	// Overhead is header(2)+length(2)+pattern(3)+command(2)+checksum(1).
	Overhead = 10
	// MaxFrameLength is the defensive ceiling; observed frames are under 300.
	MaxFrameLength = 2048
)

// FrameErrorKind discriminates FrameError. It mirrors the Swift FrameError enum
// so diagnostics and tests can match on the case rather than parse a string.
type FrameErrorKind int

const (
	FrameErrTooShort FrameErrorKind = iota + 1
	FrameErrBadHeader
	FrameErrLengthMismatch
	FrameErrBadChecksum
	FrameErrBadProtocolVersion
	FrameErrTooLarge
)

// FrameError is returned by Decode for malformed frames. Decode never repairs
// input, so every error is terminal for that candidate frame.
type FrameError struct {
	Kind FrameErrorKind
	// Size is the actual byte count for TooShort and TooLarge.
	Size int
	// Encoded and Actual are the declared and received lengths for
	// LengthMismatch.
	Encoded int
	Actual  int
	// EncodedChecksum and ComputedChecksum belong to BadChecksum.
	EncodedChecksum  byte
	ComputedChecksum byte
	// Version belongs to BadProtocolVersion.
	Version byte
}

// Error implements error. Messages are short and stable.
func (e *FrameError) Error() string {
	switch e.Kind {
	case FrameErrTooShort:
		return fmt.Sprintf("frame: too short (%d bytes)", e.Size)
	case FrameErrBadHeader:
		return "frame: bad header"
	case FrameErrLengthMismatch:
		return fmt.Sprintf("frame: length mismatch (declared %d, actual %d)", e.Encoded, e.Actual)
	case FrameErrBadChecksum:
		return fmt.Sprintf("frame: bad checksum (encoded 0x%02X, computed 0x%02X)", e.EncodedChecksum, e.ComputedChecksum)
	case FrameErrBadProtocolVersion:
		return fmt.Sprintf("frame: bad protocol version 0x%02X", e.Version)
	case FrameErrTooLarge:
		return fmt.Sprintf("frame: too large (%d bytes)", e.Size)
	default:
		return "frame: malformed"
	}
}

// FramePattern is the three-byte pattern between the length and the command.
type FramePattern struct {
	// Version is always 0x03 on the wire.
	Version byte
	// Slave is 0x00 from the app and 0x01 from the charger.
	Slave byte
	// Group is the function group: 0x01 negotiation, 0x0F session request,
	// 0x11 observed session response.
	Group byte
}

// NegotiationPattern is the app-side negotiation pattern: 03 00 01.
func NegotiationPattern() FramePattern {
	return FramePattern{Version: ProtocolVersion, Slave: SpeakerApp, Group: GroupNegotiation}
}

// SessionPattern is the app-side session pattern: 03 00 0F.
func SessionPattern() FramePattern {
	return FramePattern{Version: ProtocolVersion, Slave: SpeakerApp, Group: GroupSession}
}

// SessionResponsePattern is the observed device-side session pattern: 03 01 11.
func SessionResponsePattern() FramePattern {
	return FramePattern{Version: ProtocolVersion, Slave: SpeakerDevice, Group: GroupSessionResponse}
}

// Frame is one complete A2687 frame.
type Frame struct {
	Pattern FramePattern
	// RawCommand is the command word as it appears on the wire, flag bits
	// included (e.g. 0x4A07 = encrypted|response|0x0207).
	RawCommand uint16
	// Payload is plaintext TLVs, or AES-GCM ciphertext||tag.
	Payload []byte
}

// NewFrame builds a frame from an explicit pattern and raw command.
func NewFrame(pattern FramePattern, rawCommand uint16, payload []byte) Frame {
	return Frame{Pattern: pattern, RawCommand: rawCommand, Payload: payload}
}

// NewGroupFrame builds a frame in the given group from a raw command word.
func NewGroupFrame(group byte, rawCommand uint16, payload []byte) Frame {
	return Frame{
		Pattern:    FramePattern{Version: ProtocolVersion, Slave: SpeakerApp, Group: group},
		RawCommand: rawCommand,
		Payload:    payload,
	}
}

// NewCommandFrame builds a frame from a logical opcode plus flag bits.
func NewCommandFrame(group byte, opcode uint16, encrypted, response bool, payload []byte) Frame {
	raw := opcode
	if encrypted {
		raw |= FlagEncrypted
	}
	if response {
		raw |= FlagResponse
	}
	return NewGroupFrame(group, raw, payload)
}

// Group is the function group byte.
func (f Frame) Group() byte { return f.Pattern.Group }

// Opcode is the command word with the encrypted/response flags stripped, e.g.
// wire 0x4A07 -> 0x0207.
func (f Frame) Opcode() uint16 { return f.RawCommand & OpcodeMask }

// IsEncrypted reports whether the payload is AES-GCM sealed.
func (f Frame) IsEncrypted() bool { return f.RawCommand&FlagEncrypted != 0 }

// IsResponse reports whether the frame is a device response/ACK.
func (f Frame) IsResponse() bool { return f.RawCommand&FlagResponse != 0 }

// IsFromDevice reports whether the charger, rather than this app, produced the
// frame: a non-app speaker or the response flag.
func (f Frame) IsFromDevice() bool { return f.Pattern.Slave != SpeakerApp || f.IsResponse() }

// FrameChecksum is the XOR of every byte preceding the checksum.
func FrameChecksum(bytes []byte) byte {
	var x byte
	for _, b := range bytes {
		x ^= b
	}
	return x
}

// EncodePacket serialises a frame into its wire representation. The length
// field is Overhead+len(Payload), matching the Swift PacketCodec.
func EncodePacket(f Frame) []byte {
	length := Overhead + len(f.Payload)
	out := make([]byte, 0, length)
	out = append(out,
		Header0, Header1,
		byte(length), byte(length>>8),
		f.Pattern.Version, f.Pattern.Slave, f.Pattern.Group,
		byte(f.RawCommand>>8), byte(f.RawCommand),
	)
	out = append(out, f.Payload...)
	out = append(out, FrameChecksum(out))
	return out
}

// DecodePacket strictly validates and decodes one complete frame. It never
// repairs malformed input: short, over-long, bad header, length mismatch, bad
// version and bad checksum all return a *FrameError.
func DecodePacket(bytes []byte) (Frame, error) {
	if len(bytes) < Overhead {
		return Frame{}, &FrameError{Kind: FrameErrTooShort, Size: len(bytes)}
	}
	if len(bytes) > MaxFrameLength {
		return Frame{}, &FrameError{Kind: FrameErrTooLarge, Size: len(bytes)}
	}
	if bytes[0] != Header0 || bytes[1] != Header1 {
		return Frame{}, &FrameError{Kind: FrameErrBadHeader}
	}
	encodedLength := int(bytes[2]) | int(bytes[3])<<8
	if encodedLength != len(bytes) {
		return Frame{}, &FrameError{Kind: FrameErrLengthMismatch, Encoded: encodedLength, Actual: len(bytes)}
	}
	if bytes[4] != ProtocolVersion {
		return Frame{}, &FrameError{Kind: FrameErrBadProtocolVersion, Version: bytes[4]}
	}
	computed := FrameChecksum(bytes[:len(bytes)-1])
	if computed != bytes[len(bytes)-1] {
		return Frame{}, &FrameError{
			Kind:             FrameErrBadChecksum,
			EncodedChecksum:  bytes[len(bytes)-1],
			ComputedChecksum: computed,
		}
	}
	payload := make([]byte, len(bytes)-Overhead)
	copy(payload, bytes[9:len(bytes)-1])
	return Frame{
		Pattern: FramePattern{
			Version: bytes[4],
			Slave:   bytes[5],
			Group:   bytes[6],
		},
		RawCommand: uint16(bytes[7])<<8 | uint16(bytes[8]),
		Payload:    payload,
	}, nil
}

// FrameRejection records why a candidate frame was rejected and the head of the
// offending bytes, so diagnostics can tell a rejection apart from silence.
type FrameRejection struct {
	Err  *FrameError
	Head []byte
}

// FrameReassembler turns the raw notification stream into whole frames.
//
// The transport may split one frame across notifications or pack several into
// one. Anything that is not a well-formed frame is dropped and counted rather
// than guessed at. The exported counters are for diagnostics and are read after
// Append returns.
type FrameReassembler struct {
	buf []byte
	// DroppedBytes counts bytes discarded while resynchronising on FF 09.
	DroppedBytes int
	// RejectedFrames counts candidates rejected by DecodePacket.
	RejectedFrames int
	// LastRejection describes the most recent rejection, or nil.
	LastRejection *FrameRejection
}

// Reset drops buffered bytes. Counters are preserved (they describe the link,
// not the buffer); create a new reassembler to zero them.
func (r *FrameReassembler) Reset() {
	r.buf = r.buf[:0]
}

// Buffered returns the number of unparsed bytes currently held.
func (r *FrameReassembler) Buffered() int { return len(r.buf) }

// Append adds one notification chunk and returns every complete frame now
// available. A partial frame stays buffered until the rest arrives.
func (r *FrameReassembler) Append(chunk []byte) []Frame {
	r.buf = append(r.buf, chunk...)
	frames := make([]Frame, 0, 1)
	for {
		start := r.resyncIndex()
		if start < 0 {
			r.DroppedBytes += len(r.buf)
			r.buf = r.buf[:0]
			break
		}
		if start > 0 {
			r.DroppedBytes += start
			r.buf = r.buf[start:]
		}
		if len(r.buf) < 4 {
			break
		}
		length := int(r.buf[2]) | int(r.buf[3])<<8
		if length < Overhead || length > MaxFrameLength {
			// Bogus length: drop this header and rescan.
			r.DroppedBytes += 2
			r.buf = r.buf[2:]
			r.RejectedFrames++
			continue
		}
		if len(r.buf) < length {
			break
		}
		candidate := make([]byte, length)
		copy(candidate, r.buf[:length])
		r.buf = r.buf[length:]
		frame, err := DecodePacket(candidate)
		if err != nil {
			r.RejectedFrames++
			var fe *FrameError
			if errors.As(err, &fe) {
				head := candidate
				if len(head) > 12 {
					head = head[:12]
				}
				r.LastRejection = &FrameRejection{Err: fe, Head: append([]byte(nil), head...)}
			}
			continue
		}
		frames = append(frames, frame)
	}
	// Do not let a long-lived link retain a huge backing array after a burst.
	if len(r.buf) == 0 && cap(r.buf) > 4*MaxFrameLength {
		r.buf = nil
	}
	return frames
}

// resyncIndex returns the index of the next plausible FF 09 header, -1 when
// none is buffered. A trailing lone FF may still become a header, so it is kept.
func (r *FrameReassembler) resyncIndex() int {
	if len(r.buf) < 2 {
		if len(r.buf) == 0 {
			return -1
		}
		if r.buf[0] == Header0 {
			return 0
		}
		return -1
	}
	for i := 0; i+1 < len(r.buf); i++ {
		if r.buf[i] == Header0 && r.buf[i+1] == Header1 {
			return i
		}
	}
	if r.buf[len(r.buf)-1] == Header0 {
		return len(r.buf) - 1
	}
	return -1
}
