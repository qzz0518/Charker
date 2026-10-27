//go:build !windows

package winble

import (
	"context"
	"errors"
	"testing"

	"charker/internal/product"
	"charker/internal/transport"
)

// TestUnsupportedStub checks that the non-Windows stand-in fails every radio
// operation with transport.ErrUnsupported and still closes its event stream.
func TestUnsupportedStub(t *testing.T) {
	tr := New(Config{})
	if tr.Events() == nil {
		t.Fatal("Events() = nil")
	}
	ctx := context.Background()
	if err := tr.Available(); !errors.Is(err, transport.ErrUnsupported) {
		t.Errorf("Available() = %v, want transport.ErrUnsupported", err)
	}
	if err := tr.Scan(ctx, product.ProductA2687); !errors.Is(err, transport.ErrUnsupported) {
		t.Errorf("Scan() = %v, want transport.ErrUnsupported", err)
	}
	if err := tr.Connect(ctx, "AA:BB:CC:DD:EE:FF"); !errors.Is(err, transport.ErrUnsupported) {
		t.Errorf("Connect() = %v, want transport.ErrUnsupported", err)
	}
	if err := tr.Write(ctx, []byte{1, 2, 3}); !errors.Is(err, transport.ErrUnsupported) {
		t.Errorf("Write() = %v, want transport.ErrUnsupported", err)
	}
	if err := tr.StopScan(); err != nil {
		t.Errorf("StopScan() = %v, want nil", err)
	}
	if err := tr.Disconnect(); err != nil {
		t.Errorf("Disconnect() = %v, want nil", err)
	}
	if err := tr.Close(); err != nil {
		t.Errorf("Close() = %v, want nil", err)
	}
	if err := tr.Close(); err != nil {
		t.Errorf("second Close() = %v, want nil", err)
	}
	for range tr.Events() { // returns once Close's channel close is seen
	}
}
