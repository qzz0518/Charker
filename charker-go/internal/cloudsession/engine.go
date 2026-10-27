package cloudsession

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"charker/internal/a2345"
	"charker/internal/anker"
	"charker/internal/product"
	"charker/internal/session"
)

// Cloud is the account API the engine uses; *anker.CloudClient implements it.
type Cloud interface {
	IsMainlandAccount() bool
	BoundDevices(ctx context.Context, productCode string) ([]anker.BoundDevice, error)
	MQTTCredentials(ctx context.Context) (anker.MQTTCredentials, error)
	A2345CloudSettings(ctx context.Context, serial string) (anker.CloudSettings, error)
	A2345ChargingModes(ctx context.Context, serial string) ([]anker.CloudChargingMode, error)
	A2345ClockThemes(ctx context.Context, language string) ([]anker.CloudTheme, error)
	A2345CustomScreensavers(ctx context.Context, serial string) ([]anker.CloudTheme, error)
	SetA2345CustomModeEnabled(ctx context.Context, on bool, serial string) error
	SetA2345MaxCompatibility(ctx context.Context, on bool, serial string) error
	SetA2345DeviceIdentification(ctx context.Context, on bool, serial string) error
	AddA2345ChargingMode(ctx context.Context, mode anker.CloudChargingMode, serial string) error
	UpdateA2345ChargingMode(ctx context.Context, mode anker.CloudChargingMode) error
	DeleteA2345ChargingMode(ctx context.Context, id int) error
	UploadA2345CustomPicture(ctx context.Context, jpeg []byte, serial string) error
	DeleteA2345CustomPicture(ctx context.Context, id uint32) error
}

// Subscriber is the MQTT session the engine drives; *anker.Subscriber
// implements it.
type Subscriber interface {
	Start()
	Stop()
	Events() <-chan anker.MQTTEvent
	Send(a2345.Command) error
}

// Errors returned by Engine. User-facing refusals are *Refusal (Localized).
var (
	ErrClosed         = errors.New("cloudsession: closed")
	ErrNotRunning     = errors.New("cloudsession: not running")
	ErrAlreadyStarted = errors.New("cloudsession: already started")
	ErrBusy           = errors.New("cloudsession: sign-in already in progress")
	ErrNoStore        = errors.New("cloudsession: no credential store")
)

// Refusal is a write or action the engine refused, with the Mac's message.
type Refusal struct{ Message anker.Text }

func (r *Refusal) Error() string    { return r.Message.String() }
func (r *Refusal) Text() anker.Text { return r.Message }

// Options configures an Engine. Zero durations take the macOS defaults.
//
// The callbacks run on the engine's loop goroutine: they must return quickly
// and must not call Engine methods synchronously (Snapshot is fine).
type Options struct {
	// Store keeps the auth token (anker.NewFileStore under the data dir).
	Store anker.CredentialStore
	// HTTPClient is used for sign-in and cloud requests; nil = anker default.
	HTTPClient *http.Client
	// Demo runs the simulated charger instead of the cloud.
	Demo bool
	// SelectedSerial is Preferences.a2345SelectedSerial; OnSelectedSerial
	// persists a change (manual pick, or the automatic single-device fallback).
	SelectedSerial   string
	OnSelectedSerial func(serial string)
	// WritesEnabled is the A2687 "allow port switching" opt-in, shared by the
	// A2345 port switches, countdowns and schedules.
	WritesEnabled bool
	// ThemeLanguage is anker.ThemeLanguage of the UI ("zh-Hans" or "en").
	ThemeLanguage string
	// DemoModeName names the simulator's stored custom mode (the localized
	// "办公桌").
	DemoModeName string
	// Clock is the wall clock; nil = time.Now.
	Clock func() time.Time
	// OnSample receives every telemetry sample (total and per-port watts
	// C1 C2 C3 C4 A1 A2), like session.Options.OnSample; feed internal/energy.
	OnSample func(at time.Time, totalWatts float64, perPortWatts [6]float64)
	// OnEnergyBreak is finishA2345EnergyObservation: close the current
	// energy segment (device switch, failure, sign-out).
	OnEnergyBreak func()
	// OnMessage is setActionMessage: one transient user-facing message.
	OnMessage func(anker.Text)
	// Diagnostics records one line (category "MQTT", "WRITE", "CLOUD").
	// Lines never contain tokens, topics, serials or payload bytes.
	Diagnostics func(category, message string)

	// Test seams. NewCloud defaults to anker.NewCloudClient, NewSubscriber
	// to anker.NewSubscriber, Account to an anker.AccountClient on HTTPClient.
	NewCloud      func(anker.Authentication) Cloud
	NewSubscriber func(anker.MQTTConfig) Subscriber
	Account       *anker.AccountClient

	// Timings (AppModel's constants).
	TelemetryWatchdog    time.Duration // 45 s without telemetry renews the subscription
	StaleAfter           time.Duration // 15 s without telemetry marks the reading stale
	ReadbackDelay        time.Duration // 800 ms after a write settles
	SettingsRetryAfter   time.Duration // re-request 0x0200 at most every 10 s while settings are missing
	RetryUnit            time.Duration // reconnect delay unit: 1 s << n, capped at 16
	MaxConsecutiveFails  int           // 5
	AckUnit              time.Duration // scales the acknowledgement waits (1 s)
	ThemeDownloadTimeout time.Duration // 45 s
	ExtrasRetryDelay     time.Duration // 20 s between account-data attempts
	DemoInterval         time.Duration // 2 s
}

func (o *Options) defaults() {
	set := func(d *time.Duration, v time.Duration) {
		if *d <= 0 {
			*d = v
		}
	}
	set(&o.TelemetryWatchdog, 45*time.Second)
	set(&o.StaleAfter, 15*time.Second)
	set(&o.ReadbackDelay, 800*time.Millisecond)
	set(&o.SettingsRetryAfter, 10*time.Second)
	set(&o.RetryUnit, time.Second)
	set(&o.AckUnit, time.Second)
	set(&o.ThemeDownloadTimeout, 45*time.Second)
	set(&o.ExtrasRetryDelay, 20*time.Second)
	set(&o.DemoInterval, 2*time.Second)
	if o.MaxConsecutiveFails <= 0 {
		o.MaxConsecutiveFails = 5
	}
	if o.ThemeLanguage == "" {
		o.ThemeLanguage = anker.ThemeLanguage(true)
	}
	if o.DemoModeName == "" {
		o.DemoModeName = "办公桌"
	}
	if o.Clock == nil {
		o.Clock = time.Now
	}
	if o.NewCloud == nil {
		httpClient, clock := o.HTTPClient, o.Clock
		o.NewCloud = func(a anker.Authentication) Cloud { return anker.NewCloudClient(a, httpClient, clock) }
	}
	if o.NewSubscriber == nil {
		o.NewSubscriber = func(c anker.MQTTConfig) Subscriber { return anker.NewSubscriber(c) }
	}
	if o.Account == nil {
		o.Account = &anker.AccountClient{HTTP: o.HTTPClient, Now: o.Clock}
	}
}

const historyCap = 600

// timerSlot is one re-armable timer owned by the loop. Re-arming or
// cancelling bumps seq so a callback already queued becomes a no-op.
type timerSlot struct {
	t   *time.Timer
	seq uint64
}

func (s *timerSlot) cancel() {
	if s.t != nil {
		s.t.Stop()
		s.t = nil
	}
	s.seq++
}

// state is owned by the loop goroutine.
type state struct {
	started  bool
	phase    Phase
	attempt  int
	failure  *anker.Text
	device   *Device
	devices  []Device
	reading  *reading
	history  []session.HistorySample
	isStale  bool
	isDemo   bool
	warning  *anker.Text
	settings *a2345.DeviceSettings
	reported map[a2345.PortGroup]time.Time

	hasStoredAuth bool
	nickname      string
	signingIn     bool
	selected      string
	writesEnabled bool

	generation  uint64
	genCancel   context.CancelFunc
	sub         Subscriber
	client      Cloud
	cloudDevice *anker.BoundDevice
	settingsAt  time.Time
	lastDiag    string

	stale, watchdog, readback, themeTimer timerSlot

	pending          []a2345.WriteKey
	writeCancel      map[a2345.WriteKey]context.CancelFunc
	writeLabels      map[a2345.WriteKey]*anker.Text
	writeCompletions map[a2345.WriteKey]func(bool)

	cloudSettings  *anker.CloudSettings
	modes          []anker.CloudChargingMode
	modesLoaded    bool
	themes         []anker.CloudTheme
	themesLoaded   bool
	pictures       []anker.CloudTheme
	picturesLoaded bool
	cloudWork      map[string]bool
	themeDownload  *uint32
	extrasRunning  bool

	demoCancel context.CancelFunc
}

// Engine drives one A2345: the Anker account, the MQTT subscription and the
// writes, or the simulator. All mutable state lives on one loop goroutine
// (the counterpart of AppModel's main actor); public methods are safe from
// any goroutine and Snapshot() is a cheap atomic read.
type Engine struct {
	opts    Options
	actions chan func()
	quit    chan struct{}
	done    chan struct{}

	mu      sync.Mutex
	running bool
	stopped bool
	subs    map[int]chan Snapshot
	nextSub int

	snap atomic.Pointer[Snapshot]
	st   state
	// dirty is loop-owned: the current action has not been published yet.
	dirty bool
}

// New builds an engine; Start runs it.
func New(opts Options) *Engine {
	opts.defaults()
	e := &Engine{
		opts:    opts,
		actions: make(chan func(), 64),
		quit:    make(chan struct{}),
		done:    make(chan struct{}),
		subs:    map[int]chan Snapshot{},
	}
	e.st.phase = PhaseIdle
	e.st.selected = opts.SelectedSerial
	e.st.writesEnabled = opts.WritesEnabled
	e.st.reported = map[a2345.PortGroup]time.Time{}
	e.st.writeCancel = map[a2345.WriteKey]context.CancelFunc{}
	e.st.writeLabels = map[a2345.WriteKey]*anker.Text{}
	e.st.writeCompletions = map[a2345.WriteKey]func(bool){}
	e.st.cloudWork = map[string]bool{}
	initial := e.build()
	e.snap.Store(&initial)
	return e
}

// Start launches the loop and begins the demo or the cloud session (when a
// credential is stored). It does not block.
func (e *Engine) Start(ctx context.Context) error {
	e.mu.Lock()
	if e.stopped {
		e.mu.Unlock()
		return ErrClosed
	}
	if e.running {
		e.mu.Unlock()
		return ErrAlreadyStarted
	}
	e.running = true
	e.mu.Unlock()
	go e.loop()
	go func() {
		select {
		case <-ctx.Done():
			e.Stop()
		case <-e.quit:
		}
	}()
	e.call(func() {
		e.st.started = true
		if e.opts.Demo {
			e.startDemo()
		} else {
			e.startCloud()
		}
	})
	return nil
}

// Stop ends everything (subscription, timers, demo) and closes subscriber
// channels. It is idempotent.
func (e *Engine) Stop() {
	e.mu.Lock()
	if e.stopped {
		e.mu.Unlock()
		return
	}
	e.stopped = true
	running := e.running
	subs := e.subs
	e.subs = map[int]chan Snapshot{}
	e.mu.Unlock()
	if running {
		e.call(func() {
			e.stopDemo()
			e.stopCloud()
			e.st.started = false
		})
		close(e.quit)
		<-e.done
	} else {
		close(e.quit)
	}
	for _, ch := range subs {
		close(ch)
	}
}

// Snapshot returns the latest published state.
func (e *Engine) Snapshot() Snapshot { return *e.snap.Load() }

// Subscribe returns a channel of snapshots; the current one is delivered
// immediately. A slow consumer loses the oldest snapshot. Stop closes it.
func (e *Engine) Subscribe(buffer int) <-chan Snapshot {
	ch := make(chan Snapshot, max(1, buffer))
	e.mu.Lock()
	if e.stopped {
		e.mu.Unlock()
		close(ch)
		return ch
	}
	id := e.nextSub
	e.nextSub++
	e.subs[id] = ch
	e.mu.Unlock()
	ch <- e.Snapshot()
	return ch
}

func (e *Engine) loop() {
	defer close(e.done)
	for {
		select {
		case fn := <-e.actions:
			e.dirty = true
			fn()
			if e.dirty {
				e.publish()
			}
		case <-e.quit:
			return
		}
	}
}

// post queues fn on the loop; false once the engine is closed.
func (e *Engine) post(fn func()) bool {
	select {
	case e.actions <- fn:
		return true
	case <-e.quit:
		return false
	}
}

// call runs fn on the loop and waits; its effect is published before call
// returns. Never call it from the loop.
func (e *Engine) call(fn func()) bool {
	done := make(chan struct{})
	if !e.post(func() { fn(); e.publish(); close(done) }) {
		return false
	}
	select {
	case <-done:
		return true
	case <-e.quit:
		return false
	}
}

// exec runs a public action on the loop, returning its error.
func (e *Engine) exec(fn func() error) error {
	e.mu.Lock()
	running, stopped := e.running, e.stopped
	e.mu.Unlock()
	if stopped {
		return ErrClosed
	}
	if !running {
		return ErrNotRunning
	}
	var err error
	if !e.call(func() { err = fn() }) {
		return ErrClosed
	}
	return err
}

// on runs fn on the loop if generation gen is still current; it reports
// whether fn ran. Used by the background goroutines (Swift's isCurrentA2345Cloud).
func (e *Engine) on(gen uint64, fn func()) bool {
	ran := false
	e.call(func() {
		if e.st.generation == gen && e.st.genCancel != nil {
			fn()
			ran = true
		}
	})
	return ran
}

// arm schedules fn on the loop after d, replacing what slot held.
func (e *Engine) arm(slot *timerSlot, d time.Duration, fn func()) {
	slot.cancel()
	seq := slot.seq
	slot.t = time.AfterFunc(d, func() {
		e.post(func() {
			if slot.seq == seq {
				slot.t = nil
				fn()
			}
		})
	})
}

func (e *Engine) now() time.Time { return e.opts.Clock() }

func (e *Engine) diag(category, format string, args ...any) {
	if e.opts.Diagnostics != nil {
		e.opts.Diagnostics(category, fmt.Sprintf(format, args...))
	}
}

func (e *Engine) message(t anker.Text) {
	if e.opts.OnMessage != nil && !t.IsZero() {
		e.opts.OnMessage(t)
	}
}

func (e *Engine) energyBreak() {
	if e.opts.OnEnergyBreak != nil {
		e.opts.OnEnergyBreak()
	}
}

func (e *Engine) publish() {
	e.dirty = false
	s := e.build()
	e.snap.Store(&s)
	e.mu.Lock()
	subs := make([]chan Snapshot, 0, len(e.subs))
	for _, ch := range e.subs {
		subs = append(subs, ch)
	}
	e.mu.Unlock()
	for _, ch := range subs {
		select {
		case ch <- s:
			continue
		default:
		}
		select {
		case <-ch:
		default:
		}
		select {
		case ch <- s:
		default:
		}
	}
}

// build assembles the snapshot from the loop's state.
func (e *Engine) build() Snapshot {
	st := &e.st
	now := e.now()
	s := Snapshot{
		Phase:     st.phase.SessionPhase(),
		Stage:     st.phase,
		Failure:   st.failure,
		Device:    st.device,
		Devices:   append([]Device{}, st.devices...),
		History:   decimatedHistory(st.history, 180),
		IsStale:   st.isStale,
		IsDemo:    st.isDemo,
		Warning:   st.warning,
		SignedIn:  st.hasStoredAuth,
		SigningIn: st.signingIn,
		Nickname:  st.nickname,
	}
	if st.phase == PhaseReconnecting {
		s.Attempt = st.attempt
	}
	failure := anker.Text{}
	if st.failure != nil {
		failure = *st.failure
	}
	s.StatusLabel, s.StatusDetail = e.statusTexts(failure)
	if st.reading != nil {
		s.Reading = productReading(st.reading, st.settings)
		s.Telemetry = telemetryView(st.reading, st.settings, st.reported, now)
		s.LastUpdatedMs = st.reading.receivedAt.UnixMilli()
	}
	s.Live = st.phase == PhaseMonitoring && st.reading != nil && !st.isStale
	s.CanRetry = e.canRetry()

	x := &s.A2345
	x.Settings = settingsView(st.settings, st.reported, now)
	if st.cloudSettings != nil {
		cs := *st.cloudSettings
		x.CloudSettings = &cs
	}
	if st.modesLoaded {
		x.ChargingModes = append([]anker.CloudChargingMode{}, st.modes...)
	}
	if st.themesLoaded {
		x.Themes = append([]anker.CloudTheme{}, st.themes...)
	}
	if st.picturesLoaded {
		x.CustomPictures = append([]anker.CloudTheme{}, st.pictures...)
	}
	x.CloudWork = sortedWork(st.cloudWork)
	x.PendingWrites = pendingViews(st.pending)
	if st.themeDownload != nil {
		id := *st.themeDownload
		x.ThemeDownload = &id
	}
	x.Mainland = e.isMainland()
	x.ControlBlocker = e.controlBlocker()
	x.PortControlBlocker = e.portControlBlocker()
	x.SwitchBlocker = e.switchBlocker()
	x.NextChargingModeNumber = e.nextChargingModeNumber()
	x.SupportsCustomMode = st.settings != nil && st.settings.Supports(a2345.CapCustomChargingMode)
	x.SupportsPictureThemes = e.supportsPictureThemes()
	_, x.CanToggleClock = e.currentThemeRequest(true)
	x.CanUploadPicture = e.canUploadPicture()
	x.CurrentPictureTheme = e.currentPictureTheme()
	x.WritesEnabled = st.writesEnabled
	return s
}

// statusTexts are AppModel.activeStatusLabel/Detail for the A2345.
func (e *Engine) statusTexts(failure anker.Text) (anker.Text, anker.Text) {
	st := &e.st
	if st.isDemo {
		return anker.T("模拟设备"), anker.T("模拟数据")
	}
	if st.phase == PhaseMonitoring && st.isStale {
		return anker.T("数据已陈旧"), anker.T("超过 15 秒没有收到新数据，当前显示最后一次读数")
	}
	return st.phase.ShortLabel(), st.phase.detail(st.attempt, failure)
}

func (e *Engine) canRetry() bool {
	st := &e.st
	return !st.isDemo && !e.opts.Demo && st.hasStoredAuth && !st.signingIn &&
		!st.phase.IsBusy() && st.phase != PhaseWaitingForTelemetry && e.hasRetryableSelection()
}

func (e *Engine) hasRetryableSelection() bool {
	if len(e.st.devices) <= 1 {
		return true
	}
	for _, d := range e.st.devices {
		if d.Serial == e.st.selected {
			return true
		}
	}
	return false
}

func (e *Engine) isMainland() bool {
	return e.st.client != nil && e.st.client.IsMainlandAccount()
}

// --- account ---

// SignIn signs in with email and password (any country but CN), stores the
// token and (re)starts the cloud session. The password is used for this one
// request only. The returned account id is the A2687 owner id; the app also
// switches its connection mode to the cloud (AppModel.finishSignIn).
func (e *Engine) SignIn(ctx context.Context, email, password, country string) (anker.Account, error) {
	return e.finishSignIn(ctx, func() (anker.Authentication, error) {
		return e.opts.Account.Authenticate(ctx, email, password, country)
	})
}

// SendPhoneVerificationCode is step one of the mainland sign-in: Anker texts
// a six-digit code to the 11-digit number. There is no captcha step.
func (e *Engine) SendPhoneVerificationCode(ctx context.Context, phoneNumber string) error {
	return e.opts.Account.SendPhoneVerificationCode(ctx, phoneNumber)
}

// SignInPhone is step two of the mainland sign-in, with the texted code.
func (e *Engine) SignInPhone(ctx context.Context, phoneNumber, code string) (anker.Account, error) {
	return e.finishSignIn(ctx, func() (anker.Authentication, error) {
		return e.opts.Account.AuthenticatePhone(ctx, phoneNumber, code)
	})
}

func (e *Engine) finishSignIn(ctx context.Context, authenticate func() (anker.Authentication, error)) (anker.Account, error) {
	if e.opts.Store == nil {
		return anker.Account{}, ErrNoStore
	}
	var previous Phase
	err := e.exec(func() error {
		if e.st.signingIn {
			return ErrBusy
		}
		e.st.signingIn = true
		previous = e.st.phase
		e.st.phase = PhaseSigningIn
		return nil
	})
	if err != nil {
		return anker.Account{}, err
	}
	restore := func() {
		e.call(func() {
			e.st.signingIn = false
			if e.st.phase == PhaseSigningIn {
				if previous == PhaseSigningIn {
					e.st.phase = PhaseIdle
				} else {
					e.st.phase = previous
				}
			}
		})
	}
	auth, err := authenticate()
	if err == nil {
		// Cancelled after the network: never persist a late token.
		err = ctx.Err()
	}
	if err != nil {
		restore()
		return anker.Account{}, err
	}
	if err := e.opts.Store.Save(auth); err != nil {
		restore()
		return anker.Account{}, err
	}
	e.call(func() {
		e.st.signingIn = false
		e.st.hasStoredAuth = true
		e.st.nickname = auth.Account.Nickname
		if e.st.phase == PhaseSigningIn {
			e.st.phase = previous
		}
		if e.st.started && !e.opts.Demo {
			e.startCloud()
		}
		e.message(anker.T("账号已验证，正在连接 A2345"))
	})
	return auth.Account, nil
}

// ForgetAccount deletes the stored token and stops the cloud session. When
// the store refuses, the subscription stays alive.
func (e *Engine) ForgetAccount() error {
	return e.exec(func() error {
		if e.opts.Store != nil {
			if err := e.opts.Store.Delete(); err != nil {
				e.message(anker.T("无法删除钥匙串令牌：%@", anker.TextOf(err)))
				return err
			}
		}
		e.energyBreak()
		e.stopCloud()
		e.st.hasStoredAuth = false
		e.st.nickname = ""
		e.st.devices = nil
		e.resetSnapshot()
		e.message(anker.T("已退出 A2345 云端连接"))
		return nil
	})
}

// Retry restarts a failed or idle cloud session (retryA2345Connection).
func (e *Engine) Retry() error {
	return e.exec(func() error {
		if !e.canRetry() {
			return nil
		}
		e.startCloud()
		return nil
	})
}

// SelectDevice switches to another charger bound to the account.
func (e *Engine) SelectDevice(serial string) error {
	return e.exec(func() error {
		st := &e.st
		if e.opts.Demo || !st.hasStoredAuth || st.phase.IsBusy() {
			return nil
		}
		found := false
		for _, d := range st.devices {
			found = found || d.Serial == serial
		}
		if !found || st.selected == serial {
			return nil
		}
		if b := e.switchBlocker(); b != nil {
			e.message(*b)
			return &Refusal{Message: *b}
		}
		// Never integrate device B's first sample across device A's last.
		e.energyBreak()
		e.setSelected(serial)
		e.startCloud()
		return nil
	})
}

func (e *Engine) setSelected(serial string) {
	e.st.selected = serial
	if e.opts.OnSelectedSerial != nil {
		e.opts.OnSelectedSerial(serial)
	}
}

// SetWritesEnabled updates the port-switch opt-in.
func (e *Engine) SetWritesEnabled(on bool) error {
	return e.exec(func() error {
		e.st.writesEnabled = on
		return nil
	})
}

// --- cloud lifecycle ---

func (e *Engine) resetSnapshot() {
	st := &e.st
	st.phase, st.attempt, st.failure = PhaseIdle, 0, nil
	st.device, st.reading, st.history = nil, nil, nil
	st.isStale, st.isDemo, st.warning = false, false, nil
	st.settings = nil
	st.reported = map[a2345.PortGroup]time.Time{}
}

// startCloud is startA2345Cloud.
func (e *Engine) startCloud() {
	e.stopCloud()
	st := &e.st
	if !st.started || e.opts.Demo {
		return
	}
	if st.isDemo {
		e.resetSnapshot()
	}
	st.isDemo = false
	// A cloud reconnect must earn freshness again; durable energy lives in
	// the per-product ledger and is not affected.
	st.reading, st.history = nil, nil
	st.isStale, st.warning, st.failure = false, nil, nil
	st.settings = nil
	st.reported = map[a2345.PortGroup]time.Time{}
	st.phase = PhaseLoadingDevices
	st.lastDiag = ""
	e.diag("MQTT", "starting A2345 cloud session")

	st.generation++
	gen := st.generation
	ctx, cancel := context.WithCancel(context.Background())
	st.genCancel = cancel
	store := e.opts.Store
	go func() {
		var auth *anker.Authentication
		var err error
		if store != nil {
			auth, err = store.Load()
		}
		var valid anker.Authentication
		proceed := e.on(gen, func() {
			switch {
			case err != nil:
				e.st.hasStoredAuth = false
				e.failCloud(anker.TextOf(err), true)
			case auth == nil:
				e.st.hasStoredAuth = false
				e.energyBreak()
				e.resetSnapshot()
			case !auth.Valid(e.now()):
				e.st.hasStoredAuth = false
				e.st.nickname = ""
				_ = store.Delete()
				e.failCloud(anker.T("Anker 登录已过期，请重新登录。"), true)
			default:
				e.st.hasStoredAuth = true
				e.st.nickname = auth.Account.Nickname
				valid = *auth
				return
			}
			auth = nil
		})
		if proceed && auth != nil {
			e.runCloud(ctx, gen, valid)
		}
	}()
}

// stopCloud is stopA2345Cloud.
func (e *Engine) stopCloud() {
	st := &e.st
	st.generation++
	if st.genCancel != nil {
		st.genCancel()
		st.genCancel = nil
	}
	e.cancelWrites()
	st.stale.cancel()
	st.watchdog.cancel()
	if st.sub != nil {
		st.sub.Stop()
		st.sub = nil
	}
	st.devices = nil
	st.extrasRunning = false
	st.themeTimer.cancel()
	st.themeDownload = nil
	st.client = nil
	st.cloudDevice = nil
	st.cloudSettings = nil
	st.modes, st.modesLoaded = nil, false
	st.themes, st.themesLoaded = nil, false
	st.pictures, st.picturesLoaded = nil, false
	st.cloudWork = map[string]bool{}
}

// failCloud applies every terminal cloud edge consistently. A terminal
// failure can keep the last reading for context, marked stale.
func (e *Engine) failCloud(reason anker.Text, reset bool) {
	st := &e.st
	st.stale.cancel()
	st.watchdog.cancel()
	e.energyBreak()
	if reset {
		e.resetSnapshot()
	} else {
		st.isStale = st.reading != nil
		st.settings = nil
		st.reported = map[a2345.PortGroup]time.Time{}
	}
	st.phase = PhaseFailed
	r := reason
	st.failure = &r
	e.cancelWrites()
}

func (e *Engine) expiredAuthentication(err error) {
	e.st.hasStoredAuth = false
	e.st.nickname = ""
	e.st.devices = nil
	if e.opts.Store != nil {
		_ = e.opts.Store.Delete()
	}
	e.failCloud(anker.TextOf(err), true)
}

// runCloud is runA2345Cloud, on its own goroutine; every state change goes
// through e.on(gen, …).
func (e *Engine) runCloud(ctx context.Context, gen uint64, auth anker.Authentication) {
	client := e.opts.NewCloud(auth)
	devices, err := client.BoundDevices(ctx, "A2345")
	if ctx.Err() != nil {
		return
	}
	if err != nil {
		e.on(gen, func() {
			if errors.Is(err, anker.ErrExpiredAuthentication) {
				e.expiredAuthentication(err)
			} else {
				e.failCloud(anker.TextOf(err), false)
			}
		})
		return
	}
	sort.SliceStable(devices, func(i, j int) bool { return devices[i].DeviceSerial < devices[j].DeviceSerial })

	var device anker.BoundDevice
	chosen := false
	e.on(gen, func() {
		st := &e.st
		e.diag("MQTT", "bound A2345 device count=%d", len(devices))
		st.devices = make([]Device, 0, len(devices))
		for _, d := range devices {
			st.devices = append(st.devices, deviceSummary(d))
		}
		if len(devices) == 0 {
			e.failCloud(anker.T("这个账号下没有找到已绑定的 A2345。请先在官方 Anker App 中完成绑定与 Wi-Fi 配网。"), true)
			return
		}
		selected := -1
		for i, d := range devices {
			if d.DeviceSerial == st.selected {
				selected = i
			}
		}
		if len(devices) > 1 && selected < 0 {
			e.failCloud(anker.T("账号下找到 %d 台 A2345。请选择要监控的设备。", len(devices)), true)
			return
		}
		if selected < 0 {
			selected = 0
		}
		device = devices[selected]
		if st.selected != device.DeviceSerial {
			// A previously selected charger can disappear and leave exactly
			// one different device: a real device switch, close the ledger.
			e.energyBreak()
			e.setSelected(device.DeviceSerial)
		}
		summary := deviceSummary(device)
		st.device = &summary
		st.warning = nil
		st.client = client
		d := device
		st.cloudDevice = &d
		e.loadCloudExtras()
		chosen = true
	})
	if !chosen {
		return
	}

	lastFailure := anker.T("A2345 云端连接已中断。")
	budget := NewReconnectBudget(e.opts.MaxConsecutiveFails)
	for {
		if !e.on(gen, func() {
			if budget.ConsecutiveFailures == 0 {
				e.st.phase = PhaseConnecting
			} else {
				e.st.phase = PhaseReconnecting
				e.st.attempt = budget.ConsecutiveFailures
			}
		}) {
			return
		}

		credentials, err := client.MQTTCredentials(ctx)
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			if errors.Is(err, anker.ErrExpiredAuthentication) {
				e.on(gen, func() { e.expiredAuthentication(err) })
				return
			}
			lastFailure = anker.TextOf(err)
		} else if topic, terr := credentials.SubscriptionTopic(device); terr != nil {
			lastFailure = anker.TextOf(terr)
		} else {
			if !e.subscribeOnce(ctx, gen, credentials, device, topic, &budget, &lastFailure) {
				return
			}
		}

		allowed := false
		if !e.on(gen, func() {
			if !budget.RecordFailure() {
				return
			}
			allowed = true
			st := &e.st
			st.stale.cancel()
			st.isStale = st.reading != nil
			st.settings = nil
			st.reported = map[a2345.PortGroup]time.Time{}
			st.phase = PhaseReconnecting
			st.attempt = budget.ConsecutiveFailures
			e.cancelWrites()
		}) {
			return
		}
		if !allowed {
			break
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Duration(budget.RetryDelaySeconds()) * e.opts.RetryUnit):
		}
	}
	e.on(gen, func() { e.failCloud(lastFailure, false) })
}

// subscribeOnce runs one MQTT subscription until it ends; false when the
// generation is gone (the caller returns).
func (e *Engine) subscribeOnce(ctx context.Context, gen uint64, credentials anker.MQTTCredentials,
	device anker.BoundDevice, topic string, budget *ReconnectBudget, lastFailure *anker.Text) bool {
	sub := e.opts.NewSubscriber(anker.MQTTConfig{
		Credentials: credentials,
		Device:      device,
		Topic:       topic,
		ClientID:    credentials.ClientID(rand.Uint32N(100_000)),
	})
	if !e.on(gen, func() {
		e.diag("MQTT", "temporary client identity acquired")
		e.st.sub = sub
	}) {
		return false
	}
	sub.Start()
	for ev := range sub.Events() {
		ended := false
		if !e.on(gen, func() {
			switch ev.Kind {
			case anker.MQTTConnected:
				e.diag("MQTT", "broker accepted connection")
				e.st.phase = PhaseConnecting
			case anker.MQTTSubscribed:
				e.st.settingsAt = e.now()
				e.diag("MQTT", "device topic subscription active")
				e.st.phase = PhaseWaitingForTelemetry
				e.armWatchdog(gen, sub)
			case anker.MQTTMessage:
				if e.handleMessage(ev.Payload) {
					budget.RecordValidTelemetry()
					e.armWatchdog(gen, sub)
				}
			case anker.MQTTDisconnected:
				e.diag("MQTT", "subscription disconnected")
				*lastFailure = anker.T("Anker MQTT 连接已断开。")
				ended = true
			case anker.MQTTFailed:
				*lastFailure = anker.T("Anker MQTT 返回了无效数据。")
				if ev.Err != nil {
					e.diag("MQTT", "subscription failed (kind %d)", ev.Err.Kind)
					*lastFailure = ev.Err.Text()
				}
				ended = true
			}
		}) || ctx.Err() != nil {
			sub.Stop()
			return false
		}
		if ended {
			break
		}
	}
	return e.on(gen, func() {
		if e.st.sub == sub {
			e.st.watchdog.cancel()
			e.st.sub = nil
		}
	})
}

func deviceSummary(d anker.BoundDevice) Device {
	return Device{
		Serial: d.DeviceSerial, Name: d.DisplayName(), Firmware: d.SoftwareVersion,
		WiFiOnline: d.WiFiOnline, Product: string(product.ProductA2345),
		ProductName: product.ProductA2345.DisplayName(),
	}
}

// armWatchdog: broker keepalives only prove the socket is alive. If the
// charger never publishes — or stops while PINGRESP continues — recycle the
// subscription through the bounded retry ladder.
func (e *Engine) armWatchdog(gen uint64, sub Subscriber) {
	var expected time.Time
	if e.st.reading != nil {
		expected = e.st.reading.receivedAt
	}
	e.arm(&e.st.watchdog, e.opts.TelemetryWatchdog, func() {
		st := &e.st
		var current time.Time
		if st.reading != nil {
			current = st.reading.receivedAt
		}
		if st.generation != gen || st.sub != sub || !current.Equal(expected) {
			return
		}
		if !expected.IsZero() {
			st.isStale = true
		}
		e.diag("MQTT", "telemetry deadline reached; renewing subscription")
		sub.Stop()
	})
}

func (e *Engine) armStale(at time.Time) {
	e.arm(&e.st.stale, e.opts.StaleAfter, func() {
		if e.st.reading != nil && e.st.reading.receivedAt.Equal(at) {
			e.st.isStale = true
		}
	})
}

// handleMessage decodes one MQTT payload; true for valid electrical
// telemetry (the only evidence that renews the watchdog and the budget).
func (e *Engine) handleMessage(payload []byte) bool {
	st := &e.st
	bytes, err := anker.DecodeCloudPayload(payload)
	var msg a2345.DecodedMessage
	if err == nil {
		var frame a2345.Frame
		if frame, err = a2345.Decode(bytes); err == nil {
			msg, err = a2345.DecodeMessage(frame)
		}
	}
	if err != nil {
		// Topics may carry non-A2345 housekeeping. Diagnostics name only the
		// error kind: no JSON, serials or topics.
		safe := fmt.Sprintf("%T:%v", err, err)
		if safe != st.lastDiag {
			st.lastDiag = safe
			e.diag("MQTT", "ignored unsupported A2345 payload (%s)", safe)
		}
		return false
	}
	now := e.now()
	switch msg.Kind {
	case a2345.MessageRealtime:
		e.applyReading(readingFrom(msg.Realtime.Ports, now), "first valid A2345 realtime frame received")
		// The snapshot request goes out once per subscription and its reply
		// can be lost; without it no control is shown.
		if st.settings == nil && st.sub != nil &&
			(st.settingsAt.IsZero() || now.Sub(st.settingsAt) >= e.opts.SettingsRetryAfter) {
			st.settingsAt = now
			_ = st.sub.Send(a2345.RequestStatusSnapshot())
			_ = st.sub.Send(a2345.ThemeStatus())
		}
		return true
	case a2345.MessageStatusSnapshot:
		e.applySettings(msg.StatusSnapshot.Settings, now)
		e.applyReading(readingFrom(msg.StatusSnapshot.Ports, now), "first valid A2345 status snapshot received")
		return true
	case a2345.MessageSettingsUpdate:
		e.applyUpdates(msg.Updates, now)
		// 0x0301: new firmware is running. Read everything again, as the
		// official app does, so the update flag and capabilities catch up.
		for _, u := range msg.Updates {
			if u.Kind == a2345.UpdateFirmwareVersion {
				e.requestReadback(true)
				break
			}
		}
	case a2345.MessageAcknowledgement:
		e.resolveWrite(*msg.Acknowledgement)
	case a2345.MessageVersionInfo:
		e.diag("MQTT", "A2345 version frame received")
		if st.device != nil && st.device.Firmware != msg.VersionInfo.SoftwareVersion {
			d := *st.device
			d.Firmware = msg.VersionInfo.SoftwareVersion
			st.device = &d
		}
	}
	return false
}

// applyReading keeps UI, history, stale timer and energy identical for both
// electrical frames.
func (e *Engine) applyReading(r *reading, firstDiag string) {
	st := &e.st
	if st.phase != PhaseMonitoring {
		e.diag("MQTT", "%s", firstDiag)
	}
	st.phase = PhaseMonitoring
	e.record(r)
	e.armStale(r.receivedAt)
}

// record is applyA2345: the reading, one history sample, one energy sample.
func (e *Engine) record(r *reading) {
	st := &e.st
	st.reading = r
	st.isStale = false
	per := r.orderedPortPower()
	total := r.totalPower()
	st.history = append(st.history, session.HistorySample{T: r.receivedAt.UnixMilli(), Total: total, PerPort: per[:]})
	if len(st.history) > historyCap {
		st.history = append([]session.HistorySample(nil), st.history[len(st.history)-historyCap:]...)
	}
	if e.opts.OnSample != nil {
		e.opts.OnSample(r.receivedAt, total, per)
	}
}

func (e *Engine) applySettings(incoming a2345.DeviceSettings, at time.Time) {
	st := &e.st
	merged := incoming.Clone()
	if st.settings != nil {
		merged = st.settings.MergingSnapshot(incoming)
	}
	for g, c := range merged.PortControls {
		if c.CountdownEnabled {
			st.reported[g] = at
		}
	}
	st.settings = &merged
	if merged.FirmwareVersion != nil && st.device != nil && st.device.Firmware != *merged.FirmwareVersion {
		d := *st.device
		d.Firmware = *merged.FirmwareVersion
		st.device = &d
	}
}

func (e *Engine) applyUpdates(updates []a2345.SettingsUpdate, at time.Time) {
	st := &e.st
	if st.settings == nil {
		return
	}
	next := st.settings.Clone()
	for _, u := range updates {
		if u.Kind == a2345.UpdateThemeDownload && st.themeDownload != nil &&
			(u.ThemeID == nil || *u.ThemeID == *st.themeDownload) {
			// 1 = done, 0 = failed, 4 = wants a Bluetooth transfer;
			// 2 means still downloading.
			if u.Status == 1 || u.Status == 0 || u.Status == 4 {
				e.finishThemeDownload(u.Status == 1)
			}
		}
		next.Apply(u)
		if u.Kind == a2345.UpdatePortCountdown {
			st.reported[u.Group] = at
		}
	}
	st.settings = &next
}
