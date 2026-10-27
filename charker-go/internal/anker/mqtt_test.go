package anker

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"testing"
	"time"

	"charker/internal/a2345"
)

func TestConnectPacketIsMQTT311WithCleanSessionAndNoCredentials(t *testing.T) {
	got, _ := mqttConnect("cid", 60)
	want := []byte{0x10, 0x0F, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x3C, 0x00, 0x03, 0x63, 0x69, 0x64}
	if !bytes.Equal(got, want) {
		t.Fatalf("% x", got)
	}
}

func TestSubscribePacketUsesRequiredFlagsAndQoSZero(t *testing.T) {
	got, _ := mqttSubscribe("dt/a/#", 0x1234, 0)
	want := []byte{0x82, 0x0B, 0x12, 0x34, 0x00, 0x06, 0x64, 0x74, 0x2F, 0x61, 0x2F, 0x23, 0x00}
	if !bytes.Equal(got, want) {
		t.Fatalf("% x", got)
	}
}

func TestPublishPacketIsExactQoSZeroWithoutRetainOrPacketIdentifier(t *testing.T) {
	got, _ := mqttPublishQoSZero("cmd/a", []byte("{}"))
	want := []byte{0x30, 0x09, 0x00, 0x05, 0x63, 0x6D, 0x64, 0x2F, 0x61, 0x7B, 0x7D}
	if !bytes.Equal(got, want) {
		t.Fatalf("% x", got)
	}
	for _, topic := range []string{"", "cmd/a/+", "cmd/a/#"} {
		if _, err := mqttPublishQoSZero(topic, nil); !errors.Is(err, errMQTTMalformed) {
			t.Errorf("%q: %v", topic, err)
		}
	}
}

func TestFragmentedConnackDoesNotConsumeBytesUntilComplete(t *testing.T) {
	buf := []byte{0x20, 0x02, 0x00}
	p, rest, err := mqttDecodeNext(buf)
	if p != nil || err != nil || !bytes.Equal(rest, buf) {
		t.Fatalf("partial decode: %v %v", p, err)
	}
	buf = append(buf, 0x00)
	p, rest, err = mqttDecodeNext(buf)
	if err != nil || p.kind != mqttConnack || p.sessionPresent || p.returnCode != 0 || len(rest) != 0 {
		t.Fatalf("connack: %+v %v", p, err)
	}
}

func TestQoSOnePublishDecodesAndHasMatchingPubAck(t *testing.T) {
	topic := "dt/anker_power/A2345/SERIAL/data"
	body := append([]byte{0, byte(len(topic))}, topic...)
	body = append(body, 0x22, 0x33, 0x01, 0x02, 0x03)
	packet := append([]byte{0x32, byte(len(body))}, body...)
	p, rest, err := mqttDecodeNext(packet)
	if err != nil || p.kind != mqttPublish || p.topic != topic || p.qos != 1 || p.packetID != 0x2233 ||
		!bytes.Equal(p.payload, []byte{1, 2, 3}) || len(rest) != 0 {
		t.Fatalf("publish: %+v %v", p, err)
	}
	ack, _ := mqttPubAck(0x2233)
	if !bytes.Equal(ack, []byte{0x40, 0x02, 0x22, 0x33}) {
		t.Fatalf("puback % x", ack)
	}
}

func TestDecoderHandlesMultiByteRemainingLengthAndLeavesFollowingPacket(t *testing.T) {
	payload := bytes.Repeat([]byte{0x7A}, 130)
	body := append([]byte{0x00, 0x01, 'a'}, payload...)
	packet := append([]byte{0x30, 0x85, 0x01}, body...)
	packet = append(packet, 0xD0, 0x00)
	p, rest, err := mqttDecodeNext(packet)
	if err != nil || p.kind != mqttPublish || p.topic != "a" || !bytes.Equal(p.payload, payload) || p.hasPacketID {
		t.Fatalf("publish: %+v %v", p, err)
	}
	p, rest, err = mqttDecodeNext(rest)
	if err != nil || p.kind != mqttPingResponse || len(rest) != 0 {
		t.Fatalf("pingresp: %+v %v", p, err)
	}
}

func TestMalformedRemainingLengthAndQoSTwoFailClosed(t *testing.T) {
	if _, _, err := mqttDecodeNext([]byte{0x30, 0x80, 0x80, 0x80, 0x80, 0x00}); !errors.Is(err, errMQTTMalformed) {
		t.Errorf("remaining length: %v", err)
	}
	var q *UnsupportedQoSError
	if _, _, err := mqttDecodeNext([]byte{0x34, 0x04, 0x00, 0x01, 0x61, 0x00}); !errors.As(err, &q) || q.QoS != 2 {
		t.Errorf("qos 2: %v", err)
	}
}

func TestDeclaredPacketAboveBusinessLimitFailsBeforeBodyArrives(t *testing.T) {
	packet := append([]byte{0x30}, mqttEncodeRemainingLength(MQTTMaximumPacketBytes+1)...)
	if _, _, err := mqttDecodeNext(packet); !errors.Is(err, errMQTTMalformed) {
		t.Fatalf("err = %v", err)
	}
}

func TestPingAndDisconnectAreTwoByteControlPackets(t *testing.T) {
	if !bytes.Equal(mqttPingRequest(), []byte{0xC0, 0x00}) || !bytes.Equal(mqttDisconnectPacket(), []byte{0xE0, 0x00}) {
		t.Fatal("control packets")
	}
}

func TestHandshakeWatchdogCoversEveryPreSubscriptionPhaseOnly(t *testing.T) {
	if MQTTHandshakeTimeout != 20*time.Second || MQTTRealtimeRefreshInterval != 8*time.Second {
		t.Fatal("timings")
	}
	want := map[subscriberState]bool{
		stateIdle: false, stateConnecting: true, stateAwaitingConnack: true,
		stateAwaitingSuback: true, stateSubscribed: false, stateStopped: false,
	}
	for s, w := range want {
		if s.requiresHandshakeWatchdog() != w {
			t.Errorf("state %d", s)
		}
	}
}

func testCredentials() MQTTCredentials {
	return MQTTCredentials{
		UserID: "user", AppName: "anker_power", ThingName: "thing", CertificateID: "certificate",
		Endpoint: "aiot-mqtt-eu.anker.com", CertificateDER: []byte{1}, PrivateKeyDER: []byte{2},
	}
}

func TestTopicBuilderRejectsWildcardsFromServerIdentity(t *testing.T) {
	c := testCredentials()
	if _, err := c.SubscriptionTopic(BoundDevice{DeviceSerial: "SERIAL/#", ProductCode: "A2345"}); !errors.Is(err, &CloudError{Kind: CloudErrInvalidMQTTTopicComponent}) {
		t.Errorf("subscription: %v", err)
	}
	if _, err := c.CommandTopic(BoundDevice{DeviceSerial: "SERIAL/+", ProductCode: "A2345"}); !errors.Is(err, &CloudError{Kind: CloudErrInvalidMQTTTopicComponent}) {
		t.Errorf("command: %v", err)
	}
}

func makeBuilder(t *testing.T, owner string) *CommandBuilder {
	t.Helper()
	b, err := NewCommandBuilder(testCredentials(),
		BoundDevice{DeviceSerial: "SERIAL123", ProductCode: "A2345", OwnerUserID: owner},
		"dt/anker_power/A2345/SERIAL123/#")
	if err != nil {
		t.Fatal(err)
	}
	return b
}

var mqttEpoch = time.Unix(1_700_000_000, 0)

func TestReadCommandEnvelopeAndNestedPayloadAreExactCompactJSON(t *testing.T) {
	data, err := makeBuilder(t, "owner").EnvelopeData(a2345.RequestStatusSnapshot(), mqttEpoch)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"head":{"client_id":"android-anker_power-user-certificate","cmd":17,"cmd_status":2,"device_pn":"A2345","device_sn":"SERIAL123","msg_seq":1,"seed":1,"sess_id":"1234-5678","sign_code":1,"timestamp":1700000000,"version":"1.0.0.1"},"payload":"{\"account_id\":\"owner\",\"data\":\"/wkUAAMADwIAoQEi/gUDAPFTZVE=\",\"device_sn\":\"SERIAL123\"}"}`
	if string(data) != want {
		t.Fatalf("envelope\n got %s\nwant %s", data, want)
	}
}

func TestReadCommandPacketUsesValidatedCommandTopicAndQoSZero(t *testing.T) {
	packet, err := makeBuilder(t, "").Packet(a2345.RealtimeTrigger(), mqttEpoch)
	if err != nil {
		t.Fatal(err)
	}
	p, rest, err := mqttDecodeNext(packet)
	if err != nil || p.kind != mqttPublish || p.topic != "cmd/anker_power/A2345/SERIAL123/req" || p.qos != 0 ||
		p.hasPacketID || len(rest) != 0 || !strings.Contains(string(p.payload), "/wkUAAMADwILoQEi/gUDAPFTZVo=") {
		t.Fatalf("packet: %+v %v", p, err)
	}
}

func TestWriteCommandsUseTheReadEnvelope(t *testing.T) {
	data, err := makeBuilder(t, "owner").EnvelopeData(a2345.SetPortOutput(a2345.GroupC1, true), mqttEpoch)
	if err != nil {
		t.Fatal(err)
	}
	var env struct {
		Head    map[string]any `json:"head"`
		Payload string         `json:"payload"`
	}
	if err := json.Unmarshal(data, &env); err != nil || env.Head["cmd"] != float64(17) || env.Head["cmd_status"] != float64(2) {
		t.Fatalf("envelope %s", data)
	}
	var payload map[string]string
	_ = json.Unmarshal([]byte(env.Payload), &payload)
	frame, _ := base64.StdEncoding.DecodeString(payload["data"])
	if hex.EncodeToString(frame) != "ff091c0003000f0207a10122a2020100a3020101fe050300f153655e" {
		t.Fatalf("frame %x", frame)
	}
}

func TestInvalidWriteNeverReachesThePacket(t *testing.T) {
	if _, err := makeBuilder(t, "").Packet(a2345.SetBrightness(7), time.Now()); err == nil {
		t.Fatal("brightness 7 encoded")
	}
}

func TestReadCommandBuilderCrossChecksExplicitDeviceAndSubscriptionTopic(t *testing.T) {
	for _, c := range []struct {
		device BoundDevice
		topic  string
	}{
		{BoundDevice{DeviceSerial: "OTHER", ProductCode: "A2345"}, "dt/anker_power/A2345/SERIAL123/#"},
		{BoundDevice{DeviceSerial: "SERIAL123", ProductCode: "A2687"}, "dt/anker_power/A2687/SERIAL123/#"},
	} {
		if _, err := NewCommandBuilder(testCredentials(), c.device, c.topic); !errors.Is(err, &MQTTError{Kind: MQTTErrInvalidConfiguration}) {
			t.Errorf("%+v: %v", c.device, err)
		}
	}
}

func TestInboundTopicMustBelongToTheExactExplicitDeviceRoot(t *testing.T) {
	b := makeBuilder(t, "")
	for topic, want := range map[string]bool{
		"dt/anker_power/A2345/SERIAL123":       true,
		"dt/anker_power/A2345/SERIAL123/data":  true,
		"dt/anker_power/A2345/OTHER/data":      false,
		"dt/anker_power/A2345/SERIAL1234/data": false,
	} {
		if b.AcceptsInboundTopic(topic) != want {
			t.Errorf("%s", topic)
		}
	}
}

func TestSuccessfulSubackTransitionPinsStateAndInitialReadOrder(t *testing.T) {
	reqs, err := acceptSuback(stateAwaitingSuback, 7, 7, []byte{0})
	if err != nil || len(reqs) != 3 || reqs[0].Kind() != a2345.CmdStatusSnapshot ||
		reqs[1].Kind() != a2345.CmdThemeStatus || reqs[2].Kind() != a2345.CmdRealtimeTrigger {
		t.Fatalf("requests %v %v", reqs, err)
	}
}

func TestSubackMustContainExactlyOneQoSZeroGrant(t *testing.T) {
	for _, c := range []struct {
		id    uint16
		codes []byte
		kind  MQTTErrorKind
	}{
		{8, []byte{0}, MQTTErrProtocolViolation},
		{7, nil, MQTTErrProtocolViolation},
		{7, []byte{0, 0}, MQTTErrProtocolViolation},
		{7, []byte{1}, MQTTErrProtocolViolation},
		{7, []byte{0x80}, MQTTErrSubscriptionRejected},
	} {
		_, err := acceptSuback(stateAwaitingSuback, 7, c.id, c.codes)
		var me *MQTTError
		if !errors.As(err, &me) || me.Kind != c.kind {
			t.Errorf("%v: %v", c.codes, err)
		}
	}
}

// fakeBroker drives the far end of a net.Pipe as an MQTT broker.
type fakeBroker struct {
	t    *testing.T
	conn net.Conn
	buf  []byte
}

func (b *fakeBroker) next() *mqttInbound {
	b.t.Helper()
	chunk := make([]byte, 4096)
	for {
		if p, rest, err := decodeClientPacket(b.buf); err != nil {
			b.t.Fatalf("broker decode: %v", err)
		} else if p != nil {
			b.buf = rest
			return p
		}
		_ = b.conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		n, err := b.conn.Read(chunk)
		if err != nil {
			b.t.Fatalf("broker read: %v", err)
		}
		b.buf = append(b.buf, chunk[:n]...)
	}
}

// decodeClientPacket decodes client-to-broker packets the test needs.
func decodeClientPacket(buf []byte) (*mqttInbound, []byte, error) {
	if len(buf) < 2 {
		return nil, buf, nil
	}
	remaining, n, complete, err := mqttRemainingLength(buf, 1)
	if err != nil || !complete || 1+n+remaining > len(buf) {
		return nil, buf, err
	}
	body := buf[1+n : 1+n+remaining]
	rest := buf[1+n+remaining:]
	p := &mqttInbound{otherType: buf[0] >> 4, body: body}
	if p.otherType == 3 {
		pub, err := mqttDecodePublish(buf[0], body)
		if err != nil {
			return nil, rest, err
		}
		pub.otherType = 3
		return pub, rest, nil
	}
	return p, rest, nil
}

func (b *fakeBroker) send(data []byte) {
	b.t.Helper()
	_ = b.conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
	if _, err := b.conn.Write(data); err != nil {
		b.t.Fatalf("broker write: %v", err)
	}
}

func nextEvent(t *testing.T, s *Subscriber) MQTTEvent {
	t.Helper()
	select {
	case ev, ok := <-s.Events():
		if !ok {
			t.Fatal("event stream closed")
		}
		return ev
	case <-time.After(3 * time.Second):
		t.Fatal("no event")
	}
	return MQTTEvent{}
}

func startPipeSubscriber(t *testing.T, cfg MQTTConfig) (*Subscriber, *fakeBroker) {
	t.Helper()
	client, server := net.Pipe()
	cfg.Credentials = testCredentials()
	cfg.Device = BoundDevice{DeviceSerial: "SERIAL123", ProductCode: "A2345", OwnerUserID: "owner"}
	cfg.Topic = "dt/anker_power/A2345/SERIAL123/#"
	cfg.ClientID = "thing_00042"
	cfg.Dial = func(context.Context) (net.Conn, error) { return client, nil }
	s := NewSubscriber(cfg)
	s.Start()
	t.Cleanup(func() { s.Stop(); server.Close() })
	return s, &fakeBroker{t: t, conn: server}
}

func TestSubscriberRunsTheWholeSessionAgainstAFakeBroker(t *testing.T) {
	s, broker := startPipeSubscriber(t, MQTTConfig{})

	connect := broker.next()
	if connect.otherType != 1 || !bytes.Contains(connect.body, []byte("thing_00042")) {
		t.Fatalf("CONNECT %+v", connect)
	}
	broker.send([]byte{0x20, 0x02, 0x00, 0x00})
	if ev := nextEvent(t, s); ev.Kind != MQTTConnected {
		t.Fatalf("event %+v", ev)
	}
	sub := broker.next()
	if sub.otherType != 8 || !bytes.Contains(sub.body, []byte("dt/anker_power/A2345/SERIAL123/#")) {
		t.Fatalf("SUBSCRIBE %+v", sub)
	}
	broker.send([]byte{0x90, 0x03, 0x00, 0x01, 0x00})

	// The three initial reads go out in order.
	for _, wantType := range []string{"0200", "0202", "020b"} {
		p := broker.next()
		if p.otherType != 3 || p.topic != "cmd/anker_power/A2345/SERIAL123/req" {
			t.Fatalf("PUBLISH %+v", p)
		}
		var env struct{ Payload string }
		_ = json.Unmarshal(p.payload, &env)
		var inner map[string]string
		_ = json.Unmarshal([]byte(env.Payload), &inner)
		frame, _ := base64.StdEncoding.DecodeString(inner["data"])
		if got := hex.EncodeToString(frame[7:9]); got != wantType || inner["account_id"] != "owner" {
			t.Fatalf("initial request %s, want %s", got, wantType)
		}
	}
	if ev := nextEvent(t, s); ev.Kind != MQTTSubscribed {
		t.Fatalf("event %+v", ev)
	}

	// An inbound QoS-1 telemetry message is delivered and acknowledged.
	topic := "dt/anker_power/A2345/SERIAL123/data"
	body := append([]byte{0, byte(len(topic))}, topic...)
	body = append(body, 0x00, 0x05, 'h', 'i')
	broker.send(append([]byte{0x32, byte(len(body))}, body...))
	if ev := nextEvent(t, s); ev.Kind != MQTTMessage || ev.Topic != topic || string(ev.Payload) != "hi" {
		t.Fatalf("event %+v", ev)
	}
	if ack := broker.next(); ack.otherType != 4 || !bytes.Equal(ack.body, []byte{0x00, 0x05}) {
		t.Fatalf("PUBACK %+v", ack)
	}

	// A write goes out on the command topic.
	done := make(chan error, 1)
	go func() { done <- s.Send(a2345.SetPortOutput(a2345.GroupC2, false)) }()
	if p := broker.next(); p.otherType != 3 || !strings.Contains(string(p.payload), `"cmd":17`) {
		t.Fatalf("write %+v", p)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if err := s.Send(a2345.SetBrightness(7)); err == nil {
		t.Fatal("invalid command sent")
	}

	// Stop sends DISCONNECT and ends the stream.
	go s.Stop()
	if p := broker.next(); p.otherType != 14 {
		t.Fatalf("DISCONNECT %+v", p)
	}
	if ev := nextEvent(t, s); ev.Kind != MQTTDisconnected {
		t.Fatalf("event %+v", ev)
	}
	if _, ok := <-s.Events(); ok {
		t.Fatal("stream not closed")
	}
	if err := s.Send(a2345.RealtimeTrigger()); !errors.Is(err, ErrNotSubscribed) {
		t.Fatalf("send after stop: %v", err)
	}
}

func TestSubscriberFailsOnAForeignTopic(t *testing.T) {
	s, broker := startPipeSubscriber(t, MQTTConfig{})
	broker.next()
	broker.send([]byte{0x20, 0x02, 0x00, 0x00})
	nextEvent(t, s)
	broker.next()
	broker.send([]byte{0x90, 0x03, 0x00, 0x01, 0x00})
	for range 3 {
		broker.next()
	}
	nextEvent(t, s)
	topic := "dt/anker_power/A2345/SERIAL1234/data"
	body := append([]byte{0, byte(len(topic))}, topic...)
	broker.send(append([]byte{0x30, byte(len(body))}, body...))
	if ev := nextEvent(t, s); ev.Kind != MQTTFailed || ev.Err.Kind != MQTTErrProtocolViolation {
		t.Fatalf("event %+v", ev)
	}
}

func TestSubscriberReportsRejectedConnectionAndHandshakeTimeout(t *testing.T) {
	s, broker := startPipeSubscriber(t, MQTTConfig{})
	broker.next()
	broker.send([]byte{0x20, 0x02, 0x00, 0x05})
	if ev := nextEvent(t, s); ev.Kind != MQTTFailed || ev.Err.Kind != MQTTErrConnectionRejected || ev.Err.Code != 5 {
		t.Fatalf("event %+v", ev)
	}

	s, broker = startPipeSubscriber(t, MQTTConfig{HandshakeTimeout: 50 * time.Millisecond})
	broker.next() // CONNECT, never answered
	if ev := nextEvent(t, s); ev.Kind != MQTTFailed || ev.Err.Kind != MQTTErrHandshakeTimedOut {
		t.Fatalf("event %+v", ev)
	}
	if got := TextOf(&MQTTError{Kind: MQTTErrConnectionRejected, Code: 5}).String(); got != "Anker MQTT 拒绝了连接（5）。" {
		t.Fatalf("text %q", got)
	}
}

func TestSubscriberRejectsAnInvalidConfigurationBeforeDialing(t *testing.T) {
	s := NewSubscriber(MQTTConfig{Credentials: testCredentials(), Device: BoundDevice{DeviceSerial: "S", ProductCode: "A2687"},
		Topic: "dt/anker_power/A2687/S/#", ClientID: "c"})
	s.Start()
	if ev := nextEvent(t, s); ev.Kind != MQTTFailed || ev.Err.Kind != MQTTErrInvalidConfiguration {
		t.Fatalf("event %+v", ev)
	}
	// Garbage DER cannot become a TLS identity.
	s = NewSubscriber(MQTTConfig{Credentials: testCredentials(), Device: BoundDevice{DeviceSerial: "S", ProductCode: "A2345"},
		Topic: "dt/anker_power/A2345/S/#", ClientID: "c"})
	s.Start()
	if ev := nextEvent(t, s); ev.Kind != MQTTFailed || ev.Err.Kind != MQTTErrInvalidClientIdentity {
		t.Fatalf("event %+v", ev)
	}
	// A failed Start must leave the subscriber usable: no lock held.
	s.Stop()
	if err := s.Send(a2345.RealtimeTrigger()); !errors.Is(err, ErrNotSubscribed) {
		t.Fatalf("send after failed start: %v", err)
	}
}
