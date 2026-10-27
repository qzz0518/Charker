// Package wire holds the device-side A2687 primitives the mock charger
// simulator needs: frame encode/decode, TLV and typed values, AES-GCM/ECDH
// helpers and session-command parsing. The client path lives in
// internal/a2687; this package deliberately no longer contains a client
// handshake or telemetry decoder.
package wire

import (
	"encoding/binary"
	"fmt"
)

// A2687 opcodes the simulator answers (spec-protocol §2.6). The client side
// uses internal/a2687's opcode constants instead.
const (
	OpInitialConnect  uint16 = 0x0001
	OpCapability      uint16 = 0x0003
	OpSetCapability   uint16 = 0x0005
	OpPublicKey       uint16 = 0x0021
	OpAESMetadata     uint16 = 0x0022
	OpUserAuth        uint16 = 0x0027
	OpBaseInfo        uint16 = 0x0029
	OpReadAll         uint16 = 0x0200
	OpScreenLanguage  uint16 = 0x0202
	OpScreenTimeout   uint16 = 0x0203
	OpScreenBright    uint16 = 0x0204
	OpFixedAllocation uint16 = 0x0205
	OpChargingMode    uint16 = 0x0206
	OpPortOutput      uint16 = 0x0207
	OpPortTimer       uint16 = 0x0209
	OpBindSuccess     uint16 = 0x020A
	OpRealtimeTrigger uint16 = 0x020B
	OpGyroscope       uint16 = 0x020D
	OpRealtimeReport  uint16 = 0x0300
)

// SessionCommand is one decoded session command (device side / tests).
type SessionCommand struct {
	Opcode uint16
	Fields map[byte][]byte
}

// ParseSessionCommand decodes a decrypted session command payload.
func ParseSessionCommand(opcode uint16, plaintext []byte) (SessionCommand, error) {
	_, fields, err := ParsePayload(plaintext)
	if err != nil {
		return SessionCommand{}, fmt.Errorf("command 0x%04x: %w", opcode, err)
	}
	return SessionCommand{Opcode: opcode, Fields: FieldsByID(fields)}, nil
}

// U8 returns a scalar field encoded as a typed u8, typed bytes(1) or a bare
// single byte.
func (c SessionCommand) U8(id byte) (byte, bool) {
	raw, ok := c.Fields[id]
	if !ok {
		return 0, false
	}
	return bareOrTypedScalar(raw)
}

// U32 returns a 32-bit field encoded as a typed u32, typed bytes(4) (the
// spec's timer shape is `04 <u32le>`) or a bare 4-byte value.
func (c SessionCommand) U32(id byte) (uint32, bool) {
	raw, ok := c.Fields[id]
	if !ok {
		return 0, false
	}
	tv := DecodeTyped(raw)
	if tv.Kind == TypedU32 && tv.Known {
		return binary.LittleEndian.Uint32(tv.Payload), true
	}
	if tv.Kind == TypedBytes && len(tv.Payload) == 4 {
		return binary.LittleEndian.Uint32(tv.Payload), true
	}
	if len(raw) == 4 {
		return binary.LittleEndian.Uint32(raw), true
	}
	return 0, false
}

// Bytes returns a typed-bytes field.
func (c SessionCommand) Bytes(id byte) ([]byte, bool) {
	raw, ok := c.Fields[id]
	if !ok {
		return nil, false
	}
	tv := DecodeTyped(raw)
	return tv.Bytes()
}

// bareOrTypedScalar accepts a bare one-byte value or a typed u8/bytes(1), as
// the device's settingByte decoder does.
func bareOrTypedScalar(raw []byte) (byte, bool) {
	if len(raw) == 1 {
		return raw[0], true
	}
	tv := DecodeTyped(raw)
	if !tv.Known {
		return 0, false
	}
	if tv.Kind == TypedU8 {
		return tv.Payload[0], true
	}
	if tv.Kind == TypedBytes && len(tv.Payload) == 1 {
		return tv.Payload[0], true
	}
	return 0, false
}
