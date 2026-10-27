package app

import (
	"context"
	"errors"
	"fmt"
	"log"

	"charker/internal/product"
	"charker/internal/session"

	"github.com/egoist/mygo"
)

// The typed events the pages subscribe to with mygo.on(name, fn). They are
// declared at package level so they are unique and stable (mygo/ipc.go).
var (
	// StateEvent is "state": the full AppState, emitted on connect,
	// disconnect, settings and scan changes, at most 5 Hz.
	StateEvent = mygo.NewEvent[AppState]("state")
	// ToastEvent is "toast": a transient user notice.
	ToastEvent = mygo.NewEvent[Toast]("toast")
	// DeviceLostEvent is "deviceLost": the connection dropped.
	DeviceLostEvent = mygo.NewEvent[DeviceLost]("deviceLost")
)

// Charker is the service bound as "Charker": the page calls
// window.mygo.call("Charker.State", …) and friends. Only exported methods of
// this type cross the IPC boundary; the App's lifecycle stays in Go.
type Charker struct {
	app *App
}

// NewService returns the bound IPC surface for an app.
func NewService(a *App) *Charker { return &Charker{app: a} }

// State returns the current AppState. It is callable on boot, before the
// session produced anything, and again at any time.
func (s *Charker) State() AppState { return s.app.State() }

// ScanStart starts scanning for chargers.
func (s *Charker) ScanStart() (any, error) {
	if err := s.app.scanStart(); err != nil {
		return nil, err
	}
	return nil, nil
}

// ScanStop stops scanning.
func (s *Charker) ScanStop() (any, error) {
	if err := s.app.scanStop(); err != nil {
		return nil, err
	}
	return nil, nil
}

// Connect connects to the charger with the given device id.
func (s *Charker) Connect(id string) (any, error) {
	if err := s.app.connect(id); err != nil {
		return nil, err
	}
	return nil, nil
}

// Disconnect disconnects from the current charger.
func (s *Charker) Disconnect() (any, error) {
	if err := s.app.disconnect(); err != nil {
		return nil, err
	}
	return nil, nil
}

// UseMock turns the simulated charger on or off.
func (s *Charker) UseMock(on bool) (any, error) {
	if err := s.app.useMock(on); err != nil {
		return nil, err
	}
	return nil, nil
}

// SetPortEnabled turns one port's output on or off.
func (s *Charker) SetPortEnabled(port string, on bool) (any, error) {
	if err := s.app.setPortEnabled(port, on); err != nil {
		return nil, err
	}
	return nil, nil
}

// SetCountdown arms (minutes > 0) or cancels (minutes == 0) a port timer.
func (s *Charker) SetCountdown(port string, minutes int) (any, error) {
	if err := s.app.setCountdown(port, minutes); err != nil {
		return nil, err
	}
	return nil, nil
}

// SetSetting writes one charger or app setting; see docs/port/contract.md §4.
func (s *Charker) SetSetting(key, value string) (any, error) {
	if err := s.app.setSetting(key, value); err != nil {
		return nil, err
	}
	return nil, nil
}

// SetWritesEnabled allows or blocks port switching and countdown writes (the
// Advanced screen's opt-in; off by default like the macOS app).
func (s *Charker) SetWritesEnabled(on bool) (any, error) {
	if err := s.app.setWritesEnabled(on); err != nil {
		return nil, err
	}
	return nil, nil
}

// EnergyReport returns the detailed energy series for "day", "week" or "month".
func (s *Charker) EnergyReport(rangeArg string) (EnergyReport, error) {
	return s.app.energyReport(rangeArg)
}

// ExportEnergy writes the energy series through a native Save dialog and
// returns the saved path, or "" when the user canceled.
func (s *Charker) ExportEnergy(ctx context.Context, rangeArg, format string) (string, error) {
	return s.app.exportEnergy(ctx, rangeArg, format)
}

// SetLocale switches the UI language between "zh" and "en"; menu and tray
// labels follow.
func (s *Charker) SetLocale(locale string) (any, error) {
	if err := s.app.setLocale(locale); err != nil {
		return nil, err
	}
	return nil, nil
}

// SetTheme switches the app appearance: "dark", "light" or "system".
func (s *Charker) SetTheme(theme string) (any, error) {
	if err := s.app.setTheme(theme); err != nil {
		return nil, err
	}
	return nil, nil
}

// ---- app-side actions (not bound themselves) ----

func (a *App) scanStart() error {
	if a.sess == nil {
		return errors.New("session is not available")
	}
	if err := a.sess.Scan(); err != nil {
		log.Printf("app: scan: %v", err)
		a.toast("error", fmt.Sprintf(a.tr(textScanFailed), err))
		return err
	}
	return nil
}

func (a *App) scanStop() error {
	if a.sess == nil {
		return errors.New("session is not available")
	}
	return a.sess.StopScan()
}

func (a *App) connect(id string) error {
	if a.sess == nil {
		return errors.New("session is not available")
	}
	if id == "" {
		return errors.New("connect: a device id is required")
	}
	if err := a.sess.Connect(id); err != nil {
		return err
	}
	a.mu.Lock()
	a.settings.LastDevice = id
	a.mu.Unlock()
	a.saveSettings()
	return nil
}

func (a *App) disconnect() error {
	if a.sess == nil {
		return errors.New("session is not available")
	}
	return a.sess.Disconnect()
}

func (a *App) useMock(on bool) error {
	if a.sess == nil {
		return errors.New("session is not available")
	}
	if err := a.sess.UseMock(on); err != nil {
		return err
	}
	a.mu.Lock()
	a.settings.Mock = on
	a.mu.Unlock()
	a.saveSettings()
	a.restartPump()
	a.publishNow()
	return nil
}

func (a *App) setPortEnabled(port string, on bool) error {
	if a.sess == nil {
		return errors.New("session is not available")
	}
	id := product.PortID(port)
	if !id.Valid() {
		return fmt.Errorf("unknown port %q", port)
	}
	if err := a.sess.SetPortEnabled(id, on); err != nil {
		a.writeError(err)
		return err
	}
	return nil
}

func (a *App) setCountdown(port string, minutes int) error {
	if a.sess == nil {
		return errors.New("session is not available")
	}
	id := product.PortID(port)
	if !id.Valid() {
		return fmt.Errorf("unknown port %q", port)
	}
	if minutes < 0 {
		return fmt.Errorf("invalid countdown %d", minutes)
	}
	if err := a.sess.SetCountdown(id, minutes); err != nil {
		a.writeError(err)
		return err
	}
	return nil
}

// writeError shows the reason a port write was refused; the page also gets
// the rejected promise, but a disabled write gate deserves an explicit hint.
func (a *App) writeError(err error) {
	if errors.Is(err, session.ErrWritesDisabled) {
		a.toast("warn", a.tr(textWritesOff))
	}
}

func (a *App) setWritesEnabled(on bool) error {
	if a.sess == nil {
		return errors.New("session is not available")
	}
	if err := a.sess.SetWritesEnabled(on); err != nil {
		return err
	}
	a.mu.Lock()
	a.settings.WritesEnabled = on
	a.mu.Unlock()
	a.saveSettings()
	a.publishNow()
	return nil
}

func (a *App) setSetting(key, value string) error {
	switch key {
	case "menuBar":
		items, err := parseMenuBar(value)
		if err != nil {
			return err
		}
		a.mu.Lock()
		a.settings.MenuBar = items
		a.mu.Unlock()
		a.saveSettings()
		a.publishNow()
		return nil
	case "locale":
		return a.setLocale(value)
	case "theme":
		return a.setTheme(value)
	}
	if a.sess == nil {
		return errors.New("session is not available")
	}
	return a.sess.SetSetting(key, value)
}

func (a *App) setLocale(locale string) error {
	norm, err := normalizeLocale(locale)
	if err != nil {
		return err
	}
	a.mu.Lock()
	changed := a.settings.Locale != norm
	a.settings.Locale = norm
	a.mu.Unlock()
	if changed {
		a.saveSettings()
	}
	if mygo.App.IsReady() {
		mygo.App.SetLocale(localeTag(norm))
	}
	a.updateTray()
	a.publishNow()
	return nil
}

func (a *App) setTheme(theme string) error {
	norm, err := normalizeTheme(theme)
	if err != nil {
		return err
	}
	a.mu.Lock()
	changed := a.settings.Theme != norm
	a.settings.Theme = norm
	a.mu.Unlock()
	if changed {
		a.saveSettings()
	}
	applyTheme(norm)
	a.publishNow()
	return nil
}
