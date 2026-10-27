package a2687

import (
	"encoding/binary"
	"encoding/hex"
	"testing"
	"time"
)

// Byte-exact captures from the pinned reference commits. The plaintexts are what those frames decrypt to under the
// firmware's static negotiation key — the ground truth this client is written
// against.
const (
	fxClientInitialConnect = "ff09200003000140010a82d0ab535303e3aa9f0c2f9c868465bc8476f556fb7d"
	fxClientCapability     = "ff09270003000140030a82d0ab53538ab3de100ac9bb87a0b8e36c1dd8167a9c25a9839d9a14d5"
	fxClientBaseInfo       = "ff09200003000140290a82d0ab535303e3aa9f0c2f9c868465bc8476f556fb55"

	fxDeviceInitialConnect = "ff091e000300014801ab273ed3e27270c3f4d676ac7d69a00572793732a6"
	fxDeviceCapability     = "ff092b000300014803ab273ed0443800b35db54c6d4a6ec3d48171a04ea7ebce8bf749e5e48c5d991a5e67"
	fxDeviceBaseInfo       = "ff0958000300014829ab273ed144326ada9fc66fa02508c5ddf549ade014d1eeb252fea1057c15b00985ab8a724fa3830e8e5b27acbaa1224fd2172c0439d27aaf9e62a66bda5c41c424f23c5c8d7df8d3b89422ddff2266"
	fxDeviceSetCapability  = "ff091b000300014805abab709a595a803dd04246b78a927453cf65"
	fxDevicePublicKey      = "ff095d000300014821ab277fc01de436d341de628c79c1384d0aea25ce030622fa3ca0808ce5d1b7365ec1b1753a11ab78fba3ca07dda95cd57c93d1267b1222bef9908f7633a758ab924eba63ee01e715be5b9c3b082e6d81c2204241"

	fxPlainClientInitialConnect = "a104ef79b569"
	fxPlainClientCapability     = "a104ef79b569a30120a40200f0"
	fxPlainDeviceInitialConnect = "00a10101"
	fxPlainDeviceCapability     = "00a10102a2022901a30144a40101a50102"
	fxPlainDeviceBaseInfo       = "00a10103a2084368617267696e67a30876302e302e352e30a411415348444b375531463531353031373731a5117ce9138146025531463531353031373731"
	fxPlainDeviceSetCapability  = "00"
	fxPlainDevicePublicKey      = "00a14012fbde1f61bf6a6a4532ae5e988993a61e39e2e278ca4f60dad1804c088e5b7d324487184742cfdc0e767497892fc2ff7773866d2052c2182adecad4e29e3dd4"

	// fxHandshakeTimestamp is the epoch carried by the captured capability frame:
	// a1 04 ef 79 b5 69.
	fxHandshakeTimestamp = "ef79b569"
)

// mustHex decodes hex, failing the test on malformed input.
func mustHex(tb testing.TB, s string) []byte {
	tb.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		tb.Fatalf("bad hex %q: %v", s, err)
	}
	return b
}

// hexStr encodes bytes as lowercase hex.
func hexStr(b []byte) string { return hex.EncodeToString(b) }

// handshakeEpoch is the capture's epoch, used to make handshake frames
// byte-identical to the fixtures.
func handshakeEpoch() time.Time {
	raw, err := hex.DecodeString(fxHandshakeTimestamp)
	if err != nil {
		panic("fixtures: bad handshake timestamp: " + err.Error())
	}
	return time.Unix(int64(binary.LittleEndian.Uint32(raw)), 0)
}

// commandEpoch is the epoch every command vector uses.
func commandEpoch() time.Time { return time.Unix(1_700_000_000, 0) }

// sessionResponseFrame builds a device session response: pattern 03 01 11, the
// response and encrypted flags set, sealed with keys.
func sessionResponseFrame(tb testing.TB, opcode uint16, plaintext []byte, keys Keys) []byte {
	tb.Helper()
	sealed, err := Seal(plaintext, keys)
	if err != nil {
		tb.Fatalf("seal: %v", err)
	}
	return EncodePacket(NewFrame(
		SessionResponsePattern(),
		opcode|FlagEncrypted|FlagResponse,
		sealed,
	))
}

// negotiationResponseFrame builds a device negotiation response: observed
// pattern 03 00 01 with the response and encrypted flags set, sealed with keys.
func negotiationResponseFrame(tb testing.TB, opcode uint16, plaintext []byte, keys Keys) []byte {
	tb.Helper()
	sealed, err := Seal(plaintext, keys)
	if err != nil {
		tb.Fatalf("seal: %v", err)
	}
	return EncodePacket(NewFrame(
		FramePattern{Version: ProtocolVersion, Slave: SpeakerApp, Group: GroupNegotiation},
		opcode|FlagEncrypted|FlagResponse,
		sealed,
	))
}

// portStruct builds the live port struct in the shape real firmware sends:
// typed bytes [status, mV LE, mA LE, cW LE].
func portStruct(status byte, millivolts, milliamps, centiwatts uint16) []byte {
	value := []byte{
		status,
		byte(millivolts), byte(millivolts >> 8),
		byte(milliamps), byte(milliamps >> 8),
		byte(centiwatts), byte(centiwatts >> 8),
	}
	return BytesValue(value).Encoded()
}

// controlStruct builds the 12-byte cable/profile control struct.
func controlStruct(cable, profile byte) []byte {
	value := append(IdleControlPrefix(), cable, profile)
	return BytesValue(value).Encoded()
}

// reportPayload builds a decrypted device payload with a leading 0x00 status.
func reportPayload(fields ...TLV) Payload {
	return NewPayload(bytePtr(0), fields)
}

func bytePtr(v byte) *byte { return &v }

func boolPtr(v bool) *bool { return &v }

func intPtr(v int) *int { return &v }

func strPtr(v string) *string { return &v }
