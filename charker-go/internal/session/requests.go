package session

import (
	"fmt"
	"time"

	"charker/internal/a2687"
	"charker/internal/transport"
)

// This file is the request/reply half of ChargerSession: writes that wait for
// the charger's own answer (send(_:awaitOpcode:timeout:)), fire-and-forget
// frames, the poll hold a cover push takes, the charging-mode writes with
// their AA read-back, and the picker flows (browse, add a charger, forget).

// replyWaiter is one in-flight request. A reply carries nothing that says
// which request it answers, so the oldest waiter for an opcode takes it.
type replyWaiter struct {
	opcode uint16
	ch     chan replyResult
}

type replyResult struct {
	payload a2687.Payload
	err     error
}

func (l *loop) hasWaiter(opcode uint16) bool {
	for _, w := range l.waiters {
		if w.opcode == opcode {
			return true
		}
	}
	return false
}

func (l *loop) removeWaiter(target *replyWaiter) {
	for i, w := range l.waiters {
		if w == target {
			l.waiters = append(l.waiters[:i], l.waiters[i+1:]...)
			return
		}
	}
}

func (l *loop) resolveWaiter(opcode uint16, p a2687.Payload) bool {
	for i, w := range l.waiters {
		if w.opcode != opcode {
			continue
		}
		l.waiters = append(l.waiters[:i], l.waiters[i+1:]...)
		select {
		case w.ch <- replyResult{payload: p}:
		default:
		}
		return true
	}
	return false
}

func (l *loop) failWaiters(err error) {
	for _, w := range l.waiters {
		select {
		case w.ch <- replyResult{err: err}:
		default:
		}
	}
	l.waiters = nil
}

// handleSessionFrame routes one post-handshake frame. Like ChargerSession it
// decodes every report regardless of the response flag: the hardware's 1 Hz
// stream arrives as a plain 0x4300 notification and the read-all answer as a
// 0x0200 response, and both carry state (the settings fields only ride the
// read-all). Acknowledgements go to the port-write ledger and to any waiter.
func (l *loop) handleSessionFrame(f incomingFrame) {
	stateFrame := f.opcode == opRealtime || (f.opcode == opReadAll && f.response)
	if f.response && !stateFrame {
		l.handleAck(f.opcode, f.raw)
	}
	if stateFrame {
		l.handleTelemetry(f.raw)
	}
	if l.hs == nil {
		return
	}
	readAllAnswer := f.opcode == opReadAll && l.hasWaiter(opRealtime)
	if !l.hasWaiter(f.opcode) && !readAllAnswer {
		return
	}
	p, err := l.hs.payload(f.raw)
	if err != nil {
		return
	}
	if !l.resolveWaiter(f.opcode, p) && f.opcode == opReadAll {
		// A read-all awaited on the report opcode (setChargingMode,
		// readCoverPictureID): the simulator answers with 0x0300, hardware
		// with a 0x0200 response; either one answers it.
		l.resolveWaiter(opRealtime, p)
	}
}

// liveLoop returns the running loop, or nil.
func (m *Manager) liveLoop() *loop {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.running {
		return nil
	}
	return m.loop
}

// request writes one frame and waits for the charger's answer to awaitOpcode.
// The waiter is registered before the write, never after: a reply can arrive
// while the write is still returning. Like ChargerSession.send it checks no
// gate beyond a live session; callers check theirs once per sequence.
func (m *Manager) request(build func(*loop) (outgoingFrame, error), awaitOpcode uint16, timeout time.Duration) (a2687.Payload, error) {
	l := m.liveLoop()
	if l == nil {
		return a2687.Payload{}, ErrNotRunning
	}
	var w *replyWaiter
	err := m.exec(func(l *loop) error {
		if l.phase != PhasePolling || l.hs == nil {
			return ErrNotReady
		}
		frame, err := build(l)
		if err != nil {
			return err
		}
		w = &replyWaiter{opcode: awaitOpcode, ch: make(chan replyResult, 1)}
		l.waiters = append(l.waiters, w)
		if err := l.tr.Write(l.ctx, frame.bytes); err != nil {
			l.removeWaiter(w)
			return fmt.Errorf("session: write: %w", err)
		}
		return nil
	})
	if err != nil {
		return a2687.Payload{}, err
	}
	if timeout <= 0 {
		timeout = m.opts.ReplyTimeout
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case r := <-w.ch:
		return r.payload, r.err
	case <-timer.C:
		_ = m.exec(func(l *loop) error {
			l.removeWaiter(w)
			return nil
		})
		select {
		case r := <-w.ch:
			return r.payload, r.err
		default:
		}
		return a2687.Payload{}, fmt.Errorf("%w: no reply to 0x%04x", ErrTimeout, awaitOpcode)
	case <-l.ctx.Done():
		return a2687.Payload{}, ErrClosed
	}
}

// send writes one frame the charger does not answer and returns once the
// bytes are on the wire (a cover fill slice).
func (m *Manager) send(build func(*loop) (outgoingFrame, error)) error {
	return m.exec(func(l *loop) error {
		if l.phase != PhasePolling || l.hs == nil {
			return ErrNotReady
		}
		frame, err := build(l)
		if err != nil {
			return err
		}
		if err := l.tr.Write(l.ctx, frame.bytes); err != nil {
			return fmt.Errorf("session: write: %w", err)
		}
		return nil
	})
}

func messageFrame(msg a2687.OutgoingMessage) func(*loop) (outgoingFrame, error) {
	return func(l *loop) (outgoingFrame, error) { return l.hs.message(msg) }
}

func readAllFrame(l *loop) (outgoingFrame, error) { return l.hs.readAll(l.now()) }

// holdPolling pauses the poll timer until the returned release runs
// (ChargerSession.withPollingHeld): a cover push must not have probes and
// read-alls interleaved with its slices.
func (m *Manager) holdPolling() func() {
	_ = m.exec(func(l *loop) error {
		l.pollHolds++
		return nil
	})
	released := false
	return func() {
		if released {
			return
		}
		released = true
		_ = m.exec(func(l *loop) error {
			if l.pollHolds > 0 {
				l.pollHolds--
			}
			return nil
		})
	}
}

// requireReady is ChargerSession.requireSessionReady.
func (m *Manager) requireReady() error {
	return m.exec(func(l *loop) error {
		if l.phase != PhasePolling || l.hs == nil || !l.hs.ready() {
			return ErrNotReady
		}
		return nil
	})
}

// --- charging mode -----------------------------------------------------------

// SetChargingMode switches the power-allocation mode (0 AI, 1 standard) and
// reads AA back (ChargerSession.setChargingMode). true means AA came back
// holding the code that was sent. false is not a failure: the settings field
// is a handshake snapshot and may not move until the next link, so it means
// "not confirmed yet". Only a returned error is a failed write.
func (m *Manager) SetChargingMode(code byte) (bool, error) {
	switch code {
	case byte(a2687.ChargingModeAI), byte(a2687.ChargingModeStandard):
	case byte(a2687.ChargingModeCustom):
		return false, fmt.Errorf("%w: custom charging mode needs its power limits", ErrInvalidArgument)
	default:
		return false, fmt.Errorf("%w: charging mode %d", ErrInvalidArgument, code)
	}
	return m.chargingModeWrite(code, func(at time.Time) a2687.OutgoingMessage {
		return a2687.SetChargingMode(a2687.ChargingMode(code), at)
	})
}

// SetCustomChargingMode switches to custom mode with C1..C3 limits in watts
// (each 0 or 15..140, at most 160 together). Same read-back contract as
// SetChargingMode.
func (m *Manager) SetCustomChargingMode(autoExit bool, watts [3]int) (bool, error) {
	var w [3]byte
	for i, v := range watts {
		if v < 0 || v > 255 {
			return false, fmt.Errorf("%w: custom power %d W", ErrInvalidArgument, v)
		}
		w[i] = byte(v)
	}
	power := a2687.NewCustomChargingPower(autoExit, w)
	if !power.IsValid() {
		return false, fmt.Errorf("%w: custom power limits %v", ErrInvalidArgument, watts)
	}
	return m.chargingModeWrite(byte(a2687.ChargingModeCustom), func(at time.Time) a2687.OutgoingMessage {
		return a2687.SetCustomChargingMode(power, at)
	})
}

func (m *Manager) chargingModeWrite(code byte, build func(time.Time) a2687.OutgoingMessage) (bool, error) {
	if err := m.requireReady(); err != nil {
		return false, err
	}
	reply, err := m.request(func(l *loop) (outgoingFrame, error) {
		return l.hs.message(build(l.now()))
	}, opChargeMode, m.opts.ReplyTimeout)
	if err != nil {
		return false, err
	}
	// The result code is the payload's leading status byte, not A1 (a
	// constant 0x31 on this firmware).
	if !reply.IsOK() {
		status, _ := reply.StatusCode()
		return false, fmt.Errorf("%w: charging mode status 0x%02x", ErrDeviceRejected, status)
	}
	// A fresh read-all, not just the next report: AA rides the read-all and
	// the 1 Hz stream never mentions it.
	_, _ = m.request(readAllFrame, opRealtime, m.opts.ReplyTimeout)
	s := m.Snapshot()
	if s.Telemetry == nil || s.Telemetry.Settings == nil || s.Telemetry.Settings.ChargingMode == nil {
		return false, nil
	}
	return *s.Telemetry.Settings.ChargingMode == int(code), nil
}

// --- picking a charger ------------------------------------------------------------

// autoConnects reports whether a discovered charger may connect by itself:
// a saved one (or the simulator, which advertises itself as saved).
func (l *loop) autoConnects(d transport.Discovered) bool {
	if d.Saved {
		return true
	}
	for _, id := range l.remembered {
		if id == d.ID {
			return true
		}
	}
	return false
}

// canBrowse is SessionSnapshot.canBrowseNearbyDevices: no link to keep.
func (l *loop) canBrowse() bool {
	switch l.phase {
	case PhaseIdle, PhaseScanning, PhaseConnecting, PhaseReconnecting, PhaseFailed:
		return true
	}
	return false
}

// Browse scans so the picker can show everything nearby
// (ChargerSession.browse). Already-seen devices stay listed. A live link is
// never dropped for it.
func (m *Manager) Browse() error {
	return m.exec(func(l *loop) error {
		if !l.canBrowse() {
			_ = l.tr.StopScan()
			l.scanning = false
			l.publish()
			return nil
		}
		if l.phase == PhaseIdle || l.phase == PhaseFailed {
			l.phase = PhaseScanning
			l.errStr = ""
			l.browsing = true
			l.userDisconnected = false
		}
		l.scanning = true
		l.scanStarted = l.now()
		l.publish()
		if err := l.tr.Scan(l.ctx, l.opts.Product); err != nil {
			l.scanning = false
			l.fail(fmt.Errorf("session: scan: %w", err))
			return err
		}
		return nil
	})
}

// BrowseForNewCharger lets go of the current charger and lists everything
// nearby, so another one can be picked and saved. Nothing connects by itself
// until a device is picked or CancelBrowseForNewCharger runs.
func (m *Manager) BrowseForNewCharger() error {
	return m.exec(func(l *loop) error {
		released := ""
		if l.current != nil && (l.phase == PhasePolling || l.phase == PhaseHandshake || l.phase == PhaseConnecting) {
			released = l.current.ID
		}
		l.dropLink()
		l.disarmRetry()
		l.retryAttempt = 0
		l.released = released
		l.browsing = true
		l.userDisconnected = false
		l.targetID = ""
		l.phase = PhaseScanning
		l.scanning = true
		l.scanStarted = l.now()
		l.errStr = ""
		l.publish()
		if err := l.tr.Scan(l.ctx, l.opts.Product); err != nil {
			l.scanning = false
			l.fail(fmt.Errorf("session: scan: %w", err))
			return err
		}
		return nil
	})
}

// CancelBrowseForNewCharger leaves an add-charger browse without a pick: the
// charger it let go of comes back first, then the saved chargers.
func (m *Manager) CancelBrowseForNewCharger() error {
	return m.exec(func(l *loop) error {
		released := l.released
		l.released = ""
		l.browsing = false
		_ = l.tr.StopScan()
		l.scanning = false
		target := released
		if target == "" && len(l.remembered) > 0 {
			target = l.remembered[0]
		}
		if target == "" {
			return l.startScanning()
		}
		return l.connectTo(target)
	})
}

// Forget stops remembering a charger. When it is the one in use (or waited
// for) the link is dropped and the session carries on with the saved
// chargers that remain, or lists nearby devices when none is left.
func (m *Manager) Forget(id string) error {
	if id == "" {
		return fmt.Errorf("%w: empty device id", ErrInvalidArgument)
	}
	return m.exec(func(l *loop) error {
		kept := l.remembered[:0:0]
		for _, r := range l.remembered {
			if r != id {
				kept = append(kept, r)
			}
		}
		l.remembered = kept
		if l.released == id {
			l.released = ""
		}
		current := l.targetID == id || (l.current != nil && l.current.ID == id)
		if !current {
			return nil
		}
		l.dropLink()
		l.disarmRetry()
		l.retryAttempt = 0
		l.targetID = ""
		l.resetChargerScoped()
		if len(l.remembered) > 0 {
			return l.connectTo(l.remembered[0])
		}
		l.browsing = true
		l.userDisconnected = false
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
	})
}
