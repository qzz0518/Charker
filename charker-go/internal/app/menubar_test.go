package app

import (
	"encoding/json"
	"testing"

	"charker/internal/prefs"
	"charker/internal/product"
	"charker/internal/session"
)

// Fixtures shared with web/js/pages/menubar.js (menuBarSelfTest): the
// preview and the tooltip render through twins and must agree.
func fixtureTelemetry() *session.Telemetry {
	return &session.Telemetry{Ports: []session.PortTelemetry{
		{Port: "C1", StatusCode: 1, Voltage: 20, Current: 3.25, Power: 65},
		{Port: "C2", StatusCode: 1, Voltage: 5, Current: 0, Power: 0},
		{Port: "C3", StatusCode: 0, Voltage: 0, Current: 0, Power: 0},
	}}
}

func items(t *testing.T, raw string) []prefs.MenuBarItem {
	t.Helper()
	list, ok := prefs.DecodeMenuBarItems(json.RawMessage(raw))
	if !ok {
		t.Fatalf("bad fixture %s", raw)
	}
	return list
}

func TestRenderReadout(t *testing.T) {
	in := readoutInput{
		ports:      product.ProductA2687.PortIDs(),
		telemetry:  fixtureTelemetry(),
		stateLabel: "已连接",
		deviceName: "Anker Prime 160W",
		decimals:   1,
		nicknames:  []string{"", "iPad", ""},
		portsText:  func(n int) string { return string(rune('0'+n)) + " 口" },
		sampleText: "文本",
	}
	cases := []struct {
		name   string
		layout string
		hide   bool
		want   string
	}{
		{"total", `[{"kind":"totalPower"}]`, false, "65.0 W"},
		{"bare", `[{"kind":"totalPower","showsUnit":false,"decimals":0}]`, false, "65"},
		{"three ports", `[{"kind":"portPower","port":0},{"kind":"separator","label":"·"},{"kind":"portPower","port":1},{"kind":"separator","label":"·"},{"kind":"portPower","port":2}]`, false, "C1 65.0 W · iPad 0.0 W · C3 0.0 W"},
		{"hide idle runs", `[{"kind":"portPower","port":0},{"kind":"separator","label":"·"},{"kind":"portPower","port":1},{"kind":"separator","label":"|"},{"kind":"portPower","port":2}]`, true, "C1 65.0 W"},
		{"label wins", `[{"kind":"portPower","port":1,"label":"Pad"},{"kind":"portPower","port":0,"showsPortName":false,"decimals":2}]`, false, "Pad 0.0 W 65.00 W"},
		{"ports and state", `[{"kind":"totalPower","label":"Σ"},{"kind":"separator"},{"kind":"portsCount","systemContent":"activePortsCount"},{"kind":"separator","label":"|"},{"kind":"state"}]`, false, "Σ 65.0 W · 1 口 | 已连接"},
		{"text", `[{"kind":"deviceName"},{"kind":"text","label":""},{"kind":"text","systemContent":"sampleText"}]`, false, "Anker Prime 160W 文本"},
		{"empty", `[]`, false, ""},
		{"other product's port", `[{"kind":"totalPower"},{"kind":"separator"},{"kind":"portPower","port":3}]`, false, "65.0 W"},
	}
	for _, c := range cases {
		in.hideIdlePorts = c.hide
		if got := renderReadout(items(t, c.layout), in); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
	in.telemetry = nil
	if got := renderReadout(items(t, `[{"kind":"totalPower"},{"kind":"separator"},{"kind":"portPower","port":0}]`), in); got != "— · C1 —" {
		t.Errorf("placeholders: got %q", got)
	}
}

func TestTrayToolTip(t *testing.T) {
	a := New(Config{})
	st := a.currentState()
	st.Session.Phase = PhasePolling
	st.Session.Telemetry = fixtureTelemetry()
	if got := a.trayToolTip(st); got != "Charker · 65.0 W" {
		t.Errorf("live: %q", got)
	}
	st.Prefs.ShowIconOnly = true // the digits are off; the tooltip stays
	if got := a.trayToolTip(st); got != "Charker · 65.0 W" {
		t.Errorf("digits off: %q", got)
	}
	st.Prefs.ShowIconOnly = false
	st.Session.Phase = PhaseReconnecting
	if got := a.trayToolTip(st); got != "Charker · 重连中" {
		t.Errorf("offline: %q", got)
	}
	long := truncateUTF16(repeat("功率 ", 80), trayToolTipLimit)
	if n := len([]rune(long)); n > trayToolTipLimit {
		t.Errorf("tooltip not truncated: %d", n)
	}
}

func repeat(s string, n int) string {
	out := ""
	for range n {
		out += s
	}
	return out
}
