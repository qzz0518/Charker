package app

import (
	"testing"
	"time"

	"charker/internal/product"
	"charker/internal/session"
)

// stubEnergy is a deterministic Energy for the mapper tests.
type stubEnergy struct{}

func (stubEnergy) Summary() EnergySummary {
	return EnergySummary{
		Day:   EnergyPeriod{Wh: 12.3, Cost: 0.74, Currency: "CNY"},
		Week:  EnergyPeriod{Wh: 86.5, Cost: 5.19, Currency: "CNY"},
		Month: EnergyPeriod{Wh: 342.8, Cost: 20.57, Currency: "CNY"},
	}
}
func (stubEnergy) Report(rangeArg string) EnergyReport {
	return EnergyReport{Range: rangeArg, Buckets: []EnergyBucket{}, Sessions: []EnergySession{}}
}
func (stubEnergy) Export(rangeArg, format string) ([]byte, error) { return []byte(format), nil }

func testReading() *product.Reading {
	r := &product.Reading{Product: product.ProductA2687, ReceivedAt: time.Now()}
	r.Ports = []product.PortReading{
		{Enabled: true, Status: 1, Watts: 40, Volts: 20, Amps: 2, Protocol: "PD", Cable: "5A"},
		{Enabled: true, Status: 1, Watts: 12, Volts: 9, Amps: 1.33, Protocol: "PPS"},
		{Enabled: false},
	}
	r.TotalWattsOf()
	return r
}

func TestMapPorts(t *testing.T) {
	now := int64(1_761_570_000_000)
	ctrl := product.PortControl{Enabled: true, CountdownMinutes: 30, TimerMinutes: 45}
	settings := product.Settings{PortControls: map[product.PortID]product.PortControl{
		product.PortC1: ctrl,
	}}
	ports, charging, connected, total := mapPorts(testReading(), settings, now, 160)

	if len(ports) != 3 {
		t.Fatalf("got %d ports, want 3", len(ports))
	}
	if ports[0].ID != "C1" || ports[2].ID != "C3" {
		t.Fatalf("port order: %v", []string{ports[0].ID, ports[1].ID, ports[2].ID})
	}
	if ports[0].CountdownEndMs != now+30*60_000 {
		t.Errorf("countdownEndMs = %d, want %d", ports[0].CountdownEndMs, now+30*60_000)
	}
	if ports[0].TimerMinutes != 45 {
		t.Errorf("timerMinutes = %d, want 45", ports[0].TimerMinutes)
	}
	if got := ports[0].BarPct; got < 0.24 || got > 0.26 {
		t.Errorf("barPct = %v, want ~0.25", got)
	}
	if charging != 2 || connected != 2 {
		t.Errorf("charging=%d connected=%d, want 2/2", charging, connected)
	}
	if total != 52 {
		t.Errorf("total = %v, want 52", total)
	}
	if ports[2].Enabled {
		t.Error("C3 should be disabled")
	}
}

func TestMapPortsEmpty(t *testing.T) {
	ports, charging, connected, total := mapPorts(nil, product.Settings{}, 0, 0)
	if len(ports) != 3 || charging != 0 || connected != 0 || total != 0 {
		t.Fatalf("empty reading: ports=%d charging=%d connected=%d total=%v", len(ports), charging, connected, total)
	}
	if ports[0].BarPct != 0 {
		t.Errorf("barPct without limit = %v, want 0", ports[0].BarPct)
	}
}

func TestMapDeviceSettingsDefaults(t *testing.T) {
	d := mapDeviceSettings(product.Settings{})
	if !d.ScreenOn || d.Brightness != 80 || d.Language != "zh" || d.Orientation != "auto" {
		t.Fatalf("defaults = %+v", d)
	}
	if d.AutoLock || d.FixedAllocation || d.Theme != "" {
		t.Fatalf("defaults = %+v", d)
	}
}

func TestMapDeviceSettingsOverrides(t *testing.T) {
	on, lock, fixed := false, true, true
	brightness := 42
	lang, orient, theme := "en", "right", "dark"
	d := mapDeviceSettings(product.Settings{
		ScreenOn:        &on,
		Brightness:      &brightness,
		Language:        &lang,
		Orientation:     &orient,
		AutoLock:        &lock,
		Theme:           &theme,
		FixedAllocation: &fixed,
	})
	if d.ScreenOn || d.Brightness != 42 || d.Language != "en" || d.Orientation != "right" ||
		!d.AutoLock || d.Theme != "dark" || !d.FixedAllocation {
		t.Fatalf("overrides = %+v", d)
	}
}

func TestMapDevicesKeepsCurrent(t *testing.T) {
	current := &DeviceInfo{ID: "mock-a2687", Name: "Anker", Product: "a2687", Connected: true}
	out := mapDevices([]Device{
		{ID: "mock-a2687", Name: "Anker"},
		{ID: "other", Name: "Other", Saved: true},
	}, current)
	if len(out) != 2 {
		t.Fatalf("got %d devices, want 2", len(out))
	}
	if !out[0].Connected || out[0].ID != "mock-a2687" {
		t.Fatalf("current device not first/connected: %+v", out)
	}
	if out[1].ID != "other" || !out[1].Saved {
		t.Fatalf("saved device lost: %+v", out[1])
	}
}

func TestBuildState(t *testing.T) {
	a := &App{
		version:  "0.1.0",
		energy:   stubEnergy{},
		settings: Settings{Locale: "zh", Theme: "system", MenuBar: []MenuBarItem{{Kind: "total", Decimals: 1}}},
		snap:     Snapshot{Phase: PhasePolling, Reading: testReading(), Devices: []Device{}},
	}
	a.snap.History = []product.Sample{{T: 1, W: 42}}
	a.snap.Stats = product.SessionStats{PeakW: 59.4, AvgW: 35.3, EnergyWh: 1.2, ConnectedMs: 1000}
	limit := 160.0
	a.snap.LimitWatts = limit
	a.settings.MenuBar = []MenuBarItem{{Kind: "total", Decimals: 1}}

	a.mu.Lock()
	st := a.buildStateLocked(123)
	a.mu.Unlock()

	if st.App.Version != "0.1.0" || st.App.Platform != "windows" || st.App.Locale != "zh" {
		t.Errorf("app info = %+v", st.App)
	}
	if st.Phase != PhasePolling || len(st.Devices) != 0 || st.Devices == nil {
		t.Errorf("phase/devices: %q %v", st.Phase, st.Devices)
	}
	if st.Totals.Watts != 52 || st.Totals.Limit != 160 || st.Totals.ChargingCount != 2 {
		t.Errorf("totals = %+v", st.Totals)
	}
	if len(st.History) != 1 || len(st.Ports) != 3 {
		t.Errorf("history=%d ports=%d", len(st.History), len(st.Ports))
	}
	if st.Energy.Day.Wh != 12.3 {
		t.Errorf("energy = %+v", st.Energy)
	}
	if st.Settings.WritesEnabled {
		t.Error("writesEnabled should mirror app settings (off by default in the test)")
	}
	if st.LastUpdatedMs != 123 {
		t.Errorf("lastUpdatedMs = %d", st.LastUpdatedMs)
	}
	if st.MenuBar.Items[0].Kind != "total" {
		t.Errorf("menuBar = %+v", st.MenuBar)
	}
}

func TestBuildStateNoticeAndNulls(t *testing.T) {
	a := &App{settings: Settings{Locale: "en", MenuBar: []MenuBarItem{{Kind: "state", Decimals: 0}}}}
	a.snap = Snapshot{Phase: PhaseFailed, Err: "handshake timed out"}
	a.mu.Lock()
	st := a.buildStateLocked(1)
	a.mu.Unlock()
	if st.Device != nil {
		t.Error("device should be nil without a session device")
	}
	if st.Notice == nil || st.Notice.Kind != "error" || st.Notice.Text != "handshake timed out" {
		t.Fatalf("notice = %+v", st.Notice)
	}
	if len(st.Ports) != 3 || len(st.History) != 0 {
		t.Fatalf("ports=%d history=%d", len(st.Ports), len(st.History))
	}
}

func TestPhaseAliases(t *testing.T) {
	if PhaseIdle != session.PhaseIdle || PhaseFailed != session.PhaseFailed {
		t.Fatal("phase constants are not the session's")
	}
}
