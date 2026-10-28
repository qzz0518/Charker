package session_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"charker/internal/product"
	"charker/internal/session"
	"charker/internal/transport/mock"
)

func newTestManager(t *testing.T) (*session.Manager, *mock.Transport) {
	t.Helper()
	tr := mock.NewWithOptions(mock.Options{
		ReportInterval: 10 * time.Millisecond,
		ConnectDelay:   time.Millisecond,
		ScanDelay:      time.Millisecond,
	})
	opts := session.DefaultOptions()
	opts.PollInterval = 50 * time.Millisecond
	opts.StaleAfter = 500 * time.Millisecond
	opts.StageTimeout = 250 * time.Millisecond
	opts.MaxBackoff = 20 * time.Millisecond
	opts.ReplyTimeout = 750 * time.Millisecond
	opts.OpeningBurstSpacing = 0
	opts.WritesEnabled = true
	m := session.NewManager(tr, opts)
	t.Cleanup(m.Stop)
	return m, tr
}

func waitFor(t *testing.T, m *session.Manager, what string, cond func(session.Snapshot) bool) session.Snapshot {
	t.Helper()
	deadline := time.Now().Add(4 * time.Second)
	var last session.Snapshot
	for time.Now().Before(deadline) {
		last = m.Snapshot()
		if cond(last) {
			return last
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("timeout waiting for %s; last snapshot: phase=%s err=%q warning=%q reading=%+v",
		what, last.Phase, last.Err, last.Warning, last.Reading)
	return last
}

func portWatts(t *testing.T, r *product.Reading, id product.PortID) product.PortReading {
	t.Helper()
	if r == nil {
		t.Fatal("no reading")
	}
	p, ok := r.Port(id)
	if !ok {
		t.Fatalf("port %s missing from reading", id)
	}
	return p
}

func TestManagerMockSessionAndTelemetry(t *testing.T) {
	m, _ := newTestManager(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sub := m.Subscribe(64)
	if err := m.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}

	// The engine must scan, find the saved mock device, connect, handshake and
	// reach polling.
	s := waitFor(t, m, "polling with telemetry", func(s session.Snapshot) bool {
		return s.Phase == session.PhasePolling && s.Reading != nil && s.Reading.TotalWatts > 40
	})
	if s.Device == nil || s.Device.ID != mock.DeviceID {
		t.Fatalf("device = %+v, want mock device", s.Device)
	}
	if !s.Device.Connected || !s.Device.Mock {
		t.Fatalf("device flags = %+v", s.Device)
	}
	if len(s.Devices) == 0 || s.Devices[0].ID != mock.DeviceID || !s.Devices[0].Saved {
		t.Fatalf("devices = %+v", s.Devices)
	}
	if s.ConnectedAtMs == 0 {
		t.Fatal("ConnectedAtMs is zero while polling")
	}

	// The Mac demo script: C1 20 V on a 100 W cable, C2 9 V Samsung Fast.
	c1 := portWatts(t, s.Reading, product.PortC1)
	if !c1.Enabled || c1.Volts < 19.5 || c1.Volts > 20.5 || c1.Watts < 40 {
		t.Fatalf("C1 = %+v, want ~20 V delivering", c1)
	}
	c2 := portWatts(t, s.Reading, product.PortC2)
	if !c2.Enabled || c2.Volts < 4.5 || c2.Watts <= 0 {
		t.Fatalf("C2 = %+v, want delivering", c2)
	}
	if s.LimitWatts != 160 {
		t.Fatalf("limit = %v, want 160", s.LimitWatts)
	}

	// Stats integrate the live samples.
	s = waitFor(t, m, "stats", func(s session.Snapshot) bool {
		return s.Stats.PeakW >= 40 && s.Stats.ConnectedMs > 0 && len(s.History) >= 3 && s.Stats.EnergyWh > 0.005
	})
	if len(s.History) > 181 {
		t.Fatalf("history has %d points, want <= 181", len(s.History))
	}
	if s.Stats.AvgW < 40 {
		t.Fatalf("avg = %v, want > 40", s.Stats.AvgW)
	}

	// Subscribers receive published snapshots.
	select {
	case got := <-sub:
		if got.Phase == "" {
			t.Fatal("empty snapshot on subscriber")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no snapshot published to subscriber")
	}

	// Settings carried from telemetry: the Mac demo's 1 min, 70 %, up,
	// auto-rotate on, standard mode.
	set := s.Telemetry.Settings
	if set == nil || set.ScreenBrightness == nil || *set.ScreenBrightness != 70 ||
		set.ScreenTimeout == nil || *set.ScreenTimeout != 1 ||
		set.ScreenOrientation == nil || *set.ScreenOrientation != 0 ||
		set.GyroscopeEnabled == nil || !*set.GyroscopeEnabled ||
		set.ChargingMode == nil || *set.ChargingMode != 1 {
		t.Fatalf("settings = %+v", set)
	}

	// P1 writes: optimistic state + read-back confirmation.
	if err := m.SetPortEnabled(product.PortC2, false); err != nil {
		t.Fatalf("SetPortEnabled(C2,false): %v", err)
	}
	s = waitFor(t, m, "C2 read-back off", func(s session.Snapshot) bool {
		if s.Reading == nil {
			return false
		}
		p, ok := s.Reading.Port(product.PortC2)
		return ok && !p.Enabled && p.Watts == 0
	})
	if s.Stats.PeakW == 0 {
		t.Fatal("peak lost after write")
	}
	if err := m.SetPortEnabled(product.PortC2, true); err != nil {
		t.Fatalf("SetPortEnabled(C2,true): %v", err)
	}
	waitFor(t, m, "C2 read-back on", func(s session.Snapshot) bool {
		if s.Reading == nil {
			return false
		}
		p, ok := s.Reading.Port(product.PortC2)
		return ok && p.Enabled && p.Watts > 0
	})

	// Countdown ACK (no read-back exists).
	if err := m.SetPortTimer(product.PortC2, 300); err != nil {
		t.Fatalf("SetPortTimer: %v", err)
	}

	// Settings write with ACK + telemetry echo.
	if err := m.SetSetting("brightness", "55"); err != nil {
		t.Fatalf("SetSetting(brightness): %v", err)
	}
	waitFor(t, m, "brightness echo", func(s session.Snapshot) bool {
		return s.Telemetry != nil && s.Telemetry.Settings != nil &&
			s.Telemetry.Settings.ScreenBrightness != nil && *s.Telemetry.Settings.ScreenBrightness == 55
	})
	if err := m.SetSetting("theme", "dark"); !errors.Is(err, session.ErrUnsupportedSetting) {
		t.Fatalf("SetSetting(theme) = %v, want ErrUnsupportedSetting", err)
	}
	if err := m.SetSetting("brightness", "7"); !errors.Is(err, session.ErrInvalidArgument) {
		t.Fatalf("SetSetting(brightness,7) = %v, want ErrInvalidArgument", err)
	}
	if err := m.SetSetting("screenTimeout", "5m"); err != nil {
		t.Fatalf("SetSetting(screenTimeout): %v", err)
	}
	if err := m.SetSetting("orientation", "right"); err != nil {
		t.Fatalf("SetSetting(orientation): %v", err)
	}
	if err := m.SetSetting("gyroscope", "false"); err != nil {
		t.Fatalf("SetSetting(gyroscope): %v", err)
	}
	if err := m.SetSetting("fixedAllocation", "dualLaptop"); err != nil {
		t.Fatalf("SetSetting(fixedAllocation): %v", err)
	}

	// Charging mode reads AA back after a fresh read-all.
	confirmed, err := m.SetChargingMode(0)
	if err != nil || !confirmed {
		t.Fatalf("SetChargingMode(AI) = %v, %v; want confirmed", confirmed, err)
	}
	if _, err := m.SetChargingMode(2); !errors.Is(err, session.ErrInvalidArgument) {
		t.Fatalf("bare custom mode = %v, want ErrInvalidArgument", err)
	}
	confirmed, err = m.SetCustomChargingMode(false, [3]int{60, 60, 40})
	if err != nil || !confirmed {
		t.Fatalf("SetCustomChargingMode = %v, %v; want confirmed", confirmed, err)
	}
	if _, err := m.SetCustomChargingMode(false, [3]int{100, 100, 0}); !errors.Is(err, session.ErrInvalidArgument) {
		t.Fatalf("over-limit custom mode = %v, want ErrInvalidArgument", err)
	}

	// A same-charger reconnect keeps the settings the writes changed: the
	// simulator is one device across links, like MockA2687Device.
	if err := m.Reconnect(); err != nil {
		t.Fatalf("Reconnect: %v", err)
	}
	waitFor(t, m, "reconnect boundary", func(s session.Snapshot) bool { return s.Phase != session.PhasePolling })
	s = waitFor(t, m, "settings after reconnect", func(s session.Snapshot) bool {
		set := s.Telemetry
		return s.Phase == session.PhasePolling && set != nil && set.Settings != nil &&
			set.Settings.ScreenTimeout != nil && *set.Settings.ScreenTimeout == 2 &&
			set.Settings.ScreenOrientation != nil && *set.Settings.ScreenOrientation == 3 &&
			set.Settings.GyroscopeEnabled != nil && !*set.Settings.GyroscopeEnabled &&
			set.Settings.ChargingMode != nil && *set.Settings.ChargingMode == 2
	})
	if s.PeripheralID != mock.DeviceID {
		t.Fatalf("peripheral = %q, want the same charger", s.PeripheralID)
	}

	// Limit update is reflected in the snapshot.
	if err := m.UpdateLimits(100); err != nil {
		t.Fatalf("UpdateLimits: %v", err)
	}
	if got := m.Snapshot().LimitWatts; got != 100 {
		t.Fatalf("limit = %v, want 100", got)
	}
}

func TestManagerReconnectAfterLinkLoss(t *testing.T) {
	m, tr := newTestManager(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := m.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	waitFor(t, m, "polling", func(s session.Snapshot) bool {
		return s.Phase == session.PhasePolling && s.Reading != nil
	})
	tr.SimulateDisconnect(nil)
	waitFor(t, m, "reconnecting", func(s session.Snapshot) bool {
		return s.Phase == session.PhaseReconnecting || s.Phase == session.PhaseConnecting
	})
	waitFor(t, m, "recovered polling", func(s session.Snapshot) bool {
		return s.Phase == session.PhasePolling && s.Reading != nil && s.Reading.TotalWatts > 40
	})
}

// A refused 0x0027 moves straight on, as ChargerSession.recover(from:) does,
// instead of sitting out the stage timeout, and says so on the snapshot.
func TestManagerUserAuthRejectedContinuesAtOnce(t *testing.T) {
	tr := mock.NewWithOptions(mock.Options{
		ReportInterval: 10 * time.Millisecond,
		ConnectDelay:   time.Millisecond,
		ScanDelay:      time.Millisecond,
		RejectUserAuth: true,
	})
	opts := session.DefaultOptions()
	opts.PollInterval = 50 * time.Millisecond
	opts.StageTimeout = 10 * time.Second
	opts.OpeningBurstSpacing = 0
	m := session.NewManager(tr, opts)
	t.Cleanup(m.Stop)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	start := time.Now()
	if err := m.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	s := waitFor(t, m, "read-only polling", func(s session.Snapshot) bool {
		return s.Phase == session.PhasePolling && s.Reading != nil
	})
	if elapsed := time.Since(start); elapsed >= opts.StageTimeout {
		t.Fatalf("ladder waited out the stage timeout (%v)", elapsed)
	}
	if !s.AuthRejected {
		t.Fatal("AuthRejected = false after a refused 0x0027")
	}
}

func TestManagerStaleDetection(t *testing.T) {
	tr := mock.NewWithOptions(mock.Options{
		ReportInterval: time.Hour, // no autonomous push
		ConnectDelay:   time.Millisecond,
		ScanDelay:      time.Millisecond,
	})
	opts := session.DefaultOptions()
	opts.PollInterval = 0 // no poll either: after the opening read-all, silence
	opts.StaleAfter = 120 * time.Millisecond
	opts.StageTimeout = 250 * time.Millisecond
	opts.MaxBackoff = 20 * time.Millisecond
	opts.OpeningBurstSpacing = 0
	m := session.NewManager(tr, opts)
	t.Cleanup(m.Stop)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := m.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	waitFor(t, m, "stale", func(s session.Snapshot) bool {
		return s.Phase == session.PhasePolling && s.IsStale
	})
}

func TestManagerWritesDisabledGate(t *testing.T) {
	tr := mock.NewWithOptions(mock.Options{
		ReportInterval: 10 * time.Millisecond,
		ConnectDelay:   time.Millisecond,
		ScanDelay:      time.Millisecond,
	})
	opts := session.DefaultOptions()
	opts.PollInterval = 0
	opts.StageTimeout = 250 * time.Millisecond
	opts.OpeningBurstSpacing = 0
	m := session.NewManager(tr, opts) // writes disabled by default
	t.Cleanup(m.Stop)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := m.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	waitFor(t, m, "polling", func(s session.Snapshot) bool { return s.Phase == session.PhasePolling })
	if err := m.SetPortEnabled(product.PortC1, false); !errors.Is(err, session.ErrWritesDisabled) {
		t.Fatalf("SetPortEnabled with writes disabled = %v, want ErrWritesDisabled", err)
	}
	if err := m.SetSetting("brightness", "60"); err != nil {
		t.Fatalf("settings write should not be gated by writesEnabled: %v", err)
	}
}

func TestManagerLifecycleAndSubscribeClose(t *testing.T) {
	m, _ := newTestManager(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sub := m.Subscribe(2)
	if err := m.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := m.Start(ctx); !errors.Is(err, session.ErrAlreadyStarted) {
		t.Fatalf("second Start = %v, want ErrAlreadyStarted", err)
	}
	waitFor(t, m, "polling", func(s session.Snapshot) bool { return s.Phase == session.PhasePolling })
	m.Stop()
	m.Stop() // idempotent
	select {
	case _, ok := <-sub:
		if ok {
			// drain buffered snapshots until close
			for range sub {
			}
		}
	case <-time.After(2 * time.Second):
		t.Fatal("subscriber channel not closed by Stop")
	}
	if p := m.Snapshot().Phase; p != session.PhaseIdle {
		t.Fatalf("phase after Stop = %s, want idle", p)
	}
	if err := m.SetPortEnabled(product.PortC1, true); !errors.Is(err, session.ErrNotRunning) {
		t.Fatalf("write after Stop = %v, want ErrNotRunning", err)
	}
}
