package a2687

import (
	"crypto/ecdh"
	"errors"
	"time"
)

// Encryption selects the key schedule an outgoing message must be sealed with.
type Encryption int

const (
	// EncryptionNegotiation is the firmware's static negotiation key.
	EncryptionNegotiation Encryption = iota
	// EncryptionSession is the derived per-connection session key.
	EncryptionSession
)

// String implements fmt.Stringer.
func (e Encryption) String() string {
	if e == EncryptionSession {
		return "session"
	}
	return "negotiation"
}

// OutgoingMessage is a message the handshake or the command layer wants sent,
// still in plaintext. The link layer seals it and builds the frame.
type OutgoingMessage struct {
	Group           byte
	Opcode          uint16
	Plaintext       []byte
	Encryption      Encryption
	ExpectsResponse bool
}

// Stage is one rung of the negotiation ladder. Each stage names the response it
// waits for, so StageSharedSecretDerived deliberately does not mean the session
// is usable: AES metadata and user auth still have to complete.
type Stage int

const (
	StageIdle Stage = iota
	StageInitialConnect
	StageCapability
	StageBaseInfo
	StageSetCapability
	StagePublicKeyExchange
	StageSharedSecretDerived
	StageAESMetadata
	StageUserAuth
	StageSessionReady
)

// AwaitedOpcode returns the logical opcode whose response advances this stage.
func (s Stage) AwaitedOpcode() (uint16, bool) {
	switch s {
	case StageInitialConnect:
		return OpcodeInitialConnect, true
	case StageCapability:
		return OpcodeCapability, true
	case StageBaseInfo:
		return OpcodeBaseInfo, true
	case StageSetCapability:
		return OpcodeSetCapability, true
	case StagePublicKeyExchange:
		return OpcodePublicKey, true
	case StageAESMetadata:
		return OpcodeAESMetadata, true
	case StageUserAuth:
		return OpcodeUserAuth, true
	default:
		return 0, false
	}
}

// IsTerminal reports whether the ladder has completed.
func (s Stage) IsTerminal() bool { return s == StageSessionReady }

// String implements fmt.Stringer.
func (s Stage) String() string {
	switch s {
	case StageIdle:
		return "idle"
	case StageInitialConnect:
		return "initialConnect"
	case StageCapability:
		return "capability"
	case StageBaseInfo:
		return "baseInfo"
	case StageSetCapability:
		return "setCapability"
	case StagePublicKeyExchange:
		return "publicKeyExchange"
	case StageSharedSecretDerived:
		return "sharedSecretDerived"
	case StageAESMetadata:
		return "aesMetadata"
	case StageUserAuth:
		return "userAuth"
	case StageSessionReady:
		return "sessionReady"
	default:
		return "unknown"
	}
}

// HandshakeErrorKind discriminates HandshakeError.
type HandshakeErrorKind int

const (
	HandshakeErrNotStarted HandshakeErrorKind = iota + 1
	HandshakeErrDeviceRejected
	HandshakeErrMissingField
	HandshakeErrCrypto
	HandshakeErrUnexpectedStage
)

// HandshakeError is a ladder failure. DeviceRejected carries the status byte the
// device returned for that rung; Crypto wraps a *CryptoError.
type HandshakeError struct {
	Kind   HandshakeErrorKind
	Stage  Stage
	Status byte
	Field  byte
	Err    error
}

// Error implements error. Messages are short and stable.
func (e *HandshakeError) Error() string {
	switch e.Kind {
	case HandshakeErrNotStarted:
		return "handshake: not started"
	case HandshakeErrDeviceRejected:
		return "handshake: device rejected " + e.Stage.String() + " with status 0x" + hexByte(e.Status)
	case HandshakeErrMissingField:
		return "handshake: missing field 0x" + hexByte(e.Field) + " at " + e.Stage.String()
	case HandshakeErrCrypto:
		if e.Err != nil {
			return "handshake: crypto: " + e.Err.Error()
		}
		return "handshake: crypto failure"
	case HandshakeErrUnexpectedStage:
		return "handshake: unexpected stage " + e.Stage.String()
	default:
		return "handshake: failure"
	}
}

// Unwrap exposes the wrapped crypto error, if any.
func (e *HandshakeError) Unwrap() error { return e.Err }

// HandshakeConfig configures a ladder run.
type HandshakeConfig struct {
	// ClientID is 40 lowercase hex chars, generated once per install. A UUID
	// string is refused by the device with status 0x09.
	ClientID string
	// TimeZoneRule is a POSIX TZ rule such as "CST-8" (sign inverted vs UTC).
	TimeZoneRule string
	// CountryCode is the uppercase region sent in 0x020A A2.
	CountryCode string
	// OwnerUserID is the Anker account id that owns the charger, optional.
	// Hardened firmware returns 0x09 for userAuth and then ignores session
	// commands unless A2 carries the owning account. The client ID is the
	// fallback for older firmware.
	OwnerUserID string
	// Now overrides the clock for tests. Nil means time.Now.
	Now func() time.Time
}

func (c HandshakeConfig) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

// Engine is the pure negotiation state machine. It owns no I/O and no timers: it
// consumes decrypted responses and produces the next plaintext messages.
type Engine struct {
	cfg HandshakeConfig

	stage            Stage
	deviceInfo       DeviceInfo
	sessionKeys      *Keys
	negotiatedMTU    uint16
	authMethod       byte
	encryptionMethod byte
	privateKey       *ecdh.PrivateKey
}

// NewEngine builds an idle engine.
func NewEngine(cfg HandshakeConfig) *Engine {
	return &Engine{
		cfg:              cfg,
		stage:            StageIdle,
		negotiatedMTU:    0x0129,
		authMethod:       0x44,
		encryptionMethod: 0x02,
	}
}

// Stage is the current ladder stage.
func (e *Engine) Stage() Stage { return e.stage }

// DeviceInfo is the identity recovered from 0x0029 (zero value before that).
func (e *Engine) DeviceInfo() DeviceInfo { return e.deviceInfo }

// SessionKeys returns the derived session key schedule once the ECDH exchange
// has landed.
func (e *Engine) SessionKeys() (Keys, bool) {
	if e.sessionKeys == nil {
		return Keys{}, false
	}
	return *e.sessionKeys, true
}

// NegotiatedMTU is the MTU the device asked for in its capability response
// (297 by default).
func (e *Engine) NegotiatedMTU() uint16 { return e.negotiatedMTU }

// AuthMethod is the auth-method byte from the capability response (0x44).
func (e *Engine) AuthMethod() byte { return e.authMethod }

// EncryptionMethod is the encryption-method byte from the capability response
// (0x02).
func (e *Engine) EncryptionMethod() byte { return e.encryptionMethod }

// Start begins the ladder and returns the 0x0001 initial-connect message.
func (e *Engine) Start() OutgoingMessage {
	e.stage = StageInitialConnect
	key, err := GenerateEphemeralKey()
	if err != nil {
		// crypto/rand failing is unrecoverable; keep the ladder in a state where
		// the next Handle reports the missing key instead of panicking.
		key = nil
	}
	e.privateKey = key
	return e.negotiation(OpcodeInitialConnect, []TLV{
		NewTLV(FieldA1, e.timestamp()),
	})
}

// timestamp is epoch seconds as a little-endian uint32, the protocol's replay
// guard.
func (e *Engine) timestamp() []byte {
	seconds := uint32(e.cfg.now().Unix())
	return []byte{byte(seconds), byte(seconds >> 8), byte(seconds >> 16), byte(seconds >> 24)}
}

// negotiation builds a negotiation-group message, sealed with the session key
// once the shared secret has been derived.
func (e *Engine) negotiation(opcode uint16, fields []TLV) OutgoingMessage {
	encryption := EncryptionNegotiation
	if e.stage >= StageSharedSecretDerived {
		encryption = EncryptionSession
	}
	return OutgoingMessage{
		Group:           GroupNegotiation,
		Opcode:          opcode,
		Plaintext:       EncodeTLVs(fields),
		Encryption:      encryption,
		ExpectsResponse: true,
	}
}

// userAuthMessage builds 0x0027. Hardened firmware only arms telemetry when A2
// carries the account that owns the charger, so the local pseudonymous client ID
// is only a fallback for older firmware.
func (e *Engine) userAuthMessage() OutgoingMessage {
	identity := e.cfg.OwnerUserID
	if identity == "" {
		identity = e.cfg.ClientID
	}
	return e.negotiation(OpcodeUserAuth, []TLV{
		NewTLV(FieldA1, e.timestamp()),
		NewTLV(FieldA2, []byte(identity)),
	})
}

// Handle feeds one decrypted device response in. Frames that do not belong to
// the awaited stage — asynchronous reports, duplicates — return no messages
// instead of derailing the ladder.
func (e *Engine) Handle(opcode uint16, payload Payload) ([]OutgoingMessage, error) {
	if e.stage == StageIdle {
		return nil, &HandshakeError{Kind: HandshakeErrNotStarted, Stage: e.stage}
	}
	awaited, ok := e.stage.AwaitedOpcode()
	if !ok || awaited != opcode {
		return nil, nil
	}
	if !payload.IsOK() {
		status, _ := payload.StatusCode()
		return nil, &HandshakeError{Kind: HandshakeErrDeviceRejected, Stage: e.stage, Status: status}
	}

	switch e.stage {
	case StageInitialConnect:
		e.stage = StageCapability
		return []OutgoingMessage{e.negotiation(OpcodeCapability, []TLV{
			NewTLV(FieldA1, e.timestamp()),
			NewTLV(FieldA3, []byte{0x20}),
			NewTLV(FieldA4, []byte{0x00, 0xF0}),
		})}, nil

	case StageCapability:
		if mtu, ok := payload.Field(FieldA2); ok && len(mtu) >= 2 {
			e.negotiatedMTU = uint16(mtu[0]) | uint16(mtu[1])<<8
		}
		if auth, ok := payload.Field(FieldA3); ok && len(auth) >= 1 {
			e.authMethod = auth[0]
		}
		if enc, ok := payload.Field(FieldA5); ok && len(enc) >= 1 {
			e.encryptionMethod = enc[0]
		}
		e.stage = StageBaseInfo
		return []OutgoingMessage{e.negotiation(OpcodeBaseInfo, []TLV{
			NewTLV(FieldA1, e.timestamp()),
		})}, nil

	case StageBaseInfo:
		e.deviceInfo = DecodeDeviceInfo(payload)
		e.stage = StageSetCapability
		return []OutgoingMessage{e.negotiation(OpcodeSetCapability, []TLV{
			NewTLV(FieldA1, e.timestamp()),
			NewTLV(FieldA3, []byte{0x20}),
			NewTLV(FieldA4, []byte{byte(e.negotiatedMTU), byte(e.negotiatedMTU >> 8)}),
			NewTLV(FieldA5, []byte{e.authMethod}),
			NewTLV(FieldA6, []byte{e.encryptionMethod}),
		})}, nil

	case StageSetCapability:
		if e.privateKey == nil {
			return nil, &HandshakeError{Kind: HandshakeErrNotStarted, Stage: e.stage}
		}
		e.stage = StagePublicKeyExchange
		return []OutgoingMessage{e.negotiation(OpcodePublicKey, []TLV{
			NewTLV(FieldA1, RawPublicKey(e.privateKey)),
		})}, nil

	case StagePublicKeyExchange:
		if e.privateKey == nil {
			return nil, &HandshakeError{Kind: HandshakeErrNotStarted, Stage: e.stage}
		}
		point, ok := payload.Field(FieldA1)
		if !ok || len(point) != 64 {
			return nil, &HandshakeError{Kind: HandshakeErrMissingField, Stage: e.stage, Field: FieldA1}
		}
		secret, err := SharedSecret(e.privateKey, point)
		if err != nil {
			return nil, wrapHandshakeCrypto(e.stage, err)
		}
		keys, err := NewKeysFromSecret(secret)
		if err != nil {
			return nil, wrapHandshakeCrypto(e.stage, err)
		}
		e.sessionKeys = &keys
		// The ephemeral private key has done its job; drop it immediately.
		e.privateKey = nil
		e.stage = StageAESMetadata
		return []OutgoingMessage{e.negotiation(OpcodeAESMetadata, []TLV{
			NewTLV(FieldA1, e.timestamp()),
			NewTLV(FieldA3, aesMetadataCapability),
			NewTLV(FieldA5, []byte(e.cfg.TimeZoneRule)),
		})}, nil

	case StageAESMetadata:
		e.stage = StageUserAuth
		return []OutgoingMessage{e.userAuthMessage()}, nil

	case StageUserAuth:
		e.stage = StageSessionReady
		return e.sessionOpeningMessages(), nil

	default:
		return nil, &HandshakeError{Kind: HandshakeErrUnexpectedStage, Stage: e.stage}
	}
}

func wrapHandshakeCrypto(stage Stage, err error) error {
	var cryptoErr *CryptoError
	if errors.As(err, &cryptoErr) {
		return &HandshakeError{Kind: HandshakeErrCrypto, Stage: stage, Err: cryptoErr}
	}
	return &HandshakeError{Kind: HandshakeErrCrypto, Stage: stage, Err: err}
}

// aesMetadataCapability is the capability bitmap the official 0x0022 generator
// sends. All-zero is accepted but is not what firmware expects.
var aesMetadataCapability = []byte{0x80, 0x8F, 0xFF, 0xFF}

// CanSkipCurrentStage reports whether the session layer may nudge the ladder
// once a stage times out. 0x0022 and 0x0027 do not always ACK on some firmware;
// every other stage stays strictly blocking.
func (e *Engine) CanSkipCurrentStage() bool {
	return e.stage == StageAESMetadata || e.stage == StageUserAuth
}

// SkipCurrentStage advances past a stage whose response may never come, and
// returns the messages the next stage wants sent.
func (e *Engine) SkipCurrentStage() ([]OutgoingMessage, error) {
	switch e.stage {
	case StageAESMetadata:
		e.stage = StageUserAuth
		return []OutgoingMessage{e.userAuthMessage()}, nil
	case StageUserAuth:
		e.stage = StageSessionReady
		return e.sessionOpeningMessages(), nil
	default:
		return nil, &HandshakeError{Kind: HandshakeErrUnexpectedStage, Stage: e.stage}
	}
}

// sessionOpeningMessages is the burst sent once the session opens: read the full
// state, announce the bind, then arm the stream. The trigger is the step that
// actually makes a hardened unit report; the first two alone leave it silent.
func (e *Engine) sessionOpeningMessages() []OutgoingMessage {
	now := e.cfg.now()
	return []OutgoingMessage{
		ReadAll(now),
		RealtimeProbe(e.cfg.CountryCode, e.cfg.OwnerUserID, now),
		RealtimeTrigger(now),
	}
}

// Handshake drives the pure Engine at the frame level: it encodes and seals the
// messages the engine produces and decrypts the device's response frames. The
// caller owns the transport, the timers and the retry policy.
//
// Driving loop:
//
//	h := a2687.NewHandshake(cfg)
//	for {
//	    frame, done, err := h.Next()
//	    if err != nil { return err }
//	    if done { break }
//	    if frame != nil { transport.Write(ctx, frame); continue }
//	    // frame == nil: waiting for a response to the frame just sent
//	    ev := <-events
//	    for _, f := range reassembler.Append(ev.Data) { h.HandleResponse(f) }
//	}
type Handshake struct {
	engine *Engine
	queue  []OutgoingMessage
}

// NewHandshake starts a ladder and queues the 0x0001 initial-connect message.
func NewHandshake(cfg HandshakeConfig) *Handshake {
	engine := NewEngine(cfg)
	queue := []OutgoingMessage{engine.Start()}
	return &Handshake{engine: engine, queue: queue}
}

// Stage is the current ladder stage.
func (h *Handshake) Stage() Stage { return h.engine.Stage() }

// Engine exposes the underlying pure state machine (for device info, MTU and
// diagnostics after the ladder completes).
func (h *Handshake) Engine() *Engine { return h.engine }

// Next returns the next encoded frame to write.
//
//   - (frame, false, nil): write frame now.
//   - (nil, false, nil): nothing to send; waiting for the device's response.
//   - (nil, true, nil): the ladder is complete and the opening burst was drained.
func (h *Handshake) Next() (frame []byte, done bool, err error) {
	if len(h.queue) == 0 {
		return nil, h.engine.Stage() == StageSessionReady, nil
	}
	message := h.queue[0]
	h.queue = h.queue[1:]
	keys := NegotiationKeys()
	if message.Encryption == EncryptionSession {
		sessionKeys, ok := h.engine.SessionKeys()
		if !ok {
			return nil, false, &HandshakeError{Kind: HandshakeErrNotStarted, Stage: h.engine.Stage()}
		}
		keys = sessionKeys
	}
	sealed, err := Seal(message.Plaintext, keys)
	if err != nil {
		return nil, false, err
	}
	return EncodePacket(NewCommandFrame(message.Group, message.Opcode, true, false, sealed)), false, nil
}

// HandleResponse feeds one complete notification frame to the ladder.
//
// Non-response frames are ignored (before sessionReady the ladder only consumes
// responses), as are responses whose opcode does not match the awaited stage.
// Decryption failures are returned: the caller owns the failure budget.
func (h *Handshake) HandleResponse(frame []byte) error {
	decoded, err := DecodePacket(frame)
	if err != nil {
		return err
	}
	if !decoded.IsResponse() {
		return nil
	}
	plaintext := decoded.Payload
	if decoded.IsEncrypted() {
		keys, fallback, ok := h.decryptKeys()
		if !ok {
			return &HandshakeError{Kind: HandshakeErrNotStarted, Stage: h.engine.Stage()}
		}
		opened, openErr := Open(decoded.Payload, keys)
		if openErr != nil && fallback != nil {
			opened, openErr = Open(decoded.Payload, *fallback)
		}
		if openErr != nil {
			return openErr
		}
		plaintext = opened
	}
	payload, err := ParsePayload(plaintext)
	if err != nil {
		return err
	}
	if h.engine.Stage() == StageSessionReady {
		return nil
	}
	messages, err := h.engine.Handle(decoded.Opcode(), payload)
	if err != nil {
		return err
	}
	h.queue = append(h.queue, messages...)
	return nil
}

// decryptKeys mirrors the session's key choice: after the public-key exchange
// the session key is primary and the negotiation key is the fallback; before it
// the reverse.
func (h *Handshake) decryptKeys() (Keys, *Keys, bool) {
	sessionKeys, hasSession := h.engine.SessionKeys()
	negotiation := NegotiationKeys()
	if h.engine.Stage() > StagePublicKeyExchange && hasSession {
		return sessionKeys, &negotiation, true
	}
	if hasSession {
		return negotiation, &sessionKeys, true
	}
	return negotiation, nil, true
}

// CanSkipCurrentStage reports whether Skip is allowed.
func (h *Handshake) CanSkipCurrentStage() bool { return h.engine.CanSkipCurrentStage() }

// SkipCurrentStage nudges the ladder past a stage that may never ACK and queues
// the next stage's messages.
func (h *Handshake) SkipCurrentStage() error {
	messages, err := h.engine.SkipCurrentStage()
	if err != nil {
		return err
	}
	h.queue = append(h.queue, messages...)
	return nil
}

// hexByte formats a byte as two uppercase hex digits without fmt in the hot path.
func hexByte(b byte) string {
	const digits = "0123456789ABCDEF"
	return string([]byte{digits[b>>4], digits[b&0x0F]})
}
