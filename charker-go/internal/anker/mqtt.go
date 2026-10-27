package anker

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"strconv"
	"sync"
	"time"

	"charker/internal/a2345"
)

// MQTTErrorKind discriminates MQTTError (A2345MQTTError).
type MQTTErrorKind int

const (
	MQTTErrInvalidConfiguration MQTTErrorKind = iota + 1
	MQTTErrInvalidClientIdentity
	MQTTErrConnectionFailed
	MQTTErrConnectionRejected
	MQTTErrSubscriptionRejected
	MQTTErrProtocolViolation
	MQTTErrHandshakeTimedOut
	MQTTErrKeepAliveTimedOut
)

// MQTTError ends an MQTT session.
type MQTTError struct {
	Kind MQTTErrorKind
	// Code is the CONNACK/SUBACK return code.
	Code int
}

func (e *MQTTError) Error() string { return e.Text().String() }

// Is matches on the kind.
func (e *MQTTError) Is(target error) bool {
	t, ok := target.(*MQTTError)
	return ok && t.Kind == e.Kind
}

// Text is A2345MQTTError.errorDescription.
func (e *MQTTError) Text() Text {
	switch e.Kind {
	case MQTTErrInvalidConfiguration:
		return T("MQTT 连接参数无效。")
	case MQTTErrInvalidClientIdentity:
		return T("MQTT 客户端证书与私钥无法组成身份（%d）。", e.Code)
	case MQTTErrConnectionFailed:
		return T("无法连接 Anker MQTT 服务。")
	case MQTTErrConnectionRejected:
		return T("Anker MQTT 拒绝了连接（%d）。", e.Code)
	case MQTTErrSubscriptionRejected:
		return T("Anker MQTT 拒绝了订阅（%d）。", e.Code)
	case MQTTErrProtocolViolation:
		return T("Anker MQTT 返回了无效数据。")
	case MQTTErrHandshakeTimedOut:
		return T("Anker MQTT 连接或订阅握手超时。")
	case MQTTErrKeepAliveTimedOut:
		return T("Anker MQTT 心跳超时。")
	}
	return T("Anker MQTT 返回了无效数据。")
}

// ErrNotSubscribed is returned by Send outside an active subscription.
var ErrNotSubscribed = errors.New("mqtt: not subscribed")

// MQTT session timings.
const (
	// MQTTHandshakeTimeout is one bounded budget for the network, CONNACK and
	// SUBACK; without it a silent broker could pin one attempt forever before
	// the post-subscription telemetry watchdog exists.
	MQTTHandshakeTimeout = 20 * time.Second
	// MQTTRealtimeRefreshInterval renews the realtime trigger: the A2345's
	// device-side window is 10 s, renewed two seconds early so scheduler
	// jitter cannot create a telemetry gap.
	MQTTRealtimeRefreshInterval = 8 * time.Second
	mqttWriteTimeout            = 15 * time.Second
)

// MQTTConfig is one subscription to one A2345 (A2345MQTTConfiguration).
type MQTTConfig struct {
	Credentials MQTTCredentials
	Device      BoundDevice
	Topic       string
	ClientID    string
	// Port defaults to 8883, KeepAlive to 60 s.
	Port      uint16
	KeepAlive uint16
	// Dial replaces the TLS connection to Credentials.Endpoint (tests, a
	// fake broker). The default dials TLS 1.2+ with the client certificate
	// and verifies the broker against the system roots.
	Dial func(ctx context.Context) (net.Conn, error)
	// HandshakeTimeout and RealtimeRefreshInterval default to the constants
	// above; tests shorten them.
	HandshakeTimeout        time.Duration
	RealtimeRefreshInterval time.Duration
	// PingInterval overrides max(5 s, KeepAlive/2) (tests).
	PingInterval time.Duration
}

// MQTTEventKind discriminates MQTTEvent.
type MQTTEventKind int

const (
	MQTTConnected MQTTEventKind = iota + 1
	MQTTSubscribed
	MQTTMessage
	MQTTDisconnected
	MQTTFailed
)

// MQTTEvent is one subscriber event. Disconnected and Failed are terminal;
// the channel closes after them.
type MQTTEvent struct {
	Kind    MQTTEventKind
	Topic   string
	Payload []byte
	Err     *MQTTError
}

// mqttEventBuffer: the UI only needs the newest few state changes and frames.
// A bounded stream keeps wake/resume from replaying an unbounded backlog.
const mqttEventBuffer = 16

// Subscriber is a minimal MQTT 3.1.1 client for one A2345. Its surface can
// connect, subscribe, send one a2345.Command at a time and stop; there is no
// way to publish raw bytes or to another topic. QoS-1 messages are
// acknowledged because PUBACK is transport housekeeping, not a device write.
type Subscriber struct {
	cfg    MQTTConfig
	events chan MQTTEvent

	mu          sync.Mutex
	state       subscriberState
	conn        net.Conn
	builder     *CommandBuilder
	terminal    bool
	lastInbound time.Time
	cancel      context.CancelFunc
	handshake   *time.Timer
	stopTickers chan struct{}

	writeMu sync.Mutex
}

// NewSubscriber builds an idle subscriber.
func NewSubscriber(cfg MQTTConfig) *Subscriber {
	if cfg.Port == 0 {
		cfg.Port = 8883
	}
	if cfg.KeepAlive == 0 {
		cfg.KeepAlive = 60
	}
	if cfg.HandshakeTimeout <= 0 {
		cfg.HandshakeTimeout = MQTTHandshakeTimeout
	}
	if cfg.RealtimeRefreshInterval <= 0 {
		cfg.RealtimeRefreshInterval = MQTTRealtimeRefreshInterval
	}
	if cfg.PingInterval <= 0 {
		cfg.PingInterval = max(5*time.Second, time.Duration(cfg.KeepAlive)*time.Second/2)
	}
	return &Subscriber{cfg: cfg, events: make(chan MQTTEvent, mqttEventBuffer)}
}

// Events is the event stream; it is closed after the terminal event.
func (s *Subscriber) Events() <-chan MQTTEvent { return s.events }

// Start connects in the background. A second Start is ignored.
func (s *Subscriber) Start() {
	s.mu.Lock()
	if s.state != stateIdle {
		s.mu.Unlock()
		return
	}
	cfg := s.cfg
	if cfg.Credentials.Endpoint == "" || cfg.ClientID == "" || cfg.Topic == "" {
		s.failLocked(&MQTTError{Kind: MQTTErrInvalidConfiguration})
		s.mu.Unlock()
		return
	}
	builder, err := NewCommandBuilder(cfg.Credentials, cfg.Device, cfg.Topic)
	if err != nil {
		s.failLocked(&MQTTError{Kind: MQTTErrInvalidConfiguration})
		s.mu.Unlock()
		return
	}
	dial := cfg.Dial
	if dial == nil {
		cert, err := cfg.Credentials.TLSCertificate()
		if err != nil {
			s.failLocked(&MQTTError{Kind: MQTTErrInvalidClientIdentity})
			s.mu.Unlock()
			return
		}
		address := net.JoinHostPort(cfg.Credentials.Endpoint, strconv.Itoa(int(cfg.Port)))
		tlsConfig := &tls.Config{
			MinVersion:   tls.VersionTLS12,
			ServerName:   cfg.Credentials.Endpoint,
			Certificates: []tls.Certificate{cert},
		}
		dial = func(ctx context.Context) (net.Conn, error) {
			d := tls.Dialer{Config: tlsConfig}
			return d.DialContext(ctx, "tcp", address)
		}
	}
	s.builder = builder
	s.state = stateConnecting
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	s.handshake = time.AfterFunc(cfg.HandshakeTimeout, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.state.requiresHandshakeWatchdog() {
			s.failLocked(&MQTTError{Kind: MQTTErrHandshakeTimedOut})
		}
	})
	s.mu.Unlock()
	go s.run(ctx, dial)
}

// Stop sends DISCONNECT when subscribed, closes the socket and ends the
// stream with Disconnected. It is idempotent.
func (s *Subscriber) Stop() {
	s.mu.Lock()
	if s.terminal {
		s.mu.Unlock()
		return
	}
	conn := s.conn
	subscribed := s.state == stateSubscribed
	s.terminateLocked(MQTTEvent{Kind: MQTTDisconnected})
	s.mu.Unlock()
	if subscribed && conn != nil {
		_ = conn.SetWriteDeadline(time.Now().Add(time.Second))
		s.writeMu.Lock()
		_, _ = conn.Write(mqttDisconnectPacket())
		s.writeMu.Unlock()
	}
	if conn != nil {
		_ = conn.Close()
	}
}

// Send publishes one command to the device's request topic. It fails when
// the subscription is not active, the command does not validate or the
// socket refused it.
func (s *Subscriber) Send(cmd a2345.Command) error {
	s.mu.Lock()
	if s.state != stateSubscribed || s.builder == nil || s.conn == nil {
		s.mu.Unlock()
		return ErrNotSubscribed
	}
	packet, err := s.builder.Packet(cmd, time.Now())
	conn := s.conn
	s.mu.Unlock()
	if err != nil {
		return err
	}
	return s.writeTo(conn, packet)
}

func (s *Subscriber) run(ctx context.Context, dial func(context.Context) (net.Conn, error)) {
	conn, err := dial(ctx)
	if err != nil {
		s.fail(&MQTTError{Kind: MQTTErrConnectionFailed})
		return
	}
	s.mu.Lock()
	if s.terminal {
		s.mu.Unlock()
		_ = conn.Close()
		return
	}
	s.conn = conn
	s.state = stateAwaitingConnack
	s.lastInbound = time.Now()
	s.mu.Unlock()

	connect, err := mqttConnect(s.cfg.ClientID, s.cfg.KeepAlive)
	if err != nil {
		s.fail(&MQTTError{Kind: MQTTErrProtocolViolation})
		_ = conn.Close()
		return
	}
	go func() {
		if err := s.writeTo(conn, connect); err != nil {
			s.fail(&MQTTError{Kind: MQTTErrConnectionFailed})
		}
	}()

	var buf []byte
	chunk := make([]byte, 65_536)
	for {
		n, err := conn.Read(chunk)
		if n > 0 {
			s.mu.Lock()
			s.lastInbound = time.Now()
			s.mu.Unlock()
			buf = append(buf, chunk[:n]...)
			if len(buf) > MQTTMaximumPacketBytes+5 {
				s.fail(&MQTTError{Kind: MQTTErrProtocolViolation})
				return
			}
			for {
				packet, rest, derr := mqttDecodeNext(buf)
				if derr != nil {
					s.fail(&MQTTError{Kind: MQTTErrProtocolViolation})
					return
				}
				if packet == nil {
					break
				}
				buf = rest
				if !s.handle(conn, packet) {
					return
				}
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				// The broker closed the stream: end quietly, no DISCONNECT.
				s.mu.Lock()
				s.terminateLocked(MQTTEvent{Kind: MQTTDisconnected})
				s.mu.Unlock()
				_ = conn.Close()
			} else {
				s.fail(&MQTTError{Kind: MQTTErrConnectionFailed})
			}
			return
		}
	}
}

// handle processes one packet; false ends the read loop.
func (s *Subscriber) handle(conn net.Conn, p *mqttInbound) bool {
	var out [][]byte
	s.mu.Lock()
	if s.terminal {
		s.mu.Unlock()
		return false
	}
	switch p.kind {
	case mqttConnack:
		if s.state != stateAwaitingConnack {
			s.failLocked(&MQTTError{Kind: MQTTErrProtocolViolation})
			s.mu.Unlock()
			return false
		}
		if p.returnCode != 0 {
			s.failLocked(&MQTTError{Kind: MQTTErrConnectionRejected, Code: int(p.returnCode)})
			s.mu.Unlock()
			return false
		}
		s.emitLocked(MQTTEvent{Kind: MQTTConnected})
		s.state = stateAwaitingSuback
		packet, err := mqttSubscribe(s.cfg.Topic, 1, 0)
		if err != nil {
			s.failLocked(&MQTTError{Kind: MQTTErrProtocolViolation})
			s.mu.Unlock()
			return false
		}
		out = append(out, packet)

	case mqttSuback:
		requests, err := acceptSuback(s.state, 1, p.packetID, p.returnCodes)
		if err != nil {
			var me *MQTTError
			errors.As(err, &me)
			s.failLocked(me)
			s.mu.Unlock()
			return false
		}
		s.state = stateSubscribed
		if s.handshake != nil {
			s.handshake.Stop()
		}
		now := time.Now()
		for _, r := range requests {
			packet, err := s.builder.Packet(r, now)
			if err != nil {
				s.failLocked(&MQTTError{Kind: MQTTErrProtocolViolation})
				s.mu.Unlock()
				return false
			}
			out = append(out, packet)
		}
		s.stopTickers = make(chan struct{})
		go s.tick(conn, s.stopTickers)
		s.emitLocked(MQTTEvent{Kind: MQTTSubscribed})

	case mqttPublish:
		if s.state != stateSubscribed || s.builder == nil || !s.builder.AcceptsInboundTopic(p.topic) {
			s.failLocked(&MQTTError{Kind: MQTTErrProtocolViolation})
			s.mu.Unlock()
			return false
		}
		s.emitLocked(MQTTEvent{Kind: MQTTMessage, Topic: p.topic, Payload: p.payload})
		if p.qos == 1 {
			ack, err := mqttPubAck(p.packetID)
			if err != nil || !p.hasPacketID {
				s.failLocked(&MQTTError{Kind: MQTTErrProtocolViolation})
				s.mu.Unlock()
				return false
			}
			out = append(out, ack)
		}

	case mqttPingResponse:

	case mqttDisconnect:
		s.terminateLocked(MQTTEvent{Kind: MQTTDisconnected})
		s.mu.Unlock()
		_ = conn.Close()
		return false

	case mqttOther:
		// Commands go out with QoS 0, so PUBACK and other command-response
		// packet types have no role in this session.
	}
	s.mu.Unlock()
	for _, packet := range out {
		if err := s.writeTo(conn, packet); err != nil {
			s.fail(&MQTTError{Kind: MQTTErrConnectionFailed})
			return false
		}
	}
	return true
}

// tick runs the keep-alive ping and the realtime refresh while subscribed.
func (s *Subscriber) tick(conn net.Conn, stop <-chan struct{}) {
	ping := time.NewTicker(s.cfg.PingInterval)
	refresh := time.NewTicker(s.cfg.RealtimeRefreshInterval)
	defer ping.Stop()
	defer refresh.Stop()
	silence := time.Duration(s.cfg.KeepAlive) * 2 * time.Second
	for {
		select {
		case <-stop:
			return
		case <-ping.C:
			s.mu.Lock()
			if s.state != stateSubscribed {
				s.mu.Unlock()
				return
			}
			if time.Since(s.lastInbound) > silence {
				s.failLocked(&MQTTError{Kind: MQTTErrKeepAliveTimedOut})
				s.mu.Unlock()
				_ = conn.Close()
				return
			}
			s.mu.Unlock()
			if err := s.writeTo(conn, mqttPingRequest()); err != nil {
				s.fail(&MQTTError{Kind: MQTTErrConnectionFailed})
				return
			}
		case <-refresh.C:
			s.mu.Lock()
			if s.state != stateSubscribed || s.builder == nil {
				s.mu.Unlock()
				return
			}
			packet, err := s.builder.Packet(a2345.RealtimeTrigger(), time.Now())
			s.mu.Unlock()
			if err != nil {
				s.fail(&MQTTError{Kind: MQTTErrProtocolViolation})
				return
			}
			if err := s.writeTo(conn, packet); err != nil {
				s.fail(&MQTTError{Kind: MQTTErrConnectionFailed})
				return
			}
		}
	}
}

func (s *Subscriber) writeTo(conn net.Conn, data []byte) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_ = conn.SetWriteDeadline(time.Now().Add(mqttWriteTimeout))
	_, err := conn.Write(data)
	return err
}

func (s *Subscriber) fail(err *MQTTError) {
	s.mu.Lock()
	conn := s.conn
	s.failLocked(err)
	s.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
}

// failLocked ends the session with Failed. The caller closes the socket (or
// relies on terminateLocked having closed it).
func (s *Subscriber) failLocked(err *MQTTError) {
	if err == nil {
		err = &MQTTError{Kind: MQTTErrProtocolViolation}
	}
	s.terminateLocked(MQTTEvent{Kind: MQTTFailed, Err: err})
}

func (s *Subscriber) terminateLocked(ev MQTTEvent) {
	if s.terminal {
		return
	}
	s.terminal = true
	s.state = stateStopped
	if s.handshake != nil {
		s.handshake.Stop()
	}
	if s.stopTickers != nil {
		close(s.stopTickers)
		s.stopTickers = nil
	}
	if s.cancel != nil {
		s.cancel()
	}
	conn := s.conn
	s.conn = nil
	s.builder = nil
	if conn != nil && ev.Kind == MQTTFailed {
		// Unblock the reader; Stop closes after its DISCONNECT instead.
		go conn.Close()
	}
	s.emitLocked(ev)
	close(s.events)
}

// emitLocked never blocks: a full stream drops its oldest event.
func (s *Subscriber) emitLocked(ev MQTTEvent) {
	select {
	case s.events <- ev:
		return
	default:
	}
	select {
	case <-s.events:
	default:
	}
	select {
	case s.events <- ev:
	default:
	}
}
