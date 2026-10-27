//go:build windows

package winble

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"charker/internal/product"
	"charker/internal/transport"
)

// TestTransportLifecycleWithoutHardware exercises the parts of the transport
// that must work before any radio operation: construction, the unsupported
// product/id guards, the not-connected error, and Close closing the event
// stream. It never starts a scan or a connect, so it runs without a charger.
func TestTransportLifecycleWithoutHardware(t *testing.T) {
	tr := New(Config{})
	if tr.Events() == nil {
		t.Fatal("Events() = nil")
	}
	if got := tr.Dropped(); got != 0 {
		t.Errorf("Dropped() = %d, want 0", got)
	}

	ctx := context.Background()
	if err := tr.Write(ctx, []byte{0x01}); !errors.Is(err, transport.ErrNotConnected) {
		t.Errorf("Write before connect = %v, want transport.ErrNotConnected", err)
	}
	if err := tr.Write(ctx, nil); err != nil {
		t.Errorf("Write(nil) = %v, want nil", err)
	}
	if err := tr.Disconnect(); err != nil {
		t.Errorf("Disconnect() = %v, want nil", err)
	}
	if err := tr.StopScan(); err != nil {
		t.Errorf("StopScan() before any scan = %v, want nil", err)
	}

	if err := tr.Close(); err != nil {
		t.Errorf("Close() = %v, want nil", err)
	}
	if err := tr.Close(); err != nil {
		t.Errorf("second Close() = %v, want nil", err)
	}
	if err := tr.Write(ctx, []byte{0x01}); !errors.Is(err, transport.ErrClosed) {
		t.Errorf("Write after Close = %v, want transport.ErrClosed", err)
	}
	for range tr.Events() { // drains the buffer and ends when Close's channel close is seen
	}
}

// TestScanRejectsNonBLEProduct checks the A2345 guard: it runs before the
// adapter is enabled, so it cannot touch the radio.
func TestScanRejectsNonBLEProduct(t *testing.T) {
	tr := New(Config{})
	defer tr.Close()
	err := tr.Scan(context.Background(), product.ProductA2345)
	if !errors.Is(err, transport.ErrUnsupported) {
		t.Fatalf("Scan(A2345) = %v, want transport.ErrUnsupported", err)
	}
}

func TestConnectRejectsInvalidID(t *testing.T) {
	tr := New(Config{})
	defer tr.Close()
	for _, id := range []string{"", "not-a-mac", "AA:BB:CC:DD:EE", "mock-a2687"} {
		err := tr.Connect(context.Background(), id)
		if !errors.Is(err, transport.ErrNotFound) {
			t.Errorf("Connect(%q) = %v, want transport.ErrNotFound", id, err)
		}
	}
}

// TestNormalizeDeviceID checks the id normalisation a scan's uppercase MAC goes
// through before a connect.
func TestNormalizeDeviceID(t *testing.T) {
	got, err := normalizeDeviceID("  aa:bb:cc:dd:ee:ff  ")
	if err != nil {
		t.Fatalf("normalizeDeviceID: %v", err)
	}
	if got != "AA:BB:CC:DD:EE:FF" {
		t.Errorf("normalizeDeviceID = %q, want AA:BB:CC:DD:EE:FF", got)
	}
	for _, id := range []string{"", "nope", "AA-BB-CC-DD-EE-FF"} {
		if _, err := normalizeDeviceID(id); !errors.Is(err, transport.ErrNotFound) {
			t.Errorf("normalizeDeviceID(%q) = %v, want transport.ErrNotFound", id, err)
		}
	}
}

// TestSeenCacheRoundTrip checks the scan-then-connect cache helpers that do not
// need a radio.
func TestSeenCacheRoundTrip(t *testing.T) {
	tr := New(Config{})
	defer tr.Close()
	if _, ok := tr.cached("AA:BB:CC:DD:EE:FF"); ok {
		t.Fatal("cached() found a device before any advertisement")
	}
	tr.remember("aa:bb:cc:dd:ee:ff", seenEntry{name: "ASHDJW-1", rssi: -50})
	e, ok := tr.cached("AA:BB:CC:DD:EE:FF")
	if !ok || e.name != "ASHDJW-1" || e.rssi != -50 {
		t.Fatalf("cached() = (%+v, %v), want the remembered entry", e, ok)
	}
	tr.forget("AA:BB:CC:DD:EE:FF")
	if _, ok := tr.cached("AA:BB:CC:DD:EE:FF"); ok {
		t.Fatal("forget() did not drop the entry")
	}
}

// TestCloseWhileEmitting hammers the emit/Close lock: an event arriving from a
// WinRT callback while the transport closes must neither panic (send on a
// closed channel) nor block. This machine cannot run the Go race detector (no
// cgo C compiler), so this is the concurrency smoke test that does run here.
func TestCloseWhileEmitting(t *testing.T) {
	for i := 0; i < 200; i++ {
		tr := New(Config{EventBuffer: 1})
		stop := make(chan struct{})
		var wg sync.WaitGroup
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
					tr.emit(transport.Event{Kind: transport.EventData, Data: []byte{1}})
				}
			}
		}()

		closed := make(chan struct{})
		go func() {
			_ = tr.Close()
			close(closed)
		}()
		<-closed
		close(stop)
		wg.Wait()
		for range tr.Events() { // drains the buffer, then reports the closed channel
		}
	}
}

// TestWriteTimeoutContextHelper checks that a caller deadline is respected and
// only a deadline-free context gets the configured bound.
func TestWriteTimeoutContextHelper(t *testing.T) {
	tr := New(Config{WriteTimeout: 25})
	defer tr.Close()

	plain, cancel := withTimeout(context.Background(), tr.cfg.WriteTimeout)
	defer cancel()
	if _, ok := plain.Deadline(); !ok {
		t.Error("withTimeout(context.Background()) has no deadline")
	}

	// A caller deadline wins: the configured bound must not shorten it.
	callerDeadline := time.Now().Add(time.Hour)
	parent, parentCancel := context.WithDeadline(context.Background(), callerDeadline)
	defer parentCancel()
	inherited, inheritedCancel := withTimeout(parent, tr.cfg.WriteTimeout)
	defer inheritedCancel()
	deadline, ok := inherited.Deadline()
	if !ok || !deadline.Equal(callerDeadline) {
		t.Errorf("withTimeout(caller deadline) deadline = %v, %v; want the caller's %v", deadline, ok, callerDeadline)
	}
}
