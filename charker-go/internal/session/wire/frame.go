// Package wire holds the device-side A2687 primitives the mock charger
// simulator needs: frame encode/decode, TLV and typed values, AES-GCM/ECDH
// helpers and session-command parsing. The client path (negotiation ladder,
// telemetry decode, command encoding) lives in internal/a2687; this package
// deliberately no longer contains a client implementation.
package wire

import (
	"encoding/binary"
	"errors"
	"fmt"
)

// Frame-level constants from the recovered A2687 protocol.
const (
	header0 byte = 0xFF
	header1 byte = 0x09

	// ProtocolVersion is the only validated version byte.
	ProtocolVersion byte = 0x03
	// SpeakerApp is the slave/speaker value for frames sent by the app.
	SpeakerApp byte = 0x00
	// SpeakerDevice is the slave/speaker value for frames sent by the charger.
	SpeakerDevice byte = 0x01

	// GroupNegotiation is the plaintext/AES-GCM negotiation group.
	GroupNegotiation byte = 0x01
	// GroupSession is the encrypted session command group.
	GroupSession byte = 0x0F
	// GroupSessionResponse is the observed group of device session responses.
	GroupSessionResponse byte = 0x11

	// FlagEncrypted marks an AES-GCM sealed payload.
	FlagEncrypted uint16 = 0x4000
	// FlagResponse marks a response frame.
	FlagResponse uint16 = 0x0800

	// MaxFrameLength is the defensive upper bound; observed frames are < 300.
	MaxFrameLength = 2048
	// overhead is header..raw command + checksum.
	overhead = 10
)

// Frame errors. Messages are intentionally short and stable: tests and
// diagnostics depend on them.
var (
	ErrTooShort         = errors.New("frame: too short")
	ErrBadHeader        = errors.New("frame: bad header")
	ErrLengthMismatch   = errors.New("frame: length mismatch")
	ErrFrameTooLarge    = errors.New("frame: too large")
	ErrBadVersion       = errors.New("frame: bad protocol version")
	ErrBadChecksum      = errors.New("frame: bad checksum")
	ErrShortPayloadOpen = errors.New("crypto: payload too short")
	ErrAuthentication   = errors.New("crypto: authentication failed")
	ErrBadPublicKey     = errors.New("crypto: bad public key")
	ErrBadSharedSecret  = errors.New("crypto: bad shared secret")
)

// Frame is one decoded A2687 wire frame.
type Frame struct {
	// Group is the function group byte (0x01 negotiation, 0x0F session,
	// 0x11 observed session response group).
	Group byte
	// RawCommand carries the opcode plus the encrypted/response flag bits.
	RawCommand uint16
	// Payload is the raw (possibly sealed) payload.
	Payload []byte
}

// Opcode returns the command opcode with the flag bits stripped.
func (f Frame) Opcode() uint16 { return f.RawCommand &^ (FlagEncrypted | FlagResponse) }

// Encrypted reports whether the payload is AES-GCM sealed.
func (f Frame) Encrypted() bool { return f.RawCommand&FlagEncrypted != 0 }

// Response reports whether the frame is a response.
func (f Frame) Response() bool { return f.RawCommand&FlagResponse != 0 }

// FromDevice reports whether the frame originated from the charger.
func (f Frame) FromDevice() bool {
	return f.RawCommand&FlagResponse != 0 || f.Group == GroupSessionResponse
}

// Encode seals the frame into its wire representation.
func Encode(f Frame) []byte {
	n := overhead + len(f.Payload)
	out := make([]byte, n)
	out[0], out[1] = header0, header1
	binary.LittleEndian.PutUint16(out[2:4], uint16(n))
	out[4] = ProtocolVersion
	out[5] = SpeakerApp
	out[6] = f.Group
	binary.BigEndian.PutUint16(out[7:9], f.RawCommand)
	copy(out[9:], f.Payload)
	var xor byte
	for _, b := range out[:n-1] {
		xor ^= b
	}
	out[n-1] = xor
	return out
}

// EncodeDevice is Encode for frames sent by the charger (speaker = 1).
func EncodeDevice(f Frame) []byte {
	b := Encode(f)
	b[5] = SpeakerDevice
	// The checksum covers speaker, so recompute it.
	var xor byte
	for _, v := range b[:len(b)-1] {
		xor ^= v
	}
	b[len(b)-1] = xor
	return b
}

// Decode parses one complete frame. It is strict: it never repairs input.
func Decode(b []byte) (Frame, error) {
	if len(b) < overhead {
		return Frame{}, fmt.Errorf("%w: %d bytes", ErrTooShort, len(b))
	}
	if b[0] != header0 || b[1] != header1 {
		return Frame{}, ErrBadHeader
	}
	declared := int(binary.LittleEndian.Uint16(b[2:4]))
	if declared != len(b) {
		return Frame{}, fmt.Errorf("%w: declared %d, got %d", ErrLengthMismatch, declared, len(b))
	}
	if declared > MaxFrameLength {
		return Frame{}, fmt.Errorf("%w: %d bytes", ErrFrameTooLarge, declared)
	}
	if b[4] != ProtocolVersion {
		return Frame{}, fmt.Errorf("%w: 0x%02x", ErrBadVersion, b[4])
	}
	var xor byte
	for _, v := range b[:len(b)-1] {
		xor ^= v
	}
	if xor != b[len(b)-1] {
		return Frame{}, ErrBadChecksum
	}
	return Frame{
		Group:      b[6],
		RawCommand: binary.BigEndian.Uint16(b[7:9]),
		Payload:    append([]byte(nil), b[9:len(b)-1]...),
	}, nil
}

// Reassembler turns an arbitrary byte stream into frames, resynchronising on
// the FF09 header after garbage or a corrupt frame.
type Reassembler struct {
	buf            []byte
	DroppedBytes   int
	RejectedFrames int
}

// Push appends data and returns every complete, checksum-valid frame.
func (r *Reassembler) Push(data []byte) []Frame {
	r.buf = append(r.buf, data...)
	var out []Frame
	for {
		// Resync: find the next header pair.
		idx := -1
		for i := 0; i+1 < len(r.buf); i++ {
			if r.buf[i] == header0 && r.buf[i+1] == header1 {
				idx = i
				break
			}
		}
		if idx < 0 {
			// Keep a trailing 0xFF as a possible header; drop everything else.
			keep := 0
			if len(r.buf) > 0 && r.buf[len(r.buf)-1] == header0 {
				keep = 1
			}
			r.DroppedBytes += len(r.buf) - keep
			r.buf = r.buf[len(r.buf)-keep:]
			return out
		}
		if idx > 0 {
			r.DroppedBytes += idx
			r.buf = r.buf[idx:]
		}
		if len(r.buf) < 4 {
			return out
		}
		declared := int(binary.LittleEndian.Uint16(r.buf[2:4]))
		if declared < overhead || declared > MaxFrameLength {
			r.RejectedFrames++
			r.DroppedBytes += 2
			r.buf = r.buf[2:]
			continue
		}
		if len(r.buf) < declared {
			return out
		}
		f, err := Decode(r.buf[:declared])
		if err != nil {
			r.RejectedFrames++
			r.DroppedBytes += 2
			r.buf = r.buf[2:]
			continue
		}
		r.buf = r.buf[declared:]
		out = append(out, f)
	}
}

// Buffered returns the number of unparsed bytes currently held.
func (r *Reassembler) Buffered() int { return len(r.buf) }

// Reset drops all buffered bytes and counters.
func (r *Reassembler) Reset() {
	r.buf = nil
	r.DroppedBytes = 0
	r.RejectedFrames = 0
}
