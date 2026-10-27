package a2345

import (
	"math"
	"reflect"
	"testing"
)

func near(a, b float64) bool { return math.Abs(a-b) < 0.0001 }

func mustRealtime(t *testing.T, f Frame) RealtimeTelemetry {
	t.Helper()
	tel, err := DecodeRealtime(f)
	if err != nil {
		t.Fatalf("DecodeRealtime: %v", err)
	}
	return tel
}

func fieldIndex(t *testing.T, f Frame, id byte) int {
	t.Helper()
	for i, field := range f.Fields {
		if field.ID == id {
			return i
		}
	}
	t.Fatalf("field 0x%02X missing", id)
	return -1
}

func countUnknown(fields []TLV, id byte) int {
	n := 0
	for _, f := range fields {
		if f.ID == id {
			n++
		}
	}
	return n
}

func TestDecodesSixPortRealtimeTelemetryAndScaling(t *testing.T) {
	tel := mustRealtime(t, mustDecode(t, fxRealtimeOldFirmware))
	if tel.ResponseMarker == nil || *tel.ResponseMarker != 0x34 {
		t.Errorf("marker = %v", tel.ResponseMarker)
	}
	if len(tel.Ports) != 6 {
		t.Fatalf("ports = %d", len(tel.Ports))
	}
	c1 := tel.Ports[PortC1]
	if c1.Status != 1 || c1.Millivolts != 14_984 || c1.Milliamps != 1_632 || c1.Centiwatts != 2_384 {
		t.Errorf("c1 = %+v", c1)
	}
	if !near(c1.Voltage(), 14.984) || !near(c1.Current(), 1.632) || !near(c1.Power(), 23.84) {
		t.Errorf("c1 scaled = %v %v %v", c1.Voltage(), c1.Current(), c1.Power())
	}
	if !near(tel.Ports[PortC3].Voltage(), 5.0) {
		t.Errorf("c3 voltage = %v", tel.Ports[PortC3].Voltage())
	}
	if tel.Ports[PortA1].Power() != 0 || tel.Ports[PortA2].Power() != 0 {
		t.Error("USB-A not idle")
	}
	if tel.Timestamp == nil || *tel.Timestamp != 0x12345678 {
		t.Errorf("timestamp = %v", tel.Timestamp)
	}
}

func TestOldFirmwareWithoutA9RemainsValid(t *testing.T) {
	tel := mustRealtime(t, mustDecode(t, fxRealtimeOldFirmware))
	if tel.ProvisionalSlots != nil {
		t.Error("provisional slots present")
	}
	if len(tel.A8Slots) != 4 {
		t.Errorf("a8 = %d", len(tel.A8Slots))
	}
}

func TestPreservesA8RawWordsAndSentinelsWithoutNamingSemantics(t *testing.T) {
	slots := mustRealtime(t, mustDecode(t, fxRealtimeOldFirmware)).A8Slots
	if slots[0].Port != PortC1 || slots[0].Word0 != 0x05AC || slots[0].Word1 != 0x12A8 ||
		!reflect.DeepEqual(slots[0].Raw, []byte{0xAC, 0x05, 0xA8, 0x12}) {
		t.Errorf("slot0 = %+v", slots[0])
	}
	if !slots[1].IsUnidentified() || !slots[2].IsUnidentified() || !slots[3].IsAllOnesSentinel() {
		t.Error("sentinels")
	}
	if !reflect.DeepEqual(slots[3].Raw, []byte{0xFF, 0xFF, 0xFF, 0xFF}) || slots[3].Word0 != 0xFFFF || slots[3].Word1 != 0xFFFF {
		t.Errorf("slot3 = %+v", slots[3])
	}
}

func TestNewFirmwarePreservesProvisionalA9RawWords(t *testing.T) {
	slots := mustRealtime(t, mustDecode(t, fxRealtimeNewFirmware)).ProvisionalSlots
	if len(slots) != 4 {
		t.Fatalf("slots = %d", len(slots))
	}
	if slots[0].Port != PortC1 || slots[0].Word0 != 1 || slots[0].Word1 != 31 ||
		!reflect.DeepEqual(slots[0].Raw, []byte{0x01, 0x00, 0x1F, 0x00}) {
		t.Errorf("slot0 = %+v", slots[0])
	}
	if !slots[1].IsAllOnesSentinel() || !slots[2].IsUnidentified() || !slots[3].IsAllOnesSentinel() {
		t.Error("sentinels")
	}
}

func TestRejectsShortPortStruct(t *testing.T) {
	f := mustDecode(t, fxRealtimeOldFirmware)
	i := fieldIndex(t, f, FieldA2)
	f.Fields[i].Raw = f.Fields[i].Raw[:len(f.Fields[i].Raw)-1]
	_, err := DecodeRealtime(f)
	e := messageErr(t, err)
	if e.Kind != MsgErrInvalidFieldLength || e.ID != FieldA2 || e.Expected != 8 || e.Actual != 7 {
		t.Errorf("error = %+v", e)
	}
}

func TestChinaFirmwareLongerPortFieldsKeepLegacyReadings(t *testing.T) {
	legacy := mustRealtime(t, mustDecode(t, fxRealtimeOldFirmware))
	tel := mustRealtime(t, mustDecode(t, fxRealtimeChinaFirmware))
	for _, port := range Ports {
		got, want := tel.Ports[port], legacy.Ports[port]
		if got.Status != want.Status || got.Millivolts != want.Millivolts || got.Milliamps != want.Milliamps || got.Centiwatts != want.Centiwatts {
			t.Errorf("%s: %+v vs %+v", port.Label(), got, want)
		}
		if want.Cable != nil {
			t.Errorf("%s: legacy cable present", port.Label())
		}
	}
	c1 := tel.Ports[PortC1]
	if c1.Cable == nil || *c1.Cable != 1 || *c1.FastCharge != 1 || c1.DeviceBrand == nil || *c1.DeviceBrand != 1 {
		t.Errorf("c1 tail = %+v", c1)
	}
	if c3 := tel.Ports[PortC3]; c3.Cable == nil || *c3.Cable != 0 {
		t.Errorf("c3 cable = %v", c3.Cable)
	}
	if !reflect.DeepEqual(tel.A8Slots, legacy.A8Slots) || *tel.Timestamp != *legacy.Timestamp {
		t.Error("metadata differs")
	}
	if len(tel.UnknownFields) != 0 {
		t.Errorf("unknown = %v", tel.UnknownFields)
	}
}

func TestRejectsWrongPortValueType(t *testing.T) {
	f := mustDecode(t, fxRealtimeOldFirmware)
	f.Fields[fieldIndex(t, f, FieldA2)].Raw[0] = 0x03
	_, err := DecodeRealtime(f)
	e := messageErr(t, err)
	if e.Kind != MsgErrUnexpectedFieldType || e.ID != FieldA2 || e.ExpectedType != 0x04 || e.ActualType == nil || *e.ActualType != 0x03 {
		t.Errorf("error = %+v", e)
	}
}

func TestUnknownPortStatusIsNotExpandedIntoActive(t *testing.T) {
	r := PortReading{Status: 2, Millivolts: 5_000, Milliamps: 1_000, Centiwatts: 500}
	if r.IsActive() || r.Status != 2 {
		t.Error("status 2 treated as active")
	}
}

func TestRejectsMissingCoreFieldButKeepsDuplicateMetadataAsUnknown(t *testing.T) {
	missing := mustDecode(t, fxRealtimeOldFirmware)
	var kept []TLV
	for _, f := range missing.Fields {
		if f.ID != FieldA7 {
			kept = append(kept, f)
		}
	}
	missing.Fields = kept
	_, err := DecodeRealtime(missing)
	if e := messageErr(t, err); e.Kind != MsgErrMissingField || e.ID != FieldA7 {
		t.Errorf("error = %+v", e)
	}

	dup := mustDecode(t, fxRealtimeOldFirmware)
	dup.Fields = append(dup.Fields, dup.Fields[fieldIndex(t, dup, FieldA8)])
	tel := mustRealtime(t, dup)
	if len(tel.Ports) != 6 || len(tel.A8Slots) != 0 || countUnknown(tel.UnknownFields, FieldA8) != 2 {
		t.Errorf("ports %d a8 %d unknown a8 %d", len(tel.Ports), len(tel.A8Slots), countUnknown(tel.UnknownFields, FieldA8))
	}
}

func TestMalformedOptionalA9DoesNotDiscardCoreTelemetry(t *testing.T) {
	for _, mutate := range []func(*TLV){
		func(f *TLV) { f.Raw = f.Raw[:len(f.Raw)-1] },
		func(f *TLV) { f.Raw[0] = ValueVariable },
	} {
		f := mustDecode(t, fxRealtimeNewFirmware)
		mutate(&f.Fields[fieldIndex(t, f, FieldA9)])
		tel := mustRealtime(t, f)
		if len(tel.Ports) != 6 || tel.ProvisionalSlots != nil || countUnknown(tel.UnknownFields, FieldA9) != 1 {
			t.Errorf("ports %d provisional %v unknown %d", len(tel.Ports), tel.ProvisionalSlots, countUnknown(tel.UnknownFields, FieldA9))
		}
	}
}

func TestDecodesVersionAndComponentFields(t *testing.T) {
	v, err := DecodeVersionInfo(mustDecode(t, fxVersionInfo))
	if err != nil {
		t.Fatal(err)
	}
	if v.HardwareVersion != "1.0.0" || v.SoftwareVersion != "2.1.1.6" || *v.ProductCode != "A2345" ||
		*v.MCUComponent != "A2345_mcu" || *v.ESP32Component != "A2345_esp32" {
		t.Errorf("version = %+v", v)
	}
}

func syntheticPortFields(tail []byte) []TLV {
	var out []TLV
	for offset, port := range Ports {
		base := uint16(1_000 + offset*100)
		status := byte(1)
		if port == PortA2 {
			status = 0
		}
		raw := []byte{ValueBinary, status,
			byte(base), byte(base >> 8),
			byte(base + 1), byte((base + 1) >> 8),
			byte(base + 2), byte((base + 2) >> 8)}
		out = append(out, TLV{ID: FieldA4 + byte(offset), Raw: append(raw, tail...)})
	}
	return out
}

func TestDecodesElectricalSubsetOfSyntheticStatusSnapshot(t *testing.T) {
	preserved := TLV{ID: 0xB3, Raw: []byte{70}}
	f := Frame{
		Pattern:     FramePattern{Version: 3, Speaker: 1, Group: 15},
		MessageType: MsgStatusSnapshot,
		Fields:      append(syntheticPortFields(nil), preserved),
	}
	snap, err := DecodeStatusSnapshot(f)
	if err != nil {
		t.Fatal(err)
	}
	if len(snap.Ports) != 6 || snap.Ports[PortC1].Millivolts != 1_000 || snap.Ports[PortA2].Centiwatts != 1_502 || snap.Ports[PortA2].IsActive() {
		t.Errorf("ports = %+v", snap.Ports)
	}
	if !reflect.DeepEqual(snap.UnknownFields, []TLV{preserved}) {
		t.Errorf("unknown = %+v", snap.UnknownFields)
	}
	msg, err := DecodeMessage(f)
	if err != nil || msg.Kind != MessageStatusSnapshot || !reflect.DeepEqual(*msg.StatusSnapshot, snap) {
		t.Errorf("DecodeMessage = %+v, %v", msg, err)
	}
}

func TestDecodesChinaFirmwareStatusSnapshotPortFields(t *testing.T) {
	f := Frame{
		Pattern:     FramePattern{Version: 3, Speaker: 1, Group: 15},
		MessageType: MsgStatusSnapshot,
		Fields:      syntheticPortFields([]byte{2, 1, 2}),
	}
	snap, err := DecodeStatusSnapshot(f)
	if err != nil {
		t.Fatal(err)
	}
	c1 := snap.Ports[PortC1]
	if len(snap.Ports) != 6 || c1.Millivolts != 1_000 || c1.Milliamps != 1_001 || snap.Ports[PortA2].Centiwatts != 1_502 {
		t.Errorf("ports = %+v", snap.Ports)
	}
	if *c1.Cable != 2 || *c1.FastCharge != 1 || *c1.DeviceBrand != 2 {
		t.Errorf("c1 tail = %v %v %v", *c1.Cable, *c1.FastCharge, *c1.DeviceBrand)
	}
	if len(snap.UnknownFields) != 0 {
		t.Errorf("unknown = %+v", snap.UnknownFields)
	}
}

func TestPortTailFollowsOfficialLengthGates(t *testing.T) {
	f := mustDecode(t, fxRealtimeOldFirmware)
	i := fieldIndex(t, f, FieldA2)
	f.Fields[i].Raw = append(f.Fields[i].Raw, 1)
	if r := mustRealtime(t, f).Ports[PortC1]; r.Cable != nil {
		t.Error("cable read from an 8-byte payload")
	}
	f.Fields[i].Raw = append(f.Fields[i].Raw, 2)
	r := mustRealtime(t, f).Ports[PortC1]
	if r.Cable == nil || *r.Cable != 1 || *r.FastCharge != 2 || r.DeviceBrand != nil {
		t.Errorf("tail = %+v", r)
	}
}

func TestRejectsInvalidUTF8InVersionField(t *testing.T) {
	f := mustDecode(t, fxVersionInfo)
	f.Fields[fieldIndex(t, f, FieldA1)].Raw = []byte{ValueString, 0xFF}
	_, err := DecodeVersionInfo(f)
	if e := messageErr(t, err); e.Kind != MsgErrInvalidUTF8 || e.ID != FieldA1 {
		t.Errorf("error = %+v", e)
	}
}

func TestDecodesFourteenByteAcknowledgementAsOpaqueMarker(t *testing.T) {
	f := mustDecode(t, fxRealtimeAcknowledgement)
	if f.EncodedLength != 14 {
		t.Fatalf("length = %d", f.EncodedLength)
	}
	ack, err := DecodeAcknowledgement(f)
	if err != nil {
		t.Fatal(err)
	}
	if ack.MessageType != MsgRealtimeAck || ack.Increment == nil || *ack.Increment != 0 || ack.Marker != 0x34 {
		t.Errorf("ack = %+v", ack)
	}
}

func TestUnknownMessageTypeIsPreserved(t *testing.T) {
	f := mustDecode(t, fxVersionInfo)
	f.MessageType = 0x7777
	msg, err := DecodeMessage(f)
	if err != nil || msg.Kind != MessageUnknown || !reflect.DeepEqual(*msg.Frame, f) {
		t.Errorf("DecodeMessage = %+v, %v", msg, err)
	}
}
