package app

import (
	"testing"

	"charker/internal/product"
)

func testAppState() AppState {
	return AppState{
		Phase: PhasePolling,
		Device: &DeviceInfo{
			ID:        "mock-a2687",
			Name:      "Anker Prime 160W",
			Connected: true,
		},
		Ports: []PortInfo{
			{ID: "C1", Watts: 42.0},
			{ID: "C2", Watts: 12.5},
			{ID: "C3"},
		},
		Totals:  Totals{Watts: 54.5, Limit: 160, ChargingCount: 1},
		History: []product.Sample{},
	}
}

func TestRenderMenuBar(t *testing.T) {
	a := &App{settings: Settings{
		Locale: "zh",
		MenuBar: []MenuBarItem{
			{Kind: "total", Decimals: 1},
			{Kind: "port", Port: "C2", Decimals: 0},
			{Kind: "state"},
		},
	}}
	got := a.renderMenuBar(testAppState())
	want := "54.5 W  C2 12 W  充电中"
	if got != want {
		t.Fatalf("renderMenuBar = %q, want %q", got, want)
	}
}

func TestRenderMenuBarEnglish(t *testing.T) {
	a := &App{settings: Settings{
		Locale:  "en",
		MenuBar: []MenuBarItem{{Kind: "state"}},
	}}
	got := a.renderMenuBar(testAppState())
	if got != "Charging" {
		t.Fatalf("state text = %q", got)
	}
}

func TestStateTextPhases(t *testing.T) {
	a := &App{settings: Settings{Locale: "en"}}
	cases := map[Phase]string{
		PhaseIdle:         "Not connected",
		PhaseScanning:     "Searching",
		PhaseConnecting:   "Reconnecting",
		PhaseHandshake:    "Reconnecting",
		PhaseReconnecting: "Reconnecting",
		PhaseFailed:       "Offline",
		PhasePolling:      "Charging",
	}
	for phase, want := range cases {
		st := testAppState()
		st.Phase = phase
		if phase == PhasePolling {
			st.Totals.ChargingCount = 1
		}
		if got := a.stateText(st); got != want {
			t.Errorf("stateText(%s) = %q, want %q", phase, got, want)
		}
	}
	// Monitoring with no port delivering reads "Connected".
	st := testAppState()
	st.Totals.ChargingCount = 0
	if got := a.stateText(st); got != "Connected" {
		t.Errorf("idle polling state = %q", got)
	}
}

func TestTrayToolTip(t *testing.T) {
	a := &App{settings: Settings{
		Locale:  "zh",
		MenuBar: []MenuBarItem{{Kind: "total", Decimals: 1}},
	}}
	got := a.trayToolTip(testAppState())
	if got != "Charker · 54.5 W" {
		t.Fatalf("tooltip = %q", got)
	}
}
