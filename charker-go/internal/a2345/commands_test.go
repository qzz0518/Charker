package a2345

import (
	"bytes"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

func mustEncode(t *testing.T, c Command, at time.Time) []byte {
	t.Helper()
	b, err := c.Encode(at)
	if err != nil {
		t.Fatalf("Encode %s: %v", c, err)
	}
	return b
}

func TestReadRequestVectors(t *testing.T) {
	cases := []struct {
		name string
		got  []byte
		want string
	}{
		{"status snapshot", StatusSnapshotRequest(epoch), "ff09140003000f0200a10122fe050300f1536551"},
		{"realtime trigger", RealtimeTriggerRequest(epoch), "ff09140003000f020ba10122fe050300f153655a"},
		{"status command", mustEncode(t, RequestStatusSnapshot(), epoch), "ff09140003000f0200a10122fe050300f1536551"},
		{"realtime command", mustEncode(t, RealtimeTrigger(), epoch), "ff09140003000f020ba10122fe050300f153655a"},
	}
	for _, tc := range cases {
		if hexStr(tc.got) != tc.want {
			t.Errorf("%s = %s, want %s", tc.name, hexStr(tc.got), tc.want)
		}
	}
}

func TestBothReadRequestsRoundTripThroughStrictDecoder(t *testing.T) {
	for _, tc := range []struct {
		typ   uint16
		bytes []byte
	}{{0x0200, StatusSnapshotRequest(epoch)}, {0x020B, RealtimeTriggerRequest(epoch)}} {
		f, err := Decode(tc.bytes)
		if err != nil {
			t.Fatal(err)
		}
		if f.Pattern != (FramePattern{Version: 3, Speaker: 0, Group: 15}) || f.MessageType != tc.typ || f.Increment != nil || f.EncodedLength != 20 {
			t.Errorf("frame = %+v", f)
		}
		want := []TLV{
			{ID: FieldA1, Raw: []byte{0x22}},
			{ID: FieldTimestamp, Raw: []byte{ValueVariable, 0x00, 0xF1, 0x53, 0x65}},
		}
		if !reflect.DeepEqual(f.Fields, want) {
			t.Errorf("fields = %+v", f.Fields)
		}
	}
}

func TestReadRequestsDifferOnlyByMessageTypeAndChecksum(t *testing.T) {
	status, realtime := StatusSnapshotRequest(epoch), RealtimeTriggerRequest(epoch)
	if len(status) != len(realtime) {
		t.Fatal("lengths differ")
	}
	var diff []int
	for i := range status {
		if status[i] != realtime[i] {
			diff = append(diff, i)
		}
	}
	if !reflect.DeepEqual(diff, []int{8, len(status) - 1}) {
		t.Errorf("diff = %v", diff)
	}
}

// Write frames from the official app 3.24.0 encoder rules; the captures are
// byte-for-byte frames the official app sent (anker-solix-api #252, firmware
// 2.1.1.2).
func TestWriteVectors(t *testing.T) {
	cases := []struct {
		name string
		cmd  Command
		at   time.Time
		want string
	}{
		{"screen timeout", SetScreenTimeout(ScreenThirtySeconds), stampA, "ff09180003000f0203a10122a2020101fe0503e3ccbd6ac1"},
		{"brightness", SetBrightness(50), stampA, "ff09180003000f0204a10122a2020132fe0503e3ccbd6af5"},
		{"theme status", ThemeStatus(), stampA, "ff09140003000f0202a10122fe0503e3ccbd6a6c"},
		{"clock schedule", SetClockSchedule(ClockSchedule{StartHour: 8, EndHour: 23, Weekdays: 0x7F}), stampA,
			"ff091c0003000f0213a10122a20604080017007ffe0503e3ccbd6ab5"},
		// Capture (C1 on).
		{"port output", SetPortOutput(GroupC1, true), stampB, "ff091c0003000f0207a10122a2020100a3020101fe05030078e7686e"},
		{"port schedule", SetPortSchedule(GroupC2, SlotPowerOn, NewPortSchedule(true, 7, 30, 0x1F)), stampB,
			"ff09230003000f0208a10122a2020101a3020101a4050301071e1ffe05030078e768fa"},
	}
	for _, tc := range cases {
		if got := hexStr(mustEncode(t, tc.cmd, tc.at)); got != tc.want {
			t.Errorf("%s = %s, want %s", tc.name, got, tc.want)
		}
	}
	usbAOff := mustEncode(t, SetPortOutput(GroupUSBA, false), stampB)
	if !bytes.Equal(usbAOff[12:20], []byte{0xA2, 0x02, 0x01, 0x04, 0xA3, 0x02, 0x01, 0x00}) {
		t.Errorf("usb-a off = %x", usbAOff[12:20])
	}
}

func TestCountdownCarriesSwitchAndSeconds(t *testing.T) {
	frame := mustEncode(t, SetPortCountdown(GroupC1, true, 900), stampB)
	if hexStr(frame[12:24]) != "a2020100a306040184030000" {
		t.Errorf("fields = %s", hexStr(frame[12:24]))
	}
	if _, err := SetPortCountdown(GroupC1, true, 90_000).Encode(epoch); err == nil {
		t.Error("over-long countdown accepted")
	}
	// Cancelling echoes any reported total.
	f, err := Decode(mustEncode(t, SetPortCountdown(GroupC3, false, 100_000), stampA))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(f.Fields[2].Raw, []byte{0x04, 0x00, 0xA0, 0x86, 0x01, 0x00}) {
		t.Errorf("cancel = %x", f.Fields[2].Raw)
	}
}

func TestCustomModeMatchesCapturedProfileAndProtocols(t *testing.T) {
	// Captured by ha-anker-prime-charger: a3=01000f1619140f, a4=0200000b00000b0000020000.
	profile := CustomChargingProfile{Number: 1, AutoExit: false, Watts: []byte{15, 22, 25, 20, 15}}
	protocols := PortProtocols{Ports: []ProtocolFlags{
		ProtoUFCS,
		ProtoSCP | ProtoUFCS | ProtoPPS11V,
		ProtoSCP | ProtoUFCS | ProtoPPS11V,
		ProtoUFCS,
	}}
	f, err := Decode(mustEncode(t, SetCustomChargingMode(profile, &protocols), stampB))
	if err != nil {
		t.Fatal(err)
	}
	if f.MessageType != 0x0206 || !reflect.DeepEqual(fieldIDs(f), []byte{0xA1, 0xA2, 0xA3, 0xA4, 0xFE}) {
		t.Fatalf("frame = %+v", f)
	}
	if !bytes.Equal(f.Fields[1].Raw, []byte{0x01, 0x05}) ||
		hexStr(f.Fields[2].Raw) != "0401000f1619140f" ||
		hexStr(f.Fields[3].Raw) != "040200000b00000b0000020000" {
		t.Errorf("fields = %x %x %x", f.Fields[1].Raw, f.Fields[2].Raw, f.Fields[3].Raw)
	}
}

func TestCustomModeRejectsValuesTheOfficialAppNeverSends(t *testing.T) {
	for _, watts := range [][]byte{
		{10, 0, 0, 0, 0},      // C port inside the 1…14 W gap
		{140, 100, 0, 0, 20},  // USB-A only takes 0, 15 or 24
		{140, 100, 100, 0, 0}, // over 250 W in total
		{15, 15, 15, 15},      // not five limits
	} {
		_, err := SetCustomChargingMode(CustomChargingProfile{Number: 1, Watts: watts}, nil).Encode(epoch)
		var ce *CommandError
		if !errors.As(err, &ce) {
			t.Errorf("%v accepted (%v)", watts, err)
		}
	}
}

func TestInvertedAndPlainSwitches(t *testing.T) {
	cases := []struct {
		cmd  Command
		want byte
	}{
		{SetMaxCompatibility(true), 0x00},
		{SetMaxCompatibility(false), 0x01},
		{SetDeviceIdentification(true), 0x01},
		{ExitCustomChargingMode(), 0x00},
	}
	for _, tc := range cases {
		if got := mustEncode(t, tc.cmd, stampA)[15]; got != tc.want {
			t.Errorf("%s value = %d", tc.cmd, got)
		}
	}
	if ack, ok := SetMaxCompatibility(true).AcknowledgementType(); !ok || ack != 0x0A14 {
		t.Errorf("ack = 0x%04X %v", ack, ok)
	}
	if _, ok := RequestStatusSnapshot().AcknowledgementType(); ok {
		t.Error("snapshot request has an acknowledgement type")
	}
}

func TestPriorityAllowsAtMostTwoCPorts(t *testing.T) {
	if _, err := SetPortPriority(0b0101).Encode(epoch); err != nil {
		t.Error(err)
	}
	for _, bitmap := range []byte{0b0111, 0b1_0000} {
		if _, err := SetPortPriority(bitmap).Encode(epoch); err == nil {
			t.Errorf("%b accepted", bitmap)
		}
	}
}

func TestRejectsOutOfRangeValues(t *testing.T) {
	for name, cmd := range map[string]Command{
		"brightness low":     SetBrightness(15),
		"brightness step":    SetBrightness(52),
		"brightness high":    SetBrightness(105),
		"schedule hour":      SetPortSchedule(GroupC1, SlotPowerOn, NewPortSchedule(true, 24, 0, 0)),
		"clock schedule":     SetClockSchedule(ClockSchedule{StartHour: 8, EndHour: 23, EndMinute: 60}),
		"picture without id": SetClockTheme(NewClockThemeRequest(true, ThemePicture, nil, 0, "u")),
		"long A6 url":        SetClockTheme(NewClockThemeRequest(true, ThemeStyle1, nil, 0, strings.Repeat("x", 255))),
		"zero command":       {},
	} {
		if _, err := cmd.Encode(epoch); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}

func TestBuiltInThemeSendsEmptyIDAndAssetPath(t *testing.T) {
	req := NewClockThemeRequest(true, ThemeStyle2, nil, 0, BuiltInStyleURL(ThemeStyle2))
	f, err := Decode(mustEncode(t, SetClockTheme(req), stampA))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(fieldIDs(f), []byte{0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xFE}) {
		t.Fatalf("ids = %x", fieldIDs(f))
	}
	if !bytes.Equal(f.Fields[1].Raw, []byte{0x01, 0x81}) || !bytes.Equal(f.Fields[2].Raw, []byte{0x04}) ||
		!bytes.Equal(f.Fields[4].Raw, []byte{0x03, 0xFF, 0xFF, 0xFF, 0xFF}) {
		t.Errorf("fields = %x %x %x", f.Fields[1].Raw, f.Fields[2].Raw, f.Fields[4].Raw)
	}
	if got := string(f.Fields[5].Raw[1:]); got != "assets/img/a2345/icl_a2345_theme2.png" {
		t.Errorf("url = %q", got)
	}
}

func TestCustomPictureUsesLongA7(t *testing.T) {
	url := "https://example.com/" + strings.Repeat("x", 180)
	req := NewClockThemeRequest(true, ThemeCustom, u32(77), 0x1234_5678, "")
	req.CustomURL = url
	frame := mustEncode(t, SetClockTheme(req), stampA)
	a7 := bytes.IndexByte(frame, 0xA7)
	if a7 < 0 {
		t.Fatal("no A7")
	}
	if length := int(frame[a7+1]) | int(frame[a7+2])<<8; length != len(url)+1 {
		t.Errorf("length = %d", length)
	}
	if frame[a7+3] != 0x04 {
		t.Errorf("type = 0x%02X", frame[a7+3])
	}
	if Checksum(frame[:len(frame)-1]) != frame[len(frame)-1] {
		t.Error("checksum")
	}
	// The encoded total length still matches.
	if int(frame[2])|int(frame[3])<<8 != len(frame) {
		t.Error("total length")
	}
}

func TestCommandAccessorsAndConstructorsCopy(t *testing.T) {
	watts := []byte{15, 15, 15, 15, 15}
	protocols := &PortProtocols{Ports: []ProtocolFlags{ProtoUFCS, ProtoUFCS, ProtoUFCS, ProtoUFCS}}
	cmd := SetCustomChargingMode(CustomChargingProfile{Number: 2, Watts: watts}, protocols)
	watts[0] = 99
	protocols.Ports[0] = 0
	p, pp := cmd.Profile()
	if p.Watts[0] != 15 || pp.Ports[0] != ProtoUFCS {
		t.Error("constructor aliased its arguments")
	}
	if g, ok := SetPortSchedule(GroupC3, SlotPowerOff, PortSchedule{}).Group(); !ok || g != GroupC3 {
		t.Error("group accessor")
	}
	if s, ok := SetPortSchedule(GroupC3, SlotPowerOn, PortSchedule{}).Slot(); !ok || s != SlotPowerOn {
		t.Error("slot accessor")
	}
	if _, ok := SetBrightness(50).Group(); ok {
		t.Error("brightness has a group")
	}
	if RealtimeTrigger().IsWrite() || ThemeStatus().IsWrite() || !SetUFCS(true).IsWrite() {
		t.Error("IsWrite")
	}
	if SetPortOutput(GroupC1, true).String() != "0x0207" {
		t.Error("String")
	}
}
