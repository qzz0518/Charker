package cloudsession

import (
	"context"
	"encoding/hex"
	"sync"
	"testing"
	"time"

	"charker/internal/a2345"
	"charker/internal/anker"
)

// Byte-exact frames from the a2345 fixtures and captures.
const (
	fxRealtime = "ff09640003010f030301a10134a2080401883a60065009a3080400000000000000a4080401881314000a00a5080400000000000000a6080400000000000000a7080400000000000000a81104ac05a8120000000000000000fffffffffe0503785634125d"
	// 303-byte 0x0A00, firmware 2.1.1.2, custom mode active, C1 off.
	fxSnapshot = "ff092f0103010f0a0000a10164a203024008a303020000a4080400000000000000a5080400000000000000a6080400000000000000a7080400000000000000a8080400000000000000a9080400000000000000aa140400ff0c0000ff0c000000340800000000000000ab140400ff0c0000ff0c000000201c00000000000000ac140400000c0000000c000000201c00000000000000ad140400000800020017000200580200000000000000ae140400ff0c0000ff0c000000701700000000000000af06040100000000b0020101b1020105b203040000b3020114b4020101b5020101b6020101b70302ff02b8080401000f0f0f0f0fb90604080017007fba0d04030000030000030000030000bb020101bc020101bd1104fafffbfffafffbfffafffbfffafffbfffe050370428f69e4"
	// 0x0A07 acknowledging C1.
	fxAckC1 = "ff09190003010f0a0700a10134a2020100fe050393588e690e"
	// 0x0302 push: C1 switched on.
	fxPortPush = "ff091c0003010f0302a10164a2020100a3020101fe05034c048e6975"
)

func mustHex(tb testing.TB, s string) []byte {
	tb.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		tb.Fatal(err)
	}
	return b
}

// fakeSub is an in-memory Subscriber: the test pushes events, Send records.
type fakeSub struct {
	events  chan anker.MQTTEvent
	sent    chan a2345.Command
	mu      sync.Mutex
	closed  bool
	started bool
	onStart func(*fakeSub)
}

func newFakeSub() *fakeSub {
	return &fakeSub{events: make(chan anker.MQTTEvent, 64), sent: make(chan a2345.Command, 256)}
}

func (f *fakeSub) Start() {
	f.mu.Lock()
	f.started = true
	f.mu.Unlock()
	if f.onStart != nil {
		f.onStart(f)
	}
}

func (f *fakeSub) Events() <-chan anker.MQTTEvent { return f.events }

func (f *fakeSub) Send(c a2345.Command) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return anker.ErrNotSubscribed
	}
	f.sent <- c
	return nil
}

func (f *fakeSub) push(ev anker.MQTTEvent) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.closed {
		f.events <- ev
	}
}

func (f *fakeSub) end(ev anker.MQTTEvent) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return
	}
	f.closed = true
	f.events <- ev
	close(f.events)
}

func (f *fakeSub) Stop() { f.end(anker.MQTTEvent{Kind: anker.MQTTDisconnected}) }

func (f *fakeSub) message(tb testing.TB, frameHex string) {
	f.push(anker.MQTTEvent{Kind: anker.MQTTMessage, Topic: "dt/anker_power/A2345/SERIAL123/data", Payload: mustHex(tb, frameHex)})
}

// nextSent waits for the next command of kind (skipping others).
func (f *fakeSub) nextSent(tb testing.TB, kind a2345.CommandKind) a2345.Command {
	tb.Helper()
	deadline := time.After(3 * time.Second)
	for {
		select {
		case c := <-f.sent:
			if c.Kind() == kind {
				return c
			}
		case <-deadline:
			tb.Fatalf("command kind %d never sent", kind)
			return a2345.Command{}
		}
	}
}

// fakeCloud is the account API.
type fakeCloud struct {
	mu        sync.Mutex
	devices   []anker.BoundDevice
	devErr    error
	credErr   error
	calls     []string
	settings  anker.CloudSettings
	modes     []anker.CloudChargingMode
	mainland  bool
	boundHits int
}

func (c *fakeCloud) record(name string) {
	c.mu.Lock()
	c.calls = append(c.calls, name)
	c.mu.Unlock()
}

func (c *fakeCloud) callList() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.calls...)
}

func (c *fakeCloud) IsMainlandAccount() bool { return c.mainland }

func (c *fakeCloud) BoundDevices(ctx context.Context, product string) ([]anker.BoundDevice, error) {
	c.mu.Lock()
	c.boundHits++
	c.mu.Unlock()
	return append([]anker.BoundDevice(nil), c.devices...), c.devErr
}

func (c *fakeCloud) MQTTCredentials(context.Context) (anker.MQTTCredentials, error) {
	if c.credErr != nil {
		return anker.MQTTCredentials{}, c.credErr
	}
	return anker.MQTTCredentials{
		UserID: "user", AppName: "anker_power", ThingName: "thing", CertificateID: "cert",
		Endpoint: "mqtt.example.com", CertificateDER: []byte{1}, PrivateKeyDER: []byte{2},
	}, nil
}

func (c *fakeCloud) A2345CloudSettings(context.Context, string) (anker.CloudSettings, error) {
	return c.settings, nil
}

func (c *fakeCloud) A2345ChargingModes(context.Context, string) ([]anker.CloudChargingMode, error) {
	return c.modes, nil
}

func (c *fakeCloud) A2345ClockThemes(context.Context, string) ([]anker.CloudTheme, error) {
	return []anker.CloudTheme{}, nil
}

func (c *fakeCloud) A2345CustomScreensavers(context.Context, string) ([]anker.CloudTheme, error) {
	return []anker.CloudTheme{}, nil
}

func (c *fakeCloud) SetA2345CustomModeEnabled(_ context.Context, on bool, _ string) error {
	c.record("customMode")
	return nil
}

func (c *fakeCloud) SetA2345MaxCompatibility(_ context.Context, on bool, _ string) error {
	if on {
		c.record("compatibility:on")
	} else {
		c.record("compatibility:off")
	}
	return nil
}

func (c *fakeCloud) SetA2345DeviceIdentification(_ context.Context, on bool, _ string) error {
	if on {
		c.record("identification:on")
	} else {
		c.record("identification:off")
	}
	return nil
}

func (c *fakeCloud) AddA2345ChargingMode(context.Context, anker.CloudChargingMode, string) error {
	c.record("addMode")
	return nil
}

func (c *fakeCloud) UpdateA2345ChargingMode(context.Context, anker.CloudChargingMode) error {
	c.record("updateMode")
	return nil
}

func (c *fakeCloud) DeleteA2345ChargingMode(context.Context, int) error {
	c.record("deleteMode")
	return nil
}

func (c *fakeCloud) UploadA2345CustomPicture(context.Context, []byte, string) error {
	c.record("upload")
	return nil
}

func (c *fakeCloud) DeleteA2345CustomPicture(context.Context, uint32) error {
	c.record("deletePicture")
	return nil
}

// harness wires an Engine to the fakes.
type harness struct {
	t        *testing.T
	engine   *Engine
	cloud    *fakeCloud
	store    *anker.MemoryStore
	subs     chan *fakeSub
	mu       sync.Mutex
	messages []anker.Text
	selected []string
	breaks   int
	samples  int
	onStart  func(*fakeSub)
}

func validAuth() anker.Authentication {
	return anker.NewAuthentication(anker.Account{UserID: "u", Nickname: "tester"}, "token", time.Now().Add(24*time.Hour), "JP", "")
}

func newHarness(t *testing.T, configure func(*Options)) *harness {
	t.Helper()
	h := &harness{
		t:     t,
		cloud: &fakeCloud{devices: []anker.BoundDevice{{DeviceSerial: "SERIAL123", ProductCode: "A2345", AliasName: "Desk"}}},
		store: &anker.MemoryStore{},
		subs:  make(chan *fakeSub, 16),
	}
	opts := Options{
		Store:            h.store,
		NewCloud:         func(anker.Authentication) Cloud { return h.cloud },
		ReadbackDelay:    10 * time.Millisecond,
		ExtrasRetryDelay: 10 * time.Millisecond,
		RetryUnit:        5 * time.Millisecond,
		OnMessage: func(m anker.Text) {
			h.mu.Lock()
			h.messages = append(h.messages, m)
			h.mu.Unlock()
		},
		OnSelectedSerial: func(s string) {
			h.mu.Lock()
			h.selected = append(h.selected, s)
			h.mu.Unlock()
		},
		OnEnergyBreak: func() {
			h.mu.Lock()
			h.breaks++
			h.mu.Unlock()
		},
		OnSample: func(time.Time, float64, [6]float64) {
			h.mu.Lock()
			h.samples++
			h.mu.Unlock()
		},
	}
	opts.NewSubscriber = func(cfg anker.MQTTConfig) Subscriber {
		s := newFakeSub()
		h.mu.Lock()
		s.onStart = h.onStart
		h.mu.Unlock()
		h.subs <- s
		return s
	}
	if configure != nil {
		configure(&opts)
	}
	h.engine = New(opts)
	t.Cleanup(h.engine.Stop)
	return h
}

func (h *harness) start() {
	h.t.Helper()
	if err := h.engine.Start(context.Background()); err != nil {
		h.t.Fatal(err)
	}
}

func (h *harness) nextSub() *fakeSub {
	h.t.Helper()
	select {
	case s := <-h.subs:
		return s
	case <-time.After(3 * time.Second):
		h.t.Fatal("no subscriber created")
		return nil
	}
}

func (h *harness) waitFor(what string, ok func(Snapshot) bool) Snapshot {
	h.t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		s := h.engine.Snapshot()
		if ok(s) {
			return s
		}
		if time.Now().After(deadline) {
			h.t.Fatalf("timed out waiting for %s; stage=%s failure=%v", what, s.Stage, s.Failure)
		}
		time.Sleep(2 * time.Millisecond)
	}
}

func (h *harness) waitMessage(key string) anker.Text {
	h.t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		h.mu.Lock()
		for _, m := range h.messages {
			if m.Key == key || (len(m.Args) == 2 && textKey(m.Args[1]) == key) {
				h.mu.Unlock()
				return m
			}
		}
		h.mu.Unlock()
		time.Sleep(2 * time.Millisecond)
	}
	h.t.Fatalf("message %q never shown", key)
	return anker.Text{}
}

func textKey(v any) string {
	if t, ok := v.(anker.Text); ok {
		return t.Key
	}
	return ""
}

// connect runs the session to waitingForTelemetry and returns the subscriber.
func (h *harness) connect() *fakeSub {
	h.t.Helper()
	sub := h.nextSub()
	sub.push(anker.MQTTEvent{Kind: anker.MQTTConnected})
	sub.push(anker.MQTTEvent{Kind: anker.MQTTSubscribed})
	h.waitFor("waiting for telemetry", func(s Snapshot) bool { return s.Stage == PhaseWaitingForTelemetry })
	return sub
}
