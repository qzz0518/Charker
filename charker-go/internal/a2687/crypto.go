package a2687

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/rand"
	"fmt"
)

// AES-GCM / P-256 layer of the A2687 session.
//
// Two key schedules exist:
//
//   - negotiation: a static key/nonce baked into the firmware, used until the
//     ECDH exchange completes. Knowing it buys no confidentiality; it only makes
//     the handshake parseable.
//   - session: the P-256 shared secret — bytes 0..16 are the AES-128 key, bytes
//     16..28 are the GCM nonce.
//
// The protocol reuses one nonce for every message under a session key and does
// not cover the frame header with the AAD. Those are protocol weaknesses we must
// tolerate to interoperate; they are why Open is strictly fail-closed and
// callers additionally constrain opcode, TLV schema and state.

// TagLength is the AES-GCM authentication tag length.
const TagLength = 16

// aad is the additional authenticated data, constant across the protocol.
var aad = []byte{
	0x33, 0x22, 0x11, 0x00, 0x77, 0x66, 0x55, 0x44,
	0xBB, 0xAA, 0x99, 0x88, 0xFF, 0xEE, 0xDD, 0xCC,
}

// negotiationKey is the firmware's static negotiation AES-128 key.
var negotiationKey = [16]byte{
	0xB8, 0xFF, 0x74, 0x22, 0x95, 0x5D, 0x4E, 0xB6,
	0xD5, 0x54, 0xA2, 0xC4, 0x70, 0x28, 0x05, 0x59,
}

// negotiationNonce is the static 12-byte GCM nonce for the negotiation key.
var negotiationNonce = [12]byte{
	0x6B, 0xA3, 0xE3, 0xF2, 0xF3, 0xA6, 0x0F, 0x29, 0x71, 0xCE, 0x5D, 0x1F,
}

// Keys is one AES-128-GCM key/nonce pair. It is never persisted, never logged
// and never surfaced in the UI: the fields are unexported and String redacts.
type Keys struct {
	key   [16]byte
	nonce [12]byte
}

// NewKeysFromSecret derives a session key schedule from the P-256 shared
// secret: the first 16 bytes are the AES key, bytes 16..28 the nonce. The
// secret must be at least 28 bytes (32 from P-256).
func NewKeysFromSecret(secret []byte) (Keys, error) {
	if len(secret) < 28 {
		return Keys{}, &CryptoError{Kind: CryptoErrShortSharedSecret, Size: len(secret)}
	}
	var keys Keys
	copy(keys.key[:], secret[:16])
	copy(keys.nonce[:], secret[16:28])
	return keys, nil
}

// NegotiationKeys returns the static firmware key schedule.
func NegotiationKeys() Keys {
	return Keys{key: negotiationKey, nonce: negotiationNonce}
}

// String implements fmt.Stringer without revealing the key material, so an
// accidental %v of a Keys value cannot leak a session key into a log.
func (Keys) String() string { return "a2687.Keys(<redacted>)" }

// GoString implements fmt.GoStringer for the same reason.
func (Keys) GoString() string { return "a2687.Keys(<redacted>)" }

// Format implements fmt.Formatter: any verb prints the redacted form.
func (Keys) Format(f fmt.State, verb rune) {
	_, _ = fmt.Fprint(f, "a2687.Keys(<redacted>)")
}

// CryptoErrorKind discriminates CryptoError. It mirrors the Swift
// A2687Crypto.CryptoError cases.
type CryptoErrorKind int

const (
	CryptoErrShortSharedSecret CryptoErrorKind = iota + 1
	CryptoErrPayloadTooShort
	CryptoErrAuthenticationFailed
	CryptoErrBadPublicKey
	CryptoErrSealFailed
)

// CryptoError is a failure of the crypto layer.
type CryptoError struct {
	Kind CryptoErrorKind
	// Size is the offending byte count for the short-input cases.
	Size int
}

// Error implements error. Messages are short and stable.
func (e *CryptoError) Error() string {
	switch e.Kind {
	case CryptoErrShortSharedSecret:
		return fmt.Sprintf("crypto: shared secret too short (%d bytes, need 28)", e.Size)
	case CryptoErrPayloadTooShort:
		return fmt.Sprintf("crypto: payload too short (%d bytes)", e.Size)
	case CryptoErrAuthenticationFailed:
		return "crypto: authentication failed"
	case CryptoErrBadPublicKey:
		return "crypto: bad public key"
	case CryptoErrSealFailed:
		return "crypto: seal failed"
	default:
		return "crypto: failure"
	}
}

// Seal encrypts plaintext with AES-GCM under keys and returns ciphertext||tag.
// The same fixed nonce is used for every message, as the firmware does.
func Seal(plaintext []byte, keys Keys) ([]byte, error) {
	aead, err := newGCM(keys)
	if err != nil {
		return nil, err
	}
	return aead.Seal(nil, keys.nonce[:], plaintext, aad), nil
}

// Open decrypts ciphertext||tag under keys. It is fail-closed: a payload of tag
// length or shorter, or any tag mismatch, returns an error and never plaintext.
func Open(payload []byte, keys Keys) ([]byte, error) {
	if len(payload) <= TagLength {
		return nil, &CryptoError{Kind: CryptoErrPayloadTooShort, Size: len(payload)}
	}
	aead, err := newGCM(keys)
	if err != nil {
		return nil, err
	}
	plaintext, err := aead.Open(nil, keys.nonce[:], payload, aad)
	if err != nil {
		return nil, &CryptoError{Kind: CryptoErrAuthenticationFailed}
	}
	return plaintext, nil
}

// newGCM builds the AES-GCM AEAD for a key schedule.
func newGCM(keys Keys) (cipher.AEAD, error) {
	block, err := aes.NewCipher(keys.key[:])
	if err != nil {
		return nil, &CryptoError{Kind: CryptoErrSealFailed}
	}
	aead, err := cipher.NewGCMWithNonceSize(block, len(keys.nonce))
	if err != nil {
		return nil, &CryptoError{Kind: CryptoErrSealFailed}
	}
	return aead, nil
}

// GenerateEphemeralKey makes a fresh P-256 key-agreement key. A new one is
// generated for every connection and its private half is dropped as soon as the
// shared secret is derived.
func GenerateEphemeralKey() (*ecdh.PrivateKey, error) {
	return ecdh.P256().GenerateKey(rand.Reader)
}

// RawPublicKey returns the uncompressed X||Y point (64 bytes), i.e. the x963
// representation without its 0x04 prefix — exactly what TLV A1 of opcode 0x0021
// carries.
func RawPublicKey(key *ecdh.PrivateKey) []byte {
	if key == nil {
		return nil
	}
	x963 := key.PublicKey().Bytes()
	if len(x963) == 65 && x963[0] == 0x04 {
		out := make([]byte, 64)
		copy(out, x963[1:])
		return out
	}
	return append([]byte(nil), x963...)
}

// SharedSecret derives the 32-byte P-256 shared secret from the device's raw
// 64-byte point. A point that is not 64 bytes, or not a valid curve point,
// returns CryptoErrBadPublicKey rather than a substituted value.
func SharedSecret(privateKey *ecdh.PrivateKey, devicePoint []byte) ([]byte, error) {
	if privateKey == nil {
		return nil, &CryptoError{Kind: CryptoErrBadPublicKey}
	}
	if len(devicePoint) != 64 {
		return nil, &CryptoError{Kind: CryptoErrBadPublicKey, Size: len(devicePoint)}
	}
	x963 := make([]byte, 65)
	x963[0] = 0x04
	copy(x963[1:], devicePoint)
	publicKey, err := ecdh.P256().NewPublicKey(x963)
	if err != nil {
		return nil, &CryptoError{Kind: CryptoErrBadPublicKey}
	}
	secret, err := privateKey.ECDH(publicKey)
	if err != nil {
		return nil, &CryptoError{Kind: CryptoErrBadPublicKey}
	}
	return secret, nil
}
