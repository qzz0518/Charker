package app

import (
	"encoding/json"
	"fmt"
	"log"
	"strings"

	"charker/internal/prefs"

	"github.com/egoist/mygo"
)

// SetPrefs merges a JSON patch of preference keys (the Swift Preferences
// names, as AppState.prefs spells them) into the preferences, saves them and
// applies whatever they drive: appearance, language, the write gate, the
// poll cadence, launch at login and demo mode.
func (a *App) SetPrefs(patch json.RawMessage) error {
	a.mu.Lock()
	old := a.prefs
	next := old
	// Decoding onto a copy keeps every key the patch leaves out. Slices and
	// raw JSON are replaced as a whole, which is what the pages send.
	if err := json.Unmarshal(patch, &next); err != nil {
		a.mu.Unlock()
		return fmt.Errorf("prefs: %w", err)
	}
	next = prefs.Normalize(next)
	a.prefs = next
	a.mu.Unlock()

	a.savePrefs()
	if next.Appearance != old.Appearance {
		applyAppearance(next.Appearance)
	}
	if next.Locale != old.Locale && mygo.App.IsReady() {
		mygo.App.SetLocale(localeTag(a.locale()))
	}
	if next.WritesEnabled != old.WritesEnabled && a.sess != nil {
		if err := a.sess.SetWritesEnabled(next.WritesEnabled); err != nil {
			log.Printf("app: write gate: %v", err)
		}
	}
	if next.LaunchAtLogin != old.LaunchAtLogin && mygo.App.IsReady() {
		if err := mygo.App.SetOpenAtLogin(next.LaunchAtLogin); err != nil {
			// As on macOS, a registration that fails turns the switch back.
			log.Printf("app: launch at login: %v", err)
			a.mu.Lock()
			a.prefs.LaunchAtLogin = old.LaunchAtLogin
			a.mu.Unlock()
			a.savePrefs()
			a.toast("error", fmt.Sprintf(a.tr(textLoginFailed), err))
		}
	}
	if next.DemoMode != old.DemoMode {
		if err := a.setDemo(next.DemoMode); err != nil {
			return err
		}
	}
	if (next.EnergyPricePerKWh != old.EnergyPricePerKWh || next.EnergyCurrencyCode != old.EnergyCurrencyCode) && a.energy != nil {
		if setter, ok := a.energy.(interface{ SetPrice(float64, string) }); ok {
			setter.SetPrice(next.EnergyPricePerKWh, next.EnergyCurrencyCode)
		}
	}
	a.updateTray()
	a.publishNow()
	return nil
}

// savePrefs writes the in-memory preferences. Demo mode forced by a dev
// switch is not persisted.
func (a *App) savePrefs() {
	a.mu.Lock()
	p := a.prefs
	store := a.store
	if a.forceDemo {
		p.DemoMode = a.persistedDemo
	}
	a.mu.Unlock()
	if store == nil {
		return
	}
	if err := store.SavePreferences(p); err != nil {
		log.Printf("app: saving preferences: %v", err)
	}
}

// locale returns the effective UI language: the preference, or the Windows
// display language.
func (a *App) locale() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.localeLocked()
}

func (a *App) localeLocked() string {
	if a.prefs.Locale != "" {
		return a.prefs.Locale
	}
	return a.systemLocale
}

// systemLocale reads the user's preferred languages once MyGo is ready.
func systemLocale() string {
	if !mygo.App.IsReady() {
		return "zh"
	}
	for _, tag := range mygo.App.PreferredLanguages() {
		t := strings.ToLower(tag)
		if strings.HasPrefix(t, "zh") {
			return "zh"
		}
		if strings.HasPrefix(t, "en") {
			return "en"
		}
	}
	return "en"
}

// localeTag maps the UI locale to the BCP 47 tag MyGo's own controls use.
func localeTag(locale string) string {
	if locale == "en" {
		return "en"
	}
	return "zh-Hans"
}

// applyAppearance tells MyGo which appearance the app shows; pages follow
// through prefers-color-scheme.
func applyAppearance(appearance string) {
	if !mygo.App.IsReady() {
		return
	}
	switch appearance {
	case "dark":
		mygo.Theme.SetSource(mygo.ThemeDark)
	case "light":
		mygo.Theme.SetSource(mygo.ThemeLight)
	default:
		mygo.Theme.SetSource(mygo.ThemeSystem)
	}
}
