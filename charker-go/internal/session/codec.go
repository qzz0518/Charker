package session

import (
	"fmt"
	"time"

	"charker/internal/a2687"
	"charker/internal/product"
)

// This file is the only place the session engine touches the A2687 protocol
// implementation (internal/a2687, owned by proto-a2687). Everything else codes
// against the small codec interfaces below, so the client-side protocol stays
// swappable and no a2687 types leak into the exported session API.
//
// The device-side wire helpers the mock charger uses live in
// internal/session/wire; the client path is a2687.

// Protocol opcodes the session logic needs to recognise (used for ack routing
// and telemetry dispatch). These are protocol facts, not implementation types.
const (
	opReadAll    uint16 = 0x0200
	opPortOutput uint16 = 0x0207
	opPortTimer  uint16 = 0x0209
	opBindProbe  uint16 = 0x020A
	opScreenLang uint16 = 0x0202
	opScreenTime uint16 = 0x0203
	opScreenLite uint16 = 0x0204
	opFixedAlloc uint16 = 0x0205
	opChargeMode uint16 = 0x0206
	opOrient     uint16 = 0x020B
	opGyro       uint16 = 0x020D
	opRealtime   uint16 = 0x0300
)

// incomingFrame is one reassembled device frame.
type incomingFrame struct {
	// raw is the complete encoded frame (needed by the handshake/link layer,
	// which owns decryption).
	raw      []byte
	opcode   uint16
	response bool
}

// outgoingFrame is one encoded frame ready for transport.Write.
type outgoingFrame struct {
	bytes []byte
}

// frameAssembler reassembles notification chunks into frames.
type frameAssembler interface {
	push(data []byte) []incomingFrame
	reset()
}

// handshakeConfig configures one link's negotiation ladder.
type handshakeConfig struct {
	ClientID     string
	TimeZoneRule string
	CountryCode  string
	OwnerUserID  string
	// Now returns the wall clock for command timestamps.
	Now func() time.Time
}

// handshakeInfo is the device identity learned from the base-info exchange.
type handshakeInfo struct {
	ProductName string
	Firmware    string
	Serial      string
	MAC         string
}

// decodedTelemetry is the session-facing view of one telemetry sample.
type decodedTelemetry struct {
	reading     product.Reading
	settings    *product.Settings
	hasPortData bool
}

// clientHandshake is the per-link negotiation state machine plus the
// post-handshake link (decryption, telemetry decode, command encode).
type clientHandshake interface {
	// start returns the first frame(s) to write.
	start() ([]outgoingFrame, error)
	// handleResponse feeds one raw reassembled device frame and returns the
	// frames to write next plus whether the ladder and opening burst finished.
	handleResponse(raw []byte) (out []outgoingFrame, ready bool, err error)
	// canSkip reports whether a stalled stage may be skipped once (only
	// aesMetadata/userAuth may be).
	canSkip() bool
	// skip advances past the current skippable stage.
	skip() (out []outgoingFrame, ready bool, err error)
	ready() bool
	stage() string
	warning() string
	info() handshakeInfo

	// Post-handshake commands (encoded wire frames sealed with the session key).
	readAll(now time.Time) (outgoingFrame, error)
	realtimeProbe(country, owner string, now time.Time) (outgoingFrame, error)
	portOutput(port int, on bool, now time.Time) (outgoingFrame, error)
	portTimer(port int, seconds uint32, now time.Time) (outgoingFrame, error)
	setting(opcode uint16, value byte, now time.Time) (outgoingFrame, error)

	// decodeTelemetry decodes one raw 0x0300 device frame.
	decodeTelemetry(raw []byte) (decodedTelemetry, error)
	// responseStatus returns the status byte of a raw acknowledgement frame.
	responseStatus(raw []byte) (byte, bool)
}

// codec builds assemblers and handshake/link instances.
type codec interface {
	newAssembler() frameAssembler
	newHandshake(cfg handshakeConfig) clientHandshake
}

// defaultCodec is the production implementation: the full A2687 protocol
// package owned by proto-a2687.
var defaultCodec codec = a2687Codec{}

// --- a2687-backed client path ---

type a2687Codec struct{}

func (a2687Codec) newAssembler() frameAssembler { return &a2687Assembler{} }

func (a2687Codec) newHandshake(cfg handshakeConfig) clientHandshake {
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	h := &a2687Handshake{
		h: a2687.NewHandshake(a2687.HandshakeConfig{
			ClientID:     cfg.ClientID,
			TimeZoneRule: cfg.TimeZoneRule,
			CountryCode:  cfg.CountryCode,
			OwnerUserID:  cfg.OwnerUserID,
			Now:          now,
		}),
		now: now,
	}
	return h
}

type a2687Assembler struct{ r a2687.FrameReassembler }

func (a *a2687Assembler) push(data []byte) []incomingFrame {
	frames := a.r.Append(data)
	if len(frames) == 0 {
		return nil
	}
	out := make([]incomingFrame, 0, len(frames))
	for _, f := range frames {
		out = append(out, incomingFrame{
			raw:      a2687.EncodePacket(f),
			opcode:   f.Opcode(),
			response: f.IsResponse(),
		})
	}
	return out
}

func (a *a2687Assembler) reset() { a.r.Reset() }

type a2687Handshake struct {
	h       *a2687.Handshake
	now     func() time.Time
	link    *a2687.Link
	keys    a2687.Keys
	hasKeys bool
	started bool
}

// drainNext pulls every queued frame; done is true once the ladder is complete
// and the opening burst has been drained.
func (a *a2687Handshake) drainNext() (out []outgoingFrame, done bool, err error) {
	for {
		frame, finished, err := a.h.Next()
		if err != nil {
			return out, false, err
		}
		if frame != nil {
			out = append(out, outgoingFrame{bytes: frame})
			continue
		}
		return out, finished, nil
	}
}

func (a *a2687Handshake) start() ([]outgoingFrame, error) {
	if a.started {
		return nil, fmt.Errorf("session: handshake already started")
	}
	a.started = true
	out, _, err := a.drainNext()
	return out, err
}

func (a *a2687Handshake) handleResponse(raw []byte) ([]outgoingFrame, bool, error) {
	err := a.h.HandleResponse(raw)
	if err != nil {
		var he *a2687.HandshakeError
		if asHandshakeError(err, &he) {
			// A device rejection is fatal except at the two survivable display
			// stages, where the ladder stall is handled by the skip path.
			if he.Kind == a2687.HandshakeErrDeviceRejected &&
				(he.Stage == a2687.StageAESMetadata || he.Stage == a2687.StageUserAuth) {
				return nil, false, nil
			}
			return nil, false, err
		}
		// Decryption/parse failures are a per-frame failure budget, not fatal.
		return nil, false, nil
	}
	out, done, err := a.drainNext()
	if err != nil {
		return nil, false, err
	}
	if done {
		a.ensureLink()
	}
	return out, done, nil
}

func asHandshakeError(err error, target **a2687.HandshakeError) bool {
	he, ok := err.(*a2687.HandshakeError)
	if ok {
		*target = he
	}
	return ok
}

func (a *a2687Handshake) canSkip() bool { return a.h.CanSkipCurrentStage() }

func (a *a2687Handshake) skip() ([]outgoingFrame, bool, error) {
	if err := a.h.SkipCurrentStage(); err != nil {
		return nil, false, err
	}
	out, done, err := a.drainNext()
	if err != nil {
		return nil, false, err
	}
	if done {
		a.ensureLink()
	}
	return out, done, nil
}

func (a *a2687Handshake) ready() bool { return a.h.Stage() == a2687.StageSessionReady }

func (a *a2687Handshake) stage() string { return a.h.Stage().String() }

func (a *a2687Handshake) warning() string { return "" }

func (a *a2687Handshake) info() handshakeInfo {
	d := a.h.Engine().DeviceInfo()
	return handshakeInfo{
		ProductName: d.ProductName,
		Firmware:    d.FirmwareVersion,
		Serial:      d.SerialNumber,
		MAC:         d.MACAddress,
	}
}

func (a *a2687Handshake) ensureLink() {
	if a.link != nil || a.hasKeys {
		return
	}
	keys, ok := a.h.Engine().SessionKeys()
	if !ok {
		return
	}
	a.keys = keys
	a.hasKeys = true
	a.link = a2687.NewLink(keys)
}

func (a *a2687Handshake) encode(message a2687.OutgoingMessage) (outgoingFrame, error) {
	a.ensureLink()
	if a.link == nil {
		return outgoingFrame{}, fmt.Errorf("session: session keys not established")
	}
	raw, err := a.link.EncodeCommand(message)
	if err != nil {
		return outgoingFrame{}, err
	}
	return outgoingFrame{bytes: raw}, nil
}

func (a *a2687Handshake) readAll(now time.Time) (outgoingFrame, error) {
	return a.encode(a2687.ReadAll(now))
}

func (a *a2687Handshake) realtimeProbe(country, owner string, now time.Time) (outgoingFrame, error) {
	return a.encode(a2687.RealtimeProbe(country, owner, now))
}

func (a *a2687Handshake) portOutput(port int, on bool, now time.Time) (outgoingFrame, error) {
	return a.encode(a2687.SetPortOutput(a2687.Port(port), on, now))
}

func (a *a2687Handshake) portTimer(port int, seconds uint32, now time.Time) (outgoingFrame, error) {
	return a.encode(a2687.SetPortTimer(a2687.Port(port), seconds, now))
}

func (a *a2687Handshake) setting(opcode uint16, value byte, now time.Time) (outgoingFrame, error) {
	var msg a2687.OutgoingMessage
	switch opcode {
	case opScreenLang:
		msg = a2687.SetChargerSetting(a2687.LanguageSetting(a2687.DeviceLanguage(value)), now)
	case opScreenTime:
		msg = a2687.SetChargerSetting(a2687.ScreenTimeoutSetting(a2687.ScreenTimeout(value)), now)
	case opScreenLite:
		msg = a2687.SetChargerSetting(a2687.BrightnessSetting(value), now)
	case opFixedAlloc:
		msg = a2687.SetChargerSetting(a2687.FixedAllocationSetting(a2687.FixedAllocation(value)), now)
	case opOrient:
		msg = a2687.SetChargerSetting(a2687.OrientationSetting(a2687.ScreenOrientation(value)), now)
	case opGyro:
		msg = a2687.SetChargerSetting(a2687.GyroscopeSetting(value == 1), now)
	case opChargeMode:
		msg = a2687.SetChargingMode(a2687.ChargingMode(value), now)
	default:
		return outgoingFrame{}, fmt.Errorf("session: unsupported setting opcode 0x%04x", opcode)
	}
	return a.encode(msg)
}

func (a *a2687Handshake) decodeTelemetry(raw []byte) (decodedTelemetry, error) {
	a.ensureLink()
	if a.link == nil {
		return decodedTelemetry{}, fmt.Errorf("session: link not ready")
	}
	tel, err := a.link.DecodeState(raw)
	if err != nil {
		return decodedTelemetry{}, err
	}
	reading := tel.ProductReading()
	// a2687 reports the negotiated profile as one label ("Apple PD"). The UI
	// shows a protocol badge and a device identity separately, so split the
	// vendor prefix into DeviceKind here.
	for i := range reading.Ports {
		p := &reading.Ports[i]
		if vendor, proto, ok := splitVendorProfile(p.Protocol); ok {
			p.Protocol = proto
			if p.DeviceKind == "" {
				p.DeviceKind = vendor
			}
		}
	}
	decoded := decodedTelemetry{
		reading:     reading,
		settings:    tel.ProductSettings(),
		hasPortData: len(tel.Ports) > 0,
	}
	controls := tel.ProductPortControls()
	if controls != nil {
		if decoded.settings == nil {
			decoded.settings = &product.Settings{}
		}
		decoded.settings.PortControls = controls
	}
	return decoded, nil
}

// splitVendorProfile separates "Apple PD" into ("Apple", "PD"). Profiles that
// name only the protocol (or are unknown) are left alone.
func splitVendorProfile(label string) (vendor, protocol string, ok bool) {
	switch label {
	case "Apple PD":
		return "Apple", "PD", true
	case "Samsung Fast", "Samsung Super Fast":
		return "Samsung", label, true
	case "SCP":
		return "Huawei", "SCP", true
	case "Xiaomi HyperCharge":
		return "Xiaomi", "HyperCharge", true
	}
	return "", "", false
}

func (a *a2687Handshake) responseStatus(raw []byte) (byte, bool) {
	a.ensureLink()
	if a.link == nil || !a.hasKeys {
		return 0, false
	}
	_, payload, err := a2687.DecodeResponse(raw, a.keys)
	if err != nil {
		return 0, false
	}
	return payload.StatusCode()
}
