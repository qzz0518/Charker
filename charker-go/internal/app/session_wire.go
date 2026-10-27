package app

import (
	"context"
	"errors"
	"log"
	"sync"
	"time"

	"charker/internal/product"
	"charker/internal/session"
	"charker/internal/transport"
	"charker/internal/transport/mock"
	"charker/internal/transport/winble"
)

// errNoSession is returned by actions that need a running engine.
var errNoSession = errors.New("charger session is not started")

// SessionConfig configures the session host.
type SessionConfig struct {
	// Mock starts the simulated charger.
	Mock bool
	// Remembered lists saved charger ids, most recent first.
	Remembered []string
	// LastDevice is the most recently connected charger id, tried first.
	LastDevice string
	// WritesEnabled is the port-switching opt-in (Advanced screen).
	WritesEnabled bool
}

// SessionHost adapts charker/internal/session to the app's Session seam and
// owns the mock/real manager swap behind Charker.UseMock. One host per
// process; the app restarts its snapshot pump after UseMock because the
// subscription belongs to the swapped-out manager.
type SessionHost struct {
	mu   sync.Mutex
	opts session.Options
	ctx  context.Context
	mgr  *session.Manager
	mock bool
}

// NewSessionHost returns a host over session.Manager. mockMode starts it on
// the simulated charger.
func NewSessionHost(cfg SessionConfig) *SessionHost {
	opts := session.DefaultOptions()
	opts.WritesEnabled = cfg.WritesEnabled
	remembered := make([]string, 0, len(cfg.Remembered)+1)
	if cfg.LastDevice != "" {
		remembered = append(remembered, cfg.LastDevice)
	}
	for _, id := range cfg.Remembered {
		if id != "" && id != cfg.LastDevice {
			remembered = append(remembered, id)
		}
	}
	opts.Remembered = remembered
	return &SessionHost{opts: opts, mock: cfg.Mock}
}

// SetOnSample wires the energy integration callback into the manager
// options. Call it before Start.
func (h *SessionHost) SetOnSample(fn func(atUnixMs int64, totalWatts float64, perPortWatts [6]float64)) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if fn == nil {
		h.opts.OnSample = nil
		return
	}
	h.opts.OnSample = func(at time.Time, totalWatts float64, perPortWatts [6]float64) {
		fn(at.UnixMilli(), totalWatts, perPortWatts)
	}
}

// Start starts the current engine and remembers ctx for later swaps.
func (h *SessionHost) Start(ctx context.Context) error {
	h.mu.Lock()
	h.ctx = ctx
	mgr := h.mgr
	h.mu.Unlock()
	if mgr != nil {
		return nil
	}
	return h.spawn(ctx)
}

// spawn creates a manager for the current mode and starts it.
func (h *SessionHost) spawn(ctx context.Context) error {
	h.mu.Lock()
	mockMode := h.mock
	opts := h.opts
	h.mu.Unlock()

	// The simulator may always be switched, as on macOS: the write gate
	// protects a real charger.
	if mockMode {
		opts.WritesEnabled = true
	}
	mgr := session.NewManager(h.newTransport(mockMode), opts)
	h.mu.Lock()
	h.mgr = mgr
	h.mu.Unlock()
	log.Printf("app: session starting (mock=%v)", mockMode)
	return mgr.Start(ctx)
}

// newTransport builds the transport of one mode.
func (h *SessionHost) newTransport(mockMode bool) transport.Transport {
	if mockMode {
		return mock.New()
	}
	return winble.New(winble.Config{Logf: log.Printf})
}

// Stop ends the engine and releases the transport.
func (h *SessionHost) Stop() {
	h.mu.Lock()
	mgr := h.mgr
	h.mgr = nil
	h.mu.Unlock()
	if mgr != nil {
		mgr.Stop()
	}
}

// Snapshot returns the current view, an idle snapshot before Start.
func (h *SessionHost) Snapshot() Snapshot {
	h.mu.Lock()
	mgr := h.mgr
	h.mu.Unlock()
	if mgr == nil {
		return emptySnapshot()
	}
	return mgr.Snapshot()
}

// Subscribe returns a channel of snapshots from the current manager.
func (h *SessionHost) Subscribe(buffer int) <-chan Snapshot {
	h.mu.Lock()
	mgr := h.mgr
	h.mu.Unlock()
	if mgr == nil {
		ch := make(chan Snapshot)
		close(ch)
		return ch
	}
	return mgr.Subscribe(buffer)
}

// Scan starts a scan for chargers.
func (h *SessionHost) Scan() error {
	return h.withManager(func(m *session.Manager) error { return m.Scan() })
}

// StopScan stops the scan.
func (h *SessionHost) StopScan() error {
	return h.withManager(func(m *session.Manager) error { return m.StopScan() })
}

// Connect connects to the charger with the given id.
func (h *SessionHost) Connect(id string) error {
	return h.withManager(func(m *session.Manager) error { return m.Connect(id) })
}

// Disconnect drops the link.
func (h *SessionHost) Disconnect() error {
	return h.withManager(func(m *session.Manager) error { return m.Disconnect() })
}

// Reconnect retries the last connection.
func (h *SessionHost) Reconnect() error {
	return h.withManager(func(m *session.Manager) error { return m.Reconnect() })
}

// SetPortEnabled turns one port's output on or off.
func (h *SessionHost) SetPortEnabled(port product.PortID, on bool) error {
	return h.withManager(func(m *session.Manager) error { return m.SetPortEnabled(port, on) })
}

// SetPortTimer arms (seconds > 0) or cancels one port's countdown.
func (h *SessionHost) SetPortTimer(port product.PortID, seconds int) error {
	return h.withManager(func(m *session.Manager) error { return m.SetPortTimer(port, seconds) })
}

// SetRemembered updates the saved chargers the engine reconnects to.
func (h *SessionHost) SetRemembered(ids []string) error {
	h.mu.Lock()
	h.opts.Remembered = append([]string(nil), ids...)
	mgr := h.mgr
	h.mu.Unlock()
	if mgr == nil {
		return nil
	}
	return mgr.SetRemembered(ids)
}

// SetSetting writes one charger setting.
func (h *SessionHost) SetSetting(key, value string) error {
	return h.withManager(func(m *session.Manager) error { return m.SetSetting(key, value) })
}

// UpdateLimits sets the charger's rated power.
func (h *SessionHost) UpdateLimits(limitWatts float64) error {
	return h.withManager(func(m *session.Manager) error { return m.UpdateLimits(limitWatts) })
}

// SetWritesEnabled turns the port-switch/countdown write gate on or off.
func (h *SessionHost) SetWritesEnabled(on bool) error {
	h.mu.Lock()
	h.opts.WritesEnabled = on
	mgr := h.mgr
	if h.mock {
		on = true
	}
	h.mu.Unlock()
	if mgr == nil {
		return nil // applies when the manager starts
	}
	return mgr.SetWritesEnabled(on)
}

// UseMock swaps to the simulated charger (on) or the Bluetooth transport
// (off), restarting the engine on the remembered context.
func (h *SessionHost) UseMock(on bool) error {
	h.mu.Lock()
	if h.mock == on && h.mgr != nil {
		h.mu.Unlock()
		return nil
	}
	old := h.mgr
	h.mgr = nil
	h.mock = on
	ctx := h.ctx
	h.mu.Unlock()

	if old != nil {
		old.Stop()
	}
	if ctx == nil {
		return nil // Start builds the manager for the new mode
	}
	return h.spawn(ctx)
}

// withManager runs fn on the current manager.
func (h *SessionHost) withManager(fn func(*session.Manager) error) error {
	h.mu.Lock()
	mgr := h.mgr
	h.mu.Unlock()
	if mgr == nil {
		return errNoSession
	}
	return fn(mgr)
}

// emptySnapshot is what the app sees before the engine starts.
func emptySnapshot() Snapshot {
	return Snapshot{
		Phase:      PhaseIdle,
		Devices:    []Device{},
		History:    []session.HistorySample{},
		LimitWatts: 160,
	}
}
