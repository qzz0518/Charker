package mock

import (
	"context"
	"testing"
	"time"

	"charker/internal/a2687"
	"charker/internal/product"
	"charker/internal/session/wire"
	"charker/internal/transport"
)

// newTestDevice builds a device with a fresh ephemeral key.
func newTestDevice(t *testing.T) *simDevice {
	t.Helper()
	d := newSimDevice()
	eph, err := wire.NewEphemeral()
	if err != nil {
		t.Fatalf("ephemeral: %v", err)
	}
	d.ephemeral = eph
	return d
}

// driveHandshake runs the real A2687 client ladder against the simulated
// device. It is the same code path the session engine uses, so a green result
// is an interop test of client and simulator.
func driveHandshake(t *testing.T, d *simDevice) *a2687.Link {
	t.Helper()
	h := a2687.NewHandshake(a2687.HandshakeConfig{
		ClientID:     "0123456789abcdef0123456789abcdef01234567",
		TimeZoneRule: "CST-8",
		CountryCode:  "CN",
		Now:          func() time.Time { return time.Unix(1_700_000_000, 0) },
	})
	for step := 0; step < 80; step++ {
		frame, done, err := h.Next()
		if err != nil {
			t.Fatalf("handshake next: %v", err)
		}
		if frame != nil {
			responses, _ := d.handleFrame(frame)
			for _, raw := range responses {
				if err := h.HandleResponse(raw); err != nil {
					t.Fatalf("handshake response: %v", err)
				}
			}
			continue
		}
		if done {
			keys, ok := h.Engine().SessionKeys()
			if !ok {
				t.Fatal("handshake ready without session keys")
			}
			return a2687.NewLink(keys)
		}
		t.Fatalf("handshake stalled at stage %s", h.Stage())
	}
	t.Fatal("handshake did not converge")
	return nil
}

// setupReadyDevice returns a ready device and the decoded device identity.
func setupReadyDevice(t *testing.T) (*simDevice, *a2687.Link, a2687.DeviceInfo) {
	t.Helper()
	d := newTestDevice(t)
	h := a2687.NewHandshake(a2687.HandshakeConfig{
		ClientID:     "0123456789abcdef0123456789abcdef01234567",
		TimeZoneRule: "CST-8",
		CountryCode:  "CN",
		Now:          func() time.Time { return time.Unix(1_700_000_000, 0) },
	})
	var info a2687.DeviceInfo
	for step := 0; step < 80; step++ {
		frame, done, err := h.Next()
		if err != nil {
			t.Fatalf("handshake next: %v", err)
		}
		if frame != nil {
			responses, _ := d.handleFrame(frame)
			for _, raw := range responses {
				if err := h.HandleResponse(raw); err != nil {
					t.Fatalf("handshake response: %v", err)
				}
			}
			continue
		}
		if done {
			info = h.Engine().DeviceInfo()
			keys, ok := h.Engine().SessionKeys()
			if !ok {
				t.Fatal("handshake ready without session keys")
			}
			return d, a2687.NewLink(keys), info
		}
		t.Fatalf("handshake stalled at stage %s", h.Stage())
	}
	t.Fatal("handshake did not converge")
	return nil, nil, info
}

func encodeCommand(t *testing.T, link *a2687.Link, message a2687.OutgoingMessage) []byte {
	t.Helper()
	raw, err := link.EncodeCommand(message)
	if err != nil {
		t.Fatalf("encode command: %v", err)
	}
	return raw
}

func TestDeviceHandshakeLadder(t *testing.T) {
	_, _, info := setupReadyDevice(t)
	if info.ProductName != "Charging" {
		t.Errorf("product = %q, want Charging", info.ProductName)
	}
	if info.FirmwareVersion != "v0.0.5.2" {
		t.Errorf("firmware = %q, want v0.0.5.2", info.FirmwareVersion)
	}
	if info.SerialNumber != "ASHDMOCK00000000" {
		t.Errorf("serial = %q, want ASHDMOCK00000000", info.SerialNumber)
	}
	if info.MACAddress != "02:00:5E:10:00:01" {
		t.Errorf("mac = %q, want 02:00:5E:10:00:01", info.MACAddress)
	}
}

func TestDeviceTelemetryDecode(t *testing.T) {
	d, link, _ := setupReadyDevice(t)
	if _, _ = d.handleFrame(encodeCommand(t, link, a2687.RealtimeTrigger(time.Unix(1_700_000_000, 0)))); !d.streamOn {
		t.Fatal("trigger did not arm the telemetry stream")
	}
	d.advanceScript()
	raw := d.telemetryFrame()
	if raw == nil {
		t.Fatal("no telemetry frame")
	}
	tel, err := link.DecodeStateAt(raw, time.Unix(1_700_000_001, 0))
	if err != nil {
		t.Fatalf("decode telemetry: %v", err)
	}
	reading := tel.ProductReading()
	if reading.TotalWatts < 40 || reading.TotalWatts > 44 {
		t.Errorf("total = %v, want ~42", reading.TotalWatts)
	}
	c2, ok := reading.Port(product.PortC2)
	if !ok {
		t.Fatal("C2 missing")
	}
	if !c2.Enabled || c2.Protocol != "Apple PD" {
		t.Errorf("C2 = %+v", c2)
	}
	if c2.VID != 0x05AC || c2.PID != 0x7518 {
		t.Errorf("C2 identity = %04X:%04X, want 05AC:7518", c2.VID, c2.PID)
	}
	c1, _ := reading.Port(product.PortC1)
	if !c1.Enabled || c1.Volts < 5 || c1.Watts != 0 {
		t.Errorf("C1 = %+v", c1)
	}
	settings := tel.ProductSettings()
	if settings == nil || settings.Brightness == nil || *settings.Brightness != 80 {
		t.Errorf("settings = %+v", settings)
	}
}

func TestDevicePortOutputWrite(t *testing.T) {
	d, link, _ := setupReadyDevice(t)
	if _, _ = d.handleFrame(encodeCommand(t, link, a2687.RealtimeTrigger(time.Unix(1_700_000_000, 0)))); !d.streamOn {
		t.Fatal("trigger did not arm the telemetry stream")
	}
	responses, reportNow := d.handleFrame(encodeCommand(t, link, a2687.SetPortOutput(a2687.PortC2, false, time.Unix(1_700_000_000, 0))))
	if len(responses) == 0 {
		t.Fatal("no ACK for port output write")
	}
	if !reportNow {
		t.Error("port output write should request an immediate report")
	}
	if d.ports[1].enabled {
		t.Fatal("C2 should be off after write")
	}
	// A countdown write must be accepted (typed-bytes u32 payload).
	if responses, report := d.handleFrame(encodeCommand(t, link, a2687.SetPortTimer(a2687.PortC2, 300, time.Unix(1_700_000_000, 0)))); len(responses) == 0 || !report {
		t.Fatalf("timer write responses=%d report=%v", len(responses), report)
	}
	if d.ports[1].totalSecs != 300 || d.ports[1].remainSec != 300 {
		t.Fatalf("timer state = %+v", d.ports[1])
	}
}

func TestTransportScanConnectDisconnect(t *testing.T) {
	tr := NewWithOptions(Options{ReportInterval: 10 * time.Millisecond, ConnectDelay: time.Millisecond, ScanDelay: time.Millisecond})
	defer tr.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	events := tr.Events()
	if err := tr.Scan(ctx, product.ProductA2687); err != nil {
		t.Fatalf("Scan: %v", err)
	}
	ev := waitKind(t, events, transport.EventDiscovered, 2*time.Second)
	if ev.Device.ID != DeviceID || !ev.Device.Saved || !ev.Device.Mock || ev.Device.Product != product.ProductA2687 {
		t.Fatalf("discovery event = %+v", ev)
	}
	if err := tr.Connect(ctx, DeviceID); err != nil {
		t.Fatalf("Connect: %v", err)
	}
	_ = waitKind(t, events, transport.EventConnected, 2*time.Second)
	if err := tr.Disconnect(); err != nil {
		t.Fatalf("Disconnect: %v", err)
	}
	_ = waitKind(t, events, transport.EventDisconnected, 2*time.Second)
	if err := tr.Write(ctx, []byte{0x00}); err != transport.ErrNotConnected {
		t.Fatalf("Write while disconnected = %v, want ErrNotConnected", err)
	}
}

func waitKind(t *testing.T, ch <-chan transport.Event, kind transport.EventKind, timeout time.Duration) transport.Event {
	t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case ev := <-ch:
			if ev.Kind == kind {
				return ev
			}
		case <-deadline:
			t.Fatalf("timeout waiting for event kind %d", kind)
		}
	}
}
