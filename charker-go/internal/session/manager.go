package session

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"charker/internal/product"
	"charker/internal/transport"
)

// Errors returned by Manager. Compare with errors.Is.
var (
	ErrClosed             = errors.New("session: closed")
	ErrNotRunning         = errors.New("session: not running")
	ErrAlreadyStarted     = errors.New("session: already started")
	ErrNotReady           = errors.New("session: charger not ready")
	ErrWritesDisabled     = errors.New("session: writes disabled")
	ErrUnsupportedSetting = errors.New("session: unsupported setting")
	ErrInvalidArgument    = errors.New("session: invalid argument")
	ErrTimeout            = errors.New("session: timed out")
	ErrDeviceRejected     = errors.New("session: device rejected the command")
	ErrLinkLost           = errors.New("session: link lost")
)

// Options configures a Manager. Use DefaultOptions and override fields.
type Options struct {
	// PollInterval is the 6 s poll cadence (realtime probe every tick,
	// read-all every second tick). Zero disables polling.
	PollInterval time.Duration
	// StaleAfter is the age at which the last reading is marked stale (20 s).
	StaleAfter time.Duration
	// StageTimeout is the handshake stage watchdog (8 s).
	StageTimeout time.Duration
	// OpeningBurstSpacing paces the three session-ready commands (400 ms).
	OpeningBurstSpacing time.Duration
	// MaxBackoff caps the reconnect ladder (30 s).
	MaxBackoff time.Duration
	// ReplyTimeout bounds a P1 write waiting for its acknowledgement (6 s).
	ReplyTimeout time.Duration
	// AutoConnect connects to the first discovered charger (default true).
	AutoConnect bool
	// Remembered lists saved charger ids, most recent first.
	Remembered []string
	// ClientID is the 40 lowercase hex install id. Empty generates one.
	ClientID string
	// TimeZoneRule is the POSIX TZ rule sent during the handshake.
	TimeZoneRule string
	// CountryCode is the uppercase region for the bind probe.
	CountryCode string
	// OwnerUserID is the optional Anker account id (40 lowercase hex).
	OwnerUserID string
	// WritesEnabled gates port switch + countdown writes (spec default false,
	// meaning port switching is opt-in). Charger settings are not gated.
	WritesEnabled bool
	// LimitWatts is the total power limit shown by the dashboard (160).
	LimitWatts float64
	// Product is the charger model (default A2687).
	Product product.ChargerProduct
	// Clock is the wall-clock source; nil means time.Now. Tests inject one.
	Clock func() time.Time
	// OnSample is called from the session goroutine for every telemetry
	// sample with the total and per-port watts (product port order C1..C3 in
	// the first three slots); feed internal/energy from here.
	OnSample func(at time.Time, totalWatts float64, perPortWatts [6]float64)
}

// DefaultOptions returns the spec defaults.
func DefaultOptions() Options {
	return Options{
		PollInterval:        6 * time.Second,
		StaleAfter:          20 * time.Second,
		StageTimeout:        8 * time.Second,
		OpeningBurstSpacing: 400 * time.Millisecond,
		MaxBackoff:          30 * time.Second,
		ReplyTimeout:        6 * time.Second,
		AutoConnect:         true,
		TimeZoneRule:        "UTC0",
		CountryCode:         "US",
		LimitWatts:          160,
		Product:             product.ProductA2687,
	}
}

const (
	historyCap        = 600
	maxIntegrableGap  = 120.0 // seconds; no energy is carried across a longer gap
	maxReconnectTries = 6
	minConnectTimeout = 10 * time.Second
)

// Manager owns one charger session. All mutable session state lives on the
// manager's single engine goroutine; public methods are safe from any
// goroutine and Snapshot() is a cheap atomic read.
type Manager struct {
	tr   transport.Transport
	opts Options
	cd   codec

	mu      sync.Mutex
	running bool
	stopped bool
	cancel  context.CancelFunc
	loop    *loop
	subs    map[int]chan Snapshot
	nextSub int

	bootLimit  float64
	bootWrites bool

	snap atomic.Pointer[Snapshot]
}

// NewManager builds a manager around a transport. The manager owns the
// transport: Stop() disconnects and closes it.
func NewManager(t transport.Transport, opts Options) *Manager {
	if opts.Product == "" {
		opts.Product = product.ProductA2687
	}
	if opts.LimitWatts <= 0 {
		opts.LimitWatts = 160
	}
	if opts.CountryCode == "" {
		opts.CountryCode = "US"
	}
	if opts.TimeZoneRule == "" {
		opts.TimeZoneRule = "UTC0"
	}
	if opts.StageTimeout <= 0 {
		opts.StageTimeout = 8 * time.Second
	}
	if opts.StaleAfter <= 0 {
		opts.StaleAfter = 20 * time.Second
	}
	if opts.ReplyTimeout <= 0 {
		opts.ReplyTimeout = 6 * time.Second
	}
	if opts.MaxBackoff <= 0 {
		opts.MaxBackoff = 30 * time.Second
	}
	if opts.ClientID == "" {
		opts.ClientID = newClientID()
	}
	m := &Manager{
		tr:         t,
		opts:       opts,
		cd:         defaultCodec,
		subs:       make(map[int]chan Snapshot),
		bootLimit:  opts.LimitWatts,
		bootWrites: opts.WritesEnabled,
	}
	initial := Snapshot{
		Phase:      PhaseIdle,
		Devices:    []Device{},
		History:    []product.Sample{},
		LimitWatts: opts.LimitWatts,
		Settings:   product.Settings{},
	}
	m.snap.Store(&initial)
	return m
}

func newClientID() string {
	b := make([]byte, 20)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("%040x", uint64(time.Now().UnixNano()))
	}
	return hex.EncodeToString(b)
}

// Start launches the session engine. It does not block: the engine runs until
// ctx is cancelled or Stop is called. Returns ErrAlreadyStarted on a second
// Start.
func (m *Manager) Start(ctx context.Context) error {
	if m.tr == nil {
		return errors.New("session: nil transport")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.running {
		return ErrAlreadyStarted
	}
	runCtx, cancel := context.WithCancel(ctx)
	m.running = true
	m.cancel = cancel
	l := newLoop(m, runCtx, m.opts)
	l.limitWatts = m.bootLimit
	l.writesEnabled = m.bootWrites
	m.loop = l
	go l.run()
	return nil
}

// Stop cancels the engine, waits for it to finish and releases the transport
// and subscriber channels. It is idempotent.
func (m *Manager) Stop() {
	m.mu.Lock()
	if !m.running {
		m.mu.Unlock()
		return
	}
	m.running = false
	m.stopped = true
	l := m.loop
	cancel := m.cancel
	subs := m.subs
	m.subs = make(map[int]chan Snapshot)
	m.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	if l != nil {
		<-l.done
	}
	if m.tr != nil {
		_ = m.tr.Disconnect()
		_ = m.tr.Close()
	}
	for _, ch := range subs {
		close(ch)
	}
}

// Snapshot returns the latest published state. It is cheap and safe from any
// goroutine; returned slices are immutable.
func (m *Manager) Snapshot() Snapshot {
	if p := m.snap.Load(); p != nil {
		return *p
	}
	return Snapshot{Phase: PhaseIdle, Devices: []Device{}, History: []product.Sample{}}
}

// Subscribe returns a channel of snapshots. Subscribing before Start is
// allowed; the current snapshot is delivered immediately and later state
// changes follow. The channel is closed by Stop. A slow consumer loses the
// oldest snapshot rather than blocking the session.
func (m *Manager) Subscribe(buffer int) <-chan Snapshot {
	if buffer < 1 {
		buffer = 1
	}
	ch := make(chan Snapshot, buffer)
	m.mu.Lock()
	if m.stopped {
		m.mu.Unlock()
		close(ch)
		return ch
	}
	id := m.nextSub
	m.nextSub++
	m.subs[id] = ch
	m.mu.Unlock()
	select {
	case ch <- m.Snapshot():
	default:
	}
	return ch
}

// publish stores a snapshot and fans it out without blocking the engine.
func (m *Manager) publish(s Snapshot) {
	m.snap.Store(&s)
	m.mu.Lock()
	subs := make([]chan Snapshot, 0, len(m.subs))
	for _, ch := range m.subs {
		subs = append(subs, ch)
	}
	m.mu.Unlock()
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

// --- controls ---

// Scan drops any current link and starts looking for chargers.
func (m *Manager) Scan() error {
	return m.exec(func(l *loop) error { return l.startScanning() })
}

// StopScan ends an active scan.
func (m *Manager) StopScan() error {
	return m.exec(func(l *loop) error {
		_ = l.tr.StopScan()
		l.scanning = false
		l.publish()
		return nil
	})
}

// Connect connects to one charger id (exclusive manual pick) and starts the
// handshake.
func (m *Manager) Connect(id string) error {
	if id == "" {
		return fmt.Errorf("%w: empty device id", ErrInvalidArgument)
	}
	return m.exec(func(l *loop) error { return l.connectTo(id) })
}

// Disconnect drops the link and returns to idle. Auto-reconnect stays off
// until Scan/Connect/Reconnect is called again.
func (m *Manager) Disconnect() error {
	return m.exec(func(l *loop) error {
		l.userDisconnected = true
		l.targetID = ""
		l.dropLink()
		l.phase = PhaseIdle
		l.scanning = false
		l.current = nil
		l.reading = nil
		l.connectedAt = time.Time{}
		l.stale = false
		l.errStr = ""
		l.warning = ""
		l.resetStats()
		l.stopPoll()
		l.publish()
		return nil
	})
}

// Reconnect retries the last charger (or the first remembered one).
func (m *Manager) Reconnect() error {
	return m.exec(func(l *loop) error {
		l.userDisconnected = false
		l.retryAttempt = 0
		if l.phase == PhasePolling {
			return nil
		}
		target := l.targetID
		if target == "" && l.current != nil {
			target = l.current.ID
		}
		if target == "" && len(l.remembered) > 0 {
			target = l.remembered[0]
		}
		if target == "" {
			return l.startScanning()
		}
		return l.connectTo(target)
	})
}

// SetWritesEnabled turns the port-switch/countdown write gate on or off.
func (m *Manager) SetWritesEnabled(on bool) error {
	m.mu.Lock()
	m.bootWrites = on
	m.mu.Unlock()
	return m.exec(func(l *loop) error {
		l.writesEnabled = on
		return nil
	})
}

// SetRemembered replaces the saved-charger id order used for reconnects.
func (m *Manager) SetRemembered(ids []string) error {
	m.mu.Lock()
	m.opts.Remembered = append([]string(nil), ids...)
	m.mu.Unlock()
	return m.exec(func(l *loop) error {
		l.remembered = append([]string(nil), ids...)
		return nil
	})
}

// UpdateLimits sets the total power limit used by the dashboard.
func (m *Manager) UpdateLimits(limitWatts float64) error {
	if math.IsNaN(limitWatts) || limitWatts < 0 {
		return fmt.Errorf("%w: invalid limit", ErrInvalidArgument)
	}
	m.mu.Lock()
	m.bootLimit = limitWatts
	m.mu.Unlock()
	return m.exec(func(l *loop) error {
		l.limitWatts = limitWatts
		l.publish()
		return nil
	})
}

// SetPortEnabled implements the P1 port switch: optimistic state, then a
// read-back confirmation from the next telemetry sample.
func (m *Manager) SetPortEnabled(port product.PortID, on bool) error {
	if !port.Valid() {
		return fmt.Errorf("%w: unknown port %q", ErrInvalidArgument, port)
	}
	return m.execWrite(func(l *loop, reply chan<- error) error {
		if !l.writesEnabled {
			return ErrWritesDisabled
		}
		if l.phase != PhasePolling || l.hs == nil {
			return ErrNotReady
		}
		idx := portIndex(port)
		frame, err := l.hs.portOutput(idx, on, l.now())
		if err != nil {
			return err
		}
		l.applyOptimisticPort(port, on)
		l.publish()
		p := &pendingWrite{opcode: opPortOutput, kind: writePortEnabled, port: port, on: on, reply: reply, deadline: l.now().Add(l.opts.ReplyTimeout)}
		l.pending = append(l.pending, p)
		if err := l.tr.Write(l.ctx, frame.bytes); err != nil {
			l.removePending(p)
			return fmt.Errorf("session: write port output: %w", err)
		}
		return nil
	})
}

// SetCountdown implements the P1 port countdown write (minutes; 0 cancels).
func (m *Manager) SetCountdown(port product.PortID, minutes int) error {
	if !port.Valid() {
		return fmt.Errorf("%w: unknown port %q", ErrInvalidArgument, port)
	}
	if minutes < 0 || minutes > 1440 {
		return fmt.Errorf("%w: countdown minutes out of range", ErrInvalidArgument)
	}
	return m.execWrite(func(l *loop, reply chan<- error) error {
		if !l.writesEnabled {
			return ErrWritesDisabled
		}
		if l.phase != PhasePolling || l.hs == nil {
			return ErrNotReady
		}
		idx := portIndex(port)
		frame, err := l.hs.portTimer(idx, uint32(minutes*60), l.now())
		if err != nil {
			return err
		}
		p := &pendingWrite{opcode: opPortTimer, kind: writeAckOnly, port: port, reply: reply, deadline: l.now().Add(l.opts.ReplyTimeout)}
		l.pending = append(l.pending, p)
		if err := l.tr.Write(l.ctx, frame.bytes); err != nil {
			l.removePending(p)
			return fmt.Errorf("session: write countdown: %w", err)
		}
		return nil
	})
}

// SetSetting writes one charger setting. Keys are the product.Settings JSON
// names plus "screenTimeout"/"chargingMode"; see parseSetting.
func (m *Manager) SetSetting(key string, value string) error {
	opcode, b, update, err := parseSetting(key, value)
	if err != nil {
		return err
	}
	return m.execWrite(func(l *loop, reply chan<- error) error {
		if l.phase != PhasePolling || l.hs == nil {
			return ErrNotReady
		}
		frame, err := l.hs.setting(opcode, b, l.now())
		if err != nil {
			return err
		}
		update(&l.settings)
		l.publish()
		p := &pendingWrite{opcode: opcode, kind: writeAckOnly, reply: reply, deadline: l.now().Add(l.opts.ReplyTimeout)}
		l.pending = append(l.pending, p)
		if err := l.tr.Write(l.ctx, frame.bytes); err != nil {
			l.removePending(p)
			return fmt.Errorf("session: write setting %q: %w", key, err)
		}
		return nil
	})
}

// settingUpdate applies an optimistic local settings change.
type settingUpdate func(*product.Settings)

func parseSetting(key, value string) (uint16, byte, settingUpdate, error) {
	k := strings.ToLower(strings.TrimSpace(key))
	v := strings.TrimSpace(value)
	switch k {
	case "brightness":
		n, err := strconv.Atoi(v)
		if err != nil || n < 25 || n > 100 {
			return 0, 0, nil, fmt.Errorf("%w: brightness must be 25..100", ErrInvalidArgument)
		}
		return opScreenLite, byte(n), func(s *product.Settings) {
			b := n
			s.Brightness = &b
		}, nil
	case "language":
		code, name, ok := languageCode(v)
		if !ok {
			return 0, 0, nil, fmt.Errorf("%w: language %q", ErrInvalidArgument, v)
		}
		return opScreenLang, code, func(s *product.Settings) { s.Language = &name }, nil
	case "orientation":
		code, name, ok := orientationCode(v)
		if !ok {
			return 0, 0, nil, fmt.Errorf("%w: orientation %q", ErrInvalidArgument, v)
		}
		return opOrient, code, func(s *product.Settings) { s.Orientation = &name }, nil
	case "fixedallocation":
		switch strings.ToLower(v) {
		case "c1priority", "0", "false":
			f := false
			return opFixedAlloc, 0, func(s *product.Settings) { s.FixedAllocation = &f }, nil
		case "duallaptop", "1", "true":
			t := true
			return opFixedAlloc, 1, func(s *product.Settings) { s.FixedAllocation = &t }, nil
		}
		return 0, 0, nil, fmt.Errorf("%w: fixedAllocation %q", ErrInvalidArgument, v)
	case "chargingmode":
		switch strings.ToLower(v) {
		case "ai", "0":
			return opChargeMode, 0, func(s *product.Settings) { v := "ai"; s.ChargingMode = &v }, nil
		case "standard", "1":
			return opChargeMode, 1, func(s *product.Settings) { v := "standard"; s.ChargingMode = &v }, nil
		case "custom", "2":
			return opChargeMode, 2, func(s *product.Settings) { v := "custom"; s.ChargingMode = &v }, nil
		}
		return 0, 0, nil, fmt.Errorf("%w: chargingMode %q", ErrInvalidArgument, v)
	case "screentimeout":
		code, ok := timeoutCode(v)
		if !ok {
			return 0, 0, nil, fmt.Errorf("%w: screenTimeout %q", ErrInvalidArgument, v)
		}
		enabled := code != 4
		label := screenTimeoutLabel(code)
		return opScreenTime, code, func(s *product.Settings) {
			s.AutoLock = &enabled
			s.ScreenTimeout = &label
		}, nil
	case "autolock":
		on, ok := parseBool(v)
		if !ok {
			return 0, 0, nil, fmt.Errorf("%w: autoLock %q", ErrInvalidArgument, v)
		}
		code := byte(1)
		if !on {
			code = 4
		}
		label := screenTimeoutLabel(code)
		return opScreenTime, code, func(s *product.Settings) {
			s.AutoLock = &on
			s.ScreenTimeout = &label
		}, nil
	case "screenon", "theme":
		return 0, 0, nil, fmt.Errorf("%w: %q has no A2687 command", ErrUnsupportedSetting, key)
	default:
		return 0, 0, nil, fmt.Errorf("%w: %q", ErrUnsupportedSetting, key)
	}
}

// screenTimeoutLabel renders a 0x0203 timeout code in the UI vocabulary.
func screenTimeoutLabel(code byte) string {
	switch code {
	case 0:
		return "30s"
	case 1:
		return "1m"
	case 2:
		return "5m"
	case 3:
		return "30m"
	default:
		return "12h"
	}
}

func languageCode(v string) (byte, string, bool) {
	switch strings.ToLower(v) {
	case "en", "english", "0":
		return 0, "en", true
	case "zh", "zh-hans", "chinese", "1":
		return 1, "zh", true
	case "ja", "japanese", "2":
		return 2, "ja", true
	case "de", "german", "3":
		return 3, "de", true
	}
	return 0, "", false
}

func orientationCode(v string) (byte, string, bool) {
	switch strings.ToLower(v) {
	case "up", "0":
		return 0, "up", true
	case "left", "1":
		return 1, "left", true
	case "down", "2":
		return 2, "down", true
	case "right", "3":
		return 3, "right", true
	}
	return 0, "", false
}

func timeoutCode(v string) (byte, bool) {
	switch strings.ToLower(v) {
	case "30s", "30", "0":
		return 0, true
	case "1m", "60s", "1":
		return 1, true
	case "5m", "300s", "2":
		return 2, true
	case "30m", "1800s", "3":
		return 3, true
	case "12h", "43200s", "4":
		return 4, true
	}
	return 0, false
}

func parseBool(v string) (bool, bool) {
	switch strings.ToLower(v) {
	case "true", "1", "on", "yes":
		return true, true
	case "false", "0", "off", "no":
		return false, true
	}
	return false, false
}

// portIndex maps a product port to the A2687 0-based port index.
func portIndex(p product.PortID) int {
	switch p {
	case product.PortC1:
		return 0
	case product.PortC2:
		return 1
	case product.PortC3:
		return 2
	}
	return -1
}

// --- request plumbing ---

type request struct {
	fn   func(*loop) error
	done chan error
}

func (m *Manager) exec(fn func(*loop) error) error {
	m.mu.Lock()
	l := m.loop
	running := m.running
	m.mu.Unlock()
	if !running || l == nil {
		return ErrNotRunning
	}
	req := request{fn: fn, done: make(chan error, 1)}
	select {
	case l.req <- req:
	case <-l.ctx.Done():
		return ErrClosed
	}
	select {
	case err := <-req.done:
		return err
	case <-l.ctx.Done():
		return ErrClosed
	}
}

// execWrite registers an asynchronous write and waits for the loop to resolve
// the acknowledgement/read-back (or for the session to stop).
func (m *Manager) execWrite(fn func(*loop, chan<- error) error) error {
	m.mu.Lock()
	l := m.loop
	running := m.running
	m.mu.Unlock()
	if !running || l == nil {
		return ErrNotRunning
	}
	reply := make(chan error, 1)
	if err := m.exec(func(lo *loop) error { return fn(lo, reply) }); err != nil {
		return err
	}
	select {
	case err := <-reply:
		return err
	case <-l.ctx.Done():
		return ErrClosed
	}
}

// --- engine ---

// loop is the single owner of all session state.
type loop struct {
	m    *Manager
	tr   transport.Transport
	cd   codec
	opts Options
	ctx  context.Context

	req  chan request
	done chan struct{}

	clock func() time.Time
	asm   frameAssembler
	hs    clientHandshake

	phase            Phase
	scanning         bool
	devByID          map[string]transport.Discovered
	devOrder         []string
	current          *transport.Discovered
	connectedAt      time.Time
	reading          *product.Reading
	ring             []product.Sample
	settings         product.Settings
	settingsKnown    bool
	info             handshakeInfo
	lastTelemetry    time.Time
	readyAt          time.Time
	stale            bool
	errStr           string
	warning          string
	limitWatts       float64
	writesEnabled    bool
	remembered       []string
	targetID         string
	retryAttempt     int
	userDisconnected bool
	ignoreDisconnect bool

	// session stats integrator (trapezoidal, gap-aware)
	statsPrevAt  time.Time
	statsPrevW   float64
	statEnergyWh float64
	statActiveS  float64
	statPeakW    float64

	pending []*pendingWrite
	burst   []outgoingFrame

	poll            *time.Ticker
	house           *time.Ticker
	retry           *time.Timer
	stage           *time.Timer
	burstT          *time.Timer
	connectT        *time.Timer
	connectC        chan error
	connectInFlight bool
	pollTicks       int
	scanStarted     time.Time
}

func newLoop(m *Manager, ctx context.Context, opts Options) *loop {
	clock := opts.Clock
	if clock == nil {
		clock = time.Now
	}
	houseEvery := opts.StaleAfter / 8
	if houseEvery < 100*time.Millisecond {
		houseEvery = 100 * time.Millisecond
	}
	if houseEvery > time.Second {
		houseEvery = time.Second
	}
	return &loop{
		m:             m,
		tr:            m.tr,
		cd:            m.cd,
		opts:          opts,
		ctx:           ctx,
		req:           make(chan request, 8),
		done:          make(chan struct{}),
		clock:         clock,
		asm:           m.cd.newAssembler(),
		phase:         PhaseIdle,
		devByID:       make(map[string]transport.Discovered),
		settings:      product.Settings{},
		limitWatts:    opts.LimitWatts,
		remembered:    append([]string(nil), opts.Remembered...),
		writesEnabled: opts.WritesEnabled,
		house:         time.NewTicker(houseEvery),
	}
}

func (l *loop) now() time.Time { return l.clock() }
func (l *loop) epoch() uint32  { return uint32(l.now().Unix()) }

func (l *loop) run() {
	defer close(l.done)
	defer l.cleanup()
	if err := l.startScanning(); err != nil {
		l.fail(err)
		return
	}
	for {
		var pollC, retryC, stageC, burstC, connectC <-chan time.Time
		if l.poll != nil {
			pollC = l.poll.C
		}
		if l.retry != nil {
			retryC = l.retry.C
		}
		if l.stage != nil {
			stageC = l.stage.C
		}
		if l.burstT != nil {
			burstC = l.burstT.C
		}
		if l.connectT != nil {
			connectC = l.connectT.C
		}
		select {
		case <-l.ctx.Done():
			return
		case req := <-l.req:
			req.done <- req.fn(l)
		case ev, ok := <-l.tr.Events():
			if !ok {
				l.onLinkLost(transport.ErrClosed)
				continue
			}
			l.handleEvent(ev)
		case <-l.house.C:
			l.housekeeping()
		case <-pollC:
			l.pollTick()
		case <-retryC:
			l.retry = nil
			l.retryTick()
		case <-stageC:
			l.stage = nil
			l.stageTick()
		case <-burstC:
			l.burstT = nil
			l.burstTick()
		case <-connectC:
			l.connectT = nil
			l.connectTimeout()
		case err := <-l.connectC:
			l.onConnectResult(err)
		}
	}
}

func (l *loop) cleanup() {
	l.stopPoll()
	l.disarmRetry()
	l.disarmStage()
	l.disarmBurst()
	l.disarmConnect()
	if l.house != nil {
		l.house.Stop()
	}
	for _, p := range l.pending {
		resolveErr(p.reply, ErrClosed)
	}
	l.pending = nil
	_ = l.tr.Disconnect()
	if l.phase != PhaseFailed {
		l.phase = PhaseIdle
	}
	l.scanning = false
	l.stale = false
	l.reading = nil
	l.connectedAt = time.Time{}
	l.publish()
}

// --- lifecycle ---

// startScanning drops any link and enters the scanning phase.
func (l *loop) startScanning() error {
	l.userDisconnected = false
	l.targetID = ""
	l.disarmRetry()
	l.disarmConnect()
	l.connectInFlight = false
	if l.phase == PhasePolling || l.phase == PhaseHandshake || l.phase == PhaseConnecting || l.current != nil {
		l.ignoreDisconnect = true
		_ = l.tr.Disconnect()
	}
	l.hs = nil
	l.asm.reset()
	l.stopPoll()
	l.disarmStage()
	l.disarmBurst()
	l.burst = nil
	l.current = nil
	l.reading = nil
	l.connectedAt = time.Time{}
	l.resetStats()
	l.stale = false
	l.errStr = ""
	l.warning = ""
	l.retryAttempt = 0
	l.phase = PhaseScanning
	l.scanning = true
	l.scanStarted = l.now()
	l.publish()
	if err := l.tr.Scan(l.ctx, l.opts.Product); err != nil {
		l.scanning = false
		l.fail(fmt.Errorf("session: scan: %w", err))
		return err
	}
	return nil
}

// connectTo drops any link and connects to one charger id.
func (l *loop) connectTo(id string) error {
	l.userDisconnected = false
	l.targetID = id
	l.retryAttempt = 0
	l.disarmRetry()
	l.disarmConnect()
	l.connectInFlight = false
	if l.phase == PhasePolling || l.phase == PhaseHandshake || l.phase == PhaseConnecting || l.current != nil {
		l.ignoreDisconnect = true
		_ = l.tr.Disconnect()
	}
	l.hs = nil
	l.asm.reset()
	l.stopPoll()
	l.disarmStage()
	l.disarmBurst()
	l.burst = nil
	l.current = nil
	l.reading = nil
	l.connectedAt = time.Time{}
	l.resetStats()
	l.stale = false
	l.errStr = ""
	l.warning = ""
	return l.startConnecting(id)
}

func (l *loop) startConnecting(id string) error {
	if id == "" {
		return fmt.Errorf("%w: empty device id", ErrInvalidArgument)
	}
	l.targetID = id
	l.phase = PhaseConnecting
	l.scanning = false
	_ = l.tr.StopScan()
	l.errStr = ""
	l.warning = ""
	l.publish()
	l.connectInFlight = true
	l.connectC = make(chan error, 1)
	timeout := l.opts.StageTimeout * 2
	if timeout < minConnectTimeout {
		timeout = minConnectTimeout
	}
	l.connectT = time.NewTimer(timeout)
	ctx := l.ctx
	tr := l.tr
	ch := l.connectC
	go func() {
		err := tr.Connect(ctx, id)
		select {
		case ch <- err:
		case <-ctx.Done():
		}
	}()
	return nil
}

func (l *loop) connectTimeout() {
	if !l.connectInFlight {
		return
	}
	l.connectInFlight = false
	l.onConnectFailed(ErrTimeout)
}

func (l *loop) onConnectResult(err error) {
	if !l.connectInFlight {
		return // already handled by the connect watchdog
	}
	l.connectInFlight = false
	l.disarmConnect()
	if err != nil {
		if l.userDisconnected {
			return
		}
		l.onConnectFailed(err)
		return
	}
	// Link is up: start the negotiation ladder.
	l.phase = PhaseHandshake
	l.stale = false
	l.errStr = ""
	l.warning = ""
	l.asm.reset()
	l.hs = l.cd.newHandshake(handshakeConfig{
		ClientID:     l.opts.ClientID,
		TimeZoneRule: l.opts.TimeZoneRule,
		CountryCode:  l.opts.CountryCode,
		OwnerUserID:  l.opts.OwnerUserID,
		Now:          l.now,
	})
	if l.targetID != "" {
		if dev, ok := l.devByID[l.targetID]; ok {
			d := dev
			l.current = &d
		}
	}
	l.publish()
	out, err := l.hs.start()
	if err != nil {
		l.fail(fmt.Errorf("handshake: %w", err))
		return
	}
	l.armStage()
	if len(out) > 0 {
		if werr := l.tr.Write(l.ctx, out[0].bytes); werr != nil {
			l.onLinkLost(werr)
		}
	}
	l.publish()
}

func (l *loop) onConnectFailed(err error) {
	if l.userDisconnected {
		return
	}
	if err != nil {
		l.warning = fmt.Sprintf("connect failed: %v", err)
	}
	l.retryAttempt++
	if l.retryAttempt > maxReconnectTries {
		l.fail(fmt.Errorf("session: could not connect: %v", err))
		return
	}
	l.phase = PhaseReconnecting
	l.scanning = false
	l.errStr = "connection lost"
	l.armRetry(l.backoffDelay())
	l.publish()
}

func (l *loop) onLinkLost(reason error) {
	if l.userDisconnected || l.phase == PhaseIdle || l.phase == PhaseFailed {
		return
	}
	l.hs = nil
	l.asm.reset()
	l.stopPoll()
	l.disarmStage()
	l.disarmBurst()
	l.disarmConnect()
	l.burst = nil
	l.connectInFlight = false
	for _, p := range l.pending {
		resolveErr(p.reply, ErrLinkLost)
	}
	l.pending = nil
	l.stale = l.reading != nil
	msg := "connection lost"
	if reason != nil && !errors.Is(reason, transport.ErrClosed) {
		msg = fmt.Sprintf("connection lost: %v", reason)
	}
	l.errStr = msg
	l.retryAttempt++
	if l.retryAttempt > maxReconnectTries {
		l.fail(fmt.Errorf("session: %s", msg))
		return
	}
	l.phase = PhaseReconnecting
	l.scanning = false
	l.armRetry(l.backoffDelay())
	l.publish()
}

func (l *loop) retryTick() {
	if l.userDisconnected {
		return
	}
	target := l.targetID
	if target == "" && l.current != nil {
		target = l.current.ID
	}
	if target == "" && len(l.remembered) > 0 {
		target = l.remembered[0]
	}
	if target == "" {
		l.phase = PhaseScanning
		l.scanning = true
		l.scanStarted = l.now()
		l.publish()
		if err := l.tr.Scan(l.ctx, l.opts.Product); err != nil {
			l.onConnectFailed(err)
		}
		return
	}
	if err := l.startConnecting(target); err != nil {
		l.onConnectFailed(err)
	}
}

func (l *loop) backoffDelay() time.Duration {
	attempt := l.retryAttempt
	if attempt < 1 {
		attempt = 1
	}
	if attempt > 6 {
		attempt = 6
	}
	d := time.Second << uint(attempt-1)
	if d > l.opts.MaxBackoff {
		d = l.opts.MaxBackoff
	}
	return d
}

func (l *loop) fail(err error) {
	if err == nil {
		err = errors.New("session: failed")
	}
	l.errStr = err.Error()
	l.phase = PhaseFailed
	l.scanning = false
	l.stale = false
	l.hs = nil
	l.asm.reset()
	l.stopPoll()
	l.disarmRetry()
	l.disarmStage()
	l.disarmBurst()
	l.disarmConnect()
	l.burst = nil
	l.connectInFlight = false
	for _, p := range l.pending {
		resolveErr(p.reply, err)
	}
	l.pending = nil
	l.ignoreDisconnect = true
	_ = l.tr.Disconnect()
	l.publish()
}

// dropLink intentionally disconnects without scheduling a reconnect.
func (l *loop) dropLink() {
	if l.phase == PhasePolling || l.phase == PhaseHandshake || l.phase == PhaseConnecting || l.current != nil {
		l.ignoreDisconnect = true
		_ = l.tr.Disconnect()
	}
	l.hs = nil
	l.asm.reset()
	l.stopPoll()
	l.disarmStage()
	l.disarmBurst()
	l.disarmConnect()
	l.burst = nil
	l.connectInFlight = false
	for _, p := range l.pending {
		resolveErr(p.reply, ErrLinkLost)
	}
	l.pending = nil
}

// --- events ---

func (l *loop) handleEvent(ev transport.Event) {
	switch ev.Kind {
	case transport.EventDiscovered:
		if ev.Device.ID == "" {
			return
		}
		if _, ok := l.devByID[ev.Device.ID]; !ok {
			l.devOrder = append(l.devOrder, ev.Device.ID)
		}
		l.devByID[ev.Device.ID] = ev.Device
		l.publish()
		if l.opts.AutoConnect && !l.userDisconnected && l.targetID == "" && l.phase == PhaseScanning && !l.connectInFlight {
			if err := l.startConnecting(ev.Device.ID); err != nil {
				l.onConnectFailed(err)
			}
		}
	case transport.EventScanStopped:
		l.scanning = false
		l.publish()
	case transport.EventDisconnected:
		if l.ignoreDisconnect {
			l.ignoreDisconnect = false
			return
		}
		l.onLinkLost(ev.Err)
	case transport.EventData:
		l.handleData(ev.Data)
	case transport.EventError:
		if ev.Err != nil {
			l.warning = ev.Err.Error()
			l.publish()
		}
	}
}

func (l *loop) handleData(data []byte) {
	for _, f := range l.asm.push(data) {
		switch l.phase {
		case PhaseHandshake:
			if l.hs == nil || !f.response {
				continue
			}
			out, ready, err := l.hs.handleResponse(f.raw)
			if err != nil {
				l.fail(fmt.Errorf("session: %w", err))
				return
			}
			if ready {
				l.beginPolling(out)
				return
			}
			l.writeFrames(out)
			l.armStage()
		case PhasePolling:
			if !f.response || l.hs == nil {
				continue
			}
			if f.opcode == opRealtime {
				l.handleTelemetry(f.raw)
			} else {
				l.handleAck(f.opcode, f.raw)
			}
		}
	}
}

func (l *loop) beginPolling(burst []outgoingFrame) {
	l.phase = PhasePolling
	l.scanning = false
	l.readyAt = l.now()
	if l.connectedAt.IsZero() {
		l.connectedAt = l.readyAt
	}
	l.retryAttempt = 0
	l.disarmStage()
	l.disarmRetry()
	l.disarmConnect()
	l.stale = false
	l.errStr = ""
	l.warning = l.hs.warning()
	l.info = l.hs.info()
	l.startPoll()
	l.burst = burst
	if l.opts.OpeningBurstSpacing <= 0 {
		frames := l.burst
		l.burst = nil
		l.writeFrames(frames)
	} else {
		l.burstTick()
	}
	l.publish()
}

func (l *loop) burstTick() {
	if len(l.burst) == 0 {
		return
	}
	f := l.burst[0]
	l.burst = l.burst[1:]
	if err := l.tr.Write(l.ctx, f.bytes); err != nil {
		l.onLinkLost(err)
		return
	}
	if len(l.burst) > 0 {
		l.burstT = time.NewTimer(l.opts.OpeningBurstSpacing)
	}
}

func (l *loop) writeFrames(frames []outgoingFrame) {
	for _, f := range frames {
		if err := l.tr.Write(l.ctx, f.bytes); err != nil {
			l.onLinkLost(err)
			return
		}
	}
}

// --- polling ---

func (l *loop) startPoll() {
	l.stopPoll()
	if l.opts.PollInterval > 0 {
		l.poll = time.NewTicker(l.opts.PollInterval)
		l.pollTicks = 0
	}
}

func (l *loop) stopPoll() {
	if l.poll != nil {
		l.poll.Stop()
		l.poll = nil
	}
}

func (l *loop) pollTick() {
	if l.phase != PhasePolling || l.hs == nil {
		return
	}
	l.pollTicks++
	now := l.now()
	if frame, err := l.hs.realtimeProbe(l.opts.CountryCode, l.opts.OwnerUserID, now); err == nil {
		if werr := l.tr.Write(l.ctx, frame.bytes); werr != nil {
			l.onLinkLost(werr)
			return
		}
	}
	if l.pollTicks%2 == 0 {
		if frame, err := l.hs.readAll(now); err == nil {
			if werr := l.tr.Write(l.ctx, frame.bytes); werr != nil {
				l.onLinkLost(werr)
			}
		}
	}
}

// --- telemetry and writes ---

func (l *loop) handleTelemetry(raw []byte) {
	t, err := l.hs.decodeTelemetry(raw)
	if err != nil {
		return
	}
	now := l.now()
	if t.settings != nil {
		merged := *t.settings
		if merged.PortControls == nil && l.settings.PortControls != nil {
			merged.PortControls = l.settings.PortControls
		}
		l.settings = merged
		l.settingsKnown = true
	}
	if !t.hasPortData {
		l.publish()
		return
	}
	r := t.reading
	r.ReceivedAt = now
	l.reading = &r
	l.appendHistory(now, r.TotalWatts)
	l.integrateStats(now, r.TotalWatts)
	l.lastTelemetry = now
	l.stale = false
	l.errStr = ""
	if l.opts.OnSample != nil {
		var per [6]float64
		for i, id := range l.opts.Product.PortIDs() {
			idx := portIndex(id)
			if idx >= 0 && i < len(r.Ports) {
				per[idx] = r.Ports[i].Watts
			}
		}
		l.opts.OnSample(now, r.TotalWatts, per)
	}
	l.resolvePortReadbacks(&r)
	l.publish()
}

func (l *loop) appendHistory(now time.Time, watts float64) {
	l.ring = append(l.ring, product.Sample{T: now.UnixMilli(), W: watts})
	if len(l.ring) > historyCap {
		l.ring = append([]product.Sample(nil), l.ring[len(l.ring)-historyCap:]...)
	}
}

func (l *loop) integrateStats(now time.Time, watts float64) {
	if !l.statsPrevAt.IsZero() {
		dt := now.Sub(l.statsPrevAt).Seconds()
		if dt > 0 && dt <= maxIntegrableGap {
			l.statEnergyWh += dt * (l.statsPrevW + watts) / 2 / 3600
			l.statActiveS += dt
		}
	}
	l.statsPrevAt = now
	l.statsPrevW = watts
	if watts > l.statPeakW {
		l.statPeakW = watts
	}
}

func (l *loop) resetStats() {
	l.statsPrevAt = time.Time{}
	l.statsPrevW = 0
	l.statEnergyWh = 0
	l.statActiveS = 0
	l.statPeakW = 0
}

func (l *loop) sessionStats(now time.Time) product.SessionStats {
	st := product.SessionStats{
		PeakW:    round1(l.statPeakW),
		EnergyWh: round2(l.statEnergyWh),
	}
	if l.statActiveS > 0 {
		st.AvgW = round1(l.statEnergyWh * 3600 / l.statActiveS)
	}
	if !l.connectedAt.IsZero() && now.After(l.connectedAt) {
		st.ConnectedMs = now.Sub(l.connectedAt).Milliseconds()
	}
	return st
}

// pendingWrite is one P1 command awaiting its device acknowledgement and, for
// port switches, the telemetry read-back.
type pendingWrite struct {
	opcode   uint16
	kind     writeKind
	port     product.PortID
	on       bool
	reply    chan<- error
	deadline time.Time
	acked    bool
}

type writeKind int

const (
	writePortEnabled writeKind = iota
	writeAckOnly
)

func (l *loop) removePending(p *pendingWrite) {
	for i, e := range l.pending {
		if e == p {
			l.pending = append(l.pending[:i], l.pending[i+1:]...)
			return
		}
	}
}

func (l *loop) firstPending(opcode uint16) *pendingWrite {
	for _, p := range l.pending {
		if p.opcode == opcode && !p.acked {
			return p
		}
	}
	return nil
}

func resolveErr(ch chan<- error, err error) {
	select {
	case ch <- err:
	default:
	}
}

func (l *loop) handleAck(opcode uint16, raw []byte) {
	p := l.firstPending(opcode)
	if p == nil {
		return
	}
	status := byte(0)
	if s, ok := l.hs.responseStatus(raw); ok {
		status = s
	}
	if status != 0 {
		l.removePending(p)
		resolveErr(p.reply, fmt.Errorf("%w: status 0x%02x", ErrDeviceRejected, status))
		return
	}
	p.acked = true
	if p.kind == writeAckOnly {
		l.removePending(p)
		resolveErr(p.reply, nil)
	}
}

func (l *loop) resolvePortReadbacks(r *product.Reading) {
	snapshot := append([]*pendingWrite(nil), l.pending...)
	for _, p := range snapshot {
		if p.kind != writePortEnabled || !p.acked {
			continue
		}
		got, ok := r.Port(p.port)
		if ok && got.Enabled == p.on {
			l.removePending(p)
			resolveErr(p.reply, nil)
		}
	}
}

func (l *loop) applyOptimisticPort(port product.PortID, on bool) {
	if l.reading == nil {
		return
	}
	idx := portIndex(port)
	if idx < 0 || idx >= len(l.reading.Ports) {
		return
	}
	r := *l.reading
	r.Ports = append([]product.PortReading(nil), l.reading.Ports...)
	if on {
		if r.Ports[idx].Status == 0 {
			r.Ports[idx].Status = 1
		}
	} else {
		r.Ports[idx].Status = 0
		r.Ports[idx].Watts = 0
		r.Ports[idx].Volts = 0
		r.Ports[idx].Amps = 0
	}
	r.Ports[idx].Enabled = on
	r.TotalWattsOf()
	l.reading = &r
}

// --- housekeeping ---

func (l *loop) housekeeping() {
	now := l.now()
	switch l.phase {
	case PhasePolling:
		if l.lastTelemetry.IsZero() {
			if now.Sub(l.readyAt) > l.opts.StaleAfter {
				l.fail(errors.New("session: session established but the charger sends no telemetry"))
				return
			}
		} else if !l.stale && now.Sub(l.lastTelemetry) > l.opts.StaleAfter {
			l.stale = true
			l.publish()
		}
	case PhaseScanning:
		if !l.scanStarted.IsZero() && now.Sub(l.scanStarted) > 15*time.Second && len(l.devOrder) == 0 && l.warning == "" {
			l.warning = "no charger found; a charger already connected to another app stops advertising"
			l.publish()
		}
	}
	if len(l.pending) > 0 {
		for _, p := range append([]*pendingWrite(nil), l.pending...) {
			if now.After(p.deadline) {
				l.removePending(p)
				resolveErr(p.reply, ErrTimeout)
			}
		}
	}
}

// --- publication ---

func (l *loop) publish() {
	now := l.now()
	s := Snapshot{
		Phase:         l.phase,
		Scanning:      l.scanning,
		Devices:       l.buildDevices(),
		History:       decimateHistory(l.ring),
		Stats:         l.sessionStats(now),
		Settings:      copySettings(l.settings),
		Err:           l.errStr,
		Warning:       l.warning,
		IsStale:       l.stale,
		LimitWatts:    l.limitWatts,
		LastUpdatedMs: now.UnixMilli(),
	}
	if l.current != nil {
		d := deviceFromDiscovered(*l.current)
		if l.phase == PhasePolling {
			d.Connected = true
		}
		if l.info.Firmware != "" {
			d.Firmware = l.info.Firmware
		}
		if l.info.Serial != "" {
			d.Serial = l.info.Serial
		}
		if l.info.MAC != "" {
			d.MAC = l.info.MAC
		}
		if d.Name == "" {
			d.Name = d.Product.DisplayName()
		}
		s.Device = &d
	}
	if l.reading != nil {
		r := *l.reading
		r.Ports = append([]product.PortReading(nil), l.reading.Ports...)
		s.Reading = &r
	}
	if !l.connectedAt.IsZero() {
		s.ConnectedAtMs = msOf(l.connectedAt)
	}
	l.m.publish(s)
}

func (l *loop) buildDevices() []Device {
	out := make([]Device, 0, len(l.devOrder)+1)
	seen := make(map[string]bool, len(l.devOrder)+1)
	for _, id := range l.devOrder {
		dev, ok := l.devByID[id]
		if !ok {
			continue
		}
		d := deviceFromDiscovered(dev)
		if l.current != nil && l.current.ID == id {
			d.Connected = l.phase == PhasePolling
		}
		out = append(out, d)
		seen[id] = true
	}
	if l.current != nil && !seen[l.current.ID] {
		d := deviceFromDiscovered(*l.current)
		d.Connected = l.phase == PhasePolling
		out = append(out, d)
	}
	return out
}

func deviceFromDiscovered(d transport.Discovered) Device {
	return Device{
		ID:      d.ID,
		Name:    d.Name,
		Product: d.Product,
		Address: d.Address,
		RSSI:    d.RSSI,
		Saved:   d.Saved,
		Mock:    d.Mock,
	}
}

func copySettings(s product.Settings) product.Settings {
	out := s
	if s.ScreenOn != nil {
		v := *s.ScreenOn
		out.ScreenOn = &v
	}
	if s.Brightness != nil {
		v := *s.Brightness
		out.Brightness = &v
	}
	if s.Language != nil {
		v := *s.Language
		out.Language = &v
	}
	if s.Orientation != nil {
		v := *s.Orientation
		out.Orientation = &v
	}
	if s.AutoLock != nil {
		v := *s.AutoLock
		out.AutoLock = &v
	}
	if s.Theme != nil {
		v := *s.Theme
		out.Theme = &v
	}
	if s.FixedAllocation != nil {
		v := *s.FixedAllocation
		out.FixedAllocation = &v
	}
	if s.ScreenTimeout != nil {
		v := *s.ScreenTimeout
		out.ScreenTimeout = &v
	}
	if s.ChargingMode != nil {
		v := *s.ChargingMode
		out.ChargingMode = &v
	}
	if s.AutoRotate != nil {
		v := *s.AutoRotate
		out.AutoRotate = &v
	}
	if s.PortControls != nil {
		out.PortControls = make(map[product.PortID]product.PortControl, len(s.PortControls))
		for k, v := range s.PortControls {
			out.PortControls[k] = v
		}
	}
	return out
}

// --- timer helpers ---

func (l *loop) armStage() {
	l.disarmStage()
	l.stage = time.NewTimer(l.opts.StageTimeout)
}

func (l *loop) disarmStage() {
	if l.stage != nil {
		l.stage.Stop()
		l.stage = nil
	}
}

func (l *loop) armRetry(d time.Duration) {
	l.disarmRetry()
	if d < 0 {
		d = 0
	}
	l.retry = time.NewTimer(d)
}

func (l *loop) disarmRetry() {
	if l.retry != nil {
		l.retry.Stop()
		l.retry = nil
	}
}

func (l *loop) disarmBurst() {
	if l.burstT != nil {
		l.burstT.Stop()
		l.burstT = nil
	}
}

func (l *loop) disarmConnect() {
	if l.connectT != nil {
		l.connectT.Stop()
		l.connectT = nil
	}
}

func (l *loop) stageTick() {
	if l.phase != PhaseHandshake || l.hs == nil {
		return
	}
	if l.hs.ready() {
		l.beginPolling(nil)
		return
	}
	if l.hs.canSkip() {
		out, ready, err := l.hs.skip()
		if err != nil {
			l.fail(fmt.Errorf("session: %w", err))
			return
		}
		if ready {
			l.beginPolling(out)
			return
		}
		l.writeFrames(out)
		l.armStage()
		return
	}
	l.fail(fmt.Errorf("session: handshake stage %s timed out", l.hs.stage()))
}

// round helpers for stats.
func round1(v float64) float64 { return math.Round(v*10) / 10 }
func round2(v float64) float64 { return math.Round(v*100) / 100 }
