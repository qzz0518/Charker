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

func TestDefaultsAndRoundTrip(t *testing.T) {
	dir := t.TempDir()
	s := NewStore(dir)
	def := s.LoadPreferences()
	if def.Locale != "zh" || def.Theme != "system" || def.PollSeconds != 6 {
		t.Fatalf("defaults = %+v", def)
	}
	if len(def.MenuBar.Items) != 1 || def.MenuBar.Items[0].Kind != "total" || def.MenuBar.Items[0].Decimals != 1 {
		t.Fatalf("default menu bar = %+v", def.MenuBar)
	}
	if def.WindowWidth != 969 || def.WindowHeight != 840 {
		t.Fatalf("default window = %dx%d", def.WindowWidth, def.WindowHeight)
	}

	p := def
	p.Locale = "en"
	p.Theme = "light"
	p.MockMode = true
	p.LastDeviceID = "mock-a2687"
	p.WritesEnabled = true
	p.OwnerUserID = "0123456789abcdef0123456789abcdef01234567"
	p.PollSeconds = 10
	p.EnergyCurrency = "USD"
	p.EnergyPricePerKWh = 0.42
	p.MenuBar = MenuBarConfig{Items: []MenuBarItem{
		{Kind: "total", Decimals: 2},
		{Kind: "port", Port: "C2", Decimals: 1},
		{Kind: "state", Decimals: 0},
	}}
	p.WindowX, p.WindowY = 100, 50
	p.WindowWidth, p.WindowHeight = 1120, 760
	p.WindowMaximized = true
	p.LastSection = "energy"
	if err := s.SavePreferences(p); err != nil {
		t.Fatalf("save: %v", err)
	}
	got := NewStore(dir).LoadPreferences()
	if got.Locale != "en" || got.Theme != "light" || !got.MockMode || got.LastDeviceID != "mock-a2687" {
		t.Fatalf("round-trip prefs = %+v", got)
	}
	if !got.WritesEnabled || got.OwnerUserID != p.OwnerUserID || got.PollSeconds != 10 || got.EnergyCurrency != "USD" || got.EnergyPricePerKWh != 0.42 {
		t.Fatalf("round-trip advanced = %+v", got)
	}
	if len(got.MenuBar.Items) != 3 || got.MenuBar.Items[1].Port != "C2" {
		t.Fatalf("round-trip menu bar = %+v", got.MenuBar)
	}
	if got.WindowWidth != 1120 || got.WindowX != 100 || !got.WindowMaximized || got.LastSection != "energy" {
		t.Fatalf("round-trip window = %+v", got)
	}
	// At most the prefs file and the saved file exist; no temp files leaked.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if filepath.Ext(e.Name()) == ".tmp" || (len(e.Name()) > 4 && e.Name()[len(e.Name())-4:] == ".tmp") {
			t.Fatalf("temp file leaked: %s", e.Name())
		}
	}
}

func TestCorruptPreferencesFallsBackToDefaults(t *testing.T) {
	dir := t.TempDir()
	s := NewStore(dir)
	if err := os.WriteFile(filepath.Join(dir, PreferencesFile), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := s.LoadPreferences()
	if got.Locale != "zh" || got.Theme != "system" || got.PollSeconds != 6 {
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

func TestPreferencesNormalization(t *testing.T) {
	dir := t.TempDir()
	s := NewStore(dir)
	raw := `{"locale":"fr","theme":"neon","pollSeconds":1,"energyCurrency":"usd","energyPricePerKWh":-3,
	        "ownerUserId":"nope","windowWidth":10,"windowHeight":10,
	        "menuBar":{"items":[{"kind":"nope"},{"kind":"port","port":"C9"},{"kind":"port","port":"C1","decimals":9},{"kind":"port","port":"C1"},{"kind":"total","decimals":-2}]}}`
	if err := os.WriteFile(filepath.Join(dir, PreferencesFile), []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
	p := s.LoadPreferences()
	if p.Locale != "zh" || p.Theme != "system" || p.PollSeconds != 6 {
		t.Fatalf("normalized enums = %+v", p)
	}
	if p.EnergyCurrency != "CNY" || p.EnergyPricePerKWh != 0 || p.OwnerUserID != "" {
		t.Fatalf("normalized values = %+v", p)
	}
	if p.WindowWidth != 969 || p.WindowHeight != 840 {
		t.Fatalf("normalized window = %dx%d", p.WindowWidth, p.WindowHeight)
	}
	if len(p.MenuBar.Items) != 2 {
		t.Fatalf("menu bar = %+v, want 2 items", p.MenuBar)
	}
	if p.MenuBar.Items[0].Kind != "port" || p.MenuBar.Items[0].Port != "C1" || p.MenuBar.Items[0].Decimals != 3 {
		t.Fatalf("first item = %+v", p.MenuBar.Items[0])
	}
	if p.MenuBar.Items[1].Kind != "total" || p.MenuBar.Items[1].Decimals != 0 {
		t.Fatalf("second item = %+v", p.MenuBar.Items[1])
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

func TestSaveMenuBar(t *testing.T) {
	s := newTestStore(t)
	cfg := MenuBarConfig{Items: []MenuBarItem{{Kind: "port", Port: "C3", Decimals: 2}}}
	if err := s.SaveMenuBar(cfg); err != nil {
		t.Fatalf("save menu bar: %v", err)
	}
	got := s.LoadMenuBar()
	if len(got.Items) != 1 || got.Items[0].Port != "C3" || got.Items[0].Decimals != 2 {
		t.Fatalf("menu bar = %+v", got)
	}
	// Invalid layout falls back to the default.
	if err := s.SaveMenuBar(MenuBarConfig{Items: []MenuBarItem{{Kind: "bogus"}}}); err != nil {
		t.Fatalf("save invalid: %v", err)
	}
	got = s.LoadMenuBar()
	if len(got.Items) != 1 || got.Items[0].Kind != "total" {
		t.Fatalf("fallback menu bar = %+v", got)
	}
}
