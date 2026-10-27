package app

import (
	"context"
	"encoding/json"
	"log"
	"time"

	"charker/internal/anker"
	"charker/internal/cloudsession"
	"charker/internal/matter"
	"charker/internal/product"
)

// The A2345 half of AppModel: the cloud engine runs while the 250W is the
// product on screen (signed in, or its simulator in demo mode) and the BLE
// engine runs otherwise, never both.

// cloudRun is one running cloud engine.
type cloudRun struct {
	eng    *cloudsession.Engine
	cancel context.CancelFunc
	demo   bool
}

// Cloud returns the running A2345 engine, or nil while the 160W is on screen.
func (a *App) Cloud() *cloudsession.Engine {
	a.cloudMu.Lock()
	defer a.cloudMu.Unlock()
	if a.cloud == nil {
		return nil
	}
	return a.cloud.eng
}

// applyProduct runs the engine of the product on screen
// (AppModel.product(for:)) and stops the other one.
func (a *App) applyProduct() {
	a.mu.Lock()
	active := a.activeProductLocked()
	demo := a.demo
	a.mu.Unlock()

	if active == product.ProductA2345 {
		a.stopPump()
		if a.sess != nil {
			a.sess.Stop()
		}
		a.mu.Lock()
		a.snap = Snapshot{Phase: PhaseIdle}
		a.mu.Unlock()
		a.startCloud(demo)
	} else {
		a.stopCloud()
		if a.sess != nil {
			if err := a.sess.UseMock(demo); err != nil {
				log.Printf("app: session mode: %v", err)
			}
		}
		a.restartPump()
	}
	a.syncEnergyProducts()
	a.fitWindowForProduct(active)
	a.publishNow()
}

// startCloud starts the cloud engine for the demo flag, replacing a running
// one of the other kind.
func (a *App) startCloud(demo bool) {
	a.cloudMu.Lock()
	defer a.cloudMu.Unlock()
	if a.cloud != nil && a.cloud.demo == demo {
		return
	}
	a.stopCloudLocked()

	a.mu.Lock()
	p := a.prefs
	chinese := a.localeLocked() == "zh"
	a.mu.Unlock()
	a.pumpMu.Lock()
	base := a.baseCtx
	a.pumpMu.Unlock()
	if base == nil {
		base = context.Background()
	}

	var store anker.CredentialStore = &anker.MemoryStore{}
	if a.dataDir != "" {
		store = anker.NewFileStore(a.dataDir)
	}
	eng := cloudsession.New(cloudsession.Options{
		Store:          store,
		Demo:           demo,
		SelectedSerial: p.A2345SelectedSerial,
		OnSelectedSerial: func(serial string) {
			// The engine's loop calls this; SetPrefs may call back into it.
			go a.setPrefsQuietly(map[string]any{"a2345SelectedSerial": serial})
		},
		WritesEnabled: p.WritesEnabled,
		ThemeLanguage: anker.ThemeLanguage(chinese),
		DemoModeName:  a.tr(translated{"办公桌", "Desk"}),
		OnSample: func(at time.Time, total float64, perPort [6]float64) {
			if es := a.energyService(); es != nil {
				es.Record(product.ProductA2345, at.UnixMilli(), total, perPort, demo)
			}
		},
		OnEnergyBreak: func() {
			if es := a.energyService(); es != nil {
				es.Break()
			}
		},
		OnMessage: func(t anker.Text) { a.broadcast("message", t) },
		Diagnostics: func(category, message string) {
			log.Printf("a2345 %s: %s", category, message)
		},
	})
	ctx, cancel := context.WithCancel(base)
	if err := eng.Start(ctx); err != nil {
		log.Printf("app: cloud session start: %v", err)
	}
	a.cloud = &cloudRun{eng: eng, cancel: cancel, demo: demo}
	go a.cloudPump(ctx, eng.Subscribe(16))
	log.Printf("app: cloud session starting (demo=%v)", demo)
}

// stopCloud stops the cloud engine, if any.
func (a *App) stopCloud() {
	a.cloudMu.Lock()
	defer a.cloudMu.Unlock()
	a.stopCloudLocked()
}

func (a *App) stopCloudLocked() {
	if a.cloud == nil {
		return
	}
	a.cloud.cancel()
	a.cloud.eng.Stop()
	a.cloud = nil
	a.mu.Lock()
	a.cloudSnap = nil
	a.mu.Unlock()
}

// cloudPump stores the engine's snapshots and publishes AppState at most
// five times a second, like pumpLoop.
func (a *App) cloudPump(ctx context.Context, ch <-chan cloudsession.Snapshot) {
	tick := time.NewTicker(200 * time.Millisecond)
	defer tick.Stop()
	pending := false
	var lastPhase string
	for {
		select {
		case <-ctx.Done():
			return
		case s, ok := <-ch:
			if !ok {
				return
			}
			a.mu.Lock()
			a.cloudSnap = &s
			a.mu.Unlock()
			pending = true
			if phase := string(s.Stage); phase != lastPhase {
				if s.Phase == PhaseFailed {
					a.scheduleCloudHomeRetry(ctx)
				}
				log.Printf("app: a2345 stage=%s", phase)
				lastPhase = phase
				a.publishNow()
				pending = false
			}
		case <-tick.C:
			if pending && a.served.Load() {
				a.publishNow()
				pending = false
			}
		}
	}
}

// setPrefsQuietly applies a preference patch from the app itself.
func (a *App) setPrefsQuietly(patch map[string]any) {
	data, err := json.Marshal(patch)
	if err != nil {
		return
	}
	if err := a.SetPrefs(data); err != nil {
		log.Printf("app: preferences: %v", err)
	}
}

// scheduleCloudHomeRetry is scheduleA2345HomeRetry: while the 250W is in
// Apple Home, a failed cloud connection gets one more try a minute later.
// The engine's context ending (a stop or a restart) cancels it.
func (a *App) scheduleCloudHomeRetry(ctx context.Context) {
	if !a.cloudInHome() {
		return
	}
	go func() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(60 * time.Second):
		}
		eng := a.Cloud()
		if eng == nil || !a.cloudInHome() || eng.Snapshot().Phase != PhaseFailed {
			return
		}
		if err := eng.Retry(); err != nil {
			log.Printf("app: a2345 retry for Home: %v", err)
		}
	}()
}

// cloudInHome is isA2345InHome: Home runs for the 250W and a helper is up.
func (a *App) cloudInHome() bool {
	a.home.mu.Lock()
	p := a.home.product
	a.home.mu.Unlock()
	if p != product.ProductA2345 {
		return false
	}
	s := a.home.status.Load()
	if s == nil {
		return false
	}
	up := func(st matter.Status) bool {
		return st.State != matter.StateUnavailable && st.State != matter.StateFailed && st.State != matter.StateOff
	}
	return up(s.Whole) || up(s.Ports)
}
