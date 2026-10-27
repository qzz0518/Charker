package anker

import (
	"errors"
	"strings"
	"unicode/utf8"
)

// MQTT 3.1.1 framing kept independent from the socket so every byte of
// CONNECT/SUBSCRIBE/PUBLISH/PUBACK and every fragmented inbound packet can be
// pinned by tests. Outbound PUBLISH is deliberately fixed to QoS 0; the only
// caller is the closed a2345.Command builder.

// Codec errors.
var (
	errMQTTMalformed     = errors.New("mqtt: malformed packet")
	errMQTTStringTooLong = errors.New("mqtt: string too long")
)

// UnsupportedQoSError is an inbound PUBLISH with QoS 2 (or 3).
type UnsupportedQoSError struct{ QoS byte }

func (e *UnsupportedQoSError) Error() string { return "mqtt: unsupported QoS" }

// MQTTMaximumPacketBytes is the cloud payload limit (256 KiB) plus 4 KiB for
// the topic and framing. A larger declared length is rejected before waiting
// for, or allocating, the body.
const MQTTMaximumPacketBytes = PayloadMaximumInputBytes + 4096

type mqttPacketType int

const (
	mqttConnack mqttPacketType = iota + 1
	mqttSuback
	mqttPublish
	mqttPingResponse
	mqttDisconnect
	mqttOther
)

// mqttInbound is one decoded inbound packet.
type mqttInbound struct {
	kind           mqttPacketType
	sessionPresent bool
	returnCode     byte
	packetID       uint16
	hasPacketID    bool
	returnCodes    []byte
	topic          string
	payload        []byte
	qos            byte
	otherType      byte
	body           []byte
}

func mqttConnect(clientID string, keepAlive uint16) ([]byte, error) {
	body := []byte{0x00, 0x04, 'M', 'Q', 'T', 'T',
		0x04, // MQTT 3.1.1
		0x02, // clean session; no username/password/will
		byte(keepAlive >> 8), byte(keepAlive)}
	id, err := mqttString(clientID)
	if err != nil {
		return nil, err
	}
	return mqttPacket(0x10, append(body, id...)), nil
}

func mqttSubscribe(topic string, packetID uint16, qos byte) ([]byte, error) {
	if packetID == 0 || qos > 1 {
		return nil, errMQTTMalformed
	}
	t, err := mqttString(topic)
	if err != nil {
		return nil, err
	}
	body := append([]byte{byte(packetID >> 8), byte(packetID)}, t...)
	return mqttPacket(0x82, append(body, qos)), nil
}

// mqttPublishQoSZero encodes the sole outbound PUBLISH shape: no QoS, retain
// or duplicate switches by design.
func mqttPublishQoSZero(topic string, payload []byte) ([]byte, error) {
	if topic == "" || strings.ContainsAny(topic, "+#") || len(payload) > MQTTMaximumPacketBytes {
		return nil, errMQTTMalformed
	}
	body, err := mqttString(topic)
	if err != nil {
		return nil, err
	}
	body = append(body, payload...)
	if len(body) > MQTTMaximumPacketBytes {
		return nil, errMQTTMalformed
	}
	return mqttPacket(0x30, body), nil
}

func mqttPingRequest() []byte { return []byte{0xC0, 0x00} }

func mqttPubAck(packetID uint16) ([]byte, error) {
	if packetID == 0 {
		return nil, errMQTTMalformed
	}
	return []byte{0x40, 0x02, byte(packetID >> 8), byte(packetID)}, nil
}

func mqttDisconnectPacket() []byte { return []byte{0xE0, 0x00} }

// mqttDecodeNext takes one complete packet off the front of buf. It returns
// (nil, buf, nil) while the packet is incomplete, consuming nothing.
func mqttDecodeNext(buf []byte) (*mqttInbound, []byte, error) {
	if len(buf) < 2 {
		return nil, buf, nil
	}
	remaining, encodedBytes, complete, err := mqttRemainingLength(buf, 1)
	if err != nil {
		return nil, buf, err
	}
	if !complete {
		return nil, buf, nil
	}
	header := 1 + encodedBytes
	if remaining > MQTTMaximumPacketBytes {
		return nil, buf, errMQTTMalformed
	}
	total := header + remaining
	if total > len(buf) {
		return nil, buf, nil
	}
	first := buf[0]
	typ, flags := first>>4, first&0x0F
	body := append([]byte(nil), buf[header:total]...)
	rest := buf[total:]

	switch typ {
	case 2:
		if flags != 0 || len(body) != 2 {
			return nil, rest, errMQTTMalformed
		}
		return &mqttInbound{kind: mqttConnack, sessionPresent: body[0]&0x01 == 1, returnCode: body[1]}, rest, nil
	case 3:
		p, err := mqttDecodePublish(first, body)
		return p, rest, err
	case 9:
		if flags != 0 || len(body) < 3 {
			return nil, rest, errMQTTMalformed
		}
		id := uint16(body[0])<<8 | uint16(body[1])
		if id == 0 {
			return nil, rest, errMQTTMalformed
		}
		return &mqttInbound{kind: mqttSuback, packetID: id, hasPacketID: true, returnCodes: body[2:]}, rest, nil
	case 13:
		if flags != 0 || len(body) != 0 {
			return nil, rest, errMQTTMalformed
		}
		return &mqttInbound{kind: mqttPingResponse}, rest, nil
	case 14:
		if flags != 0 || len(body) != 0 {
			return nil, rest, errMQTTMalformed
		}
		return &mqttInbound{kind: mqttDisconnect}, rest, nil
	}
	return &mqttInbound{kind: mqttOther, otherType: typ, body: body}, rest, nil
}

func mqttDecodePublish(first byte, body []byte) (*mqttInbound, error) {
	qos := (first >> 1) & 0x03
	if qos > 1 {
		return nil, &UnsupportedQoSError{QoS: qos}
	}
	if len(body) < 2 {
		return nil, errMQTTMalformed
	}
	topicLength := int(body[0])<<8 | int(body[1])
	if topicLength == 0 || len(body) < 2+topicLength {
		return nil, errMQTTMalformed
	}
	topicBytes := body[2 : 2+topicLength]
	if !utf8.Valid(topicBytes) || strings.ContainsRune(string(topicBytes), 0) {
		return nil, errMQTTMalformed
	}
	p := &mqttInbound{kind: mqttPublish, topic: string(topicBytes), qos: qos}
	offset := 2 + topicLength
	if qos == 1 {
		if len(body) < offset+2 {
			return nil, errMQTTMalformed
		}
		id := uint16(body[offset])<<8 | uint16(body[offset+1])
		if id == 0 {
			return nil, errMQTTMalformed
		}
		p.packetID, p.hasPacketID = id, true
		offset += 2
	}
	p.payload = body[offset:]
	return p, nil
}

func mqttPacket(typeAndFlags byte, body []byte) []byte {
	out := []byte{typeAndFlags}
	out = append(out, mqttEncodeRemainingLength(len(body))...)
	return append(out, body...)
}

func mqttString(value string) ([]byte, error) {
	if strings.ContainsRune(value, 0) || len(value) > 0xFFFF {
		return nil, errMQTTStringTooLong
	}
	return append([]byte{byte(len(value) >> 8), byte(len(value))}, value...), nil
}

func mqttEncodeRemainingLength(length int) []byte {
	var out []byte
	for {
		b := byte(length % 128)
		length /= 128
		if length > 0 {
			b |= 0x80
		}
		out = append(out, b)
		if length == 0 {
			return out
		}
	}
}

func mqttRemainingLength(buf []byte, start int) (value, encodedBytes int, complete bool, err error) {
	multiplier := 1
	for offset := 0; offset < 4; offset++ {
		i := start + offset
		if i >= len(buf) {
			return 0, 0, false, nil
		}
		b := buf[i]
		value += int(b&0x7F) * multiplier
		if b&0x80 == 0 {
			return value, offset + 1, true, nil
		}
		multiplier *= 128
	}
	return 0, 0, false, errMQTTMalformed
}
