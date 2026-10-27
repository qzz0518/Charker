package a2687

import (
	"testing"
)

// M12: log redaction vectors from the Swift RedactionTests.
func TestSerialIsMasked(t *testing.T) {
	cases := map[string]string{
		"ASHDEXAMPLE000001": "ASHD…0001",
		"":                  "—",
		"ABC":               "•••",
		"ABCDEFGH":          "••••••••",
		"ABCDEFGHI":         "ABCD…FGHI",
	}
	for value, want := range cases {
		if got := RedactIdentifier(value); got != want {
			t.Errorf("RedactIdentifier(%q) = %q, want %q", value, got, want)
		}
	}
}

func TestMacKeepsOnlyTheVendorPrefix(t *testing.T) {
	cases := map[string]string{
		"AA:BB:CC:DD:EE:FF": "AA:BB:••:••:••:FF",
		"":                  "—",
		"not-a-mac":         RedactIdentifier("not-a-mac"),
		"AA:BB:CC":          RedactIdentifier("AA:BB:CC"),
	}
	for value, want := range cases {
		if got := RedactMAC(value); got != want {
			t.Errorf("RedactMAC(%q) = %q, want %q", value, got, want)
		}
	}
}

func TestPayloadIsSummarisedUnlessRawCaptureIsOn(t *testing.T) {
	payload := []byte{1, 2, 3}
	if got := RedactPayload(payload, false); got != "3 B" {
		t.Errorf("summary = %q, want 3 B", got)
	}
	if got := RedactPayload(payload, true); got != "010203" {
		t.Errorf("raw = %q, want 010203", got)
	}
	if got := RedactPayload(nil, false); got != "0 B" {
		t.Errorf("empty summary = %q", got)
	}
}

func TestOpcodeFormatting(t *testing.T) {
	if got := RedactOpcode(OpcodePortOutput); got != "0x0207" {
		t.Errorf("opcode = %q", got)
	}
	if got := RedactOpcode(0x0FFF); got != "0x0FFF" {
		t.Errorf("opcode = %q", got)
	}
}
