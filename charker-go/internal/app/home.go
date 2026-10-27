package app

import (
	"context"
	"errors"
	"log"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"charker/internal/a2345"
	"charker/internal/anker"
	"charker/internal/cloudsession"
	"charker/internal/matter"
	"charker/internal/product"
)

// Apple Home: the AppModel half of MatterService (reconcileMatter,
// feedMatter, handleMatterCommand). Both accessories run while Home is
// switched on, the app is not in demo mode and the first-run setup is done,
// for the product on screen.

// homeHost owns the two Matter helpers.
type homeHost struct {
	// mu serializes reconciling and feeding. It may take a.mu (Localize
	// reads the locale), so a.mu is never held while taking it.
	mu   sync.Mutex
	home *matter.Home
	// product is what the helpers run for; "" while stopped.
	product product.ChargerProduct
	// states is the last list sent, the `previous` of Layout.States.
	states []matter.PortState
	// status is the last HomeStatus the helpers reported; nil before Home
	// was first created. A leaf: buildStateLocked reads it under a.mu.
	status atomic.Pointer[matter.HomeStatus]
	closed atomic.Bool
}

// HomeState is the Apple 家庭 page's state: both accessories' status plus
// what they are called in Home for the product on screen.
type HomeState struct {
	matter.HomeStatus
	// Name is the whole charger's accessory name.
	Name string `json:"name"`
	// Tiles are the per-port accessory's tile names, one per outlet.
	Tiles []string `json:"tiles"`
}

// homeHelperEnv points the app at another helper build (dev only; the
// release looks beside the exe).
const homeHelperEnv = "CHARKER_MATTER_HELPER"

// homeStateLocked builds AppState.home. a.mu must be held.
func (a *App) homeStateLocked() HomeState {
	p := a.activeProductLocked()
	st := HomeState{
		Name:  matter.NewLayout(p, matter.Grouped).Name(),
		Tiles: matter.NewLayout(p, matter.Bridged).Labels(),
	}
	if s := a.home.status.Load(); s != nil {
		st.HomeStatus = *s
	} else {
		off := matter.Status{State: matter.StateOff, Fabrics: -1, MDNSOK: true}
		st.HomeStatus = matter.HomeStatus{Whole: off, Ports: off}
	}
	return st
}

// homeProductLocked is the product Home should run for, or "" when it
// should not run (reconcileMatter's `wanted`). a.mu must be held.
func (a *App) homeProductLocked() product.ChargerProduct {
	if !a.prefs.MatterEnabled || a.demo || a.prefs.DemoMode || !a.prefs.InitialSetupCompleted || a.dataDir == "" {
		return ""
	}
	return a.activeProductLocked()
}

// syncHome starts, switches or stops the helpers to match the preferences
// and the product on screen, then feeds them the latest snapshot. Called on
// every publish, so it costs little when nothing changed.
func (a *App) syncHome() {
	a.mu.Lock()
	snap, cloud := a.snap, a.cloudSnap
	a.mu.Unlock()
	a.syncHomeWith(snap, cloud)
}

func (a *App) syncHomeWith(snap Snapshot, cloud *cloudsession.Snapshot) {
	a.mu.Lock()
	want := a.homeProductLocked()
	a.mu.Unlock()

	h := &a.home
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed.Load() {
		return
	}
	if want != h.product {
		if h.home == nil {
			if want == "" {
				return
			}
			h.home = a.newHome()
		}
		h.product = want
		// The other product's states are from a connection that is gone.
		h.states = nil
		h.home.SetProduct(want)
	}
	if want == "" {
		return
	}
	l, ok := h.home.Layout()
	if !ok {
		return
	}
	states := homeStates(l, snap, cloud, h.states)
	if h.states != nil && equalStates(states, h.states) {
		return
	}
	h.states = states
	h.home.Update(states)
}

func (a *App) newHome() *matter.Home {
	return matter.NewHome(matter.HomeOptions{
		Dir:       filepath.Join(a.dataDir, "Matter"),
		Helper:    os.Getenv(homeHelperEnv),
		Logf:      log.Printf,
		Localize:  a.localizeHome,
		OnCommand: a.homeCommand,
		OnStatus: func(st matter.HomeStatus) {
			a.home.status.Store(&st)
			if !a.home.closed.Load() {
				a.publishNow()
			}
		},
	})
}

// localizeHome names the per-port accessory in the app's language.
func (a *App) localizeHome(key string) string {
	if a.locale() != "en" {
		return key
	}
	switch key {
	case "Charker 160W 端口":
		return "Charker 160W Ports"
	case "Charker 250W 端口":
		return "Charker 250W Ports"
	}
	return key
}

// shutdownHome stops both helpers for good and waits until their UDP ports
// are free, at most two seconds.
func (a *App) shutdownHome() {
	h := &a.home
	h.closed.Store(true)
	h.mu.Lock()
	home := h.home
	h.product = ""
	h.mu.Unlock()
	if home == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	home.Shutdown(ctx)
}

// ResetHomePairing removes one accessory from every Home and shows a fresh
// setup code.
func (a *App) ResetHomePairing(kind matter.Kind) {
	h := &a.home
	h.mu.Lock()
	home := h.home
	running := h.product != ""
	h.mu.Unlock()
	if home != nil && running {
		home.ResetPairing(kind)
	}
}

// homeStates is MatterAccessoryLayout.portStates: every outlet's state from
// the snapshot of the layout's product. A snapshot the simulator left
// behind (demo mode was just switched off) counts as no reading: the
// simulator never reaches Home.
func homeStates(l matter.Layout, snap Snapshot, cloud *cloudsession.Snapshot, previous []matter.PortState) []matter.PortState {
	if l.Product == product.ProductA2345 {
		if cloud == nil || cloud.IsDemo {
			return l.States(nil, false, nil, previous)
		}
		return l.States(cloud.Reading, cloud.Live, cloudSwitches(cloud), previous)
	}
	if snap.Device != nil && snap.Device.Mock {
		return l.States(nil, false, nil, previous)
	}
	return l.States(snap.Reading, snap.Live(), nil, previous)
}

// cloudSwitches is the charger's own port controls by port; nil before the
// first settings snapshot.
func cloudSwitches(cs *cloudsession.Snapshot) map[product.PortID]bool {
	if cs == nil || cs.A2345.Settings == nil {
		return nil
	}
	m := map[product.PortID]bool{}
	for _, g := range cs.A2345.Settings.Groups {
		for _, p := range g.Ports {
			m[product.PortID(p)] = g.IsOn
		}
	}
	return m
}

func equalStates(a, b []matter.PortState) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// homeCommand is handleMatterCommand: a Home switch request goes through
// exactly the gate the port's own switch in the app does, and is always
// answered with the real state. The write blocks until the charger replies,
// so it runs off the helper's dispatcher.
func (a *App) homeCommand(index int, t matter.Target, on bool) {
	go func() {
		defer a.answerHome(index)
		a.home.mu.Lock()
		p := a.home.product
		a.home.mu.Unlock()
		if p == product.ProductA2345 {
			a.homeCommandA2345(t, on)
		} else {
			a.homeCommandA2687(t, on)
		}
	}()
}

func (a *App) homeCommandA2687(t matter.Target, on bool) {
	port, label := t.Ports[0], t.Label
	writes := a.Prefs().WritesEnabled
	var snap Snapshot
	if a.sess != nil {
		snap = a.sess.Snapshot()
	}
	if reason := homeA2687Refusal(writes, a.sess != nil, snap, port); reason != "" {
		a.refuseHome(label, anker.T(reason))
		return
	}
	a.broadcast("message", anker.T("%@：正在发送…", label))
	if err := a.sess.SetPortEnabled(port, on); err != nil {
		log.Printf("app: Home switch %s %v: %v", label, on, err)
		a.broadcast("message", anker.T("%@：%@", label, anker.T(describeError(err))))
		return
	}
	if on {
		a.broadcast("message", anker.T("%@ 已打开", label))
	} else {
		a.broadcast("message", anker.T("%@ 已关闭", label))
	}
}

// homeA2687Refusal is why a 160W port cannot be switched from Home, or "".
func homeA2687Refusal(writesEnabled, haveSession bool, snap Snapshot, port product.PortID) string {
	if !writesEnabled {
		return "在「高级」里打开「允许端口开关」后才能操作"
	}
	if !haveSession || snap.Phase != PhasePolling || snap.Reading == nil {
		return "需要先连上充电器"
	}
	if _, ok := snap.Reading.Port(port); !ok {
		return "需要先连上充电器"
	}
	return ""
}

func (a *App) homeCommandA2345(t matter.Target, on bool) {
	g, ok := homeGroup(t)
	if !ok {
		log.Printf("app: Home command for unknown outlet %q ignored", t.Label)
		return
	}
	label := g.Label()
	eng := a.Cloud()
	if eng == nil {
		a.refuseHome(label, anker.T("需要先连上充电器"))
		return
	}
	cs := eng.Snapshot()
	if b := cs.A2345.PortControlBlocker; b != nil {
		a.refuseHome(label, *b)
		return
	}
	if !hasGroup(cs.A2345.Settings, label) {
		a.refuseHome(label, anker.T("正在读取充电器设置"))
		return
	}
	// The engine shows the new switch state at once; if the charger then
	// refuses, the read-back corrects the app and Home together.
	if err := eng.SetPortOutput(g, on); err != nil {
		var refusal *cloudsession.Refusal
		if errors.As(err, &refusal) {
			a.refuseHome(label, refusal.Text())
			return
		}
		log.Printf("app: Home switch %s %v: %v", label, on, err)
	}
}

// homeGroup is the A2345 control group behind an outlet: the group whose
// first port is the outlet's first port.
func homeGroup(t matter.Target) (a2345.PortGroup, bool) {
	if len(t.Ports) == 0 {
		return 0, false
	}
	for _, g := range a2345.PortGroups {
		if ports := g.Ports(); len(ports) > 0 && ports[0].Label() == string(t.Ports[0]) {
			return g, true
		}
	}
	return 0, false
}

func hasGroup(s *cloudsession.SettingsView, label string) bool {
	if s == nil {
		return false
	}
	for _, g := range s.Groups {
		if g.Group == label {
			return true
		}
	}
	return false
}

func (a *App) refuseHome(label string, reason anker.Text) {
	log.Printf("app: Home request for %s ignored: %s", label, reason.String())
	a.broadcast("message", anker.T("已忽略「家庭」对 %@ 的操作：%@", label, reason))
}

// answerHome feeds the engine's own latest snapshot, which already carries
// a write's optimistic state, then answers the request with it. Both
// accessories show the outlet, so both hear it.
func (a *App) answerHome(index int) {
	a.mu.Lock()
	snap, cloud := a.snap, a.cloudSnap
	a.mu.Unlock()
	if a.sess != nil {
		snap = a.sess.Snapshot()
	}
	if eng := a.Cloud(); eng != nil {
		cs := eng.Snapshot()
		cloud = &cs
	}
	a.syncHomeWith(snap, cloud)
	a.home.mu.Lock()
	home := a.home.home
	a.home.mu.Unlock()
	if home != nil {
		home.Resend(index)
	}
}
