package app

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	"charker/internal/prefs"

	"github.com/egoist/mygo"
)

// Settings is the app's view of the persisted preferences that the Windows
// shell owns. The file itself is internal/prefs' preferences.json under
// App.Path(PathUserData); device settings (brightness, language, …) live in
// the charger and in the session snapshot instead.
type Settings struct {
	// Locale is the UI language: "zh" (default) or "en".
	Locale string `json:"locale"`
	// Theme is the app appearance: "system" (default), "dark" or "light".
	Theme string `json:"theme"`
	// Mock is the demo mode: the session engine runs the simulated charger.
	Mock bool `json:"mockMode"`
	// LastDevice is the id of the charger the user connected to last.
	LastDevice string `json:"lastDeviceId"`
	// MenuBar is the tray readout configuration (also in AppState.menuBar).
	MenuBar []MenuBarItem `json:"menuBar"`
	// Currency is the currency of the estimated energy cost.
	Currency string `json:"currency"`
	// WritesEnabled is the port-switching opt-in (Advanced screen).
	WritesEnabled bool `json:"writesEnabled"`
}

// DefaultSettings returns the settings of a first run: Charker's design is
// dark by default ("system" stays a user choice), and port switching is off
// until the user allows it in Advanced.
func DefaultSettings() Settings {
	return Settings{
		Locale:   "zh",
		Theme:    "dark",
		Currency: "CNY",
		MenuBar:  []MenuBarItem{{Kind: "total", Decimals: 1}},
	}
}

// preferencesExist reports whether the preferences file already exists, i.e.
// whether this is a first run.
func preferencesExist(store *prefs.Store) bool {
	if store == nil || store.Dir() == "" {
		return false
	}
	_, err := os.Stat(filepath.Join(store.Dir(), prefs.PreferencesFile))
	return err == nil
}

// settingsFromPreferences maps the persisted preferences into the app's view.
func settingsFromPreferences(p prefs.Preferences) Settings {
	s := Settings{
		Locale:        p.Locale,
		Theme:         p.Theme,
		Mock:          p.MockMode,
		LastDevice:    p.LastDeviceID,
		Currency:      p.EnergyCurrency,
		MenuBar:       menuBarFromPrefs(p.MenuBar.Items),
		WritesEnabled: p.WritesEnabled,
	}
	s.Normalize()
	return s
}

// Normalize fills defaults and drops values the app cannot show, so a
// corrupted or half-written preferences file never breaks the UI.
func (s *Settings) Normalize() {
	d := DefaultSettings()
	if s.Locale != "zh" && s.Locale != "en" {
		s.Locale = d.Locale
	}
	switch s.Theme {
	case "system", "dark", "light":
	default:
		s.Theme = d.Theme
	}
	if s.Currency == "" {
		s.Currency = d.Currency
	}
	s.MenuBar = sanitizeMenuBar(s.MenuBar)
}

// sanitizeMenuBar keeps only items AppState can carry: kind total|port|device|state,
// a port label for "port", decimals 0..3.
func sanitizeMenuBar(items []MenuBarItem) []MenuBarItem {
	out := make([]MenuBarItem, 0, len(items))
	for _, it := range items {
		switch it.Kind {
		case "total", "device", "state":
			it.Port = ""
		case "port":
			if it.Port == "" {
				continue
			}
		default:
			continue
		}
		it.Decimals = clampInt(it.Decimals, 0, 3)
		out = append(out, it)
	}
	if len(out) == 0 {
		return []MenuBarItem{{Kind: "total", Decimals: 1}}
	}
	return out
}

// menuBarFromPrefs converts the persisted layout to the AppState shape.
func menuBarFromPrefs(items []prefs.MenuBarItem) []MenuBarItem {
	out := make([]MenuBarItem, 0, len(items))
	for _, it := range items {
		out = append(out, MenuBarItem{Kind: it.Kind, Port: it.Port, Decimals: it.Decimals})
	}
	return out
}

// menuBarToPrefs converts the AppState shape to the persisted layout.
func menuBarToPrefs(items []MenuBarItem) []prefs.MenuBarItem {
	out := make([]prefs.MenuBarItem, 0, len(items))
	for _, it := range items {
		out = append(out, prefs.MenuBarItem{Kind: it.Kind, Port: it.Port, Decimals: it.Decimals})
	}
	return out
}

// saveSettings writes the app's settings into preferences.json, preserving the
// fields the shell does not own (poll cadence, energy price, …).
func (a *App) saveSettings() {
	a.mu.Lock()
	s := a.settings
	store := a.prefs
	forceMock := a.forceMock
	a.mu.Unlock()
	if store == nil {
		return
	}
	p := store.LoadPreferences()
	p.Locale = s.Locale
	p.Theme = s.Theme
	if !forceMock {
		p.MockMode = s.Mock
	}
	p.LastDeviceID = s.LastDevice
	p.EnergyCurrency = s.Currency
	p.WritesEnabled = s.WritesEnabled
	p.MenuBar = prefs.MenuBarConfig{Items: menuBarToPrefs(s.MenuBar)}
	if err := store.SavePreferences(p); err != nil {
		log.Printf("app: saving preferences: %v", err)
	}
}

// localeTag maps the UI locale ("zh"/"en") to the BCP 47 tag the app tells
// MyGo: menus, MyGo's own controls and mygo.locale follow it.
func localeTag(locale string) string {
	if strings.HasPrefix(strings.ToLower(locale), "en") {
		return "en"
	}
	return "zh-Hans"
}

// normalizeLocale accepts "zh", "zh-Hans", "en", "en-US" and returns the
// app's canonical "zh" or "en".
func normalizeLocale(locale string) (string, error) {
	l := strings.ToLower(strings.TrimSpace(locale))
	switch {
	case strings.HasPrefix(l, "zh"):
		return "zh", nil
	case strings.HasPrefix(l, "en"):
		return "en", nil
	}
	return "", fmt.Errorf("unsupported locale %q", locale)
}

// normalizeTheme accepts "system", "dark" or "light" (and their common
// spellings) and returns the canonical value.
func normalizeTheme(theme string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(theme)) {
	case "system", "auto", "":
		return "system", nil
	case "dark":
		return "dark", nil
	case "light":
		return "light", nil
	}
	return "", fmt.Errorf("unsupported theme %q", theme)
}

// applyTheme tells MyGo which appearance the app shows; pages follow through
// prefers-color-scheme, so no page reload is needed.
func applyTheme(theme string) {
	switch theme {
	case "dark":
		mygo.Theme.SetSource(mygo.ThemeDark)
	case "light":
		mygo.Theme.SetSource(mygo.ThemeLight)
	default:
		mygo.Theme.SetSource(mygo.ThemeSystem)
	}
}

// parseMenuBar decodes the JSON form of the menu-bar items accepted by
// Charker.SetSetting("menuBar", …).
func parseMenuBar(value string) ([]MenuBarItem, error) {
	var items []MenuBarItem
	if err := json.Unmarshal([]byte(value), &items); err != nil {
		return nil, fmt.Errorf("menuBar: %w", err)
	}
	if len(items) == 0 {
		return nil, fmt.Errorf("menuBar: at least one item is required")
	}
	for _, it := range items {
		switch it.Kind {
		case "total", "device", "state":
		case "port":
			if it.Port == "" {
				return nil, fmt.Errorf("menuBar: port item without a port")
			}
		default:
			return nil, fmt.Errorf("menuBar: unknown kind %q", it.Kind)
		}
	}
	return sanitizeMenuBar(items), nil
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
