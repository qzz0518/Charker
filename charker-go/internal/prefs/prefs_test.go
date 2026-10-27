package prefs

import (
	"os"
	"path/filepath"
	"testing"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	return NewStore(t.TempDir())
}

func TestCorruptPreferencesFallsBackToDefaults(t *testing.T) {
	dir := t.TempDir()
	s := NewStore(dir)
	if err := os.WriteFile(filepath.Join(dir, PreferencesFile), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := s.LoadPreferences()
	if got.Locale != "" || got.Appearance != "system" || got.PollSeconds != 6 {
		t.Fatalf("corrupt load = %+v, want defaults", got)
	}
	if _, err := os.Stat(filepath.Join(dir, PreferencesFile+corruptSuffix)); err != nil {
		t.Fatalf("corrupt backup missing: %v", err)
	}
	// A second load is clean (the corrupt file was moved away).
	if _, err := os.Stat(filepath.Join(dir, PreferencesFile)); !os.IsNotExist(err) {
		t.Fatalf("corrupt file should be quarantined, stat err = %v", err)
	}
}

func TestSavedChargerRoundTrip(t *testing.T) {
	dir := t.TempDir()
	s := NewStore(dir)
	list := []SavedCharger{
		{ID: "aa", Nickname: "  Desk  ", SerialNumber: "ASHD00000000001", LastConnectedAt: 1000},
		{ID: "bb", SerialNumber: "ASHD00000000002"},
		{ID: "", LastConnectedAt: 5},
		{ID: "aa", Nickname: "dup", LastConnectedAt: 2000},
	}
	if err := s.SaveSavedChargers(list); err != nil {
		t.Fatalf("save: %v", err)
	}
	got := NewStore(dir).LoadSavedChargers()
	if len(got) != 2 {
		t.Fatalf("loaded %d entries, want 2: %+v", len(got), got)
	}
	if got[0].ID != "aa" || got[0].Nickname != "Desk" {
		t.Fatalf("first = %+v", got[0])
	}
	if got[1].ID != "bb" || got[1].LastConnectedAt != 0 {
		t.Fatalf("second = %+v", got[1])
	}
	if n := DisplayName(got[1]); n != "Anker Prime 160W · 0002" {
		t.Fatalf("display name = %q", n)
	}
}

func TestCorruptSavedChargers(t *testing.T) {
	dir := t.TempDir()
	s := NewStore(dir)
	if err := os.WriteFile(filepath.Join(dir, SavedFile), []byte(`{"oops":true}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := s.LoadSavedChargers(); len(got) != 0 {
		t.Fatalf("corrupt load = %+v, want empty", got)
	}
	if _, err := os.Stat(filepath.Join(dir, SavedFile+corruptSuffix)); err != nil {
		t.Fatalf("backup missing: %v", err)
	}

	// Entry-tolerant: one bad record dropped, valid ones survive.
	raw := `[{"id":"aa","nickname":"x"},{"id":5},{"nomatch":true},{"id":"bb"}]`
	if err := os.WriteFile(filepath.Join(dir, SavedFile), []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
	got := s.LoadSavedChargers()
	if len(got) != 2 || got[0].ID != "aa" || got[1].ID != "bb" {
		t.Fatalf("tolerant load = %+v", got)
	}
}

func TestUpsertSavedRules(t *testing.T) {
	list := []SavedCharger{}
	// First connection.
	list = UpsertSaved(list, SavedCharger{ID: "id-1", SerialNumber: "SERIAL0001", LastConnectedAt: 100})
	if len(list) != 1 || list[0].Nickname != "" {
		t.Fatalf("first connection = %+v", list)
	}
	// Rename.
	list = SetNickname(list, "id-1", "  Home\nDesk  ")
	if list[0].Nickname != "Home Desk" {
		t.Fatalf("nickname = %q", list[0].Nickname)
	}
	// Reconnect, same id: timestamp refreshes, nickname kept.
	list = UpsertSaved(list, SavedCharger{ID: "id-1", LastConnectedAt: 200})
	if len(list) != 1 || list[0].LastConnectedAt != 200 || list[0].Nickname != "Home Desk" {
		t.Fatalf("same-id reconnect = %+v", list)
	}
	// New host id with the known serial takes over the entry, keeps nickname.
	list = UpsertSaved(list, SavedCharger{ID: "id-2", SerialNumber: "SERIAL0001", LastConnectedAt: 300})
	if len(list) != 1 || list[0].ID != "id-2" || list[0].Nickname != "Home Desk" {
		t.Fatalf("serial takeover = %+v", list)
	}
	// Second charger.
	list = UpsertSaved(list, SavedCharger{ID: "id-3", SerialNumber: "SERIAL0002", LastConnectedAt: 400})
	if len(list) != 2 || list[0].ID != "id-3" {
		t.Fatalf("reconnect order = %+v", list)
	}
	// Never-connected entries sort last, in insertion order.
	list = UpsertSaved(list, SavedCharger{ID: "id-4"})
	list = UpsertSaved(list, SavedCharger{ID: "id-5"})
	order := ReconnectOrder(list)
	want := []string{"id-3", "id-2", "id-4", "id-5"}
	if len(order) != len(want) {
		t.Fatalf("order = %v, want %v", order, want)
	}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("order = %v, want %v", order, want)
		}
	}
	// Nickname cap.
	list = SetNickname(list, "id-3", "abcdefghijklmnopqrstuvwxyz0123456789")
	if n := list[0].Nickname; n != "abcdefghijklmnopqrstuvwx" {
		t.Fatalf("nickname cap = %q", n)
	}
	// Remove.
	list = RemoveSaved(list, "id-3")
	if _, ok := FindSaved(list, "id-3"); ok {
		t.Fatal("id-3 not removed")
	}
	if len(list) != 3 {
		t.Fatalf("after remove = %+v", list)
	}
}

func TestDisplayName(t *testing.T) {
	cases := []struct {
		c    SavedCharger
		want string
	}{
		{SavedCharger{Nickname: "Desk"}, "Desk"},
		{SavedCharger{SerialNumber: "ASHD12340000A1"}, "Anker Prime 160W · 00A1"},
		{SavedCharger{}, "Anker Prime 160W"},
		{SavedCharger{Product: "a2345", SerialNumber: "SERIAL9999"}, "Anker Prime 250W · 9999"},
	}
	for _, tc := range cases {
		if got := DisplayName(tc.c); got != tc.want {
			t.Errorf("DisplayName(%+v) = %q, want %q", tc.c, got, tc.want)
		}
	}
}

func TestPreferencesRoundTripAndNormalize(t *testing.T) {
	st := NewStore(t.TempDir())
	p := st.LoadPreferences()
	if p.Appearance != "system" || p.Decimals != 1 || p.PollSeconds != 6 || len(p.PortNicknames) != PortCount {
		t.Fatalf("defaults = %+v", p)
	}
	p.Appearance = "neon"
	p.PollSeconds = 1
	p.PowerChartMaximum = 75
	p.EnergyCurrencyCode = " usd "
	p.PortNicknames = []string{"  Mac  ", "a\nb"}
	p.HideIdlePorts = true
	if err := st.SavePreferences(p); err != nil {
		t.Fatal(err)
	}
	got := st.LoadPreferences()
	if got.Appearance != "system" || got.PollSeconds != 6 || got.PowerChartMaximum != 0 || got.EnergyCurrencyCode != "USD" {
		t.Fatalf("normalized = %+v", got)
	}
	if !got.HideIdlePorts || got.PortNicknames[0] != "Mac" || got.PortNicknames[1] != "a b" || got.PortNicknames[2] != "" {
		t.Fatalf("round trip = %+v", got)
	}
}
