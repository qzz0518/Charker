package a2687

import (
	"errors"
	"reflect"
	"testing"
)

// testHandshakeConfig is the engine configuration of the handshake capture,
// with the clock pinned to the capture's epoch so emitted frames are
// byte-identical to the fixtures.
func testHandshakeConfig() HandshakeConfig {
	return HandshakeConfig{
		ClientID:     "79ebed35-dc9c-4904-b40c-72c4e863aa10",
		TimeZoneRule: "CST-8",
		CountryCode:  "CN",
		Now:          handshakeEpoch,
	}
}

func handshakeErrKind(tb testing.TB, err error) HandshakeErrorKind {
	tb.Helper()
	var handshakeErr *HandshakeError
	if !errors.As(err, &handshakeErr) {
		tb.Fatalf("expected *HandshakeError, got %v", err)
	}
	return handshakeErr.Kind
}

func mustPayload(tb testing.TB, hexData string) Payload {
	tb.Helper()
	payload, err := ParsePayload(mustHex(tb, hexData))
	if err != nil {
		tb.Fatalf("ParsePayload: %v", err)
	}
	return payload
}

// walkToPublicKeyExchange drives a fresh engine up to the rung that awaits the
// device's set-capability ACK (whose response yields the 0x0021 public-key
// message).
func walkToPublicKeyExchange(t *testing.T) *Engine {
	t.Helper()
	return walkToPublicKeyExchangeWith(t, testHandshakeConfig())
}

// H1/H2/H3/H4: the recorded device responses walk the ladder and produce the
// recorded client plaintexts.
func TestLadderWalksTheRecordedDeviceResponses(t *testing.T) {
	var engine = NewEngine(testHandshakeConfig())

	// H1
	first := engine.Start()
	if first.Opcode != OpcodeInitialConnect {
		t.Errorf("first opcode = 0x%04X", first.Opcode)
	}
	if first.Encryption != EncryptionNegotiation {
		t.Errorf("first encryption = %v", first.Encryption)
	}
	if engine.Stage() != StageInitialConnect {
		t.Errorf("stage = %v", engine.Stage())
	}
	if got := hexStr(first.Plaintext); got != fxPlainClientInitialConnect {
		t.Errorf("initial-connect plaintext = %s, want %s", got, fxPlainClientInitialConnect)
	}

	// H2
	next, err := engine.Handle(OpcodeInitialConnect, mustPayload(t, fxPlainDeviceInitialConnect))
	if err != nil {
		t.Fatalf("handle initialConnect: %v", err)
	}
	if got := opcodesOf(next); !reflect.DeepEqual(got, []uint16{OpcodeCapability}) {
		t.Errorf("opcodes = %v", got)
	}
	if engine.Stage() != StageCapability {
		t.Errorf("stage = %v", engine.Stage())
	}
	if got := hexStr(next[0].Plaintext); got != fxPlainClientCapability {
		t.Errorf("capability plaintext = %s, want %s", got, fxPlainClientCapability)
	}

	// H3
	next, err = engine.Handle(OpcodeCapability, mustPayload(t, fxPlainDeviceCapability))
	if err != nil {
		t.Fatalf("handle capability: %v", err)
	}
	if engine.NegotiatedMTU() != 297 {
		t.Errorf("MTU = %d, want 297", engine.NegotiatedMTU())
	}
	if engine.AuthMethod() != 0x44 {
		t.Errorf("auth = 0x%02X, want 0x44", engine.AuthMethod())
	}
	if engine.EncryptionMethod() != 0x02 {
		t.Errorf("enc = 0x%02X, want 0x02", engine.EncryptionMethod())
	}
	// The base-info request carries only the timestamp, so its plaintext is the
	// same four-byte A1 record as the initial connect.
	if got := hexStr(next[0].Plaintext); got != fxPlainClientInitialConnect {
		t.Errorf("base-info plaintext = %s, want %s", got, fxPlainClientInitialConnect)
	}

	// H4
	next, err = engine.Handle(OpcodeBaseInfo, mustPayload(t, fxPlainDeviceBaseInfo))
	if err != nil {
		t.Fatalf("handle baseInfo: %v", err)
	}
	info := engine.DeviceInfo()
	if info.ProductName != "Charging" {
		t.Errorf("product = %q", info.ProductName)
	}
	if info.FirmwareVersion != "v0.0.5.0" {
		t.Errorf("firmware = %q", info.FirmwareVersion)
	}
	// These two come from the upstream MIT capture and belong to that project
	// author's charger; the decoder is being checked against exact real bytes.
	if info.SerialNumber != "ASHDK7U1F51501771" {
		t.Errorf("serial = %q", info.SerialNumber)
	}
	if info.MACAddress != "7C:E9:13:81:46:02" {
		t.Errorf("MAC = %q", info.MACAddress)
	}
	setCapability := next[0]
	if setCapability.Opcode != OpcodeSetCapability {
		t.Fatalf("opcode = 0x%04X", setCapability.Opcode)
	}
	fields := mustPayload(t, hexStr(setCapability.Plaintext))
	for id, want := range map[byte][]byte{
		FieldA4: {0x29, 0x01},
		FieldA5: {0x44},
		FieldA6: {0x02},
	} {
		if got, ok := fields.Field(id); !ok || !reflect.DeepEqual(got, want) {
			t.Errorf("setCapability field 0x%02X = %v/%v, want %v", id, got, ok, want)
		}
	}
}

// H5/H6/H7/H8/H9: the public-key rung derives the session key and the rest of
// the ladder switches key schedules.
func TestPublicKeyExchangeDerivesSessionKeys(t *testing.T) {
	engine := walkToPublicKeyExchange(t)
	next, err := engine.Handle(OpcodeSetCapability, mustPayload(t, fxPlainDeviceSetCapability))
	if err != nil {
		t.Fatalf("handle setCapability: %v", err)
	}
	if engine.Stage() != StagePublicKeyExchange {
		t.Errorf("stage = %v", engine.Stage())
	}
	publicKeyMessage := next[0]
	if publicKeyMessage.Opcode != OpcodePublicKey {
		t.Errorf("opcode = 0x%04X", publicKeyMessage.Opcode)
	}
	if publicKeyMessage.Encryption != EncryptionNegotiation {
		t.Errorf("encryption = %v, want negotiation", publicKeyMessage.Encryption)
	}
	if _, ok := engine.SessionKeys(); ok {
		t.Error("session keys must not exist before the device point arrives")
	}
	payload := mustPayload(t, hexStr(publicKeyMessage.Plaintext))
	if point, ok := payload.Field(FieldA1); !ok || len(point) != 64 {
		t.Errorf("client point = %d bytes/%v, want 64", len(point), ok)
	}

	// H6
	next, err = engine.Handle(OpcodePublicKey, mustPayload(t, fxPlainDevicePublicKey))
	if err != nil {
		t.Fatalf("handle publicKey: %v", err)
	}
	if _, ok := engine.SessionKeys(); !ok {
		t.Fatal("session keys were not derived")
	}
	if engine.Stage() != StageAESMetadata {
		t.Errorf("stage = %v", engine.Stage())
	}
	metadata := next[0]
	if metadata.Opcode != OpcodeAESMetadata {
		t.Errorf("opcode = 0x%04X", metadata.Opcode)
	}
	if metadata.Encryption != EncryptionSession {
		t.Errorf("metadata encryption = %v, want session", metadata.Encryption)
	}
	fields := mustPayload(t, hexStr(metadata.Plaintext))
	if a1, ok := fields.Field(FieldA1); !ok || len(a1) != 4 {
		t.Errorf("metadata A1 = %x/%v, want 4-byte timestamp", a1, ok)
	}
	if a3, ok := fields.Field(FieldA3); !ok || !reflect.DeepEqual(a3, []byte{0x80, 0x8F, 0xFF, 0xFF}) {
		t.Errorf("metadata A3 = %x/%v, want 80 8F FF FF", a3, ok)
	}
	if a5, ok := fields.Field(FieldA5); !ok || string(a5) != "CST-8" {
		t.Errorf("metadata A5 = %q/%v, want CST-8", a5, ok)
	}

	// H9: the derived key alone is not session-ready.
	if engine.Stage() >= StageSessionReady {
		t.Fatalf("stage = %v, must be below sessionReady", engine.Stage())
	}

	// H7
	next, err = engine.Handle(OpcodeAESMetadata, mustPayload(t, "00"))
	if err != nil {
		t.Fatalf("handle aesMetadata: %v", err)
	}
	if got := opcodesOf(next); !reflect.DeepEqual(got, []uint16{OpcodeUserAuth}) {
		t.Errorf("opcodes = %v", got)
	}

	// H8
	next, err = engine.Handle(OpcodeUserAuth, mustPayload(t, "00"))
	if err != nil {
		t.Fatalf("handle userAuth: %v", err)
	}
	if engine.Stage() != StageSessionReady {
		t.Errorf("stage = %v", engine.Stage())
	}
	wantOpcodes := []uint16{OpcodeReadAll, OpcodeBindSuccess, OpcodeRealtimeTrigger}
	if got := opcodesOf(next); !reflect.DeepEqual(got, wantOpcodes) {
		t.Errorf("opening burst = %v, want %v", got, wantOpcodes)
	}
	for _, message := range next {
		if message.Group != GroupSession {
			t.Errorf("opcode 0x%04X group = 0x%02X, want 0x0F", message.Opcode, message.Group)
		}
		if message.Encryption != EncryptionSession {
			t.Errorf("opcode 0x%04X encryption = %v", message.Opcode, message.Encryption)
		}
	}
	// With no account id configured the bind getter carries no identity.
	bind := mustPayload(t, hexStr(next[1].Plaintext))
	if _, ok := bind.Field(FieldA3); ok {
		t.Error("bind must not carry an identity when none is configured")
	}
}

// H10: out-of-order and asynchronous frames are ignored, not errors.
func TestOutOfOrderAndAsynchronousFramesAreIgnored(t *testing.T) {
	engine := NewEngine(testHandshakeConfig())
	engine.Start()
	for _, opcode := range []uint16{OpcodeRealtimeReport, OpcodeUserAuth, OpcodeReadAll} {
		messages, err := engine.Handle(opcode, mustPayload(t, "00"))
		if err != nil {
			t.Fatalf("handle 0x%04X: %v", opcode, err)
		}
		if len(messages) != 0 {
			t.Errorf("handle 0x%04X produced messages", opcode)
		}
	}
	if engine.Stage() != StageInitialConnect {
		t.Errorf("stage = %v, want initialConnect", engine.Stage())
	}
}

// H11: a rejection stops the ladder and names the rung.
func TestRejectionStopsTheLadder(t *testing.T) {
	engine := NewEngine(testHandshakeConfig())
	engine.Start()
	status := byte(3)
	_, err := engine.Handle(OpcodeInitialConnect, NewPayload(&status, nil))
	if err == nil {
		t.Fatal("expected an error")
	}
	if kind := handshakeErrKind(t, err); kind != HandshakeErrDeviceRejected {
		t.Errorf("kind = %v", kind)
	}
	var handshakeErr *HandshakeError
	if errors.As(err, &handshakeErr) {
		if handshakeErr.Stage != StageInitialConnect || handshakeErr.Status != 3 {
			t.Errorf("error = %+v, want initialConnect/3", handshakeErr)
		}
	}
}

// H12: only the two flaky stages may be skipped, and skipping advances them.
func TestOnlyTheKnownFlakyStagesMayBeSkipped(t *testing.T) {
	engine := NewEngine(testHandshakeConfig())
	engine.Start()
	if engine.CanSkipCurrentStage() {
		t.Error("initialConnect must not be skippable")
	}
	if _, err := engine.SkipCurrentStage(); err == nil {
		t.Error("skipping initialConnect must fail")
	}

	engine = walkToPublicKeyExchange(t)
	if _, err := engine.Handle(OpcodeSetCapability, mustPayload(t, fxPlainDeviceSetCapability)); err != nil {
		t.Fatalf("handle setCapability: %v", err)
	}
	// H6 to reach aesMetadata without going through its response.
	if _, err := engine.Handle(OpcodePublicKey, mustPayload(t, fxPlainDevicePublicKey)); err != nil {
		t.Fatalf("handle publicKey: %v", err)
	}
	if !engine.CanSkipCurrentStage() {
		t.Fatal("aesMetadata must be skippable")
	}
	messages, err := engine.SkipCurrentStage()
	if err != nil {
		t.Fatalf("skip aesMetadata: %v", err)
	}
	if got := opcodesOf(messages); !reflect.DeepEqual(got, []uint16{OpcodeUserAuth}) {
		t.Errorf("skip messages = %v", got)
	}
	messages, err = engine.SkipCurrentStage()
	if err != nil {
		t.Fatalf("skip userAuth: %v", err)
	}
	if got := opcodesOf(messages); !reflect.DeepEqual(got, []uint16{OpcodeReadAll, OpcodeBindSuccess, OpcodeRealtimeTrigger}) {
		t.Errorf("skip messages = %v", got)
	}
	if engine.Stage() != StageSessionReady {
		t.Errorf("stage = %v", engine.Stage())
	}
	if engine.CanSkipCurrentStage() {
		t.Error("sessionReady must not be skippable")
	}
}

// H13: handling before start is refused.
func TestHandlingBeforeStartIsRefused(t *testing.T) {
	engine := NewEngine(testHandshakeConfig())
	status := byte(0)
	_, err := engine.Handle(OpcodeInitialConnect, NewPayload(&status, nil))
	if err == nil {
		t.Fatal("expected an error")
	}
	if kind := handshakeErrKind(t, err); kind != HandshakeErrNotStarted {
		t.Errorf("kind = %v", kind)
	}
}

// H14: the owner account id replaces the client id in userAuth, and the bind
// probe carries it as a typed byte block.
func TestOwnerUserIDCase(t *testing.T) {
	cfg := testHandshakeConfig()
	cfg.OwnerUserID = "0123456789abcdef0123456789abcdef01234567"
	engine := walkToPublicKeyExchangeWith(t, cfg)
	if _, err := engine.Handle(OpcodeSetCapability, mustPayload(t, fxPlainDeviceSetCapability)); err != nil {
		t.Fatalf("handle setCapability: %v", err)
	}
	if _, err := engine.Handle(OpcodePublicKey, mustPayload(t, fxPlainDevicePublicKey)); err != nil {
		t.Fatalf("handle publicKey: %v", err)
	}
	next, err := engine.Handle(OpcodeAESMetadata, mustPayload(t, "00"))
	if err != nil {
		t.Fatalf("handle aesMetadata: %v", err)
	}
	userAuth := mustPayload(t, hexStr(next[0].Plaintext))
	a2, ok := userAuth.Field(FieldA2)
	if !ok || string(a2) != cfg.OwnerUserID {
		t.Errorf("userAuth A2 = %q/%v, want the owner id", a2, ok)
	}
	if len(a2) != 40 {
		t.Errorf("userAuth A2 length = %d, want 40", len(a2))
	}
	next, err = engine.Handle(OpcodeUserAuth, mustPayload(t, "00"))
	if err != nil {
		t.Fatalf("handle userAuth: %v", err)
	}
	bind := mustPayload(t, hexStr(next[1].Plaintext))
	a3, ok := bind.Field(FieldA3)
	if !ok {
		t.Fatal("bind A3 missing")
	}
	if want := BytesValue([]byte(cfg.OwnerUserID)).Encoded(); !reflect.DeepEqual(a3, want) {
		t.Errorf("bind A3 = %x, want %x", a3, want)
	}
}

// walkToPublicKeyExchangeWith is walkToPublicKeyExchange with a custom config.
// It stops at the stage that awaits the set-capability ACK.
func walkToPublicKeyExchangeWith(t *testing.T, cfg HandshakeConfig) *Engine {
	t.Helper()
	engine := NewEngine(cfg)
	engine.Start()
	steps := []struct {
		opcode uint16
		plain  string
	}{
		{OpcodeInitialConnect, fxPlainDeviceInitialConnect},
		{OpcodeCapability, fxPlainDeviceCapability},
		{OpcodeBaseInfo, fxPlainDeviceBaseInfo},
	}
	for _, step := range steps {
		if _, err := engine.Handle(step.opcode, mustPayload(t, step.plain)); err != nil {
			t.Fatalf("handle 0x%04X: %v", step.opcode, err)
		}
	}
	return engine
}

func opcodesOf(messages []OutgoingMessage) []uint16 {
	out := make([]uint16, 0, len(messages))
	for _, message := range messages {
		out = append(out, message.Opcode)
	}
	return out
}

// The frame-level adapter must drive the same ladder end to end, producing the
// captured client frames byte for byte and decrypting the device responses.
func TestHandshakeAdapterWalksTheRecordedResponses(t *testing.T) {
	h := NewHandshake(testHandshakeConfig())

	frame, done, err := h.Next()
	if err != nil || done {
		t.Fatalf("Next = %v/%v/%v", frame, done, err)
	}
	if got := hexStr(frame); got != fxClientInitialConnect {
		t.Fatalf("initial frame = %s, want %s", got, fxClientInitialConnect)
	}
	if frame, done, err = h.Next(); err != nil || done || frame != nil {
		t.Fatalf("waiting Next = %v/%v/%v, want nil/false/nil", frame, done, err)
	}

	// H1-H4 responses.
	if err := h.HandleResponse(negotiationResponseFrame(t, OpcodeInitialConnect, mustHex(t, fxPlainDeviceInitialConnect), NegotiationKeys())); err != nil {
		t.Fatalf("handle initialConnect: %v", err)
	}
	frame, _, err = h.Next()
	if err != nil {
		t.Fatalf("Next: %v", err)
	}
	if got := hexStr(frame); got != fxClientCapability {
		t.Fatalf("capability frame = %s, want %s", got, fxClientCapability)
	}

	if err := h.HandleResponse(negotiationResponseFrame(t, OpcodeCapability, mustHex(t, fxPlainDeviceCapability), NegotiationKeys())); err != nil {
		t.Fatalf("handle capability: %v", err)
	}
	frame, _, err = h.Next()
	if err != nil {
		t.Fatalf("Next: %v", err)
	}
	if got := hexStr(frame); got != fxClientBaseInfo {
		t.Fatalf("base-info frame = %s, want %s", got, fxClientBaseInfo)
	}

	if err := h.HandleResponse(negotiationResponseFrame(t, OpcodeBaseInfo, mustHex(t, fxPlainDeviceBaseInfo), NegotiationKeys())); err != nil {
		t.Fatalf("handle baseInfo: %v", err)
	}
	frame, _, err = h.Next()
	if err != nil {
		t.Fatalf("Next: %v", err)
	}
	setCapability := mustDecodedFrame(t, frame)
	if setCapability.Opcode() != OpcodeSetCapability {
		t.Fatalf("opcode = 0x%04X", setCapability.Opcode())
	}
	plain, err := Open(setCapability.Payload, NegotiationKeys())
	if err != nil {
		t.Fatalf("open setCapability: %v", err)
	}
	fields := mustPayload(t, hexStr(plain))
	if mtu, ok := fields.Field(FieldA4); !ok || !reflect.DeepEqual(mtu, []byte{0x29, 0x01}) {
		t.Errorf("setCapability MTU = %x/%v", mtu, ok)
	}

	if err := h.HandleResponse(negotiationResponseFrame(t, OpcodeSetCapability, mustHex(t, fxPlainDeviceSetCapability), NegotiationKeys())); err != nil {
		t.Fatalf("handle setCapability: %v", err)
	}
	frame, _, err = h.Next()
	if err != nil {
		t.Fatalf("Next: %v", err)
	}
	publicKey := mustDecodedFrame(t, frame)
	if publicKey.Opcode() != OpcodePublicKey || !publicKey.IsEncrypted() {
		t.Fatalf("public key frame = %+v", publicKey)
	}
	plain, err = Open(publicKey.Payload, NegotiationKeys())
	if err != nil {
		t.Fatalf("open publicKey: %v", err)
	}
	if point, ok := mustPayload(t, hexStr(plain)).Field(FieldA1); !ok || len(point) != 64 {
		t.Errorf("client point = %d bytes/%v", len(point), ok)
	}

	if err := h.HandleResponse(negotiationResponseFrame(t, OpcodePublicKey, mustHex(t, fxPlainDevicePublicKey), NegotiationKeys())); err != nil {
		t.Fatalf("handle publicKey: %v", err)
	}
	sessionKeys, ok := h.Engine().SessionKeys()
	if !ok {
		t.Fatal("session keys missing after the device point")
	}
	frame, _, err = h.Next()
	if err != nil {
		t.Fatalf("Next: %v", err)
	}
	metadata := mustDecodedFrame(t, frame)
	if metadata.Opcode() != OpcodeAESMetadata {
		t.Fatalf("opcode = 0x%04X", metadata.Opcode())
	}
	plain, err = Open(metadata.Payload, sessionKeys)
	if err != nil {
		t.Fatalf("open metadata with the session key: %v", err)
	}
	if a3, ok := mustPayload(t, hexStr(plain)).Field(FieldA3); !ok || !reflect.DeepEqual(a3, []byte{0x80, 0x8F, 0xFF, 0xFF}) {
		t.Errorf("metadata A3 = %x/%v", a3, ok)
	}

	// The device's own ACKs for aesMetadata and userAuth are session-encrypted.
	if err := h.HandleResponse(sessionResponseFrame(t, OpcodeAESMetadata, mustHex(t, "00"), sessionKeys)); err != nil {
		t.Fatalf("handle aesMetadata: %v", err)
	}
	frame, _, err = h.Next()
	if err != nil {
		t.Fatalf("Next: %v", err)
	}
	if userAuth := mustDecodedFrame(t, frame); userAuth.Opcode() != OpcodeUserAuth {
		t.Fatalf("opcode = 0x%04X", userAuth.Opcode())
	}

	if err := h.HandleResponse(sessionResponseFrame(t, OpcodeUserAuth, mustHex(t, "00"), sessionKeys)); err != nil {
		t.Fatalf("handle userAuth: %v", err)
	}
	burst := make([]uint16, 0, 3)
	for i := 0; i < 3; i++ {
		frame, done, err = h.Next()
		if err != nil || done || frame == nil {
			t.Fatalf("burst frame %d = %v/%v/%v", i, frame, done, err)
		}
		burst = append(burst, mustDecodedFrame(t, frame).Opcode())
	}
	wantBurst := []uint16{OpcodeReadAll, OpcodeBindSuccess, OpcodeRealtimeTrigger}
	if !reflect.DeepEqual(burst, wantBurst) {
		t.Errorf("burst = %v, want %v", burst, wantBurst)
	}
	if _, done, err = h.Next(); err != nil || !done {
		t.Errorf("terminal Next = done %v, err %v; want true/nil", done, err)
	}
	if h.Stage() != StageSessionReady {
		t.Errorf("stage = %v", h.Stage())
	}
}

// Non-response frames and tampered responses are handled predictably.
func TestHandshakeAdapterIgnoresAndRejects(t *testing.T) {
	h := NewHandshake(testHandshakeConfig())
	if _, _, err := h.Next(); err != nil {
		t.Fatalf("Next: %v", err)
	}

	// A request-shaped frame (no response flag) is ignored.
	request := EncodePacket(NewCommandFrame(GroupNegotiation, OpcodeInitialConnect, true, false, []byte{0xAA}))
	if err := h.HandleResponse(request); err != nil {
		t.Errorf("request frame: %v", err)
	}
	if h.Stage() != StageInitialConnect {
		t.Errorf("stage = %v", h.Stage())
	}

	// A response with the wrong key fails closed.
	bad := negotiationResponseFrame(t, OpcodeInitialConnect, mustHex(t, fxPlainDeviceInitialConnect), NegotiationKeys())
	bad[len(bad)-2] ^= 0x01
	bad[len(bad)-1] = FrameChecksum(bad[:len(bad)-1])
	if err := h.HandleResponse(bad); err == nil {
		t.Error("tampered response was accepted")
	} else if kind := cryptoErrKind(t, err); kind != CryptoErrAuthenticationFailed {
		t.Errorf("kind = %v", kind)
	}

	// A frame that does not even decode reports the frame error.
	if err := h.HandleResponse([]byte{0xFF, 0x09}); err == nil {
		t.Error("truncated frame was accepted")
	}
}

// Skip is reachable through the frame-level adapter too.
func TestHandshakeAdapterSkip(t *testing.T) {
	h := NewHandshake(testHandshakeConfig())
	if h.CanSkipCurrentStage() {
		t.Error("initialConnect must not be skippable")
	}
	if err := h.SkipCurrentStage(); err == nil {
		t.Error("skip before the flaky stages must fail")
	}
	// Walk to aesMetadata.
	for _, step := range []struct {
		opcode uint16
		plain  string
	}{
		{OpcodeInitialConnect, fxPlainDeviceInitialConnect},
		{OpcodeCapability, fxPlainDeviceCapability},
		{OpcodeBaseInfo, fxPlainDeviceBaseInfo},
		{OpcodeSetCapability, fxPlainDeviceSetCapability},
	} {
		if _, _, err := h.Next(); err != nil {
			t.Fatalf("Next: %v", err)
		}
		if err := h.HandleResponse(negotiationResponseFrame(t, step.opcode, mustHex(t, step.plain), NegotiationKeys())); err != nil {
			t.Fatalf("handle 0x%04X: %v", step.opcode, err)
		}
	}
	if _, _, err := h.Next(); err != nil { // setCapability frame
		t.Fatalf("Next: %v", err)
	}
	if err := h.HandleResponse(negotiationResponseFrame(t, OpcodeSetCapability, mustHex(t, fxPlainDeviceSetCapability), NegotiationKeys())); err != nil {
		t.Fatalf("handle setCapability: %v", err)
	}
	if _, _, err := h.Next(); err != nil { // public key frame
		t.Fatalf("Next: %v", err)
	}
	if err := h.HandleResponse(negotiationResponseFrame(t, OpcodePublicKey, mustHex(t, fxPlainDevicePublicKey), NegotiationKeys())); err != nil {
		t.Fatalf("handle publicKey: %v", err)
	}
	if _, _, err := h.Next(); err != nil { // aesMetadata frame
		t.Fatalf("Next: %v", err)
	}
	if !h.CanSkipCurrentStage() {
		t.Fatal("aesMetadata must be skippable")
	}
	if err := h.SkipCurrentStage(); err != nil {
		t.Fatalf("skip: %v", err)
	}
	frame, _, err := h.Next()
	if err != nil {
		t.Fatalf("Next: %v", err)
	}
	if got := mustDecodedFrame(t, frame).Opcode(); got != OpcodeUserAuth {
		t.Errorf("opcode after skip = 0x%04X, want userAuth", got)
	}
	if err := h.SkipCurrentStage(); err != nil {
		t.Fatalf("skip userAuth: %v", err)
	}
	for i := 0; i < 3; i++ {
		if _, _, err := h.Next(); err != nil {
			t.Fatalf("burst Next: %v", err)
		}
	}
	if _, done, err := h.Next(); err != nil || !done {
		t.Errorf("terminal Next = %v/%v, want done", done, err)
	}
}

// Stage accessors.
func TestStageMetadata(t *testing.T) {
	if got, ok := StageInitialConnect.AwaitedOpcode(); !ok || got != OpcodeInitialConnect {
		t.Errorf("initialConnect awaited = 0x%04X/%v", got, ok)
	}
	if _, ok := StageIdle.AwaitedOpcode(); ok {
		t.Error("idle awaits nothing")
	}
	if _, ok := StageSessionReady.AwaitedOpcode(); ok {
		t.Error("sessionReady awaits nothing")
	}
	if !StageSessionReady.IsTerminal() || StageUserAuth.IsTerminal() {
		t.Error("terminal stages are wrong")
	}
	if got := StageAESMetadata.String(); got != "aesMetadata" {
		t.Errorf("String = %q", got)
	}
	if got := Stage(99).String(); got != "unknown" {
		t.Errorf("unknown String = %q", got)
	}
	// The ladder order is relied upon by the key-schedule choice.
	if !(StagePublicKeyExchange < StageAESMetadata) {
		t.Error("stage ordering broken")
	}
}

func mustDecodedFrame(tb testing.TB, data []byte) Frame {
	tb.Helper()
	frame, err := DecodePacket(data)
	if err != nil {
		tb.Fatalf("DecodePacket: %v", err)
	}
	return frame
}

// Every ladder rung names itself consistently; diagnostics depend on these
// strings being stable.
func TestStageStrings(t *testing.T) {
	cases := map[Stage]string{
		StageIdle:                "idle",
		StageInitialConnect:      "initialConnect",
		StageCapability:          "capability",
		StageBaseInfo:            "baseInfo",
		StageSetCapability:       "setCapability",
		StagePublicKeyExchange:   "publicKeyExchange",
		StageSharedSecretDerived: "sharedSecretDerived",
		StageAESMetadata:         "aesMetadata",
		StageUserAuth:            "userAuth",
		StageSessionReady:        "sessionReady",
	}
	for stage, want := range cases {
		t.Run(want, func(t *testing.T) {
			if got := stage.String(); got != want {
				t.Errorf("String = %q, want %q", got, want)
			}
		})
	}
}
