package wire

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/rand"
	"fmt"
)

// Static negotiation material (public protocol furniture, not a secret).
var (
	negotiationKey   = []byte{0xb8, 0xff, 0x74, 0x22, 0x95, 0x5d, 0x4e, 0xb6, 0xd5, 0x54, 0xa2, 0xc4, 0x70, 0x28, 0x05, 0x59}
	negotiationNonce = []byte{0x6b, 0xa3, 0xe3, 0xf2, 0xf3, 0xa6, 0x0f, 0x29, 0x71, 0xce, 0x5d, 0x1f}
	protocolAAD      = []byte{0x33, 0x22, 0x11, 0x00, 0x77, 0x66, 0x55, 0x44, 0xbb, 0xaa, 0x99, 0x88, 0xff, 0xee, 0xdd, 0xcc}
)

// Cipher wraps an AES-128-GCM instance with the fixed A2687 AAD. The protocol
// deliberately reuses one nonce per session; GCM's nonce is fixed at
// construction.
type Cipher struct {
	aead  cipher.AEAD
	nonce []byte
}

func newCipher(key, nonce []byte) (*Cipher, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("crypto: %w", err)
	}
	gcm, err := cipher.NewGCMWithNonceSize(block, len(nonce))
	if err != nil {
		return nil, fmt.Errorf("crypto: %w", err)
	}
	return &Cipher{aead: gcm, nonce: append([]byte(nil), nonce...)}, nil
}

var (
	negotiationCipher *Cipher
	negotiationErr    error
)

func init() {
	negotiationCipher, negotiationErr = newCipher(negotiationKey, negotiationNonce)
}

// NegotiationCipher returns the process-wide static-key cipher.
func NegotiationCipher() (*Cipher, error) {
	return negotiationCipher, negotiationErr
}

// Seal encrypts plaintext, returning ciphertext||tag.
func (c *Cipher) Seal(plaintext []byte) []byte {
	out := make([]byte, 0, len(plaintext)+c.aead.Overhead())
	return c.aead.Seal(out, c.nonce, plaintext, protocolAAD)
}

// Open decrypts and authenticates a sealed payload. It is fail-closed.
func (c *Cipher) Open(sealed []byte) ([]byte, error) {
	if len(sealed) <= c.aead.Overhead() {
		return nil, ErrShortPayloadOpen
	}
	plain, err := c.aead.Open(nil, c.nonce, sealed, protocolAAD)
	if err != nil {
		return nil, ErrAuthentication
	}
	return plain, nil
}

// SessionKeys is the per-connection key schedule: first 16 bytes of the P-256
// shared secret as the AES key, bytes 16…27 as the 12-byte GCM nonce.
type SessionKeys struct {
	Key   []byte
	Nonce []byte
}

// DeriveSessionKeys splits a 32-byte P-256 shared secret into key and nonce.
func DeriveSessionKeys(secret []byte) (*SessionKeys, error) {
	if len(secret) != 32 {
		return nil, fmt.Errorf("%w: %d bytes", ErrBadSharedSecret, len(secret))
	}
	return &SessionKeys{
		Key:   append([]byte(nil), secret[:16]...),
		Nonce: append([]byte(nil), secret[16:28]...),
	}, nil
}

// Cipher builds the session cipher.
func (k *SessionKeys) Cipher() (*Cipher, error) {
	if k == nil {
		return nil, fmt.Errorf("crypto: no session keys")
	}
	return newCipher(k.Key, k.Nonce)
}

// Ephemeral is one P-256 ECDH key pair. The private key is dropped once the
// shared secret has been derived.
type Ephemeral struct {
	priv *ecdh.PrivateKey
}

// NewEphemeral generates a fresh P-256 key pair.
func NewEphemeral() (*Ephemeral, error) {
	priv, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("crypto: ephemeral key: %w", err)
	}
	return &Ephemeral{priv: priv}, nil
}

// NewEphemeralFromPrivate rebuilds an ephemeral key from a raw 32-byte P-256
// scalar (used by the simulator for a fixed per-instance key).
func NewEphemeralFromPrivate(scalar []byte) (*Ephemeral, error) {
	priv, err := ecdh.P256().NewPrivateKey(scalar)
	if err != nil {
		return nil, fmt.Errorf("crypto: private key: %w", err)
	}
	return &Ephemeral{priv: priv}, nil
}

// PublicKey64 returns the uncompressed public key without the 0x04 prefix.
func (e *Ephemeral) PublicKey64() []byte {
	if e == nil || e.priv == nil {
		return nil
	}
	full := e.priv.PublicKey().Bytes()
	return append([]byte(nil), full[1:]...)
}

// SharedSecret derives the 32-byte shared secret with the device point. The
// ephemeral private key is dropped afterwards.
func (e *Ephemeral) SharedSecret(peer64 []byte) ([]byte, error) {
	if e == nil || e.priv == nil {
		return nil, ErrBadPublicKey
	}
	if len(peer64) != 64 {
		return nil, fmt.Errorf("%w: %d bytes", ErrBadPublicKey, len(peer64))
	}
	x963 := make([]byte, 0, 65)
	x963 = append(x963, 0x04)
	x963 = append(x963, peer64...)
	pub, err := ecdh.P256().NewPublicKey(x963)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrBadPublicKey, err)
	}
	secret, err := e.priv.ECDH(pub)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrBadSharedSecret, err)
	}
	e.priv = nil // drop the private key immediately
	return secret, nil
}
