package mock

import (
	"encoding/binary"
	"math"
	"time"

	"charker/internal/session/wire"
)

// simPort is one simulated A2687 port.
type simPort struct {
	enabled   bool
	volts     float64
	amps      float64
	cable     byte
	profile   byte
	totalSecs uint32
	remainSec uint32
}

// simDevice is a software A2687 that speaks the real wire protocol subset the
// session engine uses. It is not safe for concurrent use; the transport
// serialises access.
type simDevice struct {
	ephemeral *wire.Ephemeral
	keys      *wire.SessionKeys
	session   *wire.Cipher
	// mtu / auth / enc negotiated in the capability exchange.
	mtu  uint16
	auth byte
	enc  byte

	ports    [3]simPort
	timeout  byte // 0..4 screen timeout code
	bright   byte // 0..100
	mode     byte // charging mode code
	orient   byte // 0..3
	gyro     byte // 0/1
	streamOn bool

	tick int64
}

const (
	defaultMTU  uint16 = 297
	defaultAuth byte   = 0x44
	defaultEnc  byte   = 0x02
)

// newSimDevice builds a device in Charker's demo state:
//
//	C2 charging 42 W Apple PD (~27.5 V / 1.53 A),
//	C1 enabled but idle (5.08 V / 0 A),
//	C3 off.
func newSimDevice() *simDevice {
	d := &simDevice{
		mtu:     defaultMTU,
		auth:    defaultAuth,
		enc:     defaultEnc,
		timeout: 2, // 5 min
		bright:  80,
		mode:    0, // AI
		orient:  0,
		gyro:    0,
	}
	d.ports[0] = simPort{enabled: true, volts: 5.08, cable: 0}
	d.ports[1] = simPort{enabled: true, volts: 27.5, amps: 1.53, cable: 1, profile: 1}
	d.ports[2] = simPort{}
	return d
}

// reset restarts a link: new ephemeral key, no session, demo state.
func (d *simDevice) reset() {
	*d = *newSimDevice()
}

func portPower(p simPort) float64 {
	if !p.enabled {
		return 0
	}
	return p.volts * p.amps
}

// totalWatts reports the demo total (only the delivering C2 contributes).
func (d *simDevice) totalWatts() float64 {
	var sum float64
	for _, p := range d.ports {
		sum += portPower(p)
	}
	return sum
}

// advanceScript applies the deterministic lively-demo jitter. It runs once per
// report interval so every sample has a slightly different, realistic value.
func (d *simDevice) advanceScript() {
	d.tick++
	t := float64(d.tick)
	// C2: Apple PD at ~42 W with slow breathing and occasional jitter.
	if d.ports[1].enabled && d.ports[1].amps > 0.1 {
		d.ports[1].volts = 27.5 + 0.02*math.Sin(t/3.1) + 0.01*math.Sin(t/11.7)
		breath := 1 + 0.012*math.Sin(t/5.3) + 0.004*math.Sin(t/17.0)
		d.ports[1].amps = 1.53 * breath
	}
	// C1 stays attached but idle: 5.08 V, 0 A.
	if d.ports[0].enabled {
		d.ports[0].volts = 5.08 + 0.004*math.Sin(t/7.0)
	}
	// Countdowns tick down one report at a time.
	for i := range d.ports {
		p := &d.ports[i]
		if p.totalSecs > 0 && p.remainSec > 0 {
			if p.remainSec > uint32(reportSeconds) {
				p.remainSec -= uint32(reportSeconds)
			} else {
				p.totalSecs, p.remainSec = 0, 0
			}
		}
	}
}

// reportSeconds is how much a countdown advances per report; the transport
// keeps it in sync with Options.ReportInterval.
const reportSeconds = 1

func (d *simDevice) portBytes(i int) []byte {
	p := d.ports[i]
	status := byte(0)
	if p.enabled {
		status = 1
	}
	b := make([]byte, 7, 9)
	b[0] = status
	if p.enabled {
		binary.LittleEndian.PutUint16(b[1:3], uint16(math.Round(p.volts*1000)))
		binary.LittleEndian.PutUint16(b[3:5], uint16(math.Round(p.amps*1000)))
		binary.LittleEndian.PutUint16(b[5:7], uint16(math.Round(portPower(p)*100)))
	}
	return b
}

func (d *simDevice) controlBytes(i int) []byte {
	p := d.ports[i]
	b := make([]byte, 12)
	if p.enabled {
		b[0] = 1
	}
	if p.totalSecs > 0 {
		b[1] = 1
		binary.LittleEndian.PutUint32(b[2:6], p.totalSecs)
		binary.LittleEndian.PutUint32(b[6:10], p.remainSec)
	} else {
		// Idle default prefix: switch, no task, 300/300 s.
		binary.LittleEndian.PutUint32(b[2:6], 300)
		binary.LittleEndian.PutUint32(b[6:10], 300)
	}
	b[10] = p.cable
	if p.enabled && p.amps > 0.02 {
		b[11] = p.profile
	}
	return b
}

// telemetryPayload builds the 0x0300 plaintext: status, A1 21, three port
// structs, three control structs, connected identities and settings.
func (d *simDevice) telemetryPayload() []byte {
	fields := make([]wire.TLV, 0, 12)
	for i := 0; i < 3; i++ {
		fields = append(fields, wire.TLV{
			ID:    []byte{wire.FieldA5, wire.FieldA6, wire.FieldA7}[i],
			Value: wire.EncodeTyped(wire.TypedBytes, d.portBytes(i)),
		})
	}
	for i := 0; i < 3; i++ {
		fields = append(fields, wire.TLV{
			ID:    []byte{wire.FieldAC, wire.FieldAD, wire.FieldAE}[i],
			Value: wire.EncodeTyped(wire.TypedBytes, d.controlBytes(i)),
		})
	}
	// B4 connected USB identities: C1 none, C2 Apple 05AC:7518, C3 none.
	b4 := []byte{0xfa, 0xff, 0xfb, 0xff, 0xac, 0x05, 0x18, 0x75, 0xfa, 0xff, 0xfb, 0xff}
	fields = append(fields, wire.TLV{ID: wire.FieldB4, Value: b4})
	fields = append(fields,
		wire.TLV{ID: wire.FieldA8, Value: []byte{d.timeout}},
		wire.TLV{ID: wire.FieldA9, Value: []byte{d.bright}},
		wire.TLV{ID: wire.FieldAA, Value: []byte{d.mode}},
		wire.TLV{ID: wire.FieldAF, Value: []byte{d.orient}},
		wire.TLV{ID: wire.FieldB2, Value: []byte{d.gyro}},
	)
	payload := []byte{0x00, wire.FieldA1, 0x01, 0x21}
	return append(payload, wire.EncodeTLVs(fields)...)
}

// telemetryFrame returns a sealed 0x0300 realtime report.
func (d *simDevice) telemetryFrame() []byte {
	if d.session == nil {
		return nil
	}
	payload := d.session.Seal(d.telemetryPayload())
	f := wire.Frame{
		Group:      wire.GroupSession,
		RawCommand: wire.OpRealtimeReport | wire.FlagEncrypted | wire.FlagResponse,
		Payload:    payload,
	}
	return wire.EncodeDevice(f)
}

// responseFrame seals a device response with the right key for the opcode.
func (d *simDevice) responseFrame(opcode uint16, plaintext []byte, group byte) []byte {
	var sealed []byte
	if group == wire.GroupSession && d.session != nil {
		sealed = d.session.Seal(plaintext)
	} else if c, err := wire.NegotiationCipher(); err == nil {
		sealed = c.Seal(plaintext)
		group = wire.GroupNegotiation
	}
	f := wire.Frame{
		Group:      group,
		RawCommand: opcode | wire.FlagEncrypted | wire.FlagResponse,
		Payload:    sealed,
	}
	return wire.EncodeDevice(f)
}

// handleFrame consumes one client frame and returns the frames to send back.
// The bool reports that a fresh telemetry report should follow immediately.
func (d *simDevice) handleFrame(raw []byte) (out [][]byte, reportNow bool) {
	frame, err := wire.Decode(raw)
	if err != nil || !frame.Encrypted() {
		return nil, false
	}
	opcode := frame.Opcode()
	// Select the cipher and decrypt.
	var plain []byte
	switch opcode {
	case wire.OpInitialConnect, wire.OpCapability, wire.OpBaseInfo, wire.OpSetCapability, wire.OpPublicKey:
		c, err := wire.NegotiationCipher()
		if err != nil {
			return nil, false
		}
		plain, err = c.Open(frame.Payload)
		if err != nil {
			return nil, false
		}
	default:
		if d.session == nil {
			return nil, false
		}
		plain, err = d.session.Open(frame.Payload)
		if err != nil {
			return nil, false
		}
	}
	switch opcode {
	case wire.OpInitialConnect:
		out = append(out, d.responseFrame(opcode, []byte{0x00, 0xa1, 0x01, 0x01}, wire.GroupNegotiation))

	case wire.OpCapability:
		// 0x00 A1 02, A2 u16 0x0129, A3 0x44, A4 01, A5 02
		p := []byte{0x00, 0xa1, 0x01, 0x02, 0xa2, 0x02, 0x29, 0x01, 0xa3, 0x01, 0x44, 0xa4, 0x01, 0x01, 0xa5, 0x01, 0x02}
		out = append(out, d.responseFrame(opcode, p, wire.GroupNegotiation))

	case wire.OpBaseInfo:
		out = append(out, d.responseFrame(opcode, baseInfoPayload(), wire.GroupNegotiation))

	case wire.OpSetCapability:
		out = append(out, d.responseFrame(opcode, []byte{0x00}, wire.GroupNegotiation))

	case wire.OpPublicKey:
		cmd, err := wire.ParseSessionCommand(opcode, plain)
		if err != nil {
			return nil, false
		}
		clientPoint, ok := cmd.Fields[wire.FieldA1]
		if !ok {
			return nil, false
		}
		if len(clientPoint) == 65 && clientPoint[0] == wire.TypedBytes {
			clientPoint = clientPoint[1:]
		}
		if len(clientPoint) != 64 || d.ephemeral == nil {
			return nil, false
		}
		devicePub := d.ephemeral.PublicKey64()
		secret, err := d.ephemeral.SharedSecret(clientPoint)
		if err != nil {
			return nil, false
		}
		keys, err := wire.DeriveSessionKeys(secret)
		if err != nil {
			return nil, false
		}
		d.keys = keys
		c, err := keys.Cipher()
		if err != nil {
			return nil, false
		}
		d.session = c
		resp := []byte{0x00, wire.FieldA1, 0x40}
		resp = append(resp, devicePub...)
		out = append(out, d.responseFrame(opcode, resp, wire.GroupNegotiation))

	case wire.OpAESMetadata:
		out = append(out, d.responseFrame(opcode, []byte{0x00}, wire.GroupSession))

	case wire.OpUserAuth:
		out = append(out, d.responseFrame(opcode, []byte{0x00}, wire.GroupSession))
		d.streamOn = false // the trigger re-arms it

	case wire.OpReadAll:
		if tf := d.telemetryFrame(); tf != nil {
			out = append(out, tf)
		}

	case wire.OpBindSuccess:
		out = append(out, d.responseFrame(opcode, []byte{0x00}, wire.GroupSession))

	case wire.OpRealtimeTrigger:
		cmd, err := wire.ParseSessionCommand(opcode, plain)
		if err == nil {
			if v, ok := cmd.U8(wire.FieldA2); ok && v <= 3 {
				// Typed-u8 shape: screen orientation, not the trigger.
				d.orient = v
				out = append(out, d.responseFrame(opcode, []byte{0x00}, wire.GroupSession))
				return out, false
			}
		}
		d.streamOn = true
		out = append(out, d.responseFrame(opcode, []byte{0x00}, wire.GroupSession))

	case wire.OpPortOutput:
		cmd, err := wire.ParseSessionCommand(opcode, plain)
		if err != nil {
			return nil, false
		}
		port, ok := cmd.U8(wire.FieldA2)
		on, ok2 := cmd.U8(wire.FieldA3)
		if !ok || !ok2 || int(port) > 2 {
			return nil, false
		}
		d.setPortEnabled(int(port), on == 1)
		out = append(out, d.responseFrame(opcode, []byte{0x00}, wire.GroupSession))
		reportNow = true

	case wire.OpPortTimer:
		cmd, err := wire.ParseSessionCommand(opcode, plain)
		if err != nil {
			return nil, false
		}
		port, ok := cmd.U8(wire.FieldA2)
		secs, ok2 := cmd.U32(wire.FieldA3)
		if !ok || !ok2 || int(port) > 2 {
			return nil, false
		}
		if secs > 86400 {
			// Refuse with a non-zero status.
			out = append(out, d.responseFrame(opcode, []byte{0x04}, wire.GroupSession))
			return out, false
		}
		d.ports[port].totalSecs = secs
		d.ports[port].remainSec = secs
		out = append(out, d.responseFrame(opcode, []byte{0x00}, wire.GroupSession))
		reportNow = true

	case wire.OpScreenLanguage, wire.OpScreenTimeout, wire.OpScreenBright, wire.OpFixedAllocation, wire.OpChargingMode, wire.OpGyroscope:
		cmd, err := wire.ParseSessionCommand(opcode, plain)
		if err != nil {
			return nil, false
		}
		v, ok := cmd.U8(wire.FieldA2)
		if !ok {
			return nil, false
		}
		switch opcode {
		case wire.OpScreenTimeout:
			if v > 4 {
				out = append(out, d.responseFrame(opcode, []byte{0x04}, wire.GroupSession))
				return out, false
			}
			d.timeout = v
		case wire.OpScreenBright:
			if v < 25 || v > 100 {
				out = append(out, d.responseFrame(opcode, []byte{0x04}, wire.GroupSession))
				return out, false
			}
			d.bright = v
		case wire.OpScreenLanguage:
			// The A2687 demo does not expose language in telemetry; accept it.
		case wire.OpFixedAllocation:
			d.mode = 1 - d.mode // demo: allocation is not reported; keep ACK
		case wire.OpChargingMode:
			if v > 2 {
				out = append(out, d.responseFrame(opcode, []byte{0x04}, wire.GroupSession))
				return out, false
			}
			d.mode = v
		case wire.OpGyroscope:
			d.gyro = v & 1
		}
		out = append(out, d.responseFrame(opcode, []byte{0x00}, wire.GroupSession))
		reportNow = true
	}
	return out, reportNow
}

// setPortEnabled applies a P1 port-on/off write and gives the port a plausible
// output when it was previously off.
func (d *simDevice) setPortEnabled(i int, on bool) {
	p := &d.ports[i]
	p.enabled = on
	if on {
		switch i {
		case 0:
			p.volts, p.amps, p.cable, p.profile = 5.08, 0, 0, 0
		case 1:
			p.volts, p.amps, p.cable, p.profile = 27.5, 1.53, 1, 1
		default:
			p.volts, p.amps, p.cable, p.profile = 5.08, 0, 0, 0
		}
	} else {
		p.volts, p.amps = 0, 0
	}
}

// baseInfoPayload is the recovered device base-info plaintext adapted to the
// demo identity (firmware v0.0.5.2, serial ASHDMOCK00000000).
func baseInfoPayload() []byte {
	const (
		productName = "Charging"
		firmware    = "v0.0.5.2"
		serial      = "ASHDMOCK00000000"
		macSerial   = "MOCK00000000" // last 11 chars of serial
	)
	mac := []byte{0x02, 0x00, 0x5E, 0x10, 0x00, 0x01}
	var p []byte
	p = append(p, 0x00, 0xa1, 0x01, 0x03)
	p = append(p, 0xa2, byte(len(productName)))
	p = append(p, productName...)
	p = append(p, 0xa3, byte(len(firmware)))
	p = append(p, firmware...)
	p = append(p, 0xa4, byte(len(serial)))
	p = append(p, serial...)
	p = append(p, 0xa5, byte(len(mac)+len(macSerial)))
	p = append(p, mac...)
	p = append(p, macSerial...)
	return p
}

// runTicker advances the demo script; the transport calls it once per report.
func (d *simDevice) runTicker(interval time.Duration) {
	_ = interval
	d.advanceScript()
}
