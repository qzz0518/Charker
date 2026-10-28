// Package mock implements transport.Transport with a simulated Anker Prime
// 160W (A2687) charger. It speaks the real A2687 wire protocol subset used by
// the session engine, emits lively ~1 Hz telemetry for the demo script (C2
// charging 42 W Apple PD, C1 enabled idle 5.08 V, C3 off) and applies P1 writes
// to its state.
package mock

import (
	"context"
	"errors"
	"sync"
	"time"

	"charker/internal/product"
	"charker/internal/session/wire"
	"charker/internal/transport"
)

const (
	// DeviceID is the stable id of the simulated charger.
	DeviceID = "mock-a2687"
	// DeviceName is the advertised name.
	DeviceName = "Anker Prime 160W"
	// DeviceAddress is the fake BLE address.
	DeviceAddress = "AA:BB:CC:DD:EE:FF"
	// DefaultRSSI is the simulated signal strength.
	DefaultRSSI = -52
)

// Errors the mock returns.
var (
	ErrDisconnected = errors.New("mock: transport disconnected")
	ErrSimulated    = errors.New("mock: simulated link loss")
)

// Options tunes the simulator. The zero value gives the demo defaults: 1 s
// telemetry, 30 ms connect, 10 ms scan, whole-frame notifications.
type Options struct {
	// ReportInterval is the telemetry push period (default 2 s).
	ReportInterval time.Duration
	// ConnectDelay is the simulated connection establishment time (30 ms).
	ConnectDelay time.Duration
	// ScanDelay is the simulated discovery delay (10 ms).
	ScanDelay time.Duration
	// ChunkSize splits each device notification into chunks of this size
	// (0 = one event per frame). Use 1 to exercise the reassembler.
	ChunkSize int
	// Seed is reserved for future deterministic variation.
	Seed int64
	// Name overrides the advertised name.
	Name string
	// Address overrides the fake BLE address.
	Address string
	// RejectUserAuth answers 0x0027 the way a charger bound to another
	// account does (status 0x09) and keeps streaming, as v0.0.5.2 does.
	RejectUserAuth bool
}

func (o Options) withDefaults() Options {
	if o.ReportInterval <= 0 {
		o.ReportInterval = reportSeconds * time.Second
	}
	if o.ConnectDelay <= 0 {
		o.ConnectDelay = 30 * time.Millisecond
	}
	if o.ScanDelay <= 0 {
		o.ScanDelay = 10 * time.Millisecond
	}
	if o.Name == "" {
		o.Name = DeviceName
	}
	if o.Address == "" {
		o.Address = DeviceAddress
	}
	return o
}

// Transport is a transport.Transport backed by simDevice.
type Transport struct {
	opts   Options
	events chan transport.Event

	ctx    context.Context
	cancel context.CancelFunc

	mu        sync.Mutex // state below
	closed    bool
	scanning  bool
	scanGen   int
	connected bool
	device    *simDevice
	// last is the device of the previous link: the charger is one physical
	// unit, so its ports and settings outlive a reconnect.
	last     *simDevice
	linkDone chan struct{}
	linkGen  int

	devMu sync.Mutex // serialises simDevice access (write vs report ticker)
	emitM sync.RWMutex
	wg    sync.WaitGroup
}

// New returns a simulator with demo defaults.
func New() *Transport { return NewWithOptions(Options{}) }

// NewWithOptions returns a simulator configured by opts.
func NewWithOptions(opts Options) *Transport {
	ctx, cancel := context.WithCancel(context.Background())
	return &Transport{
		opts:   opts.withDefaults(),
		events: make(chan transport.Event, 512),
		ctx:    ctx,
		cancel: cancel,
	}
}

// Events implements transport.Transport.
func (t *Transport) Events() <-chan transport.Event { return t.events }

// Scan implements transport.Transport. It reports one saved mock device after
// a short simulated discovery delay.
func (t *Transport) Scan(ctx context.Context, p product.ChargerProduct) error {
	if p != "" && p != product.ProductA2687 {
		return transport.ErrUnsupported
	}
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return transport.ErrClosed
	}
	if t.scanning {
		t.mu.Unlock()
		return nil
	}
	t.scanning = true
	t.scanGen++
	gen := t.scanGen
	t.mu.Unlock()

	t.wg.Add(1)
	go func() {
		defer t.wg.Done()
		timer := time.NewTimer(t.opts.ScanDelay)
		defer timer.Stop()
		select {
		case <-t.ctx.Done():
			return
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		t.mu.Lock()
		stillScanning := t.scanning && t.scanGen == gen && !t.closed
		t.mu.Unlock()
		if stillScanning {
			t.emit(transport.Event{Kind: transport.EventDiscovered, Device: t.discovered(true)})
		}
	}()
	return nil
}

// StopScan implements transport.Transport.
func (t *Transport) StopScan() error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return transport.ErrClosed
	}
	wasScanning := t.scanning
	t.scanning = false
	t.scanGen++
	t.mu.Unlock()
	if wasScanning {
		t.emit(transport.Event{Kind: transport.EventScanStopped})
	}
	return nil
}

// Connect implements transport.Transport.
func (t *Transport) Connect(ctx context.Context, id string) error {
	if id != "" && id != DeviceID {
		return transport.ErrNotFound
	}
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return transport.ErrClosed
	}
	if t.connected {
		t.mu.Unlock()
		return nil
	}
	t.mu.Unlock()

	timer := time.NewTimer(t.opts.ConnectDelay)
	defer timer.Stop()
	select {
	case <-t.ctx.Done():
		return transport.ErrClosed
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
	}

	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return transport.ErrClosed
	}
	if t.connected {
		t.mu.Unlock()
		return nil
	}
	t.connected = true
	t.linkGen++
	linkDone := make(chan struct{})
	t.linkDone = linkDone
	dev := newSimDevice()
	t.devMu.Lock()
	dev.carryOver(t.last)
	t.devMu.Unlock()
	dev.ephemeral, _ = wire.NewEphemeral()
	dev.rejectAuth = t.opts.RejectUserAuth
	t.device = dev
	interval := t.opts.ReportInterval
	t.mu.Unlock()

	t.wg.Add(1)
	go t.reportLoop(linkDone, interval)
	t.emit(transport.Event{Kind: transport.EventConnected, Device: t.discovered(true)})
	return nil
}

// Disconnect implements transport.Transport.
func (t *Transport) Disconnect() error {
	t.dropLink(nil)
	return nil
}

// SimulateDisconnect drops the simulated link, emitting EventDisconnected with
// err (or ErrSimulated when nil). It is a no-op when not connected.
func (t *Transport) SimulateDisconnect(err error) {
	if err == nil {
		err = ErrSimulated
	}
	t.dropLink(err)
}

func (t *Transport) dropLink(err error) {
	t.mu.Lock()
	if t.closed || !t.connected {
		t.mu.Unlock()
		return
	}
	t.connected = false
	t.last = t.device
	t.device = nil
	if t.linkDone != nil {
		close(t.linkDone)
		t.linkDone = nil
	}
	t.mu.Unlock()
	t.emit(transport.Event{Kind: transport.EventDisconnected, Err: err})
}

// Write implements transport.Transport: the frame goes to the simulated device
// and its responses are delivered as data events.
func (t *Transport) Write(ctx context.Context, data []byte) error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return transport.ErrClosed
	}
	if !t.connected {
		t.mu.Unlock()
		return transport.ErrNotConnected
	}
	dev := t.device
	t.mu.Unlock()

	t.devMu.Lock()
	responses, reportNow := dev.handleFrame(data)
	var telemetry []byte
	if reportNow && dev.streamOn {
		dev.advanceScript()
		telemetry = dev.telemetryFrame()
	}
	t.devMu.Unlock()

	for _, resp := range responses {
		t.emitFrame(resp)
	}
	if reportNow && telemetry != nil {
		t.emitFrame(telemetry)
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
		return nil
	}
}

// Close implements transport.Transport.
func (t *Transport) Close() error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil
	}
	t.closed = true
	if t.connected {
		t.connected = false
		if t.linkDone != nil {
			close(t.linkDone)
			t.linkDone = nil
		}
	}
	t.mu.Unlock()
	t.cancel()
	t.wg.Wait()
	t.emitM.Lock()
	close(t.events)
	t.emitM.Unlock()
	return nil
}

func (t *Transport) reportLoop(linkDone <-chan struct{}, interval time.Duration) {
	defer t.wg.Done()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-t.ctx.Done():
			return
		case <-linkDone:
			return
		case <-ticker.C:
			t.mu.Lock()
			dev := t.device
			connected := t.connected
			t.mu.Unlock()
			if !connected || dev == nil {
				continue
			}
			t.devMu.Lock()
			if !dev.streamOn {
				t.devMu.Unlock()
				continue
			}
			dev.advanceScript()
			frame := dev.telemetryFrame()
			t.devMu.Unlock()
			if frame != nil {
				t.emitFrame(frame)
			}
		}
	}
}

func (t *Transport) discovered(saved bool) transport.Discovered {
	t.mu.Lock()
	name, addr := t.opts.Name, t.opts.Address
	t.mu.Unlock()
	return transport.Discovered{
		ID:      DeviceID,
		Name:    name,
		Address: addr,
		RSSI:    DefaultRSSI,
		Product: product.ProductA2687,
		Saved:   saved,
		Mock:    true,
	}
}

func (t *Transport) emitFrame(frame []byte) {
	if len(frame) == 0 {
		return
	}
	chunk := t.opts.ChunkSize
	if chunk <= 0 || chunk >= len(frame) {
		t.emit(transport.Event{Kind: transport.EventData, Data: frame})
		return
	}
	for start := 0; start < len(frame); start += chunk {
		end := start + chunk
		if end > len(frame) {
			end = len(frame)
		}
		t.emit(transport.Event{Kind: transport.EventData, Data: frame[start:end]})
	}
}

// emit publishes one event without ever blocking the simulator. A full buffer
// drops the oldest event (the session only needs the newest state).
func (t *Transport) emit(ev transport.Event) {
	t.emitM.RLock()
	defer t.emitM.RUnlock()
	if t.closed {
		return
	}
	select {
	case t.events <- ev:
		return
	default:
	}
	select {
	case <-t.events:
	default:
	}
	select {
	case t.events <- ev:
	default:
	}
}
