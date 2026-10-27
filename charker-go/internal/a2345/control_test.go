package a2345

import (
	"reflect"
	"testing"
)

func capturedSettings(t *testing.T) DeviceSettings {
	t.Helper()
	snap, err := DecodeStatusSnapshot(mustDecode(t, fxCapturedSnapshot))
	if err != nil {
		t.Fatal(err)
	}
	return snap.Settings
}

func TestDecodesCapturedFullSnapshotSettings(t *testing.T) {
	msg, err := DecodeMessage(mustDecode(t, fxCapturedSnapshot))
	if err != nil || msg.Kind != MessageStatusSnapshot {
		t.Fatalf("DecodeMessage = %+v, %v", msg, err)
	}
	s := msg.StatusSnapshot.Settings
	if *s.FirmwareVersion != "2.1.1.2" || *s.ErrorCode != 0 || s.HasFault() || len(s.PortControls) != 5 {
		t.Errorf("version %q error %d controls %d", *s.FirmwareVersion, *s.ErrorCode, len(s.PortControls))
	}
	c1 := s.PortControls[GroupC1]
	if c1.IsOn || !c1.PowerOn.IsUnset() || c1.PowerOn.Hour != 12 || c1.CountdownTotal != 2_100 || c1.Priority != 0 {
		t.Errorf("c1 = %+v", c1)
	}
	c4 := s.PortControls[GroupC4]
	if c4.PowerOn != (PortSchedule{RawSwitch: 0, Hour: 8, Minute: 0, Weekdays: 2}) ||
		c4.PowerOff != (PortSchedule{RawSwitch: 0, Hour: 23, Minute: 0, Weekdays: 2}) || c4.CountdownTotal != 600 {
		t.Errorf("c4 = %+v", c4)
	}
	if !reflect.DeepEqual(*s.Clock, ClockState{IsOn: false, HolidayEnabled: false, ThemeCode: 1}) {
		t.Errorf("clock = %+v", *s.Clock)
	}
	if v, ok := s.ScreenTimeout(); !ok || v != ScreenThirtySeconds {
		t.Errorf("screen timeout = %v", v)
	}
	if *s.ChargingModeCode != 5 || !s.IsCustomChargingMode() || *s.IsUpdatingFirmware || *s.Brightness != 20 {
		t.Error("mode/update/brightness")
	}
	if v, ok := s.KnobDirection(); !ok || v != KnobBackward {
		t.Error("knob")
	}
	if v, ok := s.HourFormat(); !ok || v != HourFormat24 {
		t.Error("hour format")
	}
	if *s.ProtocolVersion != 1 || *s.Capabilities != 0x02FF || !s.Supports(CapMaxCompatibility) || s.Supports(CapUFCSSwitch) {
		t.Error("capabilities")
	}
	if !reflect.DeepEqual(*s.CustomProfile, CustomChargingProfile{Number: 1, Watts: []byte{15, 15, 15, 15, 15}}) {
		t.Errorf("profile = %+v", *s.CustomProfile)
	}
	if *s.ClockSchedule != (ClockSchedule{StartHour: 8, EndHour: 23, Weekdays: 0x7F}) {
		t.Errorf("clock schedule = %+v", *s.ClockSchedule)
	}
	both := ProtoSCP | ProtoUFCS
	if !reflect.DeepEqual(s.PortProtocols.Ports, []ProtocolFlags{both, both, both, both}) {
		t.Errorf("protocols = %v", s.PortProtocols.Ports)
	}
	if *s.MaxCompatibility {
		t.Error("max compatibility")
	}
	// BC is present but bit 8 is clear, so the official app ignores it.
	if s.UFCS != nil {
		t.Error("ufcs read without its capability bit")
	}
	// Bit 9 is set but this firmware sends no BF.
	if s.DeviceIdentification != nil {
		t.Error("device identification")
	}
	if len(s.ConnectedDeviceUSB) != 4 {
		t.Fatalf("usb slots = %d", len(s.ConnectedDeviceUSB))
	}
	for _, slot := range s.ConnectedDeviceUSB {
		if !slot.IsEmpty() {
			t.Errorf("slot %+v not empty", slot)
		}
	}
}

func TestDecodesCapturedThemeStatus(t *testing.T) {
	msg, err := DecodeMessage(mustDecode(t, "ff09270003010f0a0200a10164a2020101a3050400000000a40104a6020101fe050370428f693b"))
	if err != nil {
		t.Fatal(err)
	}
	want := []SettingsUpdate{ThemeStatusUpdate(ClockState{ThemeCode: 1, IsShowingHoliday: boolp(false)}, true)}
	if msg.Kind != MessageSettingsUpdate || !reflect.DeepEqual(msg.Updates, want) {
		t.Errorf("updates = %+v", msg.Updates)
	}
}

func TestDecodesCapturedPortSwitchPushAndAcknowledgement(t *testing.T) {
	msg, err := DecodeMessage(mustDecode(t, "ff091c0003010f0302a10164a2020100a3020101fe05034c048e6975"))
	if err != nil || !reflect.DeepEqual(msg.Updates, []SettingsUpdate{PortOutputUpdate(GroupC1, true)}) {
		t.Errorf("push = %+v, %v", msg, err)
	}

	msg, err = DecodeMessage(mustDecode(t, "ff09190003010f0a0700a10134a2020100fe050393588e690e"))
	want := WriteAcknowledgement{MessageType: 0x0A07, Status: u8(0), Group: groupp(GroupC1)}
	if err != nil || msg.Kind != MessageAcknowledgement || !reflect.DeepEqual(*msg.Acknowledgement, want) {
		t.Errorf("ack = %+v, %v", msg.Acknowledgement, err)
	}

	msg, err = DecodeMessage(mustDecode(t, fxRealtimeAcknowledgement))
	want = WriteAcknowledgement{MessageType: 0x0A0B, Status: u8(0)}
	if err != nil || msg.Kind != MessageAcknowledgement || !reflect.DeepEqual(*msg.Acknowledgement, want) {
		t.Errorf("short ack = %+v, %v", msg.Acknowledgement, err)
	}
}

func TestScheduleAcknowledgementEchoesPortAndSlot(t *testing.T) {
	f := Frame{
		Pattern:     FramePattern{Version: 3, Speaker: 1, Group: 15},
		MessageType: 0x0A08,
		Increment:   u8(0),
		Fields: []TLV{
			{ID: 0xA1, Raw: []byte{0x34}},
			{ID: 0xA2, Raw: []byte{1, 1}},
			{ID: 0xA3, Raw: []byte{1, 1}},
		},
	}
	msg, err := DecodeMessage(f)
	want := WriteAcknowledgement{MessageType: 0x0A08, Status: u8(0), Group: groupp(GroupC2), Slot: slotp(SlotPowerOn)}
	if err != nil || !reflect.DeepEqual(*msg.Acknowledgement, want) {
		t.Errorf("ack = %+v, %v", msg.Acknowledgement, err)
	}
}

func TestDecodesCapturedVersionFrameWithoutTypeBytes(t *testing.T) {
	v, err := DecodeVersionInfo(mustDecode(t, "ff093e0003000f083000a10876302e322e392e37a20876322e312e312e32a3054132333435a40941323334355f6d6375a50b41323334355f65737033320b"))
	if err != nil {
		t.Fatal(err)
	}
	if v.HardwareVersion != "v0.2.9.7" || v.SoftwareVersion != "2.1.1.2" || *v.ProductCode != "A2345" {
		t.Errorf("version = %+v", v)
	}
}

func TestPushesMergeIntoSettings(t *testing.T) {
	s := capturedSettings(t)
	s.Apply(PortCountdownUpdate(GroupC2, true, 3_600, 3_000))
	if s.PortControls[GroupC2].CountdownRemaining != 3_000 {
		t.Error("countdown")
	}
	s.Apply(PortOutputUpdate(GroupC2, false))
	if c := s.PortControls[GroupC2]; c.CountdownEnabled || c.CountdownTotal != 0 {
		t.Errorf("switch off kept countdown: %+v", c)
	}
	s.Apply(ChargingModeUpdate(2, nil, u8(0b0011)))
	if m, ok := s.ChargingMode(); !ok || m != ModePortPriority || s.PriorityBitmap() != 0b0011 {
		t.Errorf("mode %v bitmap %b", m, s.PriorityBitmap())
	}
	s.Apply(ChargingModeUpdate(1, nil, nil))
	if s.PriorityBitmap() != 0 {
		t.Errorf("bitmap after leaving priority mode = %b", s.PriorityBitmap())
	}
	s.Apply(ErrorCodeUpdate(0b0100))
	if !s.HasFault() || !s.HasGroupFault(GroupC2) || s.HasGroupFault(GroupC1) {
		t.Error("group fault")
	}
	s.Apply(ErrorCodeUpdate(1))
	if !s.IsOverTemperature() || s.HasGroupFault(GroupC2) {
		t.Error("over-temperature")
	}
}

func TestDecodesChangeMessages(t *testing.T) {
	decode := func(typ uint16, fields ...TLV) []SettingsUpdate {
		t.Helper()
		msg, err := DecodeMessage(Frame{
			Pattern:     FramePattern{Version: 3, Speaker: 1, Group: 15},
			MessageType: typ,
			Fields:      append([]TLV{{ID: 0xA1, Raw: []byte{0x64}}}, fields...),
		})
		if err != nil || msg.Kind != MessageSettingsUpdate {
			t.Fatalf("0x%04X: %+v, %v", typ, msg, err)
		}
		return msg.Updates
	}
	cases := []struct {
		name string
		got  []SettingsUpdate
		want SettingsUpdate
	}{
		{"0307", decode(0x0307,
			TLV{ID: 0xA2, Raw: []byte{1, 4}},
			TLV{ID: 0xA3, Raw: []byte{4, 1, 0x84, 3, 0, 0, 0x58, 2, 0, 0}}),
			PortCountdownUpdate(GroupUSBA, true, 900, 600)},
		{"0308", decode(0x0308,
			TLV{ID: 0xA2, Raw: []byte{1, 0}},
			TLV{ID: 0xA3, Raw: []byte{1, 1}},
			TLV{ID: 0xA4, Raw: []byte{3, 1, 8, 0, 0x1F}}),
			PortScheduleUpdate(GroupC1, SlotPowerOn, NewPortSchedule(true, 8, 0, 0x1F))},
		{"030D", decode(0x030D,
			TLV{ID: 0xA2, Raw: []byte{1, 5}},
			TLV{ID: 0xA3, Raw: []byte{4, 1, 0, 15, 15, 15, 15, 15}},
			TLV{ID: 0xA4, Raw: []byte{1, 3}}),
			ChargingModeUpdate(5, &CustomChargingProfile{Number: 1, Watts: []byte{15, 15, 15, 15, 15}}, u8(3))},
		{"0309", decode(0x0309, TLV{ID: 0xA2, Raw: []byte{1, 0x13}}), ScreenTimeoutUpdate(3)},
		{"0311", decode(0x0311,
			TLV{ID: 0xA2, Raw: []byte{3, 9, 0, 0, 0}},
			TLV{ID: 0xA3, Raw: []byte{1, 1}},
			TLV{ID: 0xA4, Raw: []byte{1, 3}}),
			ThemeDownloadUpdate(u32(9), 1, u8(3))},
		{"0301", decode(0x0301, TLV{ID: 0xA2, Raw: []byte{2, 0x40, 0x08}}), FirmwareVersionUpdate("2.1.1.2")},
		{"030F single", decode(0x030F, TLV{ID: 0xA2, Raw: []byte{4, 2, 1}}), SinglePortPriorityUpdate(GroupC3, true)},
	}
	for _, tc := range cases {
		if !reflect.DeepEqual(tc.got, []SettingsUpdate{tc.want}) {
			t.Errorf("%s = %+v, want %+v", tc.name, tc.got, tc.want)
		}
	}
	// A recognised change type without its fields decodes to no update.
	if got := decode(0x0302); len(got) != 0 {
		t.Errorf("empty 0302 = %+v", got)
	}
}

// From CharkerCoreTests/A2345ControlTests.swift.

func TestWriteKeysMatchEchoedGroupAndSlot(t *testing.T) {
	c1 := NewWriteKey(SetPortOutput(GroupC1, true))
	c2 := NewWriteKey(SetPortOutput(GroupC2, false))
	ack := WriteAcknowledgement{MessageType: 0x0A07, Status: u8(0), Group: groupp(GroupC2)}
	if c1.Matches(ack) || !c2.Matches(ack) {
		t.Error("port output keys")
	}
	powerOn := NewWriteKey(SetPortSchedule(GroupC3, SlotPowerOn, NewPortSchedule(true, 7, 0, 0)))
	cases := []struct {
		ack  WriteAcknowledgement
		want bool
	}{
		{WriteAcknowledgement{MessageType: 0x0A08, Status: u8(0), Slot: slotp(SlotPowerOn)}, true},
		{WriteAcknowledgement{MessageType: 0x0A08, Status: u8(0), Slot: slotp(SlotPowerOff)}, false},
		{WriteAcknowledgement{MessageType: 0x0A08, Status: u8(0), Group: groupp(GroupC2), Slot: slotp(SlotPowerOn)}, false},
		// Acknowledgements that echo nothing match by type alone.
		{WriteAcknowledgement{MessageType: 0x0A08, Status: u8(0)}, true},
	}
	for i, tc := range cases {
		if got := powerOn.Matches(tc.ack); got != tc.want {
			t.Errorf("case %d = %v", i, got)
		}
	}
	brightness := NewWriteKey(SetBrightness(60))
	if !brightness.Matches(WriteAcknowledgement{MessageType: 0x0A04, Status: u8(0)}) ||
		brightness.Matches(WriteAcknowledgement{MessageType: 0x0A03, Status: u8(0)}) {
		t.Error("brightness key")
	}
	// Keys are comparable map keys.
	pending := map[WriteKey]bool{c1: true}
	if !pending[NewWriteKey(SetPortOutput(GroupC1, false))] {
		t.Error("map key")
	}
}

func TestOptimisticStateFollowsTheCommand(t *testing.T) {
	s := DemoSettings()
	s = s.Applying(SetPortCountdown(GroupC1, true, 3_600))
	if s.PortControls[GroupC1].CountdownRemaining != 3_600 {
		t.Error("countdown")
	}
	s = s.Applying(SetPortOutput(GroupC1, false))
	if c := s.PortControls[GroupC1]; c.IsOn || c.CountdownEnabled {
		t.Errorf("c1 = %+v", c)
	}
	s = s.Applying(SetChargingMode(ModePortPriority))
	s = s.Applying(SetPortPriority(0b1001))
	if s.PriorityBitmap() != 0b1001 {
		t.Errorf("bitmap = %b", s.PriorityBitmap())
	}
	s = s.Applying(SetChargingMode(ModeDualLaptop))
	if s.PriorityBitmap() != 0 {
		t.Errorf("bitmap = %b", s.PriorityBitmap())
	}
	s = s.Applying(SetClockTheme(NewClockThemeRequest(false, ThemeStyle3, nil, 0, BuiltInStyleURL(ThemeStyle3))))
	if s.Clock.IsOn || s.Clock.ThemeCode != 2 {
		t.Errorf("clock = %+v", *s.Clock)
	}
}

func TestApplyingDoesNotMutateTheReceiver(t *testing.T) {
	base := DemoSettings()
	_ = base.Applying(SetPortOutput(GroupC1, false))
	_ = base.Applying(SetBrightness(20))
	_ = base.Applying(SetHolidayTheme(true))
	if !base.PortControls[GroupC1].IsOn || *base.Brightness != 70 || base.Clock.HolidayEnabled {
		t.Error("Applying mutated its receiver")
	}
}

func TestSnapshotKeepsThemeDetailsOnlyTheThemeMessageCarries(t *testing.T) {
	previous := DemoSettings()
	previous.Clock = &ClockState{IsOn: true, ThemeCode: 3, ThemeID: u32(9), ThemeURL: str("https://example.com/t.jpg"), IsShowingHoliday: boolp(false)}
	previous.CustomImageTimeDisplay = boolp(true)

	incoming := DemoSettings()
	incoming.Clock = &ClockState{IsOn: true, HolidayEnabled: true, ThemeCode: 3, ThemeID: u32(9)}
	incoming.CustomImageTimeDisplay = nil
	merged := previous.MergingSnapshot(incoming)
	if merged.Clock.ThemeURL == nil || *merged.Clock.ThemeURL != "https://example.com/t.jpg" ||
		!merged.Clock.HolidayEnabled || merged.CustomImageTimeDisplay == nil || !*merged.CustomImageTimeDisplay {
		t.Errorf("merged clock = %+v", *merged.Clock)
	}
	if incoming.Clock.ThemeURL != nil {
		t.Error("MergingSnapshot mutated its argument")
	}

	incoming.Clock = &ClockState{IsOn: true, ThemeCode: 3, ThemeID: u32(10)}
	if previous.MergingSnapshot(incoming).Clock.ThemeURL != nil {
		t.Error("theme URL kept across a theme change")
	}
}

func TestCloneIsDeep(t *testing.T) {
	a := DemoSettings()
	b := a.Clone()
	*b.Brightness = 20
	b.PortControls[GroupC1] = PortControl{}
	b.CustomProfile.Watts[0] = 0
	b.PortProtocols.Ports[0] = 0
	b.Clock.IsOn = false
	if *a.Brightness != 70 || !a.PortControls[GroupC1].IsOn || a.CustomProfile.Watts[0] != 100 ||
		a.PortProtocols.Ports[0] == 0 || !a.Clock.IsOn {
		t.Error("Clone shares state")
	}
}
