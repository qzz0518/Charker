package a2345

import (
	"encoding/hex"
	"errors"
	"testing"
	"time"
)

// De-identified byte-exact fixtures shaped from the verified A2345 captures
// (Tests/A2345ProtocolTests/Fixtures.swift). No serial, account, token or
// MQTT topic.
const (
	// fxRealtimeOldFirmware is firmware without optional field A9.
	fxRealtimeOldFirmware = "ff09640003010f030301a10134a2080401883a60065009a3080400000000000000a4080401881314000a00a5080400000000000000a6080400000000000000a7080400000000000000a81104ac05a8120000000000000000fffffffffe0503785634125d"

	// fxRealtimeNewFirmware has the newer optional four-slot A9 field.
	fxRealtimeNewFirmware = "ff09770003010f030302a10134a2080401883a60065009a3080400000000000000a4080401881314000a00a5080400000000000000a6080400000000000000a7080400000000000000a81104ac05a8120000000000000000ffffffffa9110401001f00ffffffff00000000fffffffffe050378563412ef"

	// fxRealtimeChinaFirmware is the mainland 1.4.0.2 shape: three more
	// bytes per port (C1: 5 A cable, protocol 1, brand 1).
	fxRealtimeChinaFirmware = "ff09760003010f030301a10134a20b0401883a60065009010101a30b0400000000000000000000a40b0401881314000a00000000a50b0400000000000000000000a60b0400000000000000000000a70b0400000000000000000000a81104ac05a8120000000000000000fffffffffe0503785634124e"

	// fxVersionInfo is the 62-byte 0830 shape.
	fxVersionInfo = "ff093e0003010f0830a10600312e302e30a20800322e312e312e36a306004132333435a40a0041323334355f6d6375a50c0041323334355f657370333214"

	// fxRealtimeAcknowledgement is the 14-byte 0A0B shape.
	fxRealtimeAcknowledgement = "ff090e0003010f0a0b00a1013460"

	// fxCapturedSnapshot is a 303-byte 0x0A00 (firmware 2.1.1.2, custom mode
	// active).
	fxCapturedSnapshot = "ff092f0103010f0a0000a10164a203024008a303020000a4080400000000000000a5080400000000000000a6080400000000000000a7080400000000000000a8080400000000000000a9080400000000000000aa140400ff0c0000ff0c000000340800000000000000ab140400ff0c0000ff0c000000201c00000000000000ac140400000c0000000c000000201c00000000000000ad140400000800020017000200580200000000000000ae140400ff0c0000ff0c000000701700000000000000af06040100000000b0020101b1020105b203040000b3020114b4020101b5020101b6020101b70302ff02b8080401000f0f0f0f0fb90604080017007fba0d04030000030000030000030000bb020101bc020101bd1104fafffbfffafffbfffafffbfffafffbfffe050370428f69e4"
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

func hexStr(b []byte) string { return hex.EncodeToString(b) }

func mustDecode(tb testing.TB, s string) Frame {
	tb.Helper()
	f, err := Decode(mustHex(tb, s))
	if err != nil {
		tb.Fatalf("Decode: %v", err)
	}
	return f
}

func frameKind(tb testing.TB, err error) *FrameError {
	tb.Helper()
	var fe *FrameError
	if !errors.As(err, &fe) {
		tb.Fatalf("expected *FrameError, got %v", err)
	}
	return fe
}

func messageErr(tb testing.TB, err error) *MessageError {
	tb.Helper()
	var me *MessageError
	if !errors.As(err, &me) {
		tb.Fatalf("expected *MessageError, got %v", err)
	}
	return me
}

// Command vectors: 1_700_000_000, and the two capture stamps of the control
// tests.
var (
	epoch  = time.Unix(1_700_000_000, 0)
	stampA = time.Unix(0x6ABD_CCE3, 0)
	stampB = time.Unix(0x68E7_7800, 0)
)

func u8(v byte) *byte                    { return &v }
func u32(v uint32) *uint32               { return &v }
func str(v string) *string               { return &v }
func boolp(v bool) *bool                 { return &v }
func groupp(g PortGroup) *PortGroup      { return &g }
func slotp(s ScheduleSlot) *ScheduleSlot { return &s }
