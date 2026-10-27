package a2687

import (
	"fmt"
	"strings"
)

// Redaction helpers for anything that may reach a log file or a diagnostics
// export. Session keys, nonces, shared secrets and ECDH private keys are never
// passed through here — they simply never leave the crypto layer.

// RedactIdentifier shortens a serial or account id: "ASHDEXAMPLE000001" ->
// "ASHD…0001". Empty input becomes an em dash; a short value is masked
// completely rather than partially revealed.
func RedactIdentifier(value string) string {
	if value == "" {
		return "—"
	}
	runes := []rune(value)
	if len(runes) <= 8 {
		return strings.Repeat("•", len(runes))
	}
	return string(runes[:4]) + "…" + string(runes[len(runes)-4:])
}

// RedactMAC keeps only the vendor prefix and the last octet:
// "AA:BB:CC:DD:EE:FF" -> "AA:BB:••:••:••:FF". A value that is not a six-part
// colon-separated address falls back to RedactIdentifier.
func RedactMAC(value string) string {
	if value == "" {
		return "—"
	}
	parts := strings.Split(value, ":")
	if len(parts) != 6 {
		return RedactIdentifier(value)
	}
	return parts[0] + ":" + parts[1] + ":••:••:••:" + parts[5]
}

// RedactPayload summarises payload bytes, never dumps them, unless raw capture
// has been explicitly enabled.
func RedactPayload(bytes []byte, rawAllowed bool) string {
	if !rawAllowed {
		return fmt.Sprintf("%d B", len(bytes))
	}
	var builder strings.Builder
	builder.Grow(len(bytes) * 2)
	for _, b := range bytes {
		builder.WriteString(fmt.Sprintf("%02x", b))
	}
	return builder.String()
}

// RedactOpcode formats an opcode the way diagnostics logs it: "0x0207".
func RedactOpcode(value uint16) string { return fmt.Sprintf("0x%04X", value) }
