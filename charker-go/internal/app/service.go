package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"time"

	"charker/internal/prefs"
	"charker/internal/product"
	"charker/internal/session"

	"github.com/egoist/mygo"
)

// The typed events the pages subscribe to with mygo.on(name, fn).
var (
	// StateEvent is "state": the full AppState, at most 5 Hz.
	StateEvent = mygo.NewEvent[AppState]("state")
	// ToastEvent is "toast": a transient user notice.
	ToastEvent = mygo.NewEvent[Toast]("toast")
	// DeviceLostEvent is "deviceLost": the connection dropped.
	DeviceLostEvent = mygo.NewEvent[DeviceLost]("deviceLost")
)

// Charker is the service bound as "Charker": the page calls
// window.mygo.call("Charker.State", …) and friends.
type Charker struct {
	app *App
}

// NewService returns the bound IPC surface for an app.
func NewService(a *App) *Charker { return &Charker{app: a} }

// State returns the current AppState.
func (s *Charker) State() AppState { return s.app.State() }

// SetPrefs merges a patch of preference keys, e.g. {"hideIdlePorts": true}.
func (s *Charker) SetPrefs(patch json.RawMessage) (any, error) {
	return nil, s.app.SetPrefs(patch)
}

// Scan starts scanning for chargers.
func (s *Charker) Scan() (any, error) { return nil, s.app.withSession((Session).Scan) }

// StopScan stops scanning.
func (s *Charker) StopScan() (any, error) { return nil, s.app.withSession((Session).StopScan) }

// Connect connects to the charger with the given device id.
func (s *Charker) Connect(id string) (any, error) {
	if id == "" {
		return nil, errors.New("connect: a device id is required")
	}
	if err := s.app.withSession(func(x Session) error { return x.Connect(id) }); err != nil {
		return nil, err
	}
	s.app.mu.Lock()
	s.app.prefs.LastDeviceID = id
	s.app.mu.Unlock()
	s.app.savePrefs()
	return nil, nil
}

// Disconnect drops the link to the current charger.
func (s *Charker) Disconnect() (any, error) { return nil, s.app.withSession((Session).Disconnect) }

// Reconnect drops and re-establishes the link to the current charger.
func (s *Charker) Reconnect() (any, error) { return nil, s.app.withSession((Session).Reconnect) }

// SetPortEnabled turns one port's output on or off.
func (s *Charker) SetPortEnabled(port string, on bool) (any, error) {
	id, err := portID(port)
	if err != nil {
		return nil, err
	}
	return nil, s.app.write(func(x Session) error { return x.SetPortEnabled(id, on) })
}

// SetPortTimer arms the charger's auto-off countdown for one port; 0 cancels.
func (s *Charker) SetPortTimer(port string, seconds int) (any, error) {
	id, err := portID(port)
	if err != nil {
		return nil, err
	}
	return nil, s.app.write(func(x Session) error { return x.SetPortTimer(id, seconds) })
}

// SetChargerSetting writes one charger setting (see session.parseSetting).
func (s *Charker) SetChargerSetting(key, value string) (any, error) {
	return nil, s.app.write(func(x Session) error { return x.SetSetting(key, value) })
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

// ---- app-side actions ----

func (a *App) withSession(fn func(Session) error) error {
	if a.sess == nil {
		return errNoSession
	}
	return fn(a.sess)
}

// write runs a charger write and explains a closed write gate.
func (a *App) write(fn func(Session) error) error {
	err := a.withSession(fn)
	if errors.Is(err, session.ErrWritesDisabled) {
		a.toast("warn", a.tr(textWritesOff))
	}
	return err
}

func portID(port string) (product.PortID, error) {
	id := product.PortID(port)
	if !id.Valid() {
		return "", fmt.Errorf("unknown port %q", port)
	}
	return id, nil
}

// setDemo swaps between the simulated charger and Bluetooth.
func (a *App) setDemo(on bool) error {
	if a.sess == nil {
		return errNoSession
	}
	if err := a.sess.UseMock(on); err != nil {
		return err
	}
	a.mu.Lock()
	a.demo = on
	if !on {
		a.forceDemo = false
	}
	a.mu.Unlock()
	a.restartPump()
	return nil
}

// recordConnection remembers a charger the first time it reaches polling on
// a link, like SavedCharger.recordConnection on macOS. Demo chargers are not
// remembered.
func (a *App) recordConnection(d Device) {
	if d.Mock || d.ID == "" {
		return
	}
	a.mu.Lock()
	a.saved = prefs.UpsertSaved(a.saved, prefs.SavedCharger{
		ID:              d.ID,
		SerialNumber:    d.Serial,
		LastConnectedAt: time.Now().UnixMilli(),
		Name:            d.Name,
		Address:         d.Address,
		Product:         string(d.Product),
	})
	list := append([]prefs.SavedCharger(nil), a.saved...)
	store := a.store
	a.mu.Unlock()
	if store != nil {
		if err := store.SaveSavedChargers(list); err != nil {
			log.Printf("app: saving chargers: %v", err)
		}
	}
	if a.sess != nil {
		ids := prefs.ReconnectOrder(list)
		if err := a.sess.SetRemembered(ids); err != nil {
			log.Printf("app: remembered chargers: %v", err)
		}
	}
}
