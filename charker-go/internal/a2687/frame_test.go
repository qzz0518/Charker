package a2687

import (
	"errors"
	"reflect"
	"testing"
)

func frameErrKind(tb testing.TB, err error) FrameErrorKind {
	tb.Helper()
	var frameErr *FrameError
	if !errors.As(err, &frameErr) {
		tb.Fatalf("expected *FrameError, got %v", err)
	}
	return frameErr.Kind
}

// F1: decode a real device capability frame.
func TestDecodeRealDeviceFrame(t *testing.T) {
	frame, err := DecodePacket(mustHex(t, fxDeviceCapability))
	if err != nil {
		t.Fatalf("DecodePacket: %v", err)
	}
	if frame.Group() != GroupNegotiation {
		t.Errorf("group = 0x%02X, want 0x01", frame.Group())
	}
	if frame.RawCommand != 0x4803 {
		t.Errorf("rawCommand = 0x%04X, want 0x4803", frame.RawCommand)
	}
	if frame.Opcode() != OpcodeCapability {
		t.Errorf("opcode = 0x%04X, want 0x%04X", frame.Opcode(), OpcodeCapability)
	}
	if !frame.IsEncrypted() || !frame.IsResponse() {
		t.Errorf("flags: encrypted=%v response=%v, want both", frame.IsEncrypted(), frame.IsResponse())
	}
	if frame.Pattern != (FramePattern{Version: ProtocolVersion, Slave: SpeakerApp, Group: GroupNegotiation}) {
		t.Errorf("pattern = %+v", frame.Pattern)
	}
}

// F2: encode reproduces every capture byte for byte.
func TestEncodeIsByteIdenticalToCapture(t *testing.T) {
	cases := []struct{ name, hex string }{
		{"clientInitialConnect", fxClientInitialConnect},
		{"clientCapability", fxClientCapability},
		{"clientBaseInfo", fxClientBaseInfo},
		{"deviceInitialConnect", fxDeviceInitialConnect},
		{"deviceCapability", fxDeviceCapability},
		{"deviceBaseInfo", fxDeviceBaseInfo},
		{"deviceSetCapability", fxDeviceSetCapability},
		{"devicePublicKey", fxDevicePublicKey},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			original := mustHex(t, tc.hex)
			frame, err := DecodePacket(original)
			if err != nil {
				t.Fatalf("DecodePacket: %v", err)
			}
			if got := hexStr(EncodePacket(frame)); got != tc.hex {
				t.Errorf("encode = %s, want %s", got, tc.hex)
			}
		})
	}
}

// F3: length and flag encoding.
func TestEncodedLengthCoversWholeFrame(t *testing.T) {
	frame := NewCommandFrame(GroupSession, OpcodePortOutput, true, false, []byte{1, 2, 3})
	bytes := EncodePacket(frame)
	if len(bytes) != 13 {
		t.Fatalf("len = %d, want 13", len(bytes))
	}
	if encoded := int(bytes[2]) | int(bytes[3])<<8; encoded != len(bytes) {
		t.Errorf("length field = %d, want %d", encoded, len(bytes))
	}
	if bytes[7] != 0x42 {
		t.Errorf("bytes[7] = 0x%02X, want 0x42 (encrypted|0x02)", bytes[7])
	}
	if bytes[8] != 0x07 {
		t.Errorf("bytes[8] = 0x%02X, want 0x07", bytes[8])
	}
}

// F4: strict decode rejects each malformed shape with the right error kind.
func TestDecodeRejectsMalformedFrames(t *testing.T) {
	base := func() []byte {
		b := mustHex(t, fxDeviceSetCapability)
		return append([]byte(nil), b...)
	}
	badChecksum := base()
	badChecksum[len(badChecksum)-1] ^= 0xFF
	lengthMismatch := base()
	lengthMismatch[2] = 0x40
	badHeader := base()
	badHeader[0] = 0xFE
	badVersion := base()
	badVersion[4] = 0x04
	badVersion[len(badVersion)-1] = FrameChecksum(badVersion[:len(badVersion)-1])

	cases := []struct {
		name string
		data []byte
		want FrameErrorKind
	}{
		{"badChecksum", badChecksum, FrameErrBadChecksum},
		{"lengthMismatch", lengthMismatch, FrameErrLengthMismatch},
		{"badHeader", badHeader, FrameErrBadHeader},
		{"badVersion", badVersion, FrameErrBadProtocolVersion},
		{"tooShort", []byte{0xFF, 0x09, 0x04, 0x00}, FrameErrTooShort},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := DecodePacket(tc.data)
			if err == nil {
				t.Fatal("expected error")
			}
			if got := frameErrKind(t, err); got != tc.want {
				t.Errorf("kind = %v, want %v", got, tc.want)
			}
		})
	}

	// The version error carries the offending byte.
	_, err := DecodePacket(badVersion)
	var frameErr *FrameError
	if !errors.As(err, &frameErr) || frameErr.Version != 0x04 {
		t.Errorf("bad version error = %+v, want Version 0x04", frameErr)
	}
}

// F5: the device-side session pattern 03 01 11 must be accepted, not asserted as
// the app's 03 00 0F — validating it as a constant silently drops every
// telemetry frame the charger sends.
func TestAcceptsTheDeviceSideSessionPattern(t *testing.T) {
	bytes := []byte{0xFF, 0x09, 0x00, 0x00, 0x03, 0x01, 0x11, 0x4A, 0x00, 0xAB, 0xCD}
	bytes[2] = byte(len(bytes) + 1)
	bytes = append(bytes, FrameChecksum(bytes))

	frame, err := DecodePacket(bytes)
	if err != nil {
		t.Fatalf("DecodePacket: %v", err)
	}
	if want := (FramePattern{Version: 0x03, Slave: 0x01, Group: 0x11}); frame.Pattern != want {
		t.Errorf("pattern = %+v, want %+v", frame.Pattern, want)
	}
	if frame.Opcode() != OpcodeReadAll {
		t.Errorf("opcode = 0x%04X, want 0x%04X", frame.Opcode(), OpcodeReadAll)
	}
	if !frame.IsResponse() || !frame.IsEncrypted() || !frame.IsFromDevice() {
		t.Errorf("flags: response=%v encrypted=%v fromDevice=%v, want all true",
			frame.IsResponse(), frame.IsEncrypted(), frame.IsFromDevice())
	}
	if !reflect.DeepEqual(frame.Payload, []byte{0xAB, 0xCD}) {
		t.Errorf("payload = %x", frame.Payload)
	}
}

func TestPatternRoundTripsAndFromDevice(t *testing.T) {
	original := NewFrame(
		FramePattern{Version: 0x03, Slave: 0x01, Group: 0x11},
		0x4A0B,
		[]byte{0x01},
	)
	decoded, err := DecodePacket(EncodePacket(original))
	if err != nil {
		t.Fatalf("DecodePacket: %v", err)
	}
	if !reflect.DeepEqual(decoded, original) {
		t.Errorf("decoded = %+v, want %+v", decoded, original)
	}

	appFrame := NewCommandFrame(GroupNegotiation, OpcodeInitialConnect, true, false, nil)
	if appFrame.IsFromDevice() {
		t.Error("an app frame must not be from the device")
	}
	responseFrame := NewCommandFrame(GroupSession, OpcodeReadAll, true, true, nil)
	if !responseFrame.IsFromDevice() {
		t.Error("a response frame must be from the device")
	}
	slaveFrame := NewFrame(FramePattern{Version: 0x03, Slave: 0x01, Group: 0x01}, 0x0000, nil)
	if !slaveFrame.IsFromDevice() {
		t.Error("a slave=1 frame must be from the device")
	}
}

func TestRejectsTooLargeFrame(t *testing.T) {
	// A plausible length field above the defensive ceiling is rejected when the
	// candidate arrives whole; the reassembler also refuses to buffer it.
	data := make([]byte, MaxFrameLength+1)
	data[0], data[1] = Header0, Header1
	length := len(data)
	data[2], data[3] = byte(length), byte(length>>8)
	if _, err := DecodePacket(data); err == nil {
		t.Fatal("expected error")
	} else if kind := frameErrKind(t, err); kind != FrameErrTooLarge {
		t.Errorf("kind = %v, want too large", kind)
	}
}

// R1: reassemble a frame split across 20-byte notifications.
func TestReassemblesFrameSplitAcrossNotifications(t *testing.T) {
	var reassembler FrameReassembler
	full := mustHex(t, fxDeviceBaseInfo)
	var frames []Frame
	for start := 0; start < len(full); start += 20 {
		end := start + 20
		if end > len(full) {
			end = len(full)
		}
		frames = append(frames, reassembler.Append(full[start:end])...)
	}
	if len(frames) != 1 {
		t.Fatalf("frames = %d, want 1", len(frames))
	}
	if frames[0].Opcode() != OpcodeBaseInfo {
		t.Errorf("opcode = 0x%04X, want 0x%04X", frames[0].Opcode(), OpcodeBaseInfo)
	}
	if reassembler.DroppedBytes != 0 || reassembler.RejectedFrames != 0 {
		t.Errorf("counters = %d/%d, want 0/0", reassembler.DroppedBytes, reassembler.RejectedFrames)
	}
}

// R1b: one-byte notifications still reassemble (mock acceptance criterion).
func TestReassemblesOneByteNotifications(t *testing.T) {
	var reassembler FrameReassembler
	full := mustHex(t, fxDeviceCapability)
	var frames []Frame
	for _, b := range full {
		frames = append(frames, reassembler.Append([]byte{b})...)
	}
	if len(frames) != 1 || frames[0].Opcode() != OpcodeCapability {
		t.Fatalf("frames = %+v", frames)
	}
}

// R2: two frames in one notification.
func TestSplitsConcatenatedFrames(t *testing.T) {
	var reassembler FrameReassembler
	data := append(mustHex(t, fxDeviceInitialConnect), mustHex(t, fxDeviceSetCapability)...)
	frames := reassembler.Append(data)
	if len(frames) != 2 {
		t.Fatalf("frames = %d, want 2", len(frames))
	}
	got := []uint16{frames[0].Opcode(), frames[1].Opcode()}
	want := []uint16{OpcodeInitialConnect, OpcodeSetCapability}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("opcodes = %v, want %v", got, want)
	}
}

// R3: garbage before a header is dropped and counted.
func TestResynchronisesAfterGarbage(t *testing.T) {
	var reassembler FrameReassembler
	data := append([]byte{0x01, 0x02, 0x03}, mustHex(t, fxDeviceSetCapability)...)
	frames := reassembler.Append(data)
	if len(frames) != 1 {
		t.Fatalf("frames = %d, want 1", len(frames))
	}
	if reassembler.DroppedBytes != 3 {
		t.Errorf("droppedBytes = %d, want 3", reassembler.DroppedBytes)
	}
}

// R4: a corrupt frame is rejected, never repaired.
func TestCorruptFrameIsRejectedNotRepaired(t *testing.T) {
	var reassembler FrameReassembler
	data := mustHex(t, fxDeviceSetCapability)
	data[len(data)-1] ^= 0x01
	frames := reassembler.Append(data)
	if len(frames) != 0 {
		t.Fatalf("frames = %d, want 0", len(frames))
	}
	if reassembler.RejectedFrames != 1 {
		t.Errorf("rejectedFrames = %d, want 1", reassembler.RejectedFrames)
	}
	if reassembler.LastRejection == nil {
		t.Fatal("expected a recorded rejection")
	}
	if reassembler.LastRejection.Err.Kind != FrameErrBadChecksum {
		t.Errorf("rejection kind = %v, want bad checksum", reassembler.LastRejection.Err.Kind)
	}
	if len(reassembler.LastRejection.Head) == 0 || reassembler.LastRejection.Head[0] != Header0 {
		t.Errorf("rejection head = %x", reassembler.LastRejection.Head)
	}
}

// R5: an implausible length must not stall the stream.
func TestImplausibleLengthDoesNotStallTheStream(t *testing.T) {
	var reassembler FrameReassembler
	if frames := reassembler.Append([]byte{0xFF, 0x09, 0x02, 0x00}); len(frames) != 0 {
		t.Fatalf("premature frames = %d", len(frames))
	}
	frames := reassembler.Append(mustHex(t, fxDeviceSetCapability))
	if len(frames) != 1 {
		t.Fatalf("frames = %d, want 1", len(frames))
	}
	if reassembler.RejectedFrames != 1 {
		t.Errorf("rejectedFrames = %d, want 1", reassembler.RejectedFrames)
	}
}

func TestReassemblerResetKeepsPartialFrameOut(t *testing.T) {
	var reassembler FrameReassembler
	full := mustHex(t, fxDeviceCapability)
	reassembler.Append(full[:10])
	reassembler.Reset()
	if reassembler.Buffered() != 0 {
		t.Errorf("buffered = %d, want 0", reassembler.Buffered())
	}
	frames := reassembler.Append(full)
	if len(frames) != 1 {
		t.Fatalf("frames = %d, want 1", len(frames))
	}
}

func TestOpcodeNameIsStable(t *testing.T) {
	cases := map[uint16]string{
		OpcodeInitialConnect: "initialConnect",
		OpcodeCapability:     "capability",
		OpcodeReadAll:        "readAll",
		OpcodeRealtimeReport: "realtimeReport",
		0x0999:               "0x0999",
	}
	for opcode, want := range cases {
		if got := OpcodeName(opcode); got != want {
			t.Errorf("OpcodeName(0x%04X) = %q, want %q", opcode, got, want)
		}
	}
}

func TestPortConstants(t *testing.T) {
	if got := []Port{PortC1, PortC2, PortC3}; !reflect.DeepEqual(got, Ports) {
		t.Errorf("Ports = %v", got)
	}
	for _, port := range Ports {
		if !port.Valid() {
			t.Errorf("port %d should be valid", port)
		}
	}
	if Port(3).Valid() {
		t.Error("port 3 should be invalid")
	}
	if got := PortC2.Label(); got != "C2" {
		t.Errorf("Label = %q", got)
	}
	if PortC1.TelemetryField() != FieldA5 || PortC2.TelemetryField() != FieldA6 || PortC3.TelemetryField() != FieldA7 {
		t.Error("telemetry field mapping is wrong")
	}
	if PortC1.CableField() != FieldAC || PortC2.CableField() != FieldAD || PortC3.CableField() != FieldAE {
		t.Error("cable field mapping is wrong")
	}
}

// The fixture matrix: every captured frame's metadata, so a change in the
// pattern handling is caught once rather than through a downstream test.
func TestFixtureFrameMatrix(t *testing.T) {
	cases := []struct {
		name      string
		hexData   string
		group     byte
		slave     byte
		opcode    uint16
		encrypted bool
		response  bool
	}{
		{"clientInitialConnect", fxClientInitialConnect, GroupNegotiation, SpeakerApp, OpcodeInitialConnect, true, false},
		{"clientCapability", fxClientCapability, GroupNegotiation, SpeakerApp, OpcodeCapability, true, false},
		{"clientBaseInfo", fxClientBaseInfo, GroupNegotiation, SpeakerApp, OpcodeBaseInfo, true, false},
		{"deviceInitialConnect", fxDeviceInitialConnect, GroupNegotiation, SpeakerApp, OpcodeInitialConnect, true, true},
		{"deviceCapability", fxDeviceCapability, GroupNegotiation, SpeakerApp, OpcodeCapability, true, true},
		{"deviceBaseInfo", fxDeviceBaseInfo, GroupNegotiation, SpeakerApp, OpcodeBaseInfo, true, true},
		{"deviceSetCapability", fxDeviceSetCapability, GroupNegotiation, SpeakerApp, OpcodeSetCapability, true, true},
		{"devicePublicKey", fxDevicePublicKey, GroupNegotiation, SpeakerApp, OpcodePublicKey, true, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			raw := mustHex(t, tc.hexData)
			frame, err := DecodePacket(raw)
			if err != nil {
				t.Fatalf("DecodePacket: %v", err)
			}
			if frame.Group() != tc.group || frame.Pattern.Slave != tc.slave {
				t.Errorf("pattern = %+v", frame.Pattern)
			}
			if frame.Opcode() != tc.opcode {
				t.Errorf("opcode = 0x%04X, want 0x%04X", frame.Opcode(), tc.opcode)
			}
			if frame.IsEncrypted() != tc.encrypted || frame.IsResponse() != tc.response {
				t.Errorf("flags = encrypted %v response %v", frame.IsEncrypted(), frame.IsResponse())
			}
			if len(frame.Payload) != len(raw)-Overhead {
				t.Errorf("payload = %d bytes, want %d", len(frame.Payload), len(raw)-Overhead)
			}
			if !reflect.DeepEqual(EncodePacket(frame), raw) {
				t.Error("re-encode is not byte-identical")
			}
		})
	}
}
