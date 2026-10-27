// Package prefs persists Charker's user preferences with plain JSON files
// under a caller-supplied base directory (the app passes mygo's user-data
// path). It has no mygo or platform imports: pure Go + os.
package prefs

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
)

// File names inside the base directory.
const (
	PreferencesFile = "preferences.json"
	SavedFile       = "saved-chargers.json"
	corruptSuffix   = ".corrupt.json"
)

// MenuBarItem is one entry of the structured menu-bar layout (contract §4.1).
type MenuBarItem struct {
	// Kind is one of "total", "port", "device", "state".
	Kind string `json:"kind"`
	// Port is the port id for Kind "port" ("C1"…"C3").
	Port string `json:"port,omitempty"`
	// Decimals is the number of decimals for power values (0…3).
	Decimals int `json:"decimals"`
}

// MenuBarConfig is the ordered menu-bar layout.
type MenuBarConfig struct {
	Items []MenuBarItem `json:"items"`
}

// DefaultMenuBarConfig is the dashboard default: total power with one decimal.
func DefaultMenuBarConfig() MenuBarConfig {
	return MenuBarConfig{Items: []MenuBarItem{{Kind: "total", Decimals: 1}}}
}

// Preferences is the persisted app configuration. JSON names are stable and
// consumed by internal/app.
type Preferences struct {
	// Locale is the UI language: "zh" (default) or "en".
	Locale string `json:"locale"`
	// Theme is "system" (default), "light" or "dark".
	Theme string `json:"theme"`
	// MockMode runs the simulator instead of real Bluetooth.
	MockMode bool `json:"mockMode"`
	// DemoMode marks the in-memory demo product flow.
	DemoMode bool `json:"demoMode"`
	// LastDeviceID is the charger id connected most recently.
	LastDeviceID string `json:"lastDeviceId"`
	// WritesEnabled is the port-switching opt-in.
	WritesEnabled bool `json:"writesEnabled"`
	// OwnerUserID is the optional Anker account id (40 hex).
	OwnerUserID string `json:"ownerUserId"`
	// PollSeconds is the telemetry poll cadence (floor 3).
	PollSeconds int `json:"pollSeconds"`
	// EnergyCurrency is the 3-letter ISO currency code used for cost.
	EnergyCurrency string `json:"energyCurrency"`
	// EnergyPricePerKWh is the electricity price (>= 0, 0 = no cost shown).
	EnergyPricePerKWh float64 `json:"energyPricePerKWh"`
	// MenuBar is the tray/menu-bar layout.
	MenuBar MenuBarConfig `json:"menuBar"`
	// Window keys keep the last window placement.
	WindowX         int  `json:"windowX"`
	WindowY         int  `json:"windowY"`
	WindowWidth     int  `json:"windowWidth"`
	WindowHeight    int  `json:"windowHeight"`
	WindowMaximized bool `json:"windowMaximized"`
	// LastSection is the last route shown.
	LastSection string `json:"lastSection"`
}

// DefaultPreferences returns the defaults used for a first launch and for any
// missing/corrupt file.
func DefaultPreferences() Preferences {
	return Preferences{
		Locale:            "zh",
		Theme:             "system",
		MockMode:          false,
		LastSection:       "overview",
		PollSeconds:       6,
		EnergyCurrency:    "CNY",
		EnergyPricePerKWh: 0,
		MenuBar:           DefaultMenuBarConfig(),
		WindowWidth:       969,
		WindowHeight:      840,
	}
}

// Store reads and writes the preference files below one base directory.
type Store struct {
	dir string
}

// NewStore returns a store rooted at baseDir. The directory is created on the
// first save.
func NewStore(baseDir string) *Store { return &Store{dir: baseDir} }

// Dir is the base directory the store writes below.
func (s *Store) Dir() string { return s.dir }

// LoadPreferences loads preferences. Missing files yield defaults; a corrupt
// file is moved to preferences.corrupt.json (once) and defaults are returned.
func (s *Store) LoadPreferences() Preferences {
	p := DefaultPreferences()
	data, ok := s.readFile(PreferencesFile)
	if !ok {
		return p
	}
	if err := json.Unmarshal(data, &p); err != nil {
		s.quarantine(PreferencesFile)
		return DefaultPreferences()
	}
	return normalizePreferences(p)
}

// SavePreferences writes preferences atomically (temp file + rename).
func (s *Store) SavePreferences(p Preferences) error {
	p = normalizePreferences(p)
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return s.writeFileAtomic(PreferencesFile, append(data, '\n'))
}

// LoadMenuBar returns just the menu-bar config from preferences.
func (s *Store) LoadMenuBar() MenuBarConfig {
	return s.LoadPreferences().MenuBar
}

// SaveMenuBar updates the menu-bar config in the preferences file.
func (s *Store) SaveMenuBar(cfg MenuBarConfig) error {
	p := s.LoadPreferences()
	p.MenuBar = cfg
	return s.SavePreferences(p)
}

// normalizePreferences clamps and repairs values loaded from disk.
func normalizePreferences(p Preferences) Preferences {
	def := DefaultPreferences()
	switch p.Locale {
	case "zh", "en":
	default:
		p.Locale = def.Locale
	}
	switch p.Theme {
	case "system", "light", "dark":
	default:
		p.Theme = def.Theme
	}
	if p.PollSeconds < 3 {
		p.PollSeconds = def.PollSeconds
	}
	if p.OwnerUserID != "" && !isLowerHex(p.OwnerUserID, 40) {
		p.OwnerUserID = ""
	}
	if !isCurrencyCode(p.EnergyCurrency) {
		p.EnergyCurrency = def.EnergyCurrency
	}
	if math.IsNaN(p.EnergyPricePerKWh) || math.IsInf(p.EnergyPricePerKWh, 0) || p.EnergyPricePerKWh < 0 {
		p.EnergyPricePerKWh = 0
	}
	if p.WindowWidth < 890 {
		p.WindowWidth = def.WindowWidth
	}
	if p.WindowHeight < 600 {
		p.WindowHeight = def.WindowHeight
	}
	if p.LastSection == "" {
		p.LastSection = def.LastSection
	}
	p.MenuBar = normalizeMenuBar(p.MenuBar)
	return p
}

// normalizeMenuBar drops unknown/invalid items, clamps decimals and dedupes
// value items (total/device/state once, port once per port); separator/text
// kinds are repeatable.
func normalizeMenuBar(cfg MenuBarConfig) MenuBarConfig {
	out := MenuBarConfig{Items: make([]MenuBarItem, 0, len(cfg.Items))}
	seenKind := map[string]bool{}
	seenPort := map[string]bool{}
	for _, it := range cfg.Items {
		it.Decimals = clampDecimals(it.Decimals)
		switch it.Kind {
		case "total", "device", "state":
			if seenKind[it.Kind] {
				continue
			}
			seenKind[it.Kind] = true
			it.Port = ""
			out.Items = append(out.Items, it)
		case "port":
			if !validPort(it.Port) {
				continue
			}
			if seenPort[it.Port] {
				continue
			}
			seenPort[it.Port] = true
			out.Items = append(out.Items, it)
		}
	}
	if len(out.Items) == 0 {
		out = DefaultMenuBarConfig()
	}
	return out
}

func clampDecimals(n int) int {
	if n < 0 {
		return 0
	}
	if n > 3 {
		return 3
	}
	return n
}

func validPort(p string) bool {
	switch p {
	case "C1", "C2", "C3":
		return true
	}
	return false
}

func isCurrencyCode(s string) bool {
	if len(s) != 3 {
		return false
	}
	for _, r := range s {
		if r < 'A' || r > 'Z' {
			return false
		}
	}
	return true
}

func isLowerHex(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, r := range s {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f')) {
			return false
		}
	}
	return true
}

// --- file helpers ---

func (s *Store) path(name string) string { return filepath.Join(s.dir, name) }

func (s *Store) readFile(name string) ([]byte, bool) {
	data, err := os.ReadFile(s.path(name))
	if err != nil {
		return nil, false
	}
	return data, true
}

// quarantine moves a corrupt file out of the way, keeping one backup.
func (s *Store) quarantine(name string) {
	src := s.path(name)
	dst := src + corruptSuffix
	if _, err := os.Stat(dst); err == nil {
		_ = os.Remove(src) // a backup already exists; drop the repeat copy
		return
	}
	if err := os.Rename(src, dst); err != nil {
		// Fall back to copy+remove (rename can fail across edges/AV locks).
		if data, rerr := os.ReadFile(src); rerr == nil {
			if werr := os.WriteFile(dst, data, 0o644); werr == nil {
				_ = os.Remove(src)
			}
		}
	}
}

// writeFileAtomic writes data to name via a temp file in the same directory,
// then renames it into place.
func (s *Store) writeFileAtomic(name string, data []byte) error {
	if err := os.MkdirAll(s.dir, 0o755); err != nil {
		return err
	}
	dst := s.path(name)
	tmp, err := os.CreateTemp(s.dir, "."+name+".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() {
		_ = os.Remove(tmpName) // no-op after a successful rename
	}()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, dst)
}

// trimNickname trims whitespace/newlines and caps the nickname at 24 runes.
func trimNickname(s string) string {
	s = strings.TrimSpace(s)
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.Join(strings.Fields(s), " ")
	r := []rune(s)
	if len(r) > 24 {
		r = r[:24]
	}
	return string(r)
}
