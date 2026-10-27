package anker

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"strings"

	"charker/internal/a2345"
)

// PayloadError says why no A2345 frame was taken from an MQTT payload. It
// intentionally carries no source string, payload bytes or parser detail:
// cloud messages can contain account and device identifiers and must never be
// copied into logs through an error.
type PayloadError int

const (
	PayloadEmpty PayloadError = iota + 1
	PayloadInputTooLarge
	PayloadCandidateTooLarge
	PayloadMalformedJSON
	PayloadMaximumDepthExceeded
	PayloadTooManyJSONNodes
	PayloadInvalidBase64
	PayloadNonFF09
	PayloadInvalidFrame
	PayloadFrameNotFound
	PayloadAmbiguousFrames
)

func (e PayloadError) Error() string {
	switch e {
	case PayloadEmpty:
		return "payload: empty"
	case PayloadInputTooLarge:
		return "payload: input too large"
	case PayloadCandidateTooLarge:
		return "payload: candidate too large"
	case PayloadMalformedJSON:
		return "payload: malformed JSON"
	case PayloadMaximumDepthExceeded:
		return "payload: maximum depth exceeded"
	case PayloadTooManyJSONNodes:
		return "payload: too many JSON nodes"
	case PayloadInvalidBase64:
		return "payload: invalid base64"
	case PayloadNonFF09:
		return "payload: not an FF09 frame"
	case PayloadInvalidFrame:
		return "payload: invalid frame"
	case PayloadFrameNotFound:
		return "payload: frame not found"
	case PayloadAmbiguousFrames:
		return "payload: ambiguous frames"
	}
	return "payload: invalid"
}

// Payload decoder limits.
const (
	PayloadMaximumInputBytes = 256 * 1024
	PayloadMaximumJSONDepth  = 8
	PayloadMaximumJSONNodes  = 512
	// PayloadMaximumBase64Characters fits one maximum-size FF09 frame.
	PayloadMaximumBase64Characters = ((a2345.MaxFrameLength + 2) / 3) * 4
)

// DecodeCloudPayload extracts one validated A2345 FF09 frame from an MQTT
// PUBLISH payload (A2345CloudPayloadDecoder).
//
// Supported forms are raw FF09 bytes, JSON whose `payload` string contains
// another JSON document, and base64 FF09 bytes under `data` or `payload` keys
// at any permitted nesting level. Distinct multiple frames are rejected rather
// than resolved by traversal order.
func DecodeCloudPayload(payload []byte) ([]byte, error) {
	if len(payload) == 0 {
		return nil, PayloadEmpty
	}
	if len(payload) > PayloadMaximumInputBytes {
		return nil, PayloadInputTooLarge
	}
	if bytes.HasPrefix(payload, a2345.Header[:]) {
		return validatedFrame(payload)
	}
	if !looksLikeJSON(payload) {
		return nil, PayloadNonFF09
	}
	root, ok := decodeAny(payload)
	if !ok {
		return nil, PayloadMalformedJSON
	}
	t := &traversal{frames: map[string]bool{}, errors: map[PayloadError]bool{}}
	if err := t.walk(root, 0, false); err != nil {
		return nil, err
	}
	// MQTT envelopes may contain ordinary sibling `data` fields next to the
	// actual device payload. A malformed unrelated candidate must not mask one
	// unambiguous, checksum-valid frame; two distinct valid frames remain
	// ambiguous.
	if len(t.frames) > 1 {
		return nil, PayloadAmbiguousFrames
	}
	for frame := range t.frames {
		return []byte(frame), nil
	}
	for _, e := range []PayloadError{PayloadCandidateTooLarge, PayloadMalformedJSON, PayloadInvalidBase64, PayloadNonFF09, PayloadInvalidFrame} {
		if t.errors[e] {
			return nil, e
		}
	}
	return nil, PayloadFrameNotFound
}

func validatedFrame(data []byte) ([]byte, error) {
	if len(data) > a2345.MaxFrameLength {
		return nil, PayloadCandidateTooLarge
	}
	if !bytes.HasPrefix(data, a2345.Header[:]) {
		return nil, PayloadNonFF09
	}
	if _, err := a2345.Decode(data); err != nil {
		return nil, PayloadInvalidFrame
	}
	return append([]byte(nil), data...), nil
}

func looksLikeJSON(data []byte) bool {
	for _, b := range data {
		switch b {
		case '\t', '\n', '\r', ' ':
			continue
		case '[', '{':
			return true
		default:
			return false
		}
	}
	return false
}

// decodeAny parses one JSON document; trailing garbage is malformed too.
func decodeAny(data []byte) (any, bool) {
	if !json.Valid(data) {
		return nil, false
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, false
	}
	return v, true
}

type traversal struct {
	frames  map[string]bool
	errors  map[PayloadError]bool
	visited int
}

func (t *traversal) walk(value any, depth int, inspectString bool) error {
	if depth > PayloadMaximumJSONDepth {
		return PayloadMaximumDepthExceeded
	}
	t.visited++
	if t.visited > PayloadMaximumJSONNodes {
		return PayloadTooManyJSONNodes
	}
	switch v := value.(type) {
	case map[string]any:
		for key, child := range v {
			candidate := strings.EqualFold(key, "data") || strings.EqualFold(key, "payload")
			if s, ok := child.(string); ok && candidate {
				if err := t.inspect(s, depth+1); err != nil {
					return err
				}
			} else if err := t.walk(child, depth+1, false); err != nil {
				return err
			}
		}
	case []any:
		for _, child := range v {
			if err := t.walk(child, depth+1, false); err != nil {
				return err
			}
		}
	case string:
		if inspectString {
			return t.inspect(v, depth+1)
		}
	}
	return nil
}

func (t *traversal) inspect(s string, depth int) error {
	if depth > PayloadMaximumJSONDepth {
		return PayloadMaximumDepthExceeded
	}
	if len(s) > PayloadMaximumInputBytes {
		t.errors[PayloadCandidateTooLarge] = true
		return nil
	}
	trimmed := strings.TrimSpace(s)
	if strings.HasPrefix(trimmed, "{") || strings.HasPrefix(trimmed, "[") {
		nested, ok := decodeAny([]byte(trimmed))
		if !ok {
			t.errors[PayloadMalformedJSON] = true
			return nil
		}
		return t.walk(nested, depth, true)
	}
	if len(s) > PayloadMaximumBase64Characters {
		t.errors[PayloadCandidateTooLarge] = true
		return nil
	}
	decoded, err := base64.StdEncoding.Strict().DecodeString(s)
	if err != nil || strings.ContainsAny(s, "\r\n") {
		t.errors[PayloadInvalidBase64] = true
		return nil
	}
	if !bytes.HasPrefix(decoded, a2345.Header[:]) {
		t.errors[PayloadNonFF09] = true
		return nil
	}
	if len(decoded) > a2345.MaxFrameLength {
		t.errors[PayloadCandidateTooLarge] = true
		return nil
	}
	if _, err := a2345.Decode(decoded); err != nil {
		t.errors[PayloadInvalidFrame] = true
		return nil
	}
	t.frames[string(decoded)] = true
	return nil
}
