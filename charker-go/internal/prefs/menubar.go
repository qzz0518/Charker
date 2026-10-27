package prefs

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"strings"
)

// MenuBarItem is one ordered building block of the readout layout
// (CharkerCore MenuBarItem). The JSON shape is the Swift Codable one, so a
// layout reads the same on both platforms. Optional fields are pointers:
// a nil label ("use the default") and an empty one ("show nothing") differ.
type MenuBarItem struct {
	ID   string `json:"id"`
	Kind string `json:"kind"`
	// Port is the ChargerPortID raw value (0 = C1 … 2 = C3), portPower only.
	Port *int `json:"port,omitempty"`
	// Label: prefix of a value item, mark of a separator, text of a text item.
	Label *string `json:"label,omitempty"`
	// SystemContent is built-in copy that follows the app language:
	// activePortsCount or sampleText.
	SystemContent *string `json:"systemContent,omitempty"`
	ShowsUnit     bool    `json:"showsUnit"`
	ShowsPortName bool    `json:"showsPortName"`
	// Decimals overrides the global decimal places.
	Decimals *int `json:"decimals,omitempty"`
}

// Menu bar item kinds.
const (
	KindTotalPower = "totalPower"
	KindPortPower  = "portPower"
	KindPortsCount = "portsCount"
	KindState      = "state"
	KindDeviceName = "deviceName"
	KindSeparator  = "separator"
	KindText       = "text"
)

// DefaultStatusTemplate is the template of a fresh install.
const DefaultStatusTemplate = "{total}"

// defaultMenuBarItems is the layout of a fresh install: the total power. Its
// id is fixed so that every DefaultPreferences is the same value.
func defaultMenuBarItems() json.RawMessage {
	item := newItem(KindTotalPower)
	item.ID = "6F1C2B0E-3D4A-4E8B-9A57-2C1D0E7F4B10"
	return EncodeMenuBarItems([]MenuBarItem{item})
}

func validKind(kind string) bool {
	switch kind {
	case KindTotalPower, KindPortPower, KindPortsCount, KindState, KindDeviceName, KindSeparator, KindText:
		return true
	}
	return false
}

// newItem returns an item with the Swift initializer's defaults.
func newItem(kind string) MenuBarItem {
	return MenuBarItem{ID: newUUID(), Kind: kind, ShowsUnit: true, ShowsPortName: true}
}

// DecodeMenuBarItems is MenuBarConfig.decode: item-tolerant, so one corrupt
// entry drops that entry, not the whole layout. ok is false when there is no
// stored layout (empty, or not a JSON array).
func DecodeMenuBarItems(raw json.RawMessage) (items []MenuBarItem, ok bool) {
	var list []json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &list) != nil || list == nil {
		return nil, false
	}
	items = make([]MenuBarItem, 0, len(list))
	for _, entry := range list {
		item, ok := decodeItem(entry)
		if ok {
			items = append(items, item)
		}
	}
	return items, true
}

func decodeItem(entry json.RawMessage) (MenuBarItem, bool) {
	var fields struct {
		ID            *string         `json:"id"`
		Kind          string          `json:"kind"`
		Port          *int            `json:"port"`
		Label         *string         `json:"label"`
		SystemContent json.RawMessage `json:"systemContent"`
		ShowsUnit     *bool           `json:"showsUnit"`
		ShowsPortName *bool           `json:"showsPortName"`
		Decimals      *int            `json:"decimals"`
	}
	if json.Unmarshal(entry, &fields) != nil || !validKind(fields.Kind) {
		return MenuBarItem{}, false
	}
	item := newItem(fields.Kind)
	if fields.ID != nil && *fields.ID != "" {
		item.ID = *fields.ID
	}
	item.Port = fields.Port
	item.Label = fields.Label
	// A future system-content role must not make the item disappear.
	var sc string
	if json.Unmarshal(fields.SystemContent, &sc) == nil && (sc == "activePortsCount" || sc == "sampleText") {
		item.SystemContent = &sc
	}
	if fields.ShowsUnit != nil {
		item.ShowsUnit = *fields.ShowsUnit
	}
	if fields.ShowsPortName != nil {
		item.ShowsPortName = *fields.ShowsPortName
	}
	if d := fields.Decimals; d != nil {
		v := min(max(*d, 0), 3)
		item.Decimals = &v
	}
	return item, true
}

// EncodeMenuBarItems is MenuBarConfig.encode.
func EncodeMenuBarItems(items []MenuBarItem) json.RawMessage {
	if items == nil {
		items = []MenuBarItem{}
	}
	data, err := json.Marshal(items)
	if err != nil {
		return json.RawMessage("[]")
	}
	return data
}

// MenuBarLayout returns the items the readout renders: the stored layout,
// or the legacy template parsed (Preferences.menuBarItems).
func (p Preferences) MenuBarLayout() []MenuBarItem {
	if items, ok := DecodeMenuBarItems(p.MenuBarItems); ok {
		return items
	}
	return ParseTemplate(p.StatusTemplate)
}

// PortLabels are the ChargerPortID labels by raw value (0 = C1 … 5 = A2),
// every product's ports: the A2687 has the first three, the A2345 all six.
var PortLabels = []string{"C1", "C2", "C3", "C4", "A1", "A2"}

// ParseTemplate is MenuBarConfig.parse: unknown tokens stay literal text,
// and a "C1"-style literal merges into the port item after it.
func ParseTemplate(template string) []MenuBarItem {
	tokens := map[string]string{
		"{total}": KindTotalPower, "{ports}": KindPortsCount,
		"{state}": KindState, "{device}": KindDeviceName,
	}
	items := []MenuBarItem{}
	var buffer strings.Builder
	flush := func() {
		text := strings.TrimSpace(buffer.String())
		buffer.Reset()
		if text == "" {
			return
		}
		item := newItem(KindText)
		item.Label = &text
		items = append(items, item)
	}
	rest := template
outer:
	for rest != "" {
		switch {
		case strings.HasPrefix(rest, "·"), strings.HasPrefix(rest, "|"):
			flush()
			mark := "·"
			if rest[0] == '|' {
				mark = "|"
			}
			item := newItem(KindSeparator)
			item.Label = &mark
			items = append(items, item)
			rest = rest[len(mark):]
			continue
		case rest[0] == '{':
			for token, kind := range tokens {
				if strings.HasPrefix(rest, token) {
					flush()
					items = append(items, newItem(kind))
					rest = rest[len(token):]
					continue outer
				}
			}
			for index, label := range PortLabels {
				token := "{" + strings.ToLower(label) + "}"
				if !strings.HasPrefix(rest, token) {
					continue
				}
				item := newItem(KindPortPower)
				port := index
				item.Port = &port
				if strings.EqualFold(strings.TrimSpace(buffer.String()), label) {
					buffer.Reset()
				} else {
					flush()
					item.ShowsPortName = false
				}
				items = append(items, item)
				rest = rest[len(token):]
				continue outer
			}
		}
		r := []rune(rest)[0]
		buffer.WriteRune(r)
		rest = rest[len(string(r)):]
	}
	flush()
	return items
}

// normalizeMenuBar keeps the stored layout decodable and the legacy
// template in step with it, as Preferences does on macOS.
func normalizeMenuBar(p Preferences) Preferences {
	if strings.TrimSpace(p.StatusTemplate) == "" {
		p.StatusTemplate = DefaultStatusTemplate
	}
	p.MenuBarItems = EncodeMenuBarItems(p.MenuBarLayout())
	return p
}

// newUUID returns a random RFC 4122 version 4 UUID in Foundation's
// uppercase form.
func newUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "00000000-0000-4000-8000-000000000000"
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]))
}
