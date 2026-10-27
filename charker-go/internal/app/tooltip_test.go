package app

import (
	"strings"
	"testing"
	"unicode/utf16"

	"charker/internal/session"
)

func fixtureTelemetry() *session.Telemetry {
	return &session.Telemetry{Ports: []session.PortTelemetry{
		{Port: "C1", StatusCode: 1, Voltage: 20, Current: 3.25, Power: 65},
		{Port: "C2", StatusCode: 1, Voltage: 5, Current: 0, Power: 0},
		{Port: "C3", StatusCode: 0, Voltage: 0, Current: 0, Power: 0},
	}}
}

func TestTrayToolTip(t *testing.T) {
	a := New(Config{})
	st := a.currentState()
	if got := a.trayToolTip(st); got != "Charker · 搜索中" {
		t.Errorf("idle = %q", got)
	}

	st.Session.Phase = PhasePolling
	st.Session.Telemetry = fixtureTelemetry()
	want := "Anker Prime 160W · 65.0 W\nC1 65.0 W · C2 0.0 W · C3 已关闭"
	if got := a.trayToolTip(st); got != want {
		t.Errorf("live = %q, want %q", got, want)
	}

	st.Prefs.HideIdlePorts = true
	st.Prefs.Decimals = 0
	st.Session.IsStale = true
	want = "Anker Prime 160W · 65 W · 数据陈旧\nC1 65 W"
	if got := a.trayToolTip(st); got != want {
		t.Errorf("hidden idle = %q, want %q", got, want)
	}
}

func TestTrayToolTipSixPorts(t *testing.T) {
	a := New(Config{})
	st := a.currentState()
	st.App.Product = "A2345"
	st.Session.Phase = PhasePolling
	st.Session.Telemetry = &session.Telemetry{}
	for _, id := range []string{"C1", "C2", "C3", "C4", "A1", "A2"} {
		st.Session.Telemetry.Ports = append(st.Session.Telemetry.Ports,
			session.PortTelemetry{Port: id, StatusCode: 1, Voltage: 20, Current: 5, Power: 100})
	}
	got := a.trayToolTip(st)
	lines := strings.Split(got, "\n")
	if len(lines) != 3 || !strings.HasPrefix(lines[0], "Anker Prime 250W · 600.0 W") || !strings.HasPrefix(lines[2], "C4 ") {
		t.Errorf("six ports = %q", got)
	}
	if n := len(utf16.Encode([]rune(got))); n > trayToolTipLimit {
		t.Errorf("tooltip is %d UTF-16 units", n)
	}
}
