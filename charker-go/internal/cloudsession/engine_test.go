package cloudsession

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"charker/internal/a2345"
	"charker/internal/anker"
	"charker/internal/session"
)

func TestNoStoredCredentialStaysIdle(t *testing.T) {
	h := newHarness(t, nil)
	h.start()
	s := h.waitFor("idle", func(s Snapshot) bool { return s.Stage == PhaseIdle })
	if s.SignedIn || s.Phase != session.PhaseIdle || s.CanRetry {
		t.Fatalf("snapshot %+v", s)
	}
	if s.StatusLabel.Key != "未连接" || s.StatusDetail.Key != "使用 Anker 账号连接 A2345" {
		t.Fatalf("labels %v %v", s.StatusLabel, s.StatusDetail)
	}
}

func TestFullSessionReachesMonitoringAndWritesAreAcknowledged(t *testing.T) {
	h := newHarness(t, nil)
	_ = h.store.Save(validAuth())
	h.start()
	sub := h.connect()

	s := h.engine.Snapshot()
	if !s.SignedIn || s.Nickname != "tester" || s.Device == nil || s.Device.Serial != "SERIAL123" || s.Device.Name != "Desk" {
		t.Fatalf("device %+v", s.Device)
	}
	if b := s.A2345.ControlBlocker; b == nil || b.Key != "需要先连上充电器" {
		t.Fatalf("blocker before telemetry %v", b)
	}
	h.mu.Lock()
	if len(h.selected) != 1 || h.selected[0] != "SERIAL123" {
		t.Fatalf("selected %v", h.selected)
	}
	h.mu.Unlock()

	sub.message(t, fxRealtime)
	s = h.waitFor("monitoring", func(s Snapshot) bool { return s.Stage == PhaseMonitoring })
	if s.Phase != session.PhasePolling || !s.Live || s.Reading == nil || len(s.Reading.Ports) != 6 ||
		math.Abs(s.Reading.TotalWatts-23.94) > 1e-9 || len(s.History) != 1 || len(s.History[0].PerPort) != 6 {
		t.Fatalf("reading %+v history %+v", s.Reading, s.History)
	}
	c1 := s.Telemetry.Ports[0]
	if c1.Port != "C1" || c1.StatusCode != 1 || math.Abs(c1.Power-23.84) > 1e-9 || c1.Control != nil {
		t.Fatalf("C1 %+v", c1)
	}
	if b := s.A2345.ControlBlocker; b == nil || b.Key != "正在读取充电器设置" {
		t.Fatalf("blocker before settings %v", b)
	}

	sub.message(t, fxSnapshot)
	s = h.waitFor("settings", func(s Snapshot) bool { return s.A2345.Settings != nil })
	if s.A2345.ControlBlocker != nil || s.Device.Firmware != "2.1.1.2" || len(s.A2345.Settings.Groups) != 5 ||
		s.A2345.Settings.Groups[0].IsOn || !s.A2345.Settings.IsCustomChargingMode {
		t.Fatalf("settings %+v blocker %v", s.A2345.Settings, s.A2345.ControlBlocker)
	}
	if b := s.A2345.PortControlBlocker; b == nil || b.Key != "在「高级」里打开「允许端口开关」后才能操作" {
		t.Fatalf("port blocker %v", b)
	}
	var refusal *Refusal
	if err := h.engine.SetPortOutput(a2345.GroupC1, true); !errors.As(err, &refusal) {
		t.Fatalf("write without opt-in: %v", err)
	}

	_ = h.engine.SetWritesEnabled(true)
	if err := h.engine.SetPortOutput(a2345.GroupC1, true); err != nil {
		t.Fatal(err)
	}
	if c := sub.nextSent(t, a2345.CmdSetPortOutput); !c.On() {
		t.Fatal("sent the wrong switch")
	}
	s = h.engine.Snapshot()
	if len(s.A2345.PendingWrites) != 1 || s.A2345.PendingWrites[0].Group != "C1" || !s.A2345.Settings.Groups[0].IsOn {
		t.Fatalf("pending %+v", s.A2345.PendingWrites)
	}
	if s.Telemetry.Ports[0].Control == nil || s.Telemetry.Ports[0].Control.SwitchStatus != 1 {
		t.Fatalf("control %+v", s.Telemetry.Ports[0].Control)
	}
	if s.A2345.SwitchBlocker == nil {
		t.Fatal("a pending write must block device switching")
	}

	sub.message(t, fxAckC1)
	h.waitFor("ack", func(s Snapshot) bool { return len(s.A2345.PendingWrites) == 0 })
	sub.nextSent(t, a2345.CmdStatusSnapshot) // the read-back

	// A change push merges into the settings.
	sub.message(t, fxPortPush)
	h.waitFor("push", func(s Snapshot) bool { return s.A2345.Settings.Groups[0].IsOn })

	data, err := json.Marshal(h.engine.Snapshot())
	if err != nil || bytes.Contains(data, []byte("token")) || bytes.Contains(data, []byte("dt/anker_power")) {
		t.Fatalf("snapshot JSON leaks: %v %s", err, data)
	}
	h.mu.Lock()
	if h.samples < 2 {
		t.Fatalf("samples %d", h.samples)
	}
	h.mu.Unlock()
}

func TestUnacknowledgedWriteResendsOnceThenReportsAndReadsBack(t *testing.T) {
	h := newHarness(t, func(o *Options) { o.AckUnit = 10 * time.Millisecond })
	_ = h.store.Save(validAuth())
	h.start()
	sub := h.connect()
	sub.message(t, fxSnapshot)
	h.waitFor("settings", func(s Snapshot) bool { return s.A2345.ControlBlocker == nil })

	if err := h.engine.SetBrightness(52); err != nil {
		t.Fatal(err)
	}
	first := sub.nextSent(t, a2345.CmdSetBrightness)
	sub.nextSent(t, a2345.CmdSetBrightness) // the resend
	if first.Value() != 50 {
		t.Fatalf("brightness %d", first.Value())
	}
	msg := h.waitMessage("充电器没有回应，这次操作有没有生效不清楚。")
	if label, _ := msg.Args[0].(anker.Text); label.Key != "屏幕亮度" {
		t.Fatalf("label %v", msg.Args)
	}
	sub.nextSent(t, a2345.CmdStatusSnapshot)
	if s := h.engine.Snapshot(); len(s.A2345.PendingWrites) != 0 || *s.A2345.Settings.Brightness != 50 {
		t.Fatalf("after timeout %+v", s.A2345)
	}

	if err := h.engine.SetPortPriority(0b0111); err == nil {
		t.Fatal("three preferred ports accepted")
	}
	h.waitMessage("充电器不接受这个值。")
}

func TestSettingsAreReRequestedWhenTheSnapshotIsLost(t *testing.T) {
	h := newHarness(t, func(o *Options) { o.SettingsRetryAfter = 20 * time.Millisecond })
	_ = h.store.Save(validAuth())
	h.start()
	sub := h.connect()
	time.Sleep(30 * time.Millisecond)
	sub.message(t, fxRealtime)
	sub.nextSent(t, a2345.CmdStatusSnapshot)
	sub.nextSent(t, a2345.CmdThemeStatus)
}

func TestWatchdogRecyclesASilentSubscriptionThroughTheRetryLadder(t *testing.T) {
	h := newHarness(t, func(o *Options) { o.TelemetryWatchdog = 40 * time.Millisecond })
	_ = h.store.Save(validAuth())
	h.start()
	sub := h.connect()
	sub.message(t, fxRealtime)
	sub.message(t, fxSnapshot)
	h.waitFor("settings", func(s Snapshot) bool { return s.A2345.Settings != nil })

	// No telemetry for the deadline: stale, renewed, attempt 1.
	second := h.nextSub()
	s := h.engine.Snapshot()
	if !s.IsStale || s.A2345.Settings != nil || s.Reading == nil {
		t.Fatalf("after watchdog: stale=%v settings=%v", s.IsStale, s.A2345.Settings)
	}
	second.push(anker.MQTTEvent{Kind: anker.MQTTSubscribed})
	second.message(t, fxRealtime)
	s = h.waitFor("monitoring again", func(s Snapshot) bool { return s.Stage == PhaseMonitoring && !s.IsStale })
	if s.StatusLabel.Key != "已连接" {
		t.Fatalf("label %v", s.StatusLabel)
	}
}

func TestConsecutiveFailuresExhaustTheBudget(t *testing.T) {
	h := newHarness(t, func(o *Options) { o.MaxConsecutiveFails = 3 })
	h.onStart = func(s *fakeSub) {
		s.end(anker.MQTTEvent{Kind: anker.MQTTFailed, Err: &anker.MQTTError{Kind: anker.MQTTErrConnectionFailed}})
	}
	_ = h.store.Save(validAuth())
	h.start()
	s := h.waitFor("failed", func(s Snapshot) bool { return s.Stage == PhaseFailed })
	if s.Failure == nil || s.Failure.Key != "无法连接 Anker MQTT 服务。" || s.StatusDetail.Key != s.Failure.Key || !s.CanRetry {
		t.Fatalf("failure %v canRetry %v", s.Failure, s.CanRetry)
	}
	if n := len(h.subs); n != 3 {
		t.Fatalf("%d subscriptions, want 3", n)
	}
	// Retry starts a new generation.
	h.onStart = nil
	if err := h.engine.Retry(); err != nil {
		t.Fatal(err)
	}
	h.waitFor("connecting", func(s Snapshot) bool { return s.Stage == PhaseConnecting || s.Stage == PhaseLoadingDevices })
}

func TestReconnectBudget(t *testing.T) {
	b := NewReconnectBudget(5)
	for i, want := range []int{1, 2, 4, 8} {
		if !b.RecordFailure() || b.RetryDelaySeconds() != want {
			t.Fatalf("failure %d: delay %d", i+1, b.RetryDelaySeconds())
		}
	}
	if b.RecordFailure() || b.ConsecutiveFailures != 5 {
		t.Fatal("fifth failure must be terminal")
	}
	b = NewReconnectBudget(5)
	b.RecordFailure()
	b.RecordFailure()
	b.RecordValidTelemetry()
	if b.ConsecutiveFailures != 0 || !b.RecordFailure() || b.RetryDelaySeconds() != 1 {
		t.Fatal("valid telemetry must reset the streak")
	}
}

func TestExpiredTokensAreDeleted(t *testing.T) {
	h := newHarness(t, nil)
	h.cloud.devErr = anker.ErrExpiredAuthentication
	_ = h.store.Save(validAuth())
	h.start()
	s := h.waitFor("failed", func(s Snapshot) bool { return s.Stage == PhaseFailed })
	if a, _ := h.store.Load(); a != nil || s.SignedIn || s.Failure.Key != "Anker 登录已过期，请重新登录。" {
		t.Fatalf("store=%v signedIn=%v failure=%v", a, s.SignedIn, s.Failure)
	}

	h = newHarness(t, nil)
	expired := validAuth()
	expired.TokenExpiresAt = time.Now().Add(-time.Hour)
	_ = h.store.Save(expired)
	h.start()
	s = h.waitFor("failed", func(s Snapshot) bool { return s.Stage == PhaseFailed })
	if a, _ := h.store.Load(); a != nil || s.Failure.Key != "Anker 登录已过期，请重新登录。" || h.cloud.boundHits != 0 {
		t.Fatalf("expired record: store=%v failure=%v", a, s.Failure)
	}
}

func TestSeveralDevicesNeedAChoice(t *testing.T) {
	h := newHarness(t, nil)
	h.cloud.devices = []anker.BoundDevice{
		{DeviceSerial: "SERIALB", ProductCode: "A2345"},
		{DeviceSerial: "SERIALA", ProductCode: "A2345"},
	}
	_ = h.store.Save(validAuth())
	h.start()
	s := h.waitFor("failed", func(s Snapshot) bool { return s.Stage == PhaseFailed })
	if s.Failure.Key != "账号下找到 %d 台 A2345。请选择要监控的设备。" || len(s.Devices) != 2 || s.Devices[0].Serial != "SERIALA" || s.CanRetry {
		t.Fatalf("failure %v devices %v", s.Failure, s.Devices)
	}
	if err := h.engine.SelectDevice("SERIALB"); err != nil {
		t.Fatal(err)
	}
	h.connect()
	s = h.engine.Snapshot()
	h.mu.Lock()
	defer h.mu.Unlock()
	if s.Device.Serial != "SERIALB" || len(h.selected) != 1 || h.selected[0] != "SERIALB" || h.breaks == 0 {
		t.Fatalf("device %v selected %v breaks %d", s.Device, h.selected, h.breaks)
	}
}

func TestNoBoundDeviceFails(t *testing.T) {
	h := newHarness(t, nil)
	h.cloud.devices = nil
	_ = h.store.Save(validAuth())
	h.start()
	s := h.waitFor("failed", func(s Snapshot) bool { return s.Stage == PhaseFailed })
	if !strings.HasPrefix(s.Failure.Key, "这个账号下没有找到已绑定的 A2345") {
		t.Fatalf("failure %v", s.Failure)
	}
}

func TestLabSwitchesWriteTheAccountFirstAndExcludeEachOther(t *testing.T) {
	h := newHarness(t, nil)
	on := true
	h.cloud.settings = anker.CloudSettings{DeviceIdentification: &on}
	_ = h.store.Save(validAuth())
	h.start()
	sub := h.connect()
	sub.message(t, fxSnapshot)
	h.waitFor("extras and settings", func(s Snapshot) bool {
		return s.A2345.Settings != nil && s.A2345.CloudSettings != nil && s.A2345.ChargingModes != nil
	})
	if err := h.engine.SetMaxCompatibility(true); err != nil {
		t.Fatal(err)
	}
	sub.nextSent(t, a2345.CmdSetDeviceIdentification)
	sub.nextSent(t, a2345.CmdSetMaxCompatibility)
	if calls := h.cloud.callList(); len(calls) != 2 || calls[0] != "identification:off" || calls[1] != "compatibility:on" {
		t.Fatalf("account calls %v", calls)
	}
	h.waitFor("cloud settings", func(s Snapshot) bool {
		cs := s.A2345.CloudSettings
		return cs.MaxCompatibility != nil && *cs.MaxCompatibility && cs.DeviceIdentification != nil && !*cs.DeviceIdentification
	})
}

func TestDemoRunsWithoutAnAccount(t *testing.T) {
	var mu sync.Mutex
	clock := time.Unix(1_900_000_000, 0)
	now := func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		return clock
	}
	advance := func(d time.Duration) {
		mu.Lock()
		clock = clock.Add(d)
		mu.Unlock()
	}
	h := newHarness(t, func(o *Options) {
		o.Demo = true
		o.DemoInterval = 5 * time.Millisecond
		o.DemoModeName = "Desk"
		o.Clock = now
		o.NewCloud = func(anker.Authentication) Cloud { t.Error("demo touched the cloud"); return nil }
	})
	h.start()
	s := h.waitFor("demo reading", func(s Snapshot) bool { return s.Reading != nil && len(s.History) >= 2 })
	if !s.IsDemo || s.Stage != PhaseMonitoring || !s.Live || s.StatusLabel.Key != "模拟设备" || s.Device.Serial != DemoSerial ||
		len(s.A2345.Settings.Groups) != 5 || len(s.A2345.ChargingModes) != 1 || s.A2345.ChargingModes[0].Name != "Desk" ||
		s.A2345.ControlBlocker != nil || s.A2345.PortControlBlocker != nil || s.Reading.TotalWatts <= 0 {
		t.Fatalf("demo snapshot %+v", s)
	}
	if s.Telemetry.Ports[0].Device == nil || s.Telemetry.Ports[0].Device.VendorID != 0x05AC {
		t.Fatalf("demo identity %+v", s.Telemetry.Ports[0])
	}

	// Writes apply locally without the opt-in.
	if err := h.engine.SetPortOutput(a2345.GroupUSBA, false); err != nil {
		t.Fatal(err)
	}
	h.waitFor("USB-A off", func(s Snapshot) bool {
		return !s.A2345.Settings.Groups[4].IsOn && s.Telemetry.Ports[4].Power == 0 && s.Telemetry.Ports[5].Power == 0
	})

	// The simulated countdown switches C2 off when it runs out.
	if err := h.engine.SetPortCountdown(a2345.GroupC2, 60); err != nil {
		t.Fatal(err)
	}
	s = h.waitFor("countdown", func(s Snapshot) bool { return s.A2345.Settings.Groups[1].Countdown.Enabled })
	if r := s.A2345.Settings.Groups[1].Countdown.Remaining; r == nil || *r != 60 {
		t.Fatalf("remaining %v", r)
	}
	advance(30 * time.Second)
	s = h.waitFor("run down", func(s Snapshot) bool {
		r := s.A2345.Settings.Groups[1].Countdown.Remaining
		return r != nil && *r == 30
	})
	if c := s.Telemetry.Ports[1].Control; c == nil || !c.Running || c.CountdownRemaining != 30 {
		t.Fatalf("control %+v", c)
	}
	advance(31 * time.Second)
	h.waitFor("C2 off", func(s Snapshot) bool { return !s.A2345.Settings.Groups[1].IsOn })

	// Stored custom modes are edited locally too.
	mode := s.A2345.ChargingModes[0]
	mode.Number = 2
	if err := h.engine.SaveChargingMode(mode, true); err != nil {
		t.Fatal(err)
	}
	s = h.waitFor("two modes", func(s Snapshot) bool { return len(s.A2345.ChargingModes) == 2 })
	if s.A2345.ChargingModes[1].ID != 2 || *s.A2345.NextChargingModeNumber != 3 {
		t.Fatalf("modes %+v next %v", s.A2345.ChargingModes, s.A2345.NextChargingModeNumber)
	}
	if err := h.engine.ApplyChargingMode(mode); err != nil {
		t.Fatal(err)
	}
	h.waitFor("custom mode", func(s Snapshot) bool { return s.A2345.Settings.IsCustomChargingMode })
}

type stubTransport func(*http.Request) (*http.Response, error)

func (f stubTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestSignInStoresTheTokenAndConnects(t *testing.T) {
	var sawPassword bool
	client := &http.Client{Transport: stubTransport(func(r *http.Request) (*http.Response, error) {
		body, _ := io.ReadAll(r.Body)
		sawPassword = sawPassword || bytes.Contains(body, []byte("hunter2"))
		data, _ := json.Marshal(map[string]any{"code": 0, "data": map[string]any{
			"user_id": "owner-id", "nick_name": "nick", "auth_token": "fresh-token",
			"token_expires_at": time.Now().Add(time.Hour).Unix(),
		}})
		return &http.Response{StatusCode: 200, Body: io.NopCloser(bytes.NewReader(data)), Header: http.Header{}}, nil
	})}
	h := newHarness(t, func(o *Options) { o.HTTPClient = client })
	h.start()
	h.waitFor("idle", func(s Snapshot) bool { return s.Stage == PhaseIdle })

	account, err := h.engine.SignIn(context.Background(), "person@example.com", "hunter2", "JP")
	if err != nil || account.UserID != "owner-id" || sawPassword {
		t.Fatalf("sign in: %v %v (password in clear: %v)", account, err, sawPassword)
	}
	if a, _ := h.store.Load(); a == nil || a.AuthToken != "fresh-token" {
		t.Fatal("token not stored")
	}
	h.connect()
	if s := h.engine.Snapshot(); !s.SignedIn || s.Nickname != "nick" {
		t.Fatalf("snapshot %+v", s)
	}
	h.waitMessage("账号已验证，正在连接 A2345")

	// A bad address fails before the network and leaves the phase alone.
	if _, err := h.engine.SignIn(context.Background(), "nope", "x", "JP"); anker.TextOf(err).Key != "邮箱格式不对" {
		t.Fatalf("err = %v", err)
	}
	if err := h.engine.ForgetAccount(); err != nil {
		t.Fatal(err)
	}
	if a, _ := h.store.Load(); a != nil || h.engine.Snapshot().SignedIn || h.engine.Snapshot().Stage != PhaseIdle {
		t.Fatal("forget kept the account")
	}
}

func TestStopEndsEverything(t *testing.T) {
	h := newHarness(t, nil)
	_ = h.store.Save(validAuth())
	h.start()
	sub := h.connect()
	ch := h.engine.Subscribe(4)
	h.engine.Stop()
	for range ch {
	}
	if _, ok := <-sub.Events(); ok {
		// drain the terminal event
		for range sub.Events() {
		}
	}
	if err := h.engine.SetBrightness(50); !errors.Is(err, ErrClosed) {
		t.Fatalf("after stop: %v", err)
	}
}
