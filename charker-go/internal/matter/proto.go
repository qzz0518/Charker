package matter

import (
	"encoding/json"
	"fmt"
)

// portLine is the stdin line for one port, without the newline. Fixed key
// order keeps the log readable and the tests exact.
func portLine(index int, s PortState) string {
	return fmt.Sprintf(`{"type":"port","index":%d,"on":%t,"voltage_mv":%d,"current_ma":%d,"power_mw":%d}`,
		max(0, index), s.On, max(0, s.VoltageMV), max(0, s.CurrentMA), max(0, s.PowerMW))
}

const shutdownLine = `{"type":"shutdown"}`

// eventKind is the type of one stdout line.
type eventKind int

const (
	evOnboarding eventKind = iota + 1
	evFabrics
	evCommand
	// evMDNS: the advertisement failed (ok false, once per failure streak) or
	// came back after one. The helper keeps running and retrying.
	evMDNS
	// evError is fatal; the helper exits non-zero next.
	evError
)

// event is one line the helper printed on stdout.
type event struct {
	kind       eventKind
	qr         string
	manualCode string
	count      int
	index      int
	on         bool
	ok         bool
	code       string
	message    string
}

// parseEvent returns false for a malformed line, a known type missing its
// fields, or a type this build does not know: a newer helper must not break
// an older app.
func parseEvent(line string) (event, bool) {
	var raw struct {
		Type       string  `json:"type"`
		QR         *string `json:"qr"`
		ManualCode *string `json:"manual_code"`
		Count      *int    `json:"count"`
		Index      *int    `json:"index"`
		On         *bool   `json:"on"`
		OK         *bool   `json:"ok"`
		Code       *string `json:"code"`
		Message    *string `json:"message"`
	}
	if json.Unmarshal([]byte(line), &raw) != nil {
		return event{}, false
	}
	switch raw.Type {
	case "onboarding":
		if raw.QR == nil || raw.ManualCode == nil {
			return event{}, false
		}
		return event{kind: evOnboarding, qr: *raw.QR, manualCode: *raw.ManualCode}, true
	case "fabrics":
		if raw.Count == nil || *raw.Count < 0 {
			return event{}, false
		}
		return event{kind: evFabrics, count: *raw.Count}, true
	case "command":
		if raw.Index == nil || *raw.Index < 0 || raw.On == nil {
			return event{}, false
		}
		return event{kind: evCommand, index: *raw.Index, on: *raw.On}, true
	case "mdns":
		if raw.OK == nil {
			return event{}, false
		}
		return event{kind: evMDNS, ok: *raw.OK}, true
	case "error":
		e := event{kind: evError, code: "internal"}
		if raw.Code != nil {
			e.code = *raw.Code
		}
		if raw.Message != nil {
			e.message = *raw.Message
		}
		return e, true
	}
	return event{}, false
}

// FormatManualCode groups an 11-digit manual pairing code as Home and printed
// Matter labels do: 34970112332 -> 3497-011-2332. Anything else is returned
// untouched.
func FormatManualCode(code string) string {
	if len(code) != 11 {
		return code
	}
	for _, c := range code {
		if c < '0' || c > '9' {
			return code
		}
	}
	return code[:4] + "-" + code[4:7] + "-" + code[7:]
}
