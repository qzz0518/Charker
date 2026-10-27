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

// PortCount is the number of A2687 ports a nickname can be set for.
const PortCount = 3

// CameraPose is the saved "home" view of the 3D charger (ModelCameraPose).
type CameraPose struct {
	Theta    float64 `json:"theta"`
	Phi      float64 `json:"phi"`
	Distance float64 `json:"distance"`
}

// Preferences mirrors the macOS app's Preferences (CharkerCore), minus what
// has no Windows counterpart (Dock icon, Apple Home, the A2345 cloud). JSON
// names follow the Swift property names so the pages read the same keys the
// SwiftUI views read.
type Preferences struct {
	// Locale is "zh" or "en"; empty follows the Windows display language.
	Locale     string `json:"locale"`
	Appearance string `json:"appearance"`

	// Menu bar (here: the tray readout).
	StatusTemplate    string          `json:"statusTemplate"`
	Decimals          int             `json:"decimals"`
	HideIdlePorts     bool            `json:"hideIdlePorts"`
	ShowIconOnly      bool            `json:"showIconOnly"`
	CompactMenuBar    bool            `json:"compactMenuBar"`
	MenuBarItems      json.RawMessage `json:"menuBarItems,omitempty"`
	ShowsMenuBarIcon  bool            `json:"showsMenuBarIcon"`
	MenuBarIconSymbol string          `json:"menuBarIconSymbol"`

	LaunchAtLogin         bool   `json:"launchAtLogin"`
	DemoMode              bool   `json:"demoMode"`
	InitialSetupCompleted bool   `json:"initialSetupCompleted"`
	LastDeviceID          string `json:"lastDeviceId"`
	PollSeconds           int    `json:"pollSeconds"`
	WritesEnabled         bool   `json:"writesEnabled"`
	CaptureRawPayloads    bool   `json:"captureRawPayloads"`
	OwnerUserID           string `json:"ownerUserID"`
	LastSection           string `json:"lastSection"`

	// DashboardEnergyScope is the energy range the overview's energy stat and
	// the energy page share: session, today, week, month or all.
	DashboardEnergyScope string `json:"dashboardEnergyScope"`
	// PowerChartMaximum is the power chart's ceiling in watts; 0 is automatic.
	PowerChartMaximum  int     `json:"a2687PowerChartMaximum"`
	EnergyCurrencyCode string  `json:"energyCurrencyCode"`
	EnergyPricePerKWh  float64 `json:"energyPricePerKWh"`

	ModelHomeCamera       *CameraPose `json:"modelHomeCamera,omitempty"`
	ModelScreenStyle      string      `json:"modelScreenStyle"`
	ModelScreenCustomSlot int         `json:"modelScreenCustomSlot"`
	PortNicknames         []string    `json:"portNicknames"`
}

// DefaultPreferences returns the defaults of a fresh install.
func DefaultPreferences() Preferences {
	return Preferences{
		Appearance:           "system",
		Decimals:             1,
		ShowsMenuBarIcon:     true,
		MenuBarIconSymbol:    "bolt.fill",
		PollSeconds:          6,
		LastSection:          "dashboard",
		DashboardEnergyScope: "session",
		EnergyCurrencyCode:   "CNY",
		ModelScreenStyle:     "ankerPrime",
		PortNicknames:        make([]string, PortCount),
	}
}

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
	return Normalize(p)
}

// SavePreferences writes preferences atomically (temp file + rename).
func (s *Store) SavePreferences(p Preferences) error {
	p = Normalize(p)
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return s.writeFileAtomic(PreferencesFile, append(data, '\n'))
}

// LoadMenuBar returns just the menu-bar config from preferences.
// Normalize clamps every field to a value the app accepts.
func Normalize(p Preferences) Preferences {
	def := DefaultPreferences()
	switch p.Locale {
	case "", "zh", "en":
	default:
		p.Locale = def.Locale
	}
	switch p.Appearance {
	case "system", "light", "dark":
	default:
		p.Appearance = def.Appearance
	}
	if p.Decimals < 0 || p.Decimals > 3 {
		p.Decimals = def.Decimals
	}
	if p.PollSeconds < 3 || p.PollSeconds > 30 {
		p.PollSeconds = def.PollSeconds
	}
	if p.OwnerUserID != "" && !isLowerHex(p.OwnerUserID, 40) {
		p.OwnerUserID = ""
	}
	switch p.DashboardEnergyScope {
	case "session", "today", "week", "month", "all":
	default:
		p.DashboardEnergyScope = def.DashboardEnergyScope
	}
	switch p.PowerChartMaximum {
	case 0, 50, 100, 160:
	default:
		p.PowerChartMaximum = 0
	}
	p.EnergyCurrencyCode = strings.ToUpper(strings.TrimSpace(p.EnergyCurrencyCode))
	if !isCurrencyCode(p.EnergyCurrencyCode) {
		p.EnergyCurrencyCode = def.EnergyCurrencyCode
	}
	if math.IsNaN(p.EnergyPricePerKWh) || math.IsInf(p.EnergyPricePerKWh, 0) || p.EnergyPricePerKWh < 0 {
		p.EnergyPricePerKWh = 0
	}
	if c := p.ModelHomeCamera; c != nil && !(isFinite(c.Theta) && isFinite(c.Phi) && c.Phi >= 0 && c.Phi <= 180 &&
		isFinite(c.Distance) && c.Distance >= 0.01 && c.Distance <= 2) {
		p.ModelHomeCamera = nil
	}
	switch p.ModelScreenStyle {
	case "ankerPrime", "custom":
	default:
		p.ModelScreenStyle = def.ModelScreenStyle
	}
	if p.ModelScreenCustomSlot < 0 || p.ModelScreenCustomSlot > 2 {
		p.ModelScreenCustomSlot = 0
	}
	nick := make([]string, PortCount)
	for i := range nick {
		if i < len(p.PortNicknames) {
			nick[i] = trimNickname(p.PortNicknames[i])
		}
	}
	p.PortNicknames = nick
	if p.MenuBarIconSymbol == "" {
		p.MenuBarIconSymbol = def.MenuBarIconSymbol
	}
	if p.LastSection == "" {
		p.LastSection = def.LastSection
	}
	return p
}

func isFinite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }

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
