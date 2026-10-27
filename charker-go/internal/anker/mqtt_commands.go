package anker

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"strings"
	"time"

	"charker/internal/a2345"
)

// subscriberState is the MQTT session ladder.
type subscriberState int

const (
	stateIdle subscriberState = iota
	stateConnecting
	stateAwaitingConnack
	stateAwaitingSuback
	stateSubscribed
	stateStopped
)

func (s subscriberState) requiresHandshakeWatchdog() bool {
	return s == stateConnecting || s == stateAwaitingConnack || s == stateAwaitingSuback
}

// acceptSuback is the pure SUBACK transition. MQTT 3.1.1 permits a broker to
// grant QoS 1, but Charker requested exactly one QoS 0 subscription and fails
// closed unless the acknowledgement is exactly [0]. On success it returns the
// initial requests: the snapshot, then the theme request (it fills in what
// 0x0A00 leaves out: the theme URL and the custom-picture time display), then
// the realtime trigger.
func acceptSuback(state subscriberState, expectedID, packetID uint16, returnCodes []byte) ([]a2345.Command, error) {
	if state != stateAwaitingSuback || packetID != expectedID || len(returnCodes) != 1 {
		return nil, &MQTTError{Kind: MQTTErrProtocolViolation}
	}
	switch returnCodes[0] {
	case 0x00:
		return []a2345.Command{a2345.RequestStatusSnapshot(), a2345.ThemeStatus(), a2345.RealtimeTrigger()}, nil
	case 0x80:
		return nil, &MQTTError{Kind: MQTTErrSubscriptionRejected, Code: 0x80}
	}
	return nil, &MQTTError{Kind: MQTTErrProtocolViolation}
}

// mqttSessionID is the envelope's sess_id.
const mqttSessionID = "1234-5678"

// CommandBuilder constructs the exact Anker JSON envelope and QoS-0 PUBLISH
// for one a2345.Command. The official app wraps reads and writes in the same
// envelope (cmd 17). It stores no certificate material and cannot accept raw
// command bytes.
type CommandBuilder struct {
	subscriptionTopic string
	commandTopic      string
	clientIdentifier  string
	accountID         string
	productCode       string
	deviceSerial      string
}

// NewCommandBuilder cross-checks the device, the credentials and the topic
// the caller subscribed to.
func NewCommandBuilder(credentials MQTTCredentials, device BoundDevice, subscriptionTopic string) (*CommandBuilder, error) {
	invalid := &MQTTError{Kind: MQTTErrInvalidConfiguration}
	if device.ProductCode != "A2345" || credentials.UserID == "" || credentials.CertificateID == "" ||
		len(credentials.UserID) > 1024 || len(credentials.CertificateID) > 1024 {
		return nil, invalid
	}
	expected, err := credentials.SubscriptionTopic(device)
	if err != nil {
		return nil, invalid
	}
	command, err := credentials.CommandTopic(device)
	if err != nil {
		return nil, invalid
	}
	if subscriptionTopic != expected {
		return nil, invalid
	}
	owner := device.OwnerUserID
	if owner == "" {
		owner = credentials.UserID
	}
	if len(owner) > 1024 {
		return nil, invalid
	}
	return &CommandBuilder{
		subscriptionTopic: expected,
		commandTopic:      command,
		clientIdentifier:  strings.Join([]string{"android", credentials.AppName, credentials.UserID, credentials.CertificateID}, "-"),
		accountID:         owner,
		productCode:       device.ProductCode,
		deviceSerial:      device.DeviceSerial,
	}, nil
}

// SubscriptionTopic is the validated device wildcard topic.
func (b *CommandBuilder) SubscriptionTopic() string { return b.subscriptionTopic }

// CommandTopic is the validated request topic.
func (b *CommandBuilder) CommandTopic() string { return b.commandTopic }

// AcceptsInboundTopic checks the exact device root. Broker-side filtering is
// not treated as an identity check; the delimiter is part of the prefix so a
// serial such as SERIAL1234 cannot collide with SERIAL123.
func (b *CommandBuilder) AcceptsInboundTopic(topic string) bool {
	const wildcard = "/#"
	if !strings.HasSuffix(b.subscriptionTopic, wildcard) {
		return false
	}
	root := strings.TrimSuffix(b.subscriptionTopic, wildcard)
	return topic == root || strings.HasPrefix(topic, root+"/")
}

// Field order is alphabetical by JSON key: the envelope is compact JSON with
// sorted keys, byte for byte what the Swift encoder emits.
type envelopeHead struct {
	ClientID      string `json:"client_id"`
	Command       int    `json:"cmd"`
	CommandStatus int    `json:"cmd_status"`
	DevicePN      string `json:"device_pn"`
	DeviceSN      string `json:"device_sn"`
	MessageSeq    int    `json:"msg_seq"`
	Seed          int    `json:"seed"`
	SessionID     string `json:"sess_id"`
	SignCode      int    `json:"sign_code"`
	Timestamp     int64  `json:"timestamp"`
	Version       string `json:"version"`
}

type envelope struct {
	Head    envelopeHead `json:"head"`
	Payload string       `json:"payload"`
}

type envelopePayload struct {
	AccountID string `json:"account_id"`
	Data      string `json:"data"`
	DeviceSN  string `json:"device_sn"`
}

func compactJSON(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// EnvelopeData is the JSON envelope carrying cmd encoded at `at`.
func (b *CommandBuilder) EnvelopeData(cmd a2345.Command, at time.Time) ([]byte, error) {
	timestamp := at.Unix()
	if timestamp < 0 || timestamp > 0xFFFF_FFFF {
		return nil, &MQTTError{Kind: MQTTErrInvalidConfiguration}
	}
	frame, err := cmd.Encode(at)
	if err != nil {
		return nil, err
	}
	payload, err := compactJSON(envelopePayload{
		AccountID: b.accountID,
		Data:      base64.StdEncoding.EncodeToString(frame),
		DeviceSN:  b.deviceSerial,
	})
	if err != nil {
		return nil, &MQTTError{Kind: MQTTErrProtocolViolation}
	}
	return compactJSON(envelope{
		Head: envelopeHead{
			ClientID:      b.clientIdentifier,
			Command:       17,
			CommandStatus: 2,
			DevicePN:      b.productCode,
			DeviceSN:      b.deviceSerial,
			MessageSeq:    1,
			Seed:          1,
			SessionID:     mqttSessionID,
			SignCode:      1,
			Timestamp:     timestamp,
			Version:       "1.0.0.1",
		},
		Payload: string(payload),
	})
}

// Packet is the QoS-0 PUBLISH of cmd to the command topic.
func (b *CommandBuilder) Packet(cmd a2345.Command, at time.Time) ([]byte, error) {
	data, err := b.EnvelopeData(cmd, at)
	if err != nil {
		return nil, err
	}
	return mqttPublishQoSZero(b.commandTopic, data)
}
