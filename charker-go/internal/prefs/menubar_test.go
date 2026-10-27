package prefs

import (
	"encoding/json"
	"testing"
)

func describeItems(items []MenuBarItem) []string {
	out := []string{}
	for _, it := range items {
		s := it.Kind
		if it.Port != nil {
			s += "#" + string(rune('0'+*it.Port))
		}
		if it.Label != nil {
			s += "[" + *it.Label + "]"
		}
		if it.Kind == KindPortPower && !it.ShowsPortName {
			s += "-name"
		}
		out = append(out, s)
	}
	return out
}

func TestParseTemplate(t *testing.T) {
	cases := map[string][]string{
		"{total}":           {"totalPower"},
		"C1 {c1} · C2 {c2}": {"portPower#0", "separator[·]", "portPower#1"},
		"{total} | {state}": {"totalPower", "separator[|]", "state"},
		"{total} ({ports})": {"totalPower", "text[(]", "portsCount", "text[)]"},
		"Mac {c3} {x}":      {"text[Mac]", "portPower#2-name", "text[{x}]"},
		"{device} · {c4}":   {"deviceName", "separator[·]", "portPower#3-name"},
		"A2 {a2}":           {"portPower#5"},
		"":                  {},
	}
	for template, want := range cases {
		got := describeItems(ParseTemplate(template))
		if len(got) != len(want) {
			t.Errorf("%q: got %v, want %v", template, got, want)
			continue
		}
		for i := range got {
			if got[i] != want[i] {
				t.Errorf("%q: got %v, want %v", template, got, want)
				break
			}
		}
	}
}

func TestDecodeMenuBarItemsIsLenient(t *testing.T) {
	raw := json.RawMessage(`[{"id":"A","kind":"totalPower","showsUnit":false},{"kind":"future"},{"id":"B","kind":"text","label":"","systemContent":"later"},{"id":"C","kind":"portPower","port":1,"decimals":9}]`)
	items, ok := DecodeMenuBarItems(raw)
	if !ok || len(items) != 3 {
		t.Fatalf("decode: ok=%v items=%v", ok, items)
	}
	if items[0].ShowsUnit || !items[0].ShowsPortName {
		t.Errorf("defaults: %+v", items[0])
	}
	if items[1].Label == nil || *items[1].Label != "" || items[1].SystemContent != nil {
		t.Errorf("empty label must survive, unknown system content drop: %+v", items[1])
	}
	if items[2].Decimals == nil || *items[2].Decimals != 3 {
		t.Errorf("decimals clamp: %+v", items[2])
	}
	if _, ok := DecodeMenuBarItems(json.RawMessage(`{}`)); ok {
		t.Errorf("an object is no layout")
	}
}

func TestNormalizeSeedsTheLayout(t *testing.T) {
	p := Normalize(Preferences{StatusTemplate: "{total} | {state}"})
	items, ok := DecodeMenuBarItems(p.MenuBarItems)
	if !ok || len(items) != 3 || items[2].Kind != KindState {
		t.Fatalf("layout from template: %s", p.MenuBarItems)
	}
	empty := Normalize(Preferences{MenuBarItems: json.RawMessage(`[]`)})
	if string(empty.MenuBarItems) != "[]" || empty.StatusTemplate != DefaultStatusTemplate {
		t.Errorf("an emptied layout stays empty: %s %q", empty.MenuBarItems, empty.StatusTemplate)
	}
	def := DefaultPreferences()
	if items, _ := DecodeMenuBarItems(def.MenuBarItems); len(items) != 1 || items[0].Kind != KindTotalPower {
		t.Errorf("default layout: %s", def.MenuBarItems)
	}
}
