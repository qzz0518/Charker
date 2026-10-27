package app

import (
	"context"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"charker/internal/prefs"

	"github.com/egoist/mygo"
)

// Config configures the app shell.
type Config struct {
	// Version is the app version shown in AppState.app.version.
	Version string
	// IconPNG is the app icon (any size) used for windows and the exe.
	IconPNG []byte
	// TrayIconPNG is the small tray icon (32×32 PNG).
	TrayIconPNG []byte
	// PreloadScript is injected before the page's own scripts (dev build
	// diagnostics; empty in release builds).
	PreloadScript string
	// Store persists the app preferences under App.Path(PathUserData).
	Store *prefs.Store
	// ForceDemo starts in demo mode without persisting it (dev builds).
	ForceDemo bool
	// Session is the charger session engine.
	Session Session
	// Energy is the energy history service.
	Energy Energy
	// Emit replaces MyGo's event broadcast (the browser dev server sends the
	// events over HTTP instead); nil broadcasts to the app's pages.
	Emit func(event string, payload any)
}

// App owns the process-wide app state: the session snapshot mapped to
// AppState, the persisted settings, and the window/tray lifecycle.
type App struct {
	version       string
	iconPNG       []byte
	trayIconPNG   []byte
	preloadScript string
	store         *prefs.Store
	sess          Session
	energy        Energy
	emit          func(event string, payload any)

	mu    sync.Mutex
	prefs prefs.Preferences
	saved []prefs.SavedCharger
	// demo is whether the simulated charger runs; forceDemo means a dev switch
	// turned it on, so persistedDemo is what preferences.json keeps.
	demo          bool
	forceDemo     bool
	persistedDemo bool
	systemLocale  string
	snap          Snapshot
	lastTooltip   string
	lastUpdated   int64
	startupNotice *Notice
	served        atomic.Bool
	quitting      atomic.Bool

	uiMu   sync.Mutex
	win    *mygo.Window
	tray   *mygo.Tray
	trayUI trayUI // the tray flyout and the live icon (tray.go)
	icon   *mygo.MenuIcon
	quitF  func()

	pumpMu     sync.Mutex
	baseCtx    context.Context
	pumpCancel context.CancelFunc
}

// New builds the app shell. It does not call MyGo APIs that need the running
// app; StartUI does that from WhenReady.
func New(cfg Config) *App {
	p := prefs.DefaultPreferences()
	var saved []prefs.SavedCharger
	if cfg.Store != nil {
		p = cfg.Store.LoadPreferences()
		saved = cfg.Store.LoadSavedChargers()
	}
	a := &App{
		version:       cfg.Version,
		iconPNG:       cfg.IconPNG,
		trayIconPNG:   cfg.TrayIconPNG,
		preloadScript: cfg.PreloadScript,
		store:         cfg.Store,
		sess:          cfg.Session,
		energy:        cfg.Energy,
		emit:          cfg.Emit,
		prefs:         p,
		saved:         saved,
		demo:          p.DemoMode || cfg.ForceDemo,
		forceDemo:     cfg.ForceDemo && !p.DemoMode,
		persistedDemo: p.DemoMode,
		systemLocale:  "zh",
		snap:          Snapshot{Phase: PhaseIdle},
	}
	a.prefs.DemoMode = a.demo
	// A recovered/corrupt energy archive is surfaced as a one-time notice.
	if es, ok := cfg.Energy.(*EnergyService); ok && es.Warning() != "" {
		a.startupNotice = &Notice{Kind: "warn", Text: es.Warning()}
	}
	return a
}

// Prefs returns a copy of the preferences.
func (a *App) Prefs() prefs.Preferences {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.prefs
}

// Session returns the session engine (nil-safe).
func (a *App) Session() Session { return a.sess }

// IsQuitting reports whether the app is shutting down (close listeners let
// the window go instead of hiding it).
func (a *App) IsQuitting() bool { return a.quitting.Load() }

// SetQuitting marks a deliberate quit; called by the quit listeners.
func (a *App) SetQuitting() { a.quitting.Store(true) }

// Quit asks the app to exit; the windows close and App.Run returns. It is
// safe from any goroutine (MyGo marshals the call to the main thread).
func (a *App) Quit() {
	a.SetQuitting()
	mygo.App.Quit()
}

// energySummaryLocked returns the cached energy aggregates. a.mu must be held.
func (a *App) energySummaryLocked() EnergySummary {
	if a.energy == nil {
		return EnergySummary{}
	}
	return a.energy.Summary()
}

// RunSession starts the session engine and pumps its snapshots into AppState
// events until ctx is canceled. Call it on its own goroutine.
func (a *App) RunSession(ctx context.Context) {
	a.pumpMu.Lock()
	a.baseCtx = ctx
	a.pumpMu.Unlock()
	a.startPump(ctx)
	<-ctx.Done()
	a.stopPump()
}

// startPump subscribes to the session and starts the engine (again, after a
// mock/real switch). The previous pump, if any, is canceled first.
func (a *App) startPump(ctx context.Context) {
	if a.sess == nil {
		return
	}
	a.pumpMu.Lock()
	if a.pumpCancel != nil {
		a.pumpCancel()
	}
	pctx, cancel := context.WithCancel(ctx)
	a.pumpCancel = cancel
	a.pumpMu.Unlock()

	// Start the engine before subscribing: the manager only exists once the
	// session host started it, and Subscribe on a host without a manager
	// yields a closed channel.
	// The engine lives on the run's context, not the pump's: restarting the
	// pump (demo switch) must not cancel the manager it just spawned.
	if err := a.sess.Start(ctx); err != nil {
		log.Printf("app: session start: %v", err)
	}
	ch := a.sess.Subscribe(64)
	go a.pumpLoop(pctx, ch)
}

// stopPump cancels the snapshot pump.
func (a *App) stopPump() {
	a.pumpMu.Lock()
	cancel := a.pumpCancel
	a.pumpCancel = nil
	a.pumpMu.Unlock()
	if cancel != nil {
		cancel()
	}
}

// restartPump resubscribes after the session host swapped engines.
func (a *App) restartPump() {
	a.pumpMu.Lock()
	base := a.baseCtx
	a.pumpMu.Unlock()
	if base == nil {
		base = context.Background()
	}
	a.startPump(base)
}

// pumpLoop consumes session snapshots: it stores the latest one, turns
// transitions into toasts/deviceLost events, and publishes AppState on the
// state event at most five times a second.
func (a *App) pumpLoop(ctx context.Context, ch <-chan Snapshot) {
	tick := time.NewTicker(200 * time.Millisecond)
	defer tick.Stop()
	pending := false
	for {
		select {
		case <-ctx.Done():
			return
		case s, ok := <-ch:
			if !ok {
				return
			}
			a.handleSnapshot(s)
			pending = true
		case <-tick.C:
			if pending && a.served.Load() {
				a.publishNow()
				pending = false
			}
		}
	}
}

// handleSnapshot stores one snapshot and emits the events its transitions
// imply.
func (a *App) handleSnapshot(s Snapshot) {
	a.mu.Lock()
	old := a.snap
	a.snap = s
	a.mu.Unlock()

	if s.Phase == PhasePolling && old.Phase != PhasePolling && s.Device != nil {
		a.recordConnection(*s.Device)
	}

	lostID := ""
	if old.Device != nil && old.Device.Connected && (s.Device == nil || !s.Device.Connected) {
		lostID = old.Device.ID
	}

	important := old.Phase != s.Phase || old.Scanning != s.Scanning || lostID != ""
	if important {
		log.Printf("app: phase=%s scanning=%v devices=%d stale=%v err=%q", s.Phase, s.Scanning, len(s.Devices), s.IsStale, s.Err)
	}

	if lostID != "" {
		a.broadcast("deviceLost", DeviceLost{ID: lostID})
	}
	if important {
		a.publishNow()
	}
}

// State builds a fresh AppState. The frontend calls it once on boot and then
// applies state events; it is safe from any goroutine.
func (a *App) State() AppState {
	now := time.Now().UnixMilli()
	a.mu.Lock()
	st := a.buildStateLocked(now)
	a.mu.Unlock()
	a.served.Store(true)
	return st
}

// publishNow broadcasts the current AppState to every page (no-op before the
// page's first Charker.State call, so a state event cannot race boot).
func (a *App) publishNow() {
	if !a.served.Load() {
		return
	}
	now := time.Now().UnixMilli()
	a.mu.Lock()
	state := a.buildStateLocked(now)
	a.lastUpdated = now
	a.mu.Unlock()
	a.broadcast("state", state)
	a.updateTrayToolTip(state)
}

// toast broadcasts one transient notice.
func (a *App) toast(kind, text string) {
	if text == "" {
		return
	}
	a.broadcast("toast", Toast{Kind: kind, Text: text})
}

// notify shows a toast and, when a window is visible, nothing else: the page
// renders it. Kept for session errors the shell itself produces.

// Close stops the session, flushes the energy archive and the settings. Call
// it after App.Run returned.
func (a *App) Close() {
	a.stopPump()
	if a.sess != nil {
		a.sess.Stop()
	}
	if finisher, ok := a.energy.(interface{ Finish() error }); ok {
		if err := finisher.Finish(); err != nil {
			log.Printf("app: saving energy history: %v", err)
		}
	} else if saver, ok := a.energy.(interface{ Save() error }); ok {
		if err := saver.Save(); err != nil {
			log.Printf("app: saving energy history: %v", err)
		}
	}
	a.savePrefs()
}

// broadcast sends one event to every page.
func (a *App) broadcast(event string, payload any) {
	if a.emit != nil {
		a.emit(event, payload)
		return
	}
	var err error
	switch v := payload.(type) {
	case AppState:
		err = StateEvent.Broadcast(v)
	case Toast:
		err = ToastEvent.Broadcast(v)
	case DeviceLost:
		err = DeviceLostEvent.Broadcast(v)
	}
	if err != nil {
		log.Printf("app: broadcasting %s: %v", event, err)
	}
}
