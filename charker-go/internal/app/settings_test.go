package app

import (
	"testing"

	"charker/internal/prefs"
)

func TestNormalizeSettings(t *testing.T) {
	s := Settings{Locale: "de", Theme: "neon", MenuBar: []MenuBarItem{
		{Kind: "total", Decimals: 9},
		{Kind: "port", Port: "C2", Decimals: 2},
		{Kind: "bogus"},
		{Kind: "port"},
	}}
	s.Normalize()
	if s.Locale != "zh" || s.Theme != "dark" || s.Currency != "CNY" {
		t.Fatalf("defaults not applied: %+v", s)
	}
	if len(s.MenuBar) != 2 {
		t.Fatalf("menuBar = %+v, want 2 valid items", s.MenuBar)
	}
	if s.MenuBar[0].Decimals != 3 || s.MenuBar[1].Kind != "port" || s.MenuBar[1].Port != "C2" {
		t.Fatalf("menuBar = %+v", s.MenuBar)
	}
}

func TestNormalizeSettingsEmptyMenuBar(t *testing.T) {
	s := Settings{Locale: "en", Theme: "dark", MenuBar: []MenuBarItem{}}
	s.Normalize()
	if len(s.MenuBar) != 1 || s.MenuBar[0].Kind != "total" {
		t.Fatalf("menuBar = %+v", s.MenuBar)
	}
}

func TestSettingsFromPreferences(t *testing.T) {
	p := prefs.DefaultPreferences()
	p.Locale = "en"
	p.Theme = "dark"
	p.MockMode = true
	p.LastDeviceID = "AA:BB"
	p.EnergyCurrency = "USD"
	p.MenuBar = prefs.MenuBarConfig{Items: []prefs.MenuBarItem{{Kind: "port", Port: "C1", Decimals: 2}}}
	s := settingsFromPreferences(p)
	if s.Locale != "en" || s.Theme != "dark" || !s.Mock || s.LastDevice != "AA:BB" ||
		s.Currency != "USD" || len(s.MenuBar) != 1 || s.MenuBar[0].Port != "C1" {
		t.Fatalf("settings = %+v", s)
	}
}

func TestSettingsFromPreferencesCorrupt(t *testing.T) {
	// A preferences struct with unusable values still maps to safe defaults.
	s := settingsFromPreferences(prefs.Preferences{Locale: "xx", Theme: "neon", MenuBar: prefs.MenuBarConfig{}})
	if s.Locale != "zh" || s.Theme != "dark" || len(s.MenuBar) != 1 {
		t.Fatalf("settings = %+v", s)
	}
}

func TestSaveSettingsPreservesForeignPrefs(t *testing.T) {
	store := prefs.NewStore(t.TempDir())
	p := prefs.DefaultPreferences()
	p.PollSeconds = 9
	p.EnergyPricePerKWh = 0.42
	if err := store.SavePreferences(p); err != nil {
		t.Fatal(err)
	}
	a := &App{
		prefs: store,
		settings: Settings{
			Locale:        "en",
			Theme:         "light",
			Mock:          true,
			LastDevice:    "mock-a2687",
			Currency:      "USD",
			WritesEnabled: true,
			MenuBar:       []MenuBarItem{{Kind: "port", Port: "C2", Decimals: 0}},
		},
	}
	a.saveSettings()

	got := store.LoadPreferences()
	if got.Locale != "en" || got.Theme != "light" || !got.MockMode ||
		got.LastDeviceID != "mock-a2687" || got.EnergyCurrency != "USD" || !got.WritesEnabled {
		t.Fatalf("preferences = %+v", got)
	}
	if got.PollSeconds != 9 || got.EnergyPricePerKWh != 0.42 {
		t.Fatalf("foreign preferences clobbered: %+v", got)
	}
	if len(got.MenuBar.Items) != 1 || got.MenuBar.Items[0].Port != "C2" {
		t.Fatalf("menuBar = %+v", got.MenuBar.Items)
	}
}

func TestSaveSettingsWithoutStore(t *testing.T) {
	a := &App{settings: Settings{Locale: "en"}}
	a.saveSettings() // must not panic without a store
}

func TestParseMenuBar(t *testing.T) {
	items, err := parseMenuBar(`[{"kind":"total","decimals":1},{"kind":"port","port":"C2","decimals":0}]`)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 || items[1].Port != "C2" {
		t.Fatalf("items = %+v", items)
	}
	for _, bad := range []string{``, `null`, `[]`, `[{"kind":"nope"}]`, `[{"kind":"port"}]`, `{`} {
		if _, err := parseMenuBar(bad); err == nil {
			t.Errorf("parseMenuBar(%q) should fail", bad)
		}
	}
}

func TestNormalizeLocaleAndTheme(t *testing.T) {
	for in, want := range map[string]string{"zh": "zh", "zh-Hans": "zh", "zh-CN": "zh", "en": "en", "en-US": "en", " EN ": "en"} {
		got, err := normalizeLocale(in)
		if err != nil || got != want {
			t.Errorf("normalizeLocale(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	if _, err := normalizeLocale("fr"); err == nil {
		t.Error("normalizeLocale(fr) should fail")
	}
	for in, want := range map[string]string{"system": "system", "auto": "system", "": "system", "dark": "dark", "Light": "light"} {
		got, err := normalizeTheme(in)
		if err != nil || got != want {
			t.Errorf("normalizeTheme(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	if _, err := normalizeTheme("neon"); err == nil {
		t.Error("normalizeTheme(neon) should fail")
	}
}

func TestLocaleTag(t *testing.T) {
	if localeTag("zh") != "zh-Hans" || localeTag("en") != "en" {
		t.Fatal("localeTag mapping changed")
	}
}
