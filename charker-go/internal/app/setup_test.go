package app

import "testing"

// The real 160W waits for its account id; the 250W, the simulator and an
// unfinished setup do not ask for it here.
func TestNeedsA2687Account(t *testing.T) {
	a := New(Config{DataDir: t.TempDir()})
	const owner = "0123456789abcdef0123456789abcdef01234567"
	cases := []struct {
		setup, demo bool
		mode, owner string
		want        bool
	}{
		{true, false, "bluetooth", "", true},
		{true, false, "bluetooth", owner, false},
		{true, false, "cloud", "", false},
		{true, true, "bluetooth", "", false},
		{false, false, "bluetooth", "", false},
	}
	for _, c := range cases {
		a.mu.Lock()
		a.prefs.InitialSetupCompleted = c.setup
		a.prefs.DemoMode, a.demo = c.demo, c.demo
		a.prefs.ConnectionMode = c.mode
		a.prefs.OwnerUserID = c.owner
		got := a.needsA2687AccountLocked()
		a.mu.Unlock()
		if got != c.want {
			t.Errorf("setup=%v demo=%v mode=%q owner=%v: got %v, want %v", c.setup, c.demo, c.mode, c.owner != "", got, c.want)
		}
	}
}
