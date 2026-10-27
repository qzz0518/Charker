package matter

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// State is a helper's state for the settings page.
type State string

const (
	StateOff State = "off"
	// StateUnavailable: no charker-matter(.exe) beside the app.
	StateUnavailable State = "unavailable"
	StateStarting    State = "starting"
	// StateWaiting: up and showing its setup code until a Home adds it.
	StateWaiting State = "waitingForPairing"
	StatePaired  State = "paired"
	// StateMDNSFailed: the helper cannot advertise itself (no usable network
	// interface, UDP 5353 unavailable). It keeps running and retrying.
	StateMDNSFailed State = "mdnsFailed"
	// StateRestarting: the helper exited or hit a fatal error; a relaunch is
	// scheduled.
	StateRestarting State = "restarting"
	// StateFailed: the helper could not be launched at all.
	StateFailed State = "failed"
)

// Status is one helper as the settings page shows it.
type Status struct {
	State State `json:"state"`
	// Running: a helper process is up.
	Running bool `json:"running"`
	// Fabrics is the number of Homes (controllers) it is paired with; -1
	// until the helper has said.
	Fabrics int `json:"fabrics"`
	// QR is the `MT:...` payload and ManualCode the 11-digit setup code
	// (FormatManualCode groups it), set only while StateWaiting.
	QR         string `json:"qr,omitempty"`
	ManualCode string `json:"manualCode,omitempty"`
	// MDNSOK is false while the advertisement is failing.
	MDNSOK bool `json:"mdnsOk"`
}

// Config is what one helper publishes.
type Config struct {
	// Storage holds the pairing; deleting it resets pairing.
	Storage string
	// Name is the accessory name in Home (at most 32 bytes).
	Name string
	// Labels are the port labels, 3 or 5 (at most 32 bytes each when bridged).
	Labels []string
	// Bridge publishes every port as an accessory of its own.
	Bridge  bool
	UDPPort uint16
}

func (c Config) equal(o Config) bool {
	return c.Storage == o.Storage && c.Name == o.Name && slices.Equal(c.Labels, o.Labels) &&
		c.Bridge == o.Bridge && c.UDPPort == o.UDPPort
}

func (c Config) args() []string {
	a := []string{
		"--storage", c.Storage,
		"--name", c.Name,
		"--ports", strings.Join(c.Labels, ","),
		"--udp-port", strconv.Itoa(int(c.UDPPort)),
	}
	if c.Bridge {
		a = append(a, "--bridge")
	}
	return a
}

// Options configure a Service.
type Options struct {
	// Helper is the helper executable; "" is DefaultHelperPath().
	Helper string
	// Args go before the protocol arguments (tests re-exec themselves).
	Args []string
	// Env, when set, replaces the helper's environment.
	Env []string
	// Logf receives log lines (already prefixed); nil discards them. The
	// onboarding line carries the setup code and is never logged.
	Logf func(format string, args ...any)
	// LogPrefix starts every log line, so two helpers can be told apart.
	LogPrefix string
	// OnCommand: a controller switched port index on or off. Every call must
	// be answered with Resend(index), whatever came of it, because that is
	// how Home learns the real state. Called from the helper's reader
	// goroutine, never under the service's lock.
	OnCommand func(index int, on bool)
	// OnStatus is called after every status change, like OnCommand.
	OnStatus func(Status)
}

// DefaultHelperPath is charker-matter(.exe) beside the running executable.
func DefaultHelperPath() string {
	exe, err := os.Executable()
	if err != nil {
		return helperName
	}
	return filepath.Join(filepath.Dir(exe), helperName)
}

var (
	restartDelays  = []time.Duration{1 * time.Second, 2 * time.Second, 5 * time.Second, 10 * time.Second, 30 * time.Second}
	stableRun      = 60 * time.Second
	commandTimeout = 10 * time.Second
	killAfter      = 1500 * time.Millisecond
)

// Service runs one charker-matter helper and speaks its line protocol: it
// launches it, keeps it alive with backoff, tells it the port readings and
// passes Home's switch requests on to OnCommand.
type Service struct {
	opts Options

	mu sync.Mutex
	// cfg is what should be running; nil once stopped.
	cfg  *Config
	proc *process
	// gen is bumped on every launch and stop. Callbacks from an older
	// process carry an older value and are dropped, so a stopped helper
	// cannot restart itself.
	gen   int
	ports PortSync
	// commandTimers answer a Home request the host has left open too long.
	commandTimers map[int]*time.Timer
	// exiting holds stopped helpers by storage directory until they are gone.
	exiting map[string]*process
	// restart is a launch waiting for a restart delay or for the previous
	// helper on the same storage.
	restart    *time.Timer
	restarting bool

	status     Status
	onboarding *[2]string
	// fabrics is -1 until the helper has said, so an already paired
	// accessory does not flash its code between the two startup lines.
	fabrics     int
	mdnsFailing bool
	launchedAt  time.Time
	failures    int

	// pending OnStatus/OnCommand calls, run in order by one dispatcher
	// goroutine outside the lock, so a callback may call back in.
	pending     []func()
	dispatching bool
}

// NewService returns a stopped service.
func NewService(opts Options) *Service {
	if opts.Helper == "" {
		opts.Helper = DefaultHelperPath()
	}
	return &Service{
		opts:    opts,
		exiting: map[string]*process{},
		fabrics: -1,
		status:  Status{State: StateOff, Fabrics: -1, MDNSOK: true},
	}
}

// Status is the current status.
func (s *Service) Status() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.status
}

// Start runs the helper for cfg, replacing one running another config.
func (s *Service) Start(cfg Config) {
	s.mu.Lock()
	if s.cfg != nil && s.cfg.equal(cfg) && (s.proc != nil || s.restart != nil || s.restarting) {
		s.mu.Unlock()
		return
	}
	s.stopLocked()
	cfg.Labels = slices.Clone(cfg.Labels)
	s.cfg = &cfg
	s.setState(StateStarting)
	s.launchOnceStorageIsFree(false)
	s.unlockAndNotify()
}

// Stop sends a shutdown line and closes the helper's stdin; it exits on
// either. One still around 1.5 s later is killed. The port states go too,
// so the next start begins with every port off.
func (s *Service) Stop() {
	s.mu.Lock()
	s.stopLocked()
	s.unlockAndNotify()
}

// Shutdown is Stop, then waits until the helper is really gone or ctx ends.
func (s *Service) Shutdown(ctx context.Context) {
	s.mu.Lock()
	p := s.proc
	s.stopLocked()
	s.unlockAndNotify()
	if p == nil {
		return
	}
	select {
	case <-p.done:
	case <-ctx.Done():
	}
}

// Update sets the latest state of every port, in layout order. Only ports
// that changed are written; a (re)launch sends them all.
func (s *Service) Update(states []PortState) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.send(s.ports.Update(states)...)
}

// Resend answers a Home request with the port's real state.
func (s *Service) Resend(index int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.resendLocked(index)
}

// ResetPairing forgets every Home pairing: the storage is deleted once the
// helper has exited, so it cannot write the old identity back on its way out.
func (s *Service) ResetPairing() {
	s.mu.Lock()
	if s.cfg == nil {
		s.mu.Unlock()
		return
	}
	cfg := *s.cfg
	states := s.ports.Desired()
	s.stopLocked()
	s.cfg = &cfg
	s.ports.Update(states)
	s.setState(StateStarting)
	s.launchOnceStorageIsFree(true)
	s.unlockAndNotify()
}

func (s *Service) stopLocked() {
	s.cancelRestart()
	s.gen++
	if p := s.proc; p != nil && s.cfg != nil {
		// releaseProcess() below closes stdin after this line.
		p.in.push(shutdownLine)
		s.exiting[s.cfg.Storage] = p
		go func() {
			select {
			case <-p.done:
			case <-time.After(killAfter):
				_ = p.cmd.Process.Kill()
			}
		}()
	}
	s.cfg = nil
	s.releaseProcess()
	s.ports = PortSync{}
	s.failures = 0
	s.setState(StateOff)
}

func (s *Service) cancelRestart() {
	if s.restart != nil {
		s.restart.Stop()
		s.restart = nil
	}
	s.restarting = false
}

// launchOnceStorageIsFree: two helpers on one storage directory would write
// the same files, and the second would advertise as "(2)", so a stopped one
// is waited out first.
func (s *Service) launchOnceStorageIsFree(resetting bool) {
	storage := s.cfg.Storage
	for k, p := range s.exiting {
		if p.exited() {
			delete(s.exiting, k)
		}
	}
	outgoing := s.exiting[storage]
	gen := s.gen
	s.restarting = true
	go func() {
		if outgoing != nil {
			<-outgoing.done
		}
		s.mu.Lock()
		if s.gen != gen || s.cfg == nil {
			s.mu.Unlock()
			return
		}
		s.restarting = false
		if resetting {
			if err := os.RemoveAll(storage); err != nil {
				s.log("pairing reset could not delete storage: %v", err)
			}
		}
		s.launch()
		s.unlockAndNotify()
	}()
}

func (s *Service) launch() {
	s.restart = nil
	cfg := s.cfg
	if cfg == nil {
		return
	}
	if _, err := os.Stat(s.opts.Helper); err != nil {
		s.setState(StateUnavailable)
		return
	}
	// The helper creates the directory too, but maybe not its parents.
	_ = os.MkdirAll(cfg.Storage, 0o755)

	cmd := exec.Command(s.opts.Helper, append(slices.Clone(s.opts.Args), cfg.args()...)...)
	if s.opts.Env != nil {
		cmd.Env = s.opts.Env
	}
	hideWindow(cmd)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		s.launchFailed(err)
		return
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		s.launchFailed(err)
		return
	}
	cmd.Stderr = &lineLogger{log: func(line string) { s.log("%s", line) }}
	if err := cmd.Start(); err != nil {
		s.launchFailed(err)
		return
	}

	s.gen++
	gen := s.gen
	p := &process{cmd: cmd, in: newLineQueue(), done: make(chan struct{})}
	go p.in.drain(stdin)
	go s.read(p, gen, stdout)

	s.proc = p
	s.launchedAt = time.Now()
	s.log("helper started for %s", cfg.Name)
	s.status.Running = true
	s.send(s.ports.Connect(len(cfg.Labels))...)
}

func (s *Service) launchFailed(err error) {
	s.log("helper did not launch: %v", err)
	s.setState(StateFailed)
}

// read delivers stdout lines in order, then handles the exit once both
// stdout has closed and the process has been reaped, so none of its lines
// can come after.
func (s *Service) read(p *process, gen int, stdout io.Reader) {
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 0, 4096), 1<<20)
	for sc.Scan() {
		if line := strings.TrimSpace(sc.Text()); line != "" {
			s.handle(line, gen)
		}
	}
	// A line too long for the scanner leaves the rest unread; draining it
	// keeps the helper from blocking on a full pipe until it exits.
	_, _ = io.Copy(io.Discard, stdout)
	err := p.cmd.Wait()
	close(p.done)
	ending := "exited with status 0"
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		ending = "exited: " + exit.String()
	} else if err != nil {
		ending = "ended: " + err.Error()
	}
	s.mu.Lock()
	if gen == s.gen && s.proc == p {
		s.exited(ending)
	}
	s.unlockAndNotify()
}

func (s *Service) exited(ending string) {
	s.log("helper %s", ending)
	ranFor := time.Since(s.launchedAt)
	s.releaseProcess()
	if s.cfg == nil {
		return
	}
	if ranFor >= stableRun {
		s.failures = 0
	}
	s.setState(StateRestarting)
	delay := restartDelays[min(s.failures, len(restartDelays)-1)]
	s.failures++
	gen := s.gen
	s.restart = time.AfterFunc(delay, func() {
		s.mu.Lock()
		if s.gen == gen && s.cfg != nil {
			s.launch()
		}
		s.unlockAndNotify()
	})
}

func (s *Service) releaseProcess() {
	if s.proc != nil {
		s.proc.in.close()
	}
	s.proc = nil
	s.launchedAt = time.Time{}
	s.ports.Disconnect()
	for _, t := range s.commandTimers {
		t.Stop()
	}
	s.commandTimers = nil
	s.onboarding = nil
	s.fabrics = -1
	s.mdnsFailing = false
	s.status.Running = false
}

func (s *Service) handle(line string, gen int) {
	s.mu.Lock()
	if gen != s.gen || s.proc == nil {
		s.mu.Unlock()
		return
	}
	// Never logged verbatim: the onboarding line carries the setup code.
	ev, ok := parseEvent(line)
	if !ok {
		s.log("ignored an unrecognised stdout line")
		s.mu.Unlock()
		return
	}
	switch ev.kind {
	case evOnboarding:
		s.onboarding = &[2]string{ev.qr, ev.manualCode}
		s.refreshStatus()
	case evFabrics:
		s.log("%d fabric(s)", ev.count)
		s.fabrics = ev.count
		s.refreshStatus()
	case evMDNS:
		if ev.ok {
			s.log("mDNS registered")
		} else {
			s.log("mDNS registration failed")
		}
		s.mdnsFailing = !ev.ok
		s.refreshStatus()
	case evCommand:
		if !s.ports.Request(ev.index, ev.on) {
			break
		}
		s.log("command port %d %s", ev.index, onOff(ev.on))
		// Armed before the host sees it: a refusal answers at once.
		if t := s.commandTimers[ev.index]; t != nil {
			t.Stop()
		}
		if s.commandTimers == nil {
			s.commandTimers = map[int]*time.Timer{}
		}
		index := ev.index
		s.commandTimers[index] = time.AfterFunc(commandTimeout, func() {
			s.mu.Lock()
			defer s.mu.Unlock()
			if gen != s.gen || s.proc == nil || s.commandTimers[index] == nil {
				return
			}
			s.log("command port %d unanswered", index)
			s.resendLocked(index)
		})
		if f := s.opts.OnCommand; f != nil {
			on := ev.on
			s.pending = append(s.pending, func() { f(index, on) })
		}
	case evError:
		s.log("helper error %s: %s", ev.code, ev.message)
		s.setState(StateRestarting)
	}
	s.unlockAndNotify()
}

// unlockAndNotify releases the lock and has the queued callbacks run.
func (s *Service) unlockAndNotify() {
	if len(s.pending) > 0 && !s.dispatching {
		s.dispatching = true
		go s.dispatch()
	}
	s.mu.Unlock()
}

func (s *Service) dispatch() {
	for {
		s.mu.Lock()
		calls := s.pending
		s.pending = nil
		if len(calls) == 0 {
			s.dispatching = false
			s.mu.Unlock()
			return
		}
		s.mu.Unlock()
		for _, f := range calls {
			f()
		}
	}
}

func (s *Service) resendLocked(index int) {
	if t := s.commandTimers[index]; t != nil {
		t.Stop()
		delete(s.commandTimers, index)
	}
	if line, ok := s.ports.Answer(index); ok {
		s.send(line)
	}
}

func (s *Service) refreshStatus() {
	switch {
	case s.mdnsFailing:
		s.setState(StateMDNSFailed)
	case s.fabrics > 0:
		s.setState(StatePaired)
	case s.fabrics == 0 && s.onboarding != nil:
		s.setState(StateWaiting)
	default:
		s.setState(StateStarting)
	}
}

// setState rebuilds the status around state and queues OnStatus if it changed.
func (s *Service) setState(state State) {
	next := Status{
		State:   state,
		Running: s.proc != nil,
		Fabrics: s.fabrics,
		MDNSOK:  !s.mdnsFailing,
	}
	if state == StateWaiting && s.onboarding != nil {
		next.QR, next.ManualCode = s.onboarding[0], s.onboarding[1]
	}
	if next == s.status {
		return
	}
	s.status = next
	if f := s.opts.OnStatus; f != nil {
		s.pending = append(s.pending, func() { f(next) })
	}
}

func (s *Service) send(lines ...string) {
	if s.proc == nil {
		return
	}
	for _, l := range lines {
		s.proc.in.push(l)
	}
}

func (s *Service) log(format string, args ...any) {
	if s.opts.Logf == nil {
		return
	}
	msg := fmt.Sprintf(format, args...)
	if s.opts.LogPrefix != "" {
		msg = s.opts.LogPrefix + ": " + msg
	}
	s.opts.Logf("%s", msg)
}

func onOff(on bool) string {
	if on {
		return "on"
	}
	return "off"
}

// process is one launched helper.
type process struct {
	cmd *exec.Cmd
	in  *lineQueue
	// done closes once the process has been reaped.
	done chan struct{}
}

func (p *process) exited() bool {
	select {
	case <-p.done:
		return true
	default:
		return false
	}
}

// lineQueue feeds a helper's stdin from its own goroutine, so a stalled
// helper can never block the caller on a full pipe.
type lineQueue struct {
	mu     sync.Mutex
	lines  []string
	closed bool
	wake   chan struct{}
}

func newLineQueue() *lineQueue { return &lineQueue{wake: make(chan struct{}, 1)} }

func (q *lineQueue) push(line string) {
	q.mu.Lock()
	if !q.closed {
		q.lines = append(q.lines, line)
	}
	q.mu.Unlock()
	q.signal()
}

// close lets drain write what is queued, then close stdin.
func (q *lineQueue) close() {
	q.mu.Lock()
	q.closed = true
	q.mu.Unlock()
	q.signal()
}

func (q *lineQueue) signal() {
	select {
	case q.wake <- struct{}{}:
	default:
	}
}

func (q *lineQueue) drain(w io.WriteCloser) {
	defer w.Close()
	broken := false
	for {
		q.mu.Lock()
		lines, closed := q.lines, q.closed
		q.lines = nil
		q.mu.Unlock()
		if !broken && len(lines) > 0 {
			var buf bytes.Buffer
			for _, l := range lines {
				buf.WriteString(l)
				buf.WriteByte('\n')
			}
			// A helper that died between two writes costs an EPIPE; the
			// exit is handled by the reader.
			if _, err := w.Write(buf.Bytes()); err != nil {
				broken = true
			}
		}
		if closed {
			return
		}
		<-q.wake
	}
}

// lineLogger logs a helper's stderr line by line.
type lineLogger struct {
	log     func(string)
	pending []byte
}

func (l *lineLogger) Write(b []byte) (int, error) {
	l.pending = append(l.pending, b...)
	for {
		i := bytes.IndexByte(l.pending, '\n')
		if i < 0 {
			break
		}
		if line := strings.TrimSpace(string(l.pending[:i])); line != "" {
			l.log(line)
		}
		l.pending = l.pending[i+1:]
	}
	if len(l.pending) > 64<<10 {
		l.log(strings.TrimSpace(string(l.pending)))
		l.pending = nil
	}
	return len(b), nil
}
