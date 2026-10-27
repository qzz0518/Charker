package matter

import (
	"context"
	"path/filepath"
	"sync"

	"charker/internal/product"
)

// HomeOptions configure a Home.
type HomeOptions struct {
	// Dir holds one pairing folder per accessory (Layout.StorageName), e.g.
	// %APPDATA%\Charker\Matter.
	Dir string
	// Helper is the helper executable; "" is DefaultHelperPath().
	Helper string
	// Logf receives log lines; nil discards them.
	Logf func(format string, args ...any)
	// Localize translates a bridged accessory's name (a macOS localization
	// key, "Charker 160W 端口"); nil keeps it.
	Localize func(key string) string
	// OnCommand: a controller switched the outlet at index (of Layout()) on
	// or off. Put it through the same gate as the port's own switch in the
	// app, then answer with Resend(index) whatever came of it: that is how a
	// refused switch flips back in Home. Unanswered requests are answered
	// with the current state after 10 s.
	OnCommand func(index int, target Target, on bool)
	// OnStatus is called after either helper's status changes.
	OnStatus func(HomeStatus)
}

// HomeStatus is both accessories for the settings page.
type HomeStatus struct {
	// Whole is the one-accessory charger, Ports the bridge with a tile per port.
	Whole Status `json:"whole"`
	Ports Status `json:"ports"`
}

// Home runs the two accessories every charger is published as: the whole
// charger (Grouped, UDP 5540) and one tile per port (Bridged, UDP 5541).
type Home struct {
	opts  HomeOptions
	whole *Service
	ports *Service

	mu     sync.Mutex
	layout *Layout
}

// NewHome returns a Home with both helpers stopped.
func NewHome(opts HomeOptions) *Home {
	h := &Home{opts: opts}
	mk := func(prefix string) *Service {
		return NewService(Options{
			Helper:    opts.Helper,
			Logf:      opts.Logf,
			LogPrefix: prefix,
			OnCommand: func(index int, on bool) { h.command(index, on) },
			OnStatus:  func(Status) { h.statusChanged() },
		})
	}
	h.whole = mk("Matter")
	h.ports = mk("Matter ports")
	return h
}

// SetProduct runs both helpers for p, or stops them for "" (Home off, demo
// mode, no charger picked yet). Switching products drops the port states;
// follow with Update.
func (h *Home) SetProduct(p product.ChargerProduct) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if p == "" {
		h.layout = nil
		h.whole.Stop()
		h.ports.Stop()
		return
	}
	if h.layout != nil && h.layout.Product == p {
		return
	}
	l := NewLayout(p, Grouped)
	h.layout = &l
	for _, kind := range []Kind{Grouped, Bridged} {
		h.service(kind).Start(h.config(NewLayout(p, kind)))
	}
}

// Layout is the outlets of the running product (both accessories share it).
func (h *Home) Layout() (Layout, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.layout == nil {
		return Layout{}, false
	}
	return *h.layout, true
}

// Update gives both accessories the latest state of every outlet, in
// Layout() order (Layout.States builds it from a reading).
func (h *Home) Update(states []PortState) {
	h.whole.Update(states)
	h.ports.Update(states)
}

// Resend answers a Home request with the outlet's real state. Both
// accessories show the outlet, so both hear it.
func (h *Home) Resend(index int) {
	h.whole.Resend(index)
	h.ports.Resend(index)
}

// ResetPairing removes one accessory from every Home it was added to and
// shows a fresh setup code.
func (h *Home) ResetPairing(kind Kind) { h.service(kind).ResetPairing() }

// Status is both helpers' status.
func (h *Home) Status() HomeStatus {
	return HomeStatus{Whole: h.whole.Status(), Ports: h.ports.Status()}
}

// Stop stops both helpers.
func (h *Home) Stop() { h.SetProduct("") }

// Shutdown stops both helpers and waits until they are gone or ctx ends;
// call it on app exit so Home does not wait on a dead helper's UDP port.
func (h *Home) Shutdown(ctx context.Context) {
	h.mu.Lock()
	h.layout = nil
	h.mu.Unlock()
	var wg sync.WaitGroup
	for _, s := range []*Service{h.whole, h.ports} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.Shutdown(ctx)
		}()
	}
	wg.Wait()
}

func (h *Home) service(kind Kind) *Service {
	if kind == Bridged {
		return h.ports
	}
	return h.whole
}

func (h *Home) config(l Layout) Config {
	name := l.Name()
	if l.Kind == Bridged && h.opts.Localize != nil {
		name = h.opts.Localize(name)
	}
	return Config{
		Storage: filepath.Join(h.opts.Dir, l.StorageName()),
		Name:    name,
		Labels:  l.Labels(),
		Bridge:  l.Kind == Bridged,
		UDPPort: l.UDPPort(),
	}
}

func (h *Home) command(index int, on bool) {
	l, ok := h.Layout()
	t, known := l.Target(index)
	if !ok || !known {
		// Still answered, so Home does not keep a switch nobody acted on.
		h.Resend(index)
		return
	}
	if f := h.opts.OnCommand; f != nil {
		f(index, t, on)
	} else {
		h.Resend(index)
	}
}

func (h *Home) statusChanged() {
	if f := h.opts.OnStatus; f != nil {
		f(h.Status())
	}
}
