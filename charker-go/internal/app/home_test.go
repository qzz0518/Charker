package app

import (
	"testing"
	"time"

	"charker/internal/a2345"
	"charker/internal/cloudsession"
	"charker/internal/matter"
	"charker/internal/product"
)

func TestHomeProduct(t *testing.T) {
	a := New(Config{DataDir: t.TempDir()})
	set := func(enabled, demo, setup bool, mode string) product.ChargerProduct {
		a.mu.Lock()
		defer a.mu.Unlock()
		a.prefs.MatterEnabled = enabled
		a.prefs.DemoMode, a.demo = demo, demo
		a.prefs.InitialSetupCompleted = setup
		a.prefs.ConnectionMode = mode
		return a.homeProductLocked()
	}
	cases := []struct {
		enabled, demo, setup bool
		mode                 string
		want                 product.ChargerProduct
	}{
		{true, false, true, "", product.ProductA2687},
		{true, false, true, "cloud", product.ProductA2345},
		{false, false, true, "", ""},
		// The simulator never reaches Home, nor does an unfinished setup.
		{true, true, true, "", ""},
		{true, false, false, "", ""},
	}
	for _, c := range cases {
		if got := set(c.enabled, c.demo, c.setup, c.mode); got != c.want {
			t.Errorf("enabled=%v demo=%v setup=%v mode=%q: got %q, want %q", c.enabled, c.demo, c.setup, c.mode, got, c.want)
		}
	}
}

func TestHomeA2687Refusal(t *testing.T) {
	r := &product.Reading{Product: product.ProductA2687, Ports: make([]product.PortReading, 3)}
	live := Snapshot{Phase: PhasePolling, Reading: r}
	if got := homeA2687Refusal(false, true, live, product.PortC1); got != "在「高级」里打开「允许端口开关」后才能操作" {
		t.Errorf("writes off: %q", got)
	}
	if got := homeA2687Refusal(true, true, Snapshot{Phase: PhaseReconnecting, Reading: r}, product.PortC1); got != "需要先连上充电器" {
		t.Errorf("not polling: %q", got)
	}
	if got := homeA2687Refusal(true, false, live, product.PortC1); got != "需要先连上充电器" {
		t.Errorf("no session: %q", got)
	}
	if got := homeA2687Refusal(true, true, live, product.PortC4); got != "需要先连上充电器" {
		t.Errorf("port the 160W lacks: %q", got)
	}
	if got := homeA2687Refusal(true, true, live, product.PortC2); got != "" {
		t.Errorf("allowed: %q", got)
	}
}

func TestHomeGroups(t *testing.T) {
	l := matter.NewLayout(product.ProductA2345, matter.Grouped)
	want := []a2345.PortGroup{a2345.GroupC1, a2345.GroupC2, a2345.GroupC3, a2345.GroupC4, a2345.GroupUSBA}
	for i, target := range l.Targets {
		g, ok := homeGroup(target)
		if !ok || g != want[i] {
			t.Errorf("%s: got %v %v, want %v", target.Label, g, ok, want[i])
		}
	}
}

func TestCloudSwitches(t *testing.T) {
	if cloudSwitches(&cloudsession.Snapshot{}) != nil {
		t.Fatal("switches before the first settings snapshot")
	}
	cs := &cloudsession.Snapshot{}
	cs.A2345.Settings = &cloudsession.SettingsView{Groups: []cloudsession.GroupView{
		{Group: "C1", Ports: []string{"C1"}, IsOn: true},
		{Group: "A1/A2", Ports: []string{"A1", "A2"}, IsOn: false},
	}}
	sw := cloudSwitches(cs)
	if !sw[product.PortC1] || sw[product.PortA1] || len(sw) != 3 {
		t.Fatalf("switches = %v", sw)
	}
	states := homeStates(matter.NewLayout(product.ProductA2345, matter.Grouped), Snapshot{}, cs, nil)
	if len(states) != 5 || !states[0].On || states[4].On {
		t.Fatalf("states = %+v", states)
	}
}

// Without a helper beside the exe Home says so and nothing else happens.
func TestHomeWithoutHelper(t *testing.T) {
	t.Setenv(homeHelperEnv, "")
	a := New(Config{DataDir: t.TempDir()})
	defer a.shutdownHome()
	if st := a.State().Home; st.Whole.State != matter.StateOff || st.Name != "Charker 160W" || len(st.Tiles) != 3 {
		t.Fatalf("initial home state = %+v", st)
	}
	a.mu.Lock()
	a.prefs.MatterEnabled = true
	a.prefs.InitialSetupCompleted = true
	a.mu.Unlock()
	a.publishNow()
	deadline := time.Now().Add(2 * time.Second)
	for {
		st := a.State().Home
		if st.Whole.State == matter.StateUnavailable && st.Ports.State == matter.StateUnavailable {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("home state = %+v", st)
		}
		time.Sleep(10 * time.Millisecond)
	}
	a.mu.Lock()
	a.prefs.MatterEnabled = false
	a.mu.Unlock()
	a.publishNow()
	deadline = time.Now().Add(2 * time.Second)
	for a.State().Home.Whole.State != matter.StateOff {
		if time.Now().After(deadline) {
			t.Fatalf("home still %+v after switching off", a.State().Home)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// A snapshot the simulator left behind never reaches Home.
func TestHomeStatesIgnoreSimulator(t *testing.T) {
	l := matter.NewLayout(product.ProductA2687, matter.Grouped)
	r := &product.Reading{Product: product.ProductA2687, Ports: []product.PortReading{{Enabled: true, Watts: 60, Volts: 20, Amps: 3}, {}, {}}}
	snap := Snapshot{Phase: PhasePolling, Reading: r, Device: &Device{Mock: true}}
	if s := homeStates(l, snap, nil, nil); s[0] != (matter.PortState{}) {
		t.Fatalf("simulated reading reached Home: %+v", s[0])
	}
	snap.Device.Mock = false
	if s := homeStates(l, snap, nil, nil); !s[0].On || s[0].PowerMW != 60000 {
		t.Fatalf("live reading = %+v", s[0])
	}
}
