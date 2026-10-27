package a2687

import (
	"bytes"
	"errors"
	"fmt"
	"testing"
)

func cryptoErrKind(tb testing.TB, err error) CryptoErrorKind {
	tb.Helper()
	var cryptoErr *CryptoError
	if !errors.As(err, &cryptoErr) {
		tb.Fatalf("expected *CryptoError, got %v", err)
	}
	return cryptoErr.Kind
}

// C1: the static negotiation key decrypts every real fixture.
func TestOpensRealNegotiationFramesWithTheStaticKey(t *testing.T) {
	cases := []struct{ name, frame, plain string }{
		{"clientInitialConnect", fxClientInitialConnect, fxPlainClientInitialConnect},
		{"clientCapability", fxClientCapability, fxPlainClientCapability},
		{"deviceInitialConnect", fxDeviceInitialConnect, fxPlainDeviceInitialConnect},
		{"deviceCapability", fxDeviceCapability, fxPlainDeviceCapability},
		{"deviceBaseInfo", fxDeviceBaseInfo, fxPlainDeviceBaseInfo},
		{"deviceSetCapability", fxDeviceSetCapability, fxPlainDeviceSetCapability},
		{"devicePublicKey", fxDevicePublicKey, fxPlainDevicePublicKey},
	}
	keys := NegotiationKeys()
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			frame, err := DecodePacket(mustHex(t, tc.frame))
			if err != nil {
				t.Fatalf("DecodePacket: %v", err)
			}
			opened, err := Open(frame.Payload, keys)
			if err != nil {
				t.Fatalf("Open: %v", err)
			}
			if got := hexStr(opened); got != tc.plain {
				t.Errorf("plaintext = %s, want %s", got, tc.plain)
			}
		})
	}
}

// C2: sealing the known plaintext reproduces the captured ciphertext.
func TestSealReproducesTheCapture(t *testing.T) {
	sealed, err := Seal(mustHex(t, fxPlainClientCapability), NegotiationKeys())
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	frame, err := DecodePacket(mustHex(t, fxClientCapability))
	if err != nil {
		t.Fatalf("DecodePacket: %v", err)
	}
	if !bytes.Equal(sealed, frame.Payload) {
		t.Errorf("sealed = %x, want %x", sealed, frame.Payload)
	}

	// The same for the captured initial-connect frame: the payload of the capture
	// is ciphertext||tag, exactly what Seal must produce.
	sealed, err = Seal(mustHex(t, fxPlainClientInitialConnect), NegotiationKeys())
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	captured, err := DecodePacket(mustHex(t, fxClientInitialConnect))
	if err != nil {
		t.Fatalf("DecodePacket: %v", err)
	}
	if !bytes.Equal(sealed, captured.Payload) {
		t.Errorf("initial-connect seal = %x, want %x", sealed, captured.Payload)
	}
}

// C3: tampering fails closed in both directions.
func TestTamperedPayloadFailsClosed(t *testing.T) {
	captured, err := DecodePacket(mustHex(t, fxDeviceCapability))
	if err != nil {
		t.Fatalf("DecodePacket: %v", err)
	}

	tagged := append([]byte(nil), captured.Payload...)
	tagged[len(tagged)-1] ^= 0x01
	if _, err := Open(tagged, NegotiationKeys()); err == nil {
		t.Error("tampered tag decrypted")
	} else if kind := cryptoErrKind(t, err); kind != CryptoErrAuthenticationFailed {
		t.Errorf("kind = %v, want authentication failed", kind)
	}

	ciphertext := append([]byte(nil), captured.Payload...)
	ciphertext[0] ^= 0x01
	if _, err := Open(ciphertext, NegotiationKeys()); err == nil {
		t.Error("tampered ciphertext decrypted")
	} else if kind := cryptoErrKind(t, err); kind != CryptoErrAuthenticationFailed {
		t.Errorf("kind = %v, want authentication failed", kind)
	}
}

// C4: payloads at or below the tag length are refused before any GCM work.
func TestRejectsPayloadShorterThanTheTag(t *testing.T) {
	for _, size := range []int{0, 1, TagLength} {
		payload := make([]byte, size)
		_, err := Open(payload, NegotiationKeys())
		if err == nil {
			t.Fatalf("Open(%d bytes) succeeded", size)
		}
		if kind := cryptoErrKind(t, err); kind != CryptoErrPayloadTooShort {
			t.Errorf("kind = %v, want payload too short", kind)
		}
	}
}

// C5: the 16/12 key schedule split.
func TestKeyScheduleSplitsTheSharedSecret(t *testing.T) {
	secret := make([]byte, 32)
	for i := range secret {
		secret[i] = byte(i)
	}
	keys, err := NewKeysFromSecret(secret)
	if err != nil {
		t.Fatalf("NewKeysFromSecret: %v", err)
	}
	sealed, err := Seal([]byte{0xAA, 0xBB}, keys)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	opened, err := Open(sealed, keys)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if !bytes.Equal(opened, []byte{0xAA, 0xBB}) {
		t.Errorf("opened = %x", opened)
	}

	// Two keys that differ only in the nonce half must not authenticate each
	// other's payloads: the split has to be real, not a hash of the whole secret.
	altered := append([]byte(nil), secret...)
	altered[16] ^= 0xFF
	otherKeys, err := NewKeysFromSecret(altered)
	if err != nil {
		t.Fatalf("NewKeysFromSecret: %v", err)
	}
	if _, err := Open(sealed, otherKeys); err == nil {
		t.Error("a different nonce half decrypted the payload")
	}

	if _, err := NewKeysFromSecret(secret[:27]); err == nil {
		t.Error("a 27-byte secret must be refused")
	} else if kind := cryptoErrKind(t, err); kind != CryptoErrShortSharedSecret {
		t.Errorf("kind = %v, want short shared secret", kind)
	}
	if _, err := NewKeysFromSecret(secret[:28]); err != nil {
		t.Errorf("a 28-byte secret must be accepted: %v", err)
	}
}

// C6: both sides agree on the ECDH secret.
func TestEphemeralAgreementMatchesOnBothSides(t *testing.T) {
	client, err := GenerateEphemeralKey()
	if err != nil {
		t.Fatalf("GenerateEphemeralKey: %v", err)
	}
	device, err := GenerateEphemeralKey()
	if err != nil {
		t.Fatalf("GenerateEphemeralKey: %v", err)
	}
	clientSecret, err := SharedSecret(client, RawPublicKey(device))
	if err != nil {
		t.Fatalf("client SharedSecret: %v", err)
	}
	deviceSecret, err := SharedSecret(device, RawPublicKey(client))
	if err != nil {
		t.Fatalf("device SharedSecret: %v", err)
	}
	if !bytes.Equal(clientSecret, deviceSecret) {
		t.Errorf("secrets differ: %x vs %x", clientSecret, deviceSecret)
	}
	if len(clientSecret) != 32 {
		t.Errorf("secret length = %d, want 32", len(clientSecret))
	}
}

// C7: every connection uses a fresh key pair.
func TestEveryConnectionUsesAFreshKey(t *testing.T) {
	first, err := GenerateEphemeralKey()
	if err != nil {
		t.Fatalf("GenerateEphemeralKey: %v", err)
	}
	second, err := GenerateEphemeralKey()
	if err != nil {
		t.Fatalf("GenerateEphemeralKey: %v", err)
	}
	if bytes.Equal(RawPublicKey(first), RawPublicKey(second)) {
		t.Error("two ephemeral keys are identical")
	}
	if got := len(RawPublicKey(first)); got != 64 {
		t.Errorf("raw public key length = %d, want 64", got)
	}
	if bytes.Contains(RawPublicKey(first), []byte{0x04}) && len(RawPublicKey(first)) != 64 {
		t.Error("the 0x04 x963 prefix must be stripped")
	}
}

// C8: malformed device points are refused, not coerced.
func TestRejectsMalformedDevicePoint(t *testing.T) {
	key, err := GenerateEphemeralKey()
	if err != nil {
		t.Fatalf("GenerateEphemeralKey: %v", err)
	}
	cases := [][]byte{
		{0x00},
		make([]byte, 63),
		make([]byte, 65),
		bytes.Repeat([]byte{0xFF}, 64),
		make([]byte, 64), // all zero is not a curve point
	}
	for _, point := range cases {
		if _, err := SharedSecret(key, point); err == nil {
			t.Errorf("SharedSecret accepted a %d-byte point", len(point))
		} else if kind := cryptoErrKind(t, err); kind != CryptoErrBadPublicKey {
			t.Errorf("kind = %v, want bad public key", kind)
		}
	}
}

// C9: a real device point from the capture agrees.
func TestAgreesWithARealDevicePoint(t *testing.T) {
	payload, err := ParsePayload(mustHex(t, fxPlainDevicePublicKey))
	if err != nil {
		t.Fatalf("ParsePayload: %v", err)
	}
	point, ok := payload.Field(FieldA1)
	if !ok || len(point) != 64 {
		t.Fatalf("device point = %x/%v, want 64 bytes", point, ok)
	}
	key, err := GenerateEphemeralKey()
	if err != nil {
		t.Fatalf("GenerateEphemeralKey: %v", err)
	}
	secret, err := SharedSecret(key, point)
	if err != nil {
		t.Fatalf("SharedSecret: %v", err)
	}
	if len(secret) != 32 {
		t.Errorf("secret length = %d, want 32", len(secret))
	}
}

// Keys must never leak through any fmt verb.
func TestKeysRenderRedacted(t *testing.T) {
	keys := NegotiationKeys()
	for _, format := range []string{"%v", "%+v", "%s", "%x", "%#v", "%q"} {
		rendered := fmt.Sprintf(format, keys)
		if rendered != "a2687.Keys(<redacted>)" {
			t.Errorf("fmt %q rendered %q", format, rendered)
		}
	}
	// Pointers use the same Stringer.
	rendered := fmt.Sprintf("%v", &keys)
	if rendered != "a2687.Keys(<redacted>)" {
		t.Errorf("pointer rendered %q", rendered)
	}
}

func TestEncryptionString(t *testing.T) {
	if got := EncryptionNegotiation.String(); got != "negotiation" {
		t.Errorf("negotiation = %q", got)
	}
	if got := EncryptionSession.String(); got != "session" {
		t.Errorf("session = %q", got)
	}
}
