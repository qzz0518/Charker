//go:build !windows

package winble

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"

	"charker/internal/product"
	"charker/internal/transport"
)

var _ transport.Transport = (*Transport)(nil)

// Transport is the stand-in used on platforms without a BLE backend. It has the
// same construction and method set as the Windows implementation so the app
// package builds everywhere, and every attempt to use the radio fails with
// transport.ErrUnsupported.
type Transport struct {
	cfg       Config
	events    chan transport.Event
	closeOnce sync.Once
	closed    atomic.Bool
}

// New returns the unsupported-platform transport.
func New(cfg Config) *Transport {
	return &Transport{cfg: cfg.withDefaults(), events: make(chan transport.Event)}
}

// Events implements transport.Transport; the channel is closed by Close and
// never receives an event.
func (t *Transport) Events() <-chan transport.Event { return t.events }

// Dropped always reports 0: nothing is ever emitted here.
func (t *Transport) Dropped() uint64 { return 0 }

// Available reports that Bluetooth LE is not implemented on this platform.
func (t *Transport) Available() error { return unsupported() }

// Scan implements transport.Transport.
func (t *Transport) Scan(context.Context, product.ChargerProduct) error { return unsupported() }

// StopScan implements transport.Transport; there is never a scan to stop.
func (t *Transport) StopScan() error { return nil }

// Connect implements transport.Transport.
func (t *Transport) Connect(context.Context, string) error { return unsupported() }

// Disconnect implements transport.Transport; it is a no-op.
func (t *Transport) Disconnect() error { return nil }

// Write implements transport.Transport.
func (t *Transport) Write(context.Context, []byte) error { return unsupported() }

// Close implements transport.Transport.
func (t *Transport) Close() error {
	t.closeOnce.Do(func() {
		t.closed.Store(true)
		close(t.events)
	})
	return nil
}

func unsupported() error {
	return fmt.Errorf("winble: Bluetooth LE is only implemented on Windows: %w", transport.ErrUnsupported)
}
