package a2687

import (
	"errors"
	"time"

	"charker/internal/product"
)

// ErrNoPortData reports a device frame that carried no A5/A6/A7 port struct: a
// bind ack, a trigger reply or a command acknowledgement. The frame is still
// worth decoding for its settings and diagnostics; it just must not replace the
// live reading.
var ErrNoPortData = errors.New("a2687: frame carries no port data")

// EncodeCommand seals and frames one outgoing message. Commands built by
// CommandEncoder and CoverCommands carry EncryptionSession and are sealed with
// the link's session keys; negotiation messages use the static key schedule.
//
// The resulting bytes are one complete frame, ready for a GATT write with
// response. The response flag is never set on transmit.
func EncodeCommand(message OutgoingMessage, sessionKeys Keys) ([]byte, error) {
	keys := NegotiationKeys()
	if message.Encryption == EncryptionSession {
		keys = sessionKeys
	}
	sealed, err := Seal(message.Plaintext, keys)
	if err != nil {
		return nil, err
	}
	return EncodePacket(NewCommandFrame(message.Group, message.Opcode, true, false, sealed)), nil
}

// OpenPayload decrypts a frame payload and applies the status-byte heuristic.
// Unencrypted payloads pass through, because some firmware has been observed
// reporting in the clear. A tag failure is returned, never worked around.
func OpenPayload(frame Frame, keys Keys) (Payload, error) {
	plaintext := frame.Payload
	if frame.IsEncrypted() {
		opened, err := Open(frame.Payload, keys)
		if err != nil {
			return Payload{}, err
		}
		plaintext = opened
	}
	return ParsePayload(plaintext)
}

// DecodeResponse decodes one complete notification frame and returns both the
// wire frame and its decrypted payload. It is the primitive a session uses for
// reply confirmation: p.IsOK() tells whether the device accepted the command.
func DecodeResponse(frame []byte, keys Keys) (Frame, Payload, error) {
	decoded, err := DecodePacket(frame)
	if err != nil {
		return Frame{}, Payload{}, err
	}
	payload, err := OpenPayload(decoded, keys)
	if err != nil {
		return Frame{}, Payload{}, err
	}
	return decoded, payload, nil
}

// Link is the post-handshake facade the session engine drives: it owns the
// session key schedule and the per-link settings carry-forward, and turns device
// frames into product readings.
//
// One Link belongs to one successful handshake. Create a new one (and therefore
// drop the carried settings) on every reconnect.
type Link struct {
	keys Keys
	// settings is the last non-nil settings snapshot of this link.
	settings *DeviceSettings
}

// NewLink builds a post-handshake link with the derived session keys.
func NewLink(keys Keys) *Link { return &Link{keys: keys} }

// ResetSettings forgets the carried-forward snapshot. The session calls this at
// the start of every handshake so nothing crosses a session boundary.
func (l *Link) ResetSettings() { l.settings = nil }

// Settings returns the carried-forward snapshot, if one has been read on this
// link.
func (l *Link) Settings() *DeviceSettings { return l.settings }

// EncodeCommand seals and frames one outgoing message with this link's session
// keys.
func (l *Link) EncodeCommand(message OutgoingMessage) ([]byte, error) {
	return EncodeCommand(message, l.keys)
}

// DecodeState decodes one complete notification frame into a ChargerTelemetry
// snapshot with the link's settings carry-forward applied.
func (l *Link) DecodeState(frame []byte) (ChargerTelemetry, error) {
	return l.DecodeStateAt(frame, time.Now())
}

// DecodeStateAt is DecodeState with an injected clock.
//
// The settings carry-forward rule lives here: a frame that omits the settings ids
// inherits the last non-nil snapshot of the link, so a realtime report that says
// nothing about the display does not blink the settings out. A frame that names
// the ids but whose values are unreadable yields an empty but *present* snapshot,
// which overrides the carried values with a dash.
//
// Decryption mirrors the session's key choice: the session key is primary, with
// the static negotiation key as a fallback (the Swift session tolerates a device
// that seals some frames with the other schedule). Unencrypted frames pass
// straight through.
func (l *Link) DecodeStateAt(frame []byte, now time.Time) (ChargerTelemetry, error) {
	decoded, err := DecodePacket(frame)
	if err != nil {
		return ChargerTelemetry{}, err
	}
	payload, err := OpenPayload(decoded, l.keys)
	if err != nil {
		fallback, fallbackErr := OpenPayload(decoded, NegotiationKeys())
		if fallbackErr != nil {
			return ChargerTelemetry{}, err
		}
		payload = fallback
	}
	telemetry := DecodeTelemetry(payload, decoded.Opcode(), now)
	if telemetry.Settings != nil {
		l.settings = telemetry.Settings
	} else {
		telemetry.Settings = l.settings
	}
	return telemetry, nil
}

// DecodeTelemetry decodes one complete notification frame into the frozen
// product model: the live reading and the settings snapshot (nil when none is
// known for this link). A frame with no port struct returns ErrNoPortData; see
// DecodeTelemetryAt.
//
// This is the session's hot path; use DecodeState when the raw snapshot
// (unknown/all fields, cable/profile codes) is wanted too.
func (l *Link) DecodeTelemetry(frame []byte) (product.Reading, *product.Settings, error) {
	return l.DecodeTelemetryAt(frame, time.Now())
}

// DecodeTelemetryAt is DecodeTelemetry with an injected clock.
//
// The reading is returned only for frames that carry port structs. A frame
// without any (a bind ack, a trigger reply, a write acknowledgement) returns
// ErrNoPortData with a zero reading and the settings snapshot it may have
// refreshed — callers must ignore the reading in that case and keep the previous
// one, which is exactly the "must not replace live readings" rule.
func (l *Link) DecodeTelemetryAt(frame []byte, now time.Time) (product.Reading, *product.Settings, error) {
	telemetry, err := l.DecodeStateAt(frame, now)
	if err != nil {
		return product.Reading{}, nil, err
	}
	settings := telemetry.ProductSettings()
	if !telemetry.HasPortData() {
		return product.Reading{}, settings, ErrNoPortData
	}
	return telemetry.ProductReading(), settings, nil
}
