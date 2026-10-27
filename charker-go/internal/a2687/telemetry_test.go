package a2687

import (
	"errors"
	"reflect"
	"testing"

	"charker/internal/product"
)

// decodeSettingsOf is the settings() helper from the Swift tests: decode a
// payload and return the settings snapshot (failing when there is none).
func decodeSettingsOf(t *testing.T, payload Payload) *DeviceSettings {
	t.Helper()
	settings := DecodeTelemetry(payload, OpcodeReadAll, commandEpoch()).Settings
	if settings == nil {
		t.Fatal("expected a settings snapshot")
	}
	return settings
}

func telemetryFields(fields ...TLV) Payload { return reportPayload(fields...) }

// P1: three ports decode and the total is derived locally.
func TestDecodesThreePortsAndDerivesTheTotal(t *testing.T) {
	payload := telemetryFields(
		NewTLV(FieldA1, []byte{0x21}),
		NewTLV(FieldA5, portStruct(1, 20000, 3250, 6500)),
		NewTLV(FieldA6, portStruct(1, 9000, 2000, 1800)),
		NewTLV(FieldA7, portStruct(0, 0, 0, 0)),
	)
	telemetry := DecodeTelemetry(payload, OpcodeRealtimeReport, commandEpoch())
	if len(telemetry.Ports) != 3 {
		t.Fatalf("ports = %d, want 3", len(telemetry.Ports))
	}
	if !telemetry.HasPortData() {
		t.Error("hasPortData = false")
	}
	c1, ok := telemetry.Port(PortC1)
	if !ok {
		t.Fatal("missing C1")
	}
	if c1.Voltage != 20.0 || c1.Current != 3.25 || c1.Power != 65.0 {
		t.Errorf("C1 = %v V / %v A / %v W", c1.Voltage, c1.Current, c1.Power)
	}
	if !c1.IsDelivering() || !c1.HasReadings() || !c1.IsOn() {
		t.Errorf("C1 predicates: delivering=%v readings=%v on=%v", c1.IsDelivering(), c1.HasReadings(), c1.IsOn())
	}
	if got := telemetry.TotalPower(); got != 83.0 {
		t.Errorf("totalPower = %v, want 83", got)
	}
	if got := telemetry.ActivePortCount(); got != 2 {
		t.Errorf("activePortCount = %d, want 2", got)
	}
	c3, _ := telemetry.Port(PortC3)
	if c3.IsOn() || c3.HasReadings() || c3.IsDelivering() {
		t.Errorf("C3 predicates: on=%v readings=%v delivering=%v", c3.IsOn(), c3.HasReadings(), c3.IsDelivering())
	}
	if telemetry.SourceOpcode != OpcodeRealtimeReport {
		t.Errorf("sourceOpcode = 0x%04X", telemetry.SourceOpcode)
	}
	if !telemetry.ReceivedAt.Equal(commandEpoch()) {
		t.Errorf("receivedAt = %v", telemetry.ReceivedAt)
	}
	if telemetry.AllFields.Occurrences(FieldA5) != 1 {
		t.Error("allFields lost the port struct")
	}
}

// P2: an off port's stale non-zero reading is not summed.
func TestOffPortDoesNotContributeToTheTotal(t *testing.T) {
	payload := telemetryFields(NewTLV(FieldA5, portStruct(0, 20000, 3250, 6500)))
	telemetry := DecodeTelemetry(payload, OpcodeRealtimeReport, commandEpoch())
	if got := telemetry.TotalPower(); got != 0 {
		t.Errorf("totalPower = %v, want 0", got)
	}
}

// P3: cable and charging profile decode from the control struct.
func TestDecodesCableAndChargingProfile(t *testing.T) {
	payload := telemetryFields(
		NewTLV(FieldA5, portStruct(1, 9000, 2200, 1980)),
		NewTLV(FieldAC, controlStruct(0x02, 0x01)),
	)
	port := mustPort(t, DecodeTelemetry(payload, OpcodeRealtimeReport, commandEpoch()), PortC1)
	if !port.HasCable || port.Cable != CableEPR240W {
		t.Errorf("cable = %v/%v, want EPR240W", port.Cable, port.HasCable)
	}
	if !port.HasChargingProfile || port.ChargingProfile != ChargingProfileApplePD {
		t.Errorf("profile = %v/%v, want Apple PD", port.ChargingProfile, port.HasChargingProfile)
	}
	if label, ok := port.CableLabel(); !ok || label != "EPR · 240 W" {
		t.Errorf("cable label = %q/%v", label, ok)
	}
	if label := port.ChargingProfile.Label(); label != "Apple PD" {
		t.Errorf("profile label = %q", label)
	}
}

// P4: unknown cable and profile codes are surfaced, never invented.
func TestUnknownCableCodeIsSurfacedNotInvented(t *testing.T) {
	payload := telemetryFields(
		NewTLV(FieldA5, portStruct(1, 9000, 2200, 1980)),
		NewTLV(FieldAC, controlStruct(0x7E, 0x7F)),
	)
	port := mustPort(t, DecodeTelemetry(payload, OpcodeRealtimeReport, commandEpoch()), PortC1)
	if port.Cable != CableCapability(0x7E) {
		t.Errorf("cable = 0x%02X, want 0x7E", port.Cable.Code())
	}
	if label, _ := port.Cable.Label(); label != "Unknown (0x7E)" {
		t.Errorf("cable label = %q", label)
	}
	if !port.HasChargingProfile || port.ChargingProfile != ChargingProfile(0x7F) {
		t.Errorf("profile = %v/%v", port.ChargingProfile, port.HasChargingProfile)
	}
	if label := port.ChargingProfile.Label(); label != "Unknown (0x7F)" {
		t.Errorf("profile label = %q", label)
	}
}

// P5: an idle port hides the charging profile but still reports the cable.
func TestIdlePortReportsNoChargingProfile(t *testing.T) {
	payload := telemetryFields(
		NewTLV(FieldA5, portStruct(1, 5000, 0, 0)),
		NewTLV(FieldAC, controlStruct(0x01, 0x01)),
	)
	port := mustPort(t, DecodeTelemetry(payload, OpcodeRealtimeReport, commandEpoch()), PortC1)
	if port.HasChargingProfile {
		t.Errorf("idle port reported profile %v", port.ChargingProfile)
	}
	if port.Cable != CableMax100W {
		t.Errorf("cable = %v, want max100W", port.Cable)
	}
	if attached, reported := port.IsCableAttached(); !attached || !reported {
		t.Errorf("cable attached = %v/%v, want true/true", attached, reported)
	}
}

// P6: cable presence distinguishes idle-attached, known-empty and unreported.
func TestCablePresenceDistinguishesIdleAttachedEmptyAndUnreported(t *testing.T) {
	idleAttached := PortTelemetry{Port: PortC1, StatusCode: 1, HasCable: true, Cable: CableEPR240W}
	knownEmpty := PortTelemetry{Port: PortC2, StatusCode: 1, HasCable: true, Cable: CableNone}
	unreportedIdle := PortTelemetry{Port: PortC3, StatusCode: 1}
	unreportedDelivering := PortTelemetry{Port: PortC3, StatusCode: 1, Voltage: 5, Current: 1, Power: 5}
	cases := []struct {
		name     string
		port     PortTelemetry
		attached bool
		reported bool
	}{
		{"idleAttached", idleAttached, true, true},
		{"knownEmpty", knownEmpty, false, true},
		{"unreportedIdle", unreportedIdle, false, false},
		{"unreportedDelivering", unreportedDelivering, true, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			attached, reported := tc.port.IsCableAttached()
			if attached != tc.attached || reported != tc.reported {
				t.Errorf("attached/reported = %v/%v, want %v/%v", attached, reported, tc.attached, tc.reported)
			}
		})
	}
}

// P7: a short control struct reports nothing rather than a guess.
func TestShortControlStructReportsNothing(t *testing.T) {
	payload := telemetryFields(
		NewTLV(FieldA5, portStruct(1, 9000, 2200, 1980)),
		NewTLV(FieldAC, BytesValue([]byte{0x00, 0x00, 0x02, 0x01}).Encoded()),
	)
	port := mustPort(t, DecodeTelemetry(payload, OpcodeRealtimeReport, commandEpoch()), PortC1)
	if port.Control != nil || port.HasCable || port.HasChargingProfile {
		t.Errorf("short control decoded: control=%v cable=%v profile=%v", port.Control, port.HasCable, port.HasChargingProfile)
	}
}

// P8: a payload without port structs is not a snapshot, but is still recorded.
func TestPayloadWithoutPortStructIsNotASnapshot(t *testing.T) {
	payload := telemetryFields(NewTLV(FieldA1, []byte{0x21}))
	telemetry := DecodeTelemetry(payload, OpcodeReadAll, commandEpoch())
	if telemetry.HasPortData() {
		t.Error("hasPortData = true for a bind ack")
	}
	if got, ok := telemetry.AllFields.Field(FieldA1); !ok || !reflect.DeepEqual(got, []byte{0x21}) {
		t.Errorf("allFields A1 = %x/%v", got, ok)
	}
	if telemetry.Settings != nil {
		t.Error("a frame with no settings ids must not produce a snapshot")
	}
}

// P9: a truncated port struct is rejected.
func TestTruncatedPortStructIsRejected(t *testing.T) {
	payload := telemetryFields(NewTLV(FieldA5, BytesValue([]byte{0x01, 0x20, 0x4E}).Encoded()))
	if telemetry := DecodeTelemetry(payload, OpcodeRealtimeReport, commandEpoch()); telemetry.HasPortData() {
		t.Error("a 3-byte port struct decoded")
	}
	// Bare (untyped) bytes are not a port struct either.
	bare := telemetryFields(NewTLV(FieldA5, []byte{0x01, 0x20, 0x4E, 0x00, 0x00, 0x00, 0x00}))
	if telemetry := DecodeTelemetry(bare, OpcodeRealtimeReport, commandEpoch()); telemetry.HasPortData() {
		t.Error("a bare port struct decoded")
	}
}

// P10: unknown fields are preserved but unnamed.
func TestUnknownFieldsArePreservedButUnnamed(t *testing.T) {
	const unknownID byte = 0xB3
	payload := telemetryFields(
		NewTLV(FieldA5, portStruct(1, 5000, 1000, 500)),
		NewTLV(unknownID, []byte{0x01, 0xFF}),
	)
	telemetry := DecodeTelemetry(payload, OpcodeRealtimeReport, commandEpoch())
	if got, want := telemetry.UnknownFields[unknownID], []byte{0x01, 0xFF}; !reflect.DeepEqual(got, want) {
		t.Errorf("unknownFields = %x, want %x", got, want)
	}
	if got := telemetry.AllFields.Occurrences(unknownID); got != 1 {
		t.Errorf("allFields occurrences = %d, want 1", got)
	}
	// Repeats of an unknown id keep the first occurrence in the map.
	repeated := telemetryFields(
		NewTLV(FieldA5, portStruct(1, 5000, 1000, 500)),
		NewTLV(unknownID, []byte{0x01}),
		NewTLV(unknownID, []byte{0x02}),
	)
	repeatedTelemetry := DecodeTelemetry(repeated, OpcodeRealtimeReport, commandEpoch())
	if got := repeatedTelemetry.UnknownFields[unknownID]; !reflect.DeepEqual(got, []byte{0x01}) {
		t.Errorf("first unknown occurrence = %x, want 01", got)
	}
	if got := repeatedTelemetry.AllFields.Occurrences(unknownID); got != 2 {
		t.Errorf("allFields occurrences = %d, want 2", got)
	}
}

// B1-B6: the B4 connected-device block.
var (
	b4C1AndC2      = []byte{0xAC, 0x05, 0x09, 0x73, 0xAC, 0x05, 0x18, 0x75, 0xFA, 0xFF, 0xFB, 0xFF}
	b4C1Unplugged  = []byte{0xFA, 0xFF, 0xFB, 0xFF, 0xAC, 0x05, 0x18, 0x75, 0xFA, 0xFF, 0xFB, 0xFF}
	b4AllUnplugged = []byte{0xFA, 0xFF, 0xFB, 0xFF, 0xFA, 0xFF, 0xFB, 0xFF, 0xFA, 0xFF, 0xFB, 0xFF}
	b4AllOccupied  = []byte{0xAC, 0x05, 0x19, 0x75, 0xAC, 0x05, 0x09, 0x73, 0x00, 0x00, 0x00, 0x00}
)

func telemetryWithB4(t *testing.T, block []byte) ChargerTelemetry {
	t.Helper()
	payload := telemetryFields(
		NewTLV(FieldA5, portStruct(1, 9000, 2000, 1800)),
		NewTLV(FieldA6, portStruct(1, 9000, 1000, 900)),
		NewTLV(FieldA7, portStruct(1, 5000, 500, 250)),
		NewTLV(FieldB4, block),
	)
	return DecodeTelemetry(payload, OpcodeReadAll, commandEpoch())
}

func mustPort(t *testing.T, telemetry ChargerTelemetry, port Port) PortTelemetry {
	t.Helper()
	value, ok := telemetry.Port(port)
	if !ok {
		t.Fatalf("port %v missing", port)
	}
	return value
}

func mustDevice(t *testing.T, telemetry ChargerTelemetry, port Port) USBDeviceID {
	t.Helper()
	value := mustPort(t, telemetry, port)
	if value.ConnectedDevice == nil {
		t.Fatalf("port %v has no connected device", port)
	}
	return *value.ConnectedDevice
}

func TestOneTwelveByteB4CarriesAllThreePorts(t *testing.T) {
	telemetry := telemetryWithB4(t, b4C1AndC2)
	if got := telemetry.AllFields.Occurrences(FieldB4); got != 1 {
		t.Errorf("B4 occurrences = %d, want 1", got)
	}
	c1 := mustDevice(t, telemetry, PortC1)
	if c1.VendorID != 0x05AC || c1.ProductID != 0x7309 {
		t.Errorf("C1 = %s", c1.HexDescription())
	}
	if got := c1.HexDescription(); got != "05AC:7309" {
		t.Errorf("C1 hex = %q", got)
	}
	if got := mustDevice(t, telemetry, PortC2).HexDescription(); got != "05AC:7518" {
		t.Errorf("C2 hex = %q", got)
	}
	if !mustDevice(t, telemetry, PortC3).IsNoIdentity() {
		t.Error("C3 should have no identity")
	}
}

func TestUnpluggingOnePortOnlyChangesThatPortsRecord(t *testing.T) {
	oneGone := telemetryWithB4(t, b4C1Unplugged)
	if !mustDevice(t, oneGone, PortC1).IsNoIdentity() {
		t.Error("C1 should be no-identity")
	}
	if got := mustDevice(t, oneGone, PortC2).HexDescription(); got != "05AC:7518" {
		t.Errorf("C2 hex = %q", got)
	}
	if !mustDevice(t, oneGone, PortC3).IsNoIdentity() {
		t.Error("C3 should be no-identity")
	}

	allGone := telemetryWithB4(t, b4AllUnplugged)
	for _, port := range Ports {
		if !mustDevice(t, allGone, port).IsNoIdentity() {
			t.Errorf("%v should be no-identity", port)
		}
	}
}

// The block starts with 0xFA, which a typed-value decoder would mistake for a
// type prefix; the fallback keeps the twelve bytes aligned.
func TestAttachedButUnidentifiedIsNotAnEmptyPort(t *testing.T) {
	telemetry := telemetryWithB4(t, b4AllOccupied)
	c3 := mustDevice(t, telemetry, PortC3)
	if c3.IsNoIdentity() {
		t.Error("0000:0000 must not read as no-identity")
	}
	if !c3.IsUnidentified() {
		t.Error("0000:0000 must read as unidentified")
	}
	if got := c3.HexDescription(); got != "0000:0000" {
		t.Errorf("hex = %q", got)
	}
	if mustDevice(t, telemetry, PortC1).IsUnidentified() {
		t.Error("C1 is identified")
	}
}

func TestShortB4YieldsFewerPortsRatherThanAGuess(t *testing.T) {
	telemetry := telemetryWithB4(t, b4C1AndC2[:8])
	if got := mustDevice(t, telemetry, PortC1).HexDescription(); got != "05AC:7309" {
		t.Errorf("C1 hex = %q", got)
	}
	if got := mustDevice(t, telemetry, PortC2).HexDescription(); got != "05AC:7518" {
		t.Errorf("C2 hex = %q", got)
	}
	if c3 := mustPort(t, telemetry, PortC3); c3.ConnectedDevice != nil {
		t.Errorf("C3 device = %v, want nil", c3.ConnectedDevice)
	}
}

func TestB4IsNotFiledAsUnknown(t *testing.T) {
	telemetry := telemetryWithB4(t, b4C1AndC2)
	if _, ok := telemetry.UnknownFields[FieldB4]; ok {
		t.Error("B4 must not be an unknown field")
	}
	if got, ok := telemetry.AllFields.Field(FieldB4); !ok || !reflect.DeepEqual(got, b4C1AndC2) {
		t.Errorf("allFields B4 = %x/%v", got, ok)
	}
	// A typed B4 block is also accepted.
	wrapped := telemetryFields(
		NewTLV(FieldA5, portStruct(1, 5000, 500, 250)),
		NewTLV(FieldB4, BytesValue(b4C1AndC2).Encoded()),
	)
	fromWrapped := DecodeTelemetry(wrapped, OpcodeReadAll, commandEpoch())
	if got := mustDevice(t, fromWrapped, PortC1).HexDescription(); got != "05AC:7309" {
		t.Errorf("typed B4 C1 = %q", got)
	}
}

// S1-S8: the settings snapshot.
func TestFullSettingsSnapshotDecodes(t *testing.T) {
	settings := decodeSettingsOf(t, telemetryFields(
		NewTLV(FieldA8, U8Value(1).Encoded()),
		NewTLV(FieldA9, U8Value(0x50).Encoded()),
		NewTLV(FieldAA, U8Value(1).Encoded()),
		NewTLV(FieldAF, U8Value(3).Encoded()),
		NewTLV(FieldB2, U8Value(1).Encoded()),
	))
	if value, ok := settings.ScreenTimeoutCode(); !ok || value != 1 {
		t.Errorf("timeout = %d/%v", value, ok)
	}
	if value, ok := settings.BrightnessPercent(); !ok || value != 80 {
		t.Errorf("brightness = %d/%v", value, ok)
	}
	if value, ok := settings.ModeCode(); !ok || value != 1 {
		t.Errorf("mode = %d/%v", value, ok)
	}
	if value, ok := settings.OrientationCode(); !ok || value != 3 {
		t.Errorf("orientation = %d/%v", value, ok)
	}
	if value, ok := settings.GyroEnabled(); !ok || !value {
		t.Errorf("gyro = %v/%v", value, ok)
	}
	if settings.IsEmpty() {
		t.Error("snapshot should not be empty")
	}
}

func TestGyroscopeOffDecodesAsFalse(t *testing.T) {
	settings := decodeSettingsOf(t, telemetryFields(NewTLV(FieldB2, U8Value(0).Encoded())))
	if value, ok := settings.GyroEnabled(); !ok || value {
		t.Errorf("gyro = %v/%v, want false/true", value, ok)
	}
}

func TestSettingByteReadsBothWrappedAndBareShapes(t *testing.T) {
	bare := decodeSettingsOf(t, telemetryFields(NewTLV(FieldA9, []byte{0x50})))
	if value, ok := bare.BrightnessPercent(); !ok || value != 80 {
		t.Errorf("bare brightness = %d/%v", value, ok)
	}
	wrapped := decodeSettingsOf(t, telemetryFields(NewTLV(FieldA9, BytesValue([]byte{0x50}).Encoded())))
	if value, ok := wrapped.BrightnessPercent(); !ok || value != 80 {
		t.Errorf("wrapped brightness = %d/%v", value, ok)
	}
}

func TestImplausibleBrightnessIsDroppedNotShown(t *testing.T) {
	settings := decodeSettingsOf(t, telemetryFields(
		NewTLV(FieldA9, U8Value(0xFF).Encoded()),
		NewTLV(FieldAA, U8Value(0x04).Encoded()),
	))
	if _, ok := settings.BrightnessPercent(); ok {
		t.Error("0xFF must not be shown as a percentage")
	}
	if value, ok := settings.ModeCode(); !ok || value != 4 {
		t.Errorf("mode = %d/%v, want 4", value, ok)
	}
}

func TestWiderSettingShapeIsRefusedRatherThanTruncated(t *testing.T) {
	settings := decodeSettingsOf(t, telemetryFields(NewTLV(FieldA9, U16Value(80).Encoded())))
	if _, ok := settings.BrightnessPercent(); ok {
		t.Error("a u16 brightness must not be squeezed into a byte")
	}
	if !settings.IsEmpty() {
		t.Errorf("snapshot should be empty, got %+v", settings)
	}
}

func TestOutOfRangeEnumsAreDroppedRatherThanInvented(t *testing.T) {
	settings := decodeSettingsOf(t, telemetryFields(
		NewTLV(FieldA8, U8Value(5).Encoded()),
		NewTLV(FieldAF, U8Value(4).Encoded()),
		NewTLV(FieldB2, U8Value(2).Encoded()),
	))
	if settings.ScreenTimeout != nil || settings.ScreenOrientation != nil || settings.GyroscopeEnabled != nil {
		t.Errorf("out-of-range values decoded: %+v", settings)
	}
	if !settings.IsEmpty() {
		t.Error("snapshot should be empty")
	}
}

func TestConfirmedSettingsAreNotFiledAsUnknown(t *testing.T) {
	payload := telemetryFields(
		NewTLV(FieldA8, []byte{1}),
		NewTLV(FieldA9, []byte{50}),
		NewTLV(FieldAF, []byte{2}),
		NewTLV(FieldB2, []byte{1}),
	)
	telemetry := DecodeTelemetry(payload, OpcodeReadAll, commandEpoch())
	for _, id := range []byte{FieldA8, FieldA9, FieldAF, FieldB2} {
		if _, ok := telemetry.UnknownFields[id]; ok {
			t.Errorf("field 0x%02X must not be unknown", id)
		}
	}
}

func TestFrameWithoutSettingsIDsReportsNoSnapshot(t *testing.T) {
	telemetry := DecodeTelemetry(telemetryFields(NewTLV(FieldA5, portStruct(1, 9000, 2000, 1800))), OpcodeRealtimeReport, commandEpoch())
	if telemetry.Settings != nil {
		t.Error("realtime report must not fabricate settings")
	}
}

// A frame that names settings ids but whose values are unreadable yields an
// empty but present snapshot, distinct from no snapshot at all.
func TestPresentButEmptySettingsSnapshot(t *testing.T) {
	telemetry := DecodeTelemetry(telemetryFields(NewTLV(FieldA8, U8Value(9).Encoded())), OpcodeReadAll, commandEpoch())
	if telemetry.Settings == nil {
		t.Fatal("snapshot should be present")
	}
	if !telemetry.Settings.IsEmpty() {
		t.Error("snapshot should be empty")
	}
}

// S8: device info leaves implausible fields empty.
func TestDeviceInfoLeavesImplausibleFieldsNil(t *testing.T) {
	info := DecodeDeviceInfo(NewPayload(bytePtr(0), []TLV{
		NewTLV(FieldA2, []byte{0xFF, 0xFE}),
		NewTLV(FieldA4, []byte("SHORT")),
	}))
	if info.ProductName != "" || info.SerialNumber != "" || info.MACAddress != "" {
		t.Errorf("info = %+v, want empty fields", info)
	}
	if !info.IsEmpty() {
		t.Error("IsEmpty = false")
	}
	if info := DecodeDeviceInfo(NewPayload(nil, nil)); info.IsEmpty() != true {
		t.Error("a payload without base-info fields yields an empty DeviceInfo")
	}
}

// K1/K2: the inferred countdown layout.
func TestRunningCountdownOnlyWhileStatusSaysSo(t *testing.T) {
	idle, ok := ParsePortControl([]byte{0x01, 0x00, 0x2C, 0x01, 0, 0, 0x2C, 0x01, 0, 0, 0x02, 0x01})
	if !ok {
		t.Fatal("idle control struct rejected")
	}
	if _, _, running := idle.RunningCountdown(); running {
		t.Error("idle port has a running countdown")
	}
	if !idle.MatchesIdleDefault() {
		t.Error("idle struct should match the idle default")
	}

	running, ok := ParsePortControl([]byte{0x01, 0x01, 0x10, 0x0E, 0, 0, 0x08, 0x07, 0, 0, 0x02, 0x01})
	if !ok {
		t.Fatal("running control struct rejected")
	}
	total, remaining, live := running.RunningCountdown()
	if !live || total != 3600 || remaining != 1800 {
		t.Errorf("countdown = %d/%d/%v, want 3600/1800/true", total, remaining, live)
	}
	if running.MatchesIdleDefault() {
		t.Error("running struct should not match the idle default")
	}
	// Remaining > total is refused.
	if _, _, ok := (&PortControl{CountdownTaskStatus: 1, CountdownTotal: 10, CountdownRemaining: 20}).RunningCountdown(); ok {
		t.Error("remaining > total must not be a running countdown")
	}
}

func TestPortControlRejectsShortAndCarriesExtraBytes(t *testing.T) {
	if _, ok := ParsePortControl(make([]byte, 11)); ok {
		t.Error("an 11-byte control struct must be refused")
	}
	long := append(append(IdleControlPrefix(), 0x02, 0x01), 0xAA, 0xBB)
	control, ok := ParsePortControl(long)
	if !ok {
		t.Fatal("long control struct rejected")
	}
	if !reflect.DeepEqual(control.ExtraBytes, []byte{0xAA, 0xBB}) {
		t.Errorf("extra = %x", control.ExtraBytes)
	}
	if control.Cable() != CableEPR240W || control.CableCode != 0x02 {
		t.Errorf("cable = %v", control.Cable())
	}
	if profile, ok := control.ChargingProfile(); !ok || profile != ChargingProfileApplePD {
		t.Errorf("profile = %v/%v", profile, ok)
	}
}

func TestChargingProfileCodesFromApp324(t *testing.T) {
	cases := []struct {
		code byte
		want ChargingProfile
		ok   bool
	}{
		{0x00, 0, false},
		{0x01, ChargingProfileApplePD, true},
		{0x02, ChargingProfileSamsungFast, true},
		{0x03, ChargingProfileSamsungSuperFast, true},
		{0x04, ChargingProfile(0x04), true},
		{0x05, ChargingProfileHuaweiSCP, true},
		{0x06, ChargingProfileXiaomiHyperCharge, true},
		{0x7F, ChargingProfile(0x7F), true},
	}
	for _, tc := range cases {
		got, ok := ParseChargingProfile(tc.code)
		if ok != tc.ok || got != tc.want {
			t.Errorf("ParseChargingProfile(0x%02X) = %v/%v, want %v/%v", tc.code, got, ok, tc.want, tc.ok)
		}
	}
	if label := ChargingProfileHuaweiSCP.Label(); label != "SCP" {
		t.Errorf("Huawei label = %q", label)
	}
}

func TestUSBDDeviceIDSentinels(t *testing.T) {
	noIdentity := USBDeviceID{VendorID: USBEmptyVendorID, ProductID: USBEmptyProductID}
	if !noIdentity.IsNoIdentity() || noIdentity.IsUnidentified() || noIdentity.IsNamed() {
		t.Error("FFFA:FFFB must be no-identity only")
	}
	unidentified := USBDeviceID{}
	if unidentified.IsNoIdentity() || !unidentified.IsUnidentified() || unidentified.IsNamed() {
		t.Error("0000:0000 must be unidentified only")
	}
	named := USBDeviceID{VendorID: 0x05AC, ProductID: 0x7309}
	if named.IsNoIdentity() || named.IsUnidentified() || !named.IsNamed() {
		t.Error("05AC:7309 must be named")
	}
	if got := named.HexDescription(); got != "05AC:7309" {
		t.Errorf("hex = %q", got)
	}
}

func TestCableCapabilityLabels(t *testing.T) {
	cases := map[CableCapability]string{
		CableMax60W:           "3A · 60 W",
		CableMax100W:          "5A · 100 W",
		CableEPR240W:          "EPR · 240 W",
		CableCapability(0x7E): "Unknown (0x7E)",
	}
	for capability, want := range cases {
		got, ok := capability.Label()
		if !ok || got != want {
			t.Errorf("label(0x%02X) = %q/%v, want %q", capability.Code(), got, ok, want)
		}
	}
	if label, ok := CableNone.Label(); ok || label != "" {
		t.Errorf("CableNone label = %q/%v, want no label", label, ok)
	}
	if !CableEPR240W.IsEPR() || CableMax60W.IsEPR() || !CableNone.IsNone() {
		t.Error("cable predicates are wrong")
	}
}

// The product bridge: readings carry the confirmed identity and hide sentinels.
func TestProductReadingMapping(t *testing.T) {
	payload := telemetryFields(
		NewTLV(FieldA5, portStruct(1, 20000, 3250, 6500)),
		NewTLV(FieldA6, portStruct(0, 20000, 3250, 6500)), // stale behind an off flag
		NewTLV(FieldA7, portStruct(1, 9000, 2200, 1980)),
		NewTLV(FieldAC, controlStruct(0x02, 0x01)),
		NewTLV(FieldAE, controlStruct(0x01, 0x00)),
		NewTLV(FieldB4, b4C1AndC2),
	)
	telemetry := DecodeTelemetry(payload, OpcodeRealtimeReport, commandEpoch())
	reading := telemetry.ProductReading()

	if reading.Product != product.ProductA2687 {
		t.Errorf("product = %v", reading.Product)
	}
	if len(reading.Ports) != 3 {
		t.Fatalf("ports = %d, want 3", len(reading.Ports))
	}
	c1, ok := reading.Port(product.PortC1)
	if !ok {
		t.Fatal("missing C1")
	}
	if !c1.Enabled || c1.Status != 1 {
		t.Errorf("C1 enabled/status = %v/%d", c1.Enabled, c1.Status)
	}
	if c1.Volts != 20.0 || c1.Amps != 3.25 || c1.Watts != 65.0 {
		t.Errorf("C1 = %v/%v/%v", c1.Volts, c1.Amps, c1.Watts)
	}
	if c1.Cable != "EPR · 240 W" || !c1.EPR || c1.Protocol != "Apple PD" {
		t.Errorf("C1 cable/EPR/protocol = %q/%v/%q", c1.Cable, c1.EPR, c1.Protocol)
	}
	if c1.VID != 0x05AC || c1.PID != 0x7309 {
		t.Errorf("C1 VID/PID = %04X:%04X", c1.VID, c1.PID)
	}

	c2, _ := reading.Port(product.PortC2)
	if c2.Enabled {
		t.Error("C2 should be off")
	}
	if c2.Watts != 0 || c2.Volts != 0 || c2.Amps != 0 {
		t.Errorf("an off port must contribute no reading, got %v/%v/%v", c2.Volts, c2.Amps, c2.Watts)
	}
	if c2.VID != 0x05AC || c2.PID != 0x7518 {
		t.Errorf("C2 identity = %04X:%04X", c2.VID, c2.PID)
	}

	c3, _ := reading.Port(product.PortC3)
	if c3.VID != 0 || c3.PID != 0 {
		t.Errorf("C3 no-identity must map to zero VID/PID, got %04X:%04X", c3.VID, c3.PID)
	}
	if c3.Cable != "5A · 100 W" || c3.Protocol != "" {
		t.Errorf("C3 cable/protocol = %q/%q", c3.Cable, c3.Protocol)
	}

	if reading.TotalWatts != 84.8 && reading.TotalWatts != 84.80000000000001 {
		t.Errorf("totalWatts = %v, want 65+19.8", reading.TotalWatts)
	}
	if !reading.ReceivedAt.Equal(commandEpoch()) {
		t.Errorf("receivedAt = %v", reading.ReceivedAt)
	}
}

func TestProductReadingPartialFrame(t *testing.T) {
	payload := telemetryFields(NewTLV(FieldA5, portStruct(1, 5000, 1000, 500)))
	reading := DecodeTelemetry(payload, OpcodeRealtimeReport, commandEpoch()).ProductReading()
	// The product model addresses ports by index, so all three slots exist even
	// when the frame mentioned only C1.
	if len(reading.Ports) != 3 {
		t.Fatalf("ports = %d, want 3", len(reading.Ports))
	}
	c1, ok := reading.Port(product.PortC1)
	if !ok || !c1.Enabled || c1.Watts != 5 {
		t.Errorf("C1 = %+v/%v", c1, ok)
	}
	c2, ok := reading.Port(product.PortC2)
	if !ok || c2.Enabled || c2.Watts != 0 {
		t.Errorf("C2 = %+v/%v, want a zero slot", c2, ok)
	}
}

// The product bridge for settings: brightness/orientation unchanged, plus the
// device-reported timeout/mode/auto-rotate the UI contract now carries.
func TestProductSettingsMapping(t *testing.T) {
	payload := telemetryFields(
		NewTLV(FieldA8, U8Value(1).Encoded()),
		NewTLV(FieldA9, U8Value(0x50).Encoded()),
		NewTLV(FieldAA, U8Value(1).Encoded()),
		NewTLV(FieldAF, U8Value(3).Encoded()),
		NewTLV(FieldB2, U8Value(1).Encoded()),
	)
	telemetry := DecodeTelemetry(payload, OpcodeReadAll, commandEpoch())
	settings := telemetry.ProductSettings()
	if settings == nil {
		t.Fatal("expected mapped settings")
	}
	if settings.Brightness == nil || *settings.Brightness != 80 {
		t.Errorf("brightness = %v", settings.Brightness)
	}
	if settings.Orientation == nil || *settings.Orientation != "right" {
		t.Errorf("orientation = %v", settings.Orientation)
	}
	if settings.ScreenTimeout == nil || *settings.ScreenTimeout != "1m" {
		t.Errorf("screenTimeout = %v, want 1m", settings.ScreenTimeout)
	}
	if settings.ChargingMode == nil || *settings.ChargingMode != "standard" {
		t.Errorf("chargingMode = %v, want standard", settings.ChargingMode)
	}
	if settings.AutoRotate == nil || !*settings.AutoRotate {
		t.Errorf("autoRotate = %v, want true", settings.AutoRotate)
	}
	// The frozen model has no faithful field for these: do not invent one.
	if settings.Language != nil || settings.AutoLock != nil || settings.ScreenOn != nil ||
		settings.Theme != nil || settings.FixedAllocation != nil || settings.PortControls != nil {
		t.Errorf("unexpected settings fields: %+v", settings)
	}

	if got := DecodeTelemetry(telemetryFields(NewTLV(FieldA5, portStruct(1, 5000, 0, 0))), OpcodeRealtimeReport, commandEpoch()).ProductSettings(); got != nil {
		t.Errorf("a frame with no settings ids mapped to %+v", got)
	}
	// A present-but-empty snapshot maps to a non-nil empty product.Settings.
	empty := DecodeTelemetry(telemetryFields(NewTLV(FieldA8, U8Value(9).Encoded())), OpcodeReadAll, commandEpoch()).ProductSettings()
	if empty == nil {
		t.Error("an unreadable settings snapshot should still map to a present value")
	}
}

// The stable strings the UI/session contract expects for the new fields.
func TestProductSettingsStringVocabulary(t *testing.T) {
	timeoutCases := []struct {
		code byte
		want string
	}{
		{0, "30s"},
		{1, "1m"},
		{2, "5m"},
		{3, "30m"},
		{4, "12h"},
	}
	for _, tc := range timeoutCases {
		settings := (DeviceSettings{ScreenTimeout: bytePtr(tc.code)})
		value := (&ChargerTelemetry{Settings: &settings}).ProductSettings().ScreenTimeout
		if value == nil || *value != tc.want {
			t.Errorf("screenTimeout code %d = %v, want %q", tc.code, value, tc.want)
		}
	}
	// Unnamed codes are raw decimal strings, never guessed labels.
	if got := productScreenTimeout(9); got != "9" {
		t.Errorf("productScreenTimeout(9) = %q, want \"9\"", got)
	}

	modeCases := []struct {
		code byte
		want string
	}{
		{0, "ai"},
		{1, "standard"},
		{2, "custom"},
		{4, "4"},
		{7, "7"},
		{0xFF, "255"},
	}
	for _, tc := range modeCases {
		settings := (DeviceSettings{ChargingMode: bytePtr(tc.code)})
		value := (&ChargerTelemetry{Settings: &settings}).ProductSettings().ChargingMode
		if value == nil || *value != tc.want {
			t.Errorf("chargingMode code %d = %v, want %q", tc.code, value, tc.want)
		}
	}

	for _, enabled := range []bool{true, false} {
		settings := (DeviceSettings{GyroscopeEnabled: boolPtr(enabled)})
		value := (&ChargerTelemetry{Settings: &settings}).ProductSettings().AutoRotate
		if value == nil || *value != enabled {
			t.Errorf("autoRotate %v = %v", enabled, value)
		}
	}

	// A snapshot with none of the new ids keeps the new fields nil.
	onlyBrightness := (DeviceSettings{ScreenBrightness: bytePtr(50)})
	mapped := (&ChargerTelemetry{Settings: &onlyBrightness}).ProductSettings()
	if mapped.ScreenTimeout != nil || mapped.ChargingMode != nil || mapped.AutoRotate != nil {
		t.Errorf("unreported fields mapped: %+v", mapped)
	}
}

// The per-port control bridge: switch state always, countdown minutes only when
// the inferred bytes pass the running-countdown check.
func TestProductPortControlsMapping(t *testing.T) {
	runningControl := append(IdleControlPrefix(), 0x02, 0x01)
	copy(runningControl[1:], []byte{0x01})  // countdown task running
	copy(runningControl[2:6], u32LE(3600))  // total
	copy(runningControl[6:10], u32LE(1800)) // remaining
	payload := telemetryFields(
		NewTLV(FieldA5, portStruct(1, 20000, 3250, 6500)),
		NewTLV(FieldA6, portStruct(0, 0, 0, 0)),
		NewTLV(FieldAC, BytesValue(runningControl).Encoded()),
	)
	controls := DecodeTelemetry(payload, OpcodeRealtimeReport, commandEpoch()).ProductPortControls()
	if len(controls) != 2 {
		t.Fatalf("controls = %d, want 2", len(controls))
	}
	c1, ok := controls[product.PortC1]
	if !ok || !c1.Enabled {
		t.Errorf("C1 = %+v/%v", c1, ok)
	}
	if c1.CountdownMinutes != 30 || c1.TimerMinutes != 60 {
		t.Errorf("C1 countdown/timer = %d/%d, want 30/60", c1.CountdownMinutes, c1.TimerMinutes)
	}
	c2, ok := controls[product.PortC2]
	if !ok || c2.Enabled || c2.CountdownMinutes != 0 || c2.TimerMinutes != 0 {
		t.Errorf("C2 = %+v/%v", c2, ok)
	}
	if got := DecodeTelemetry(telemetryFields(NewTLV(FieldA1, []byte{0x21})), OpcodeReadAll, commandEpoch()).ProductPortControls(); got != nil {
		t.Errorf("a frame without ports mapped to %+v", got)
	}
	// An idle control struct (no running countdown) reports no minutes.
	idle := telemetryFields(
		NewTLV(FieldA5, portStruct(1, 5000, 1000, 500)),
		NewTLV(FieldAC, controlStruct(0x01, 0x01)),
	)
	idleControls := DecodeTelemetry(idle, OpcodeRealtimeReport, commandEpoch()).ProductPortControls()
	if value := idleControls[product.PortC1]; value.CountdownMinutes != 0 || value.TimerMinutes != 0 {
		t.Errorf("idle minutes = %d/%d", value.CountdownMinutes, value.TimerMinutes)
	}
}

// The Link facade: settings carry-forward within a link, cleared on reset.
func TestLinkSettingsCarryForward(t *testing.T) {
	secret := make([]byte, 32)
	for i := range secret {
		secret[i] = byte(i)
	}
	keys, err := NewKeysFromSecret(secret)
	if err != nil {
		t.Fatalf("NewKeysFromSecret: %v", err)
	}
	link := NewLink(keys)

	frameWithSettings := telemetryFrame(t, OpcodeReadAll, keys,
		NewTLV(FieldA5, portStruct(1, 20000, 3250, 6500)),
		NewTLV(FieldA9, U8Value(0x50).Encoded()),
		NewTLV(FieldAF, U8Value(3).Encoded()),
	)
	reading, settings, err := link.DecodeTelemetry(frameWithSettings)
	if err != nil {
		t.Fatalf("DecodeTelemetry: %v", err)
	}
	if len(reading.Ports) != 3 || !reading.Ports[0].Enabled || reading.Ports[0].Watts != 65.0 {
		t.Errorf("reading = %+v", reading)
	}
	if settings == nil || settings.Brightness == nil || *settings.Brightness != 80 {
		t.Fatalf("settings = %+v", settings)
	}

	// A frame that omits the settings ids inherits the snapshot of the link.
	frameWithout := telemetryFrame(t, OpcodeRealtimeReport, keys,
		NewTLV(FieldA5, portStruct(1, 9000, 2000, 1800)),
	)
	_, carried, err := link.DecodeTelemetry(frameWithout)
	if err != nil {
		t.Fatalf("DecodeTelemetry: %v", err)
	}
	if carried == nil || carried.Brightness == nil || *carried.Brightness != 80 {
		t.Errorf("carried settings = %+v", carried)
	}

	// A present-but-unreadable snapshot overrides the carried value with a dash.
	frameUnreadable := telemetryFrame(t, OpcodeReadAll, keys,
		NewTLV(FieldA5, portStruct(1, 9000, 2000, 1800)),
		NewTLV(FieldA9, U16Value(80).Encoded()),
	)
	_, overridden, err := link.DecodeTelemetry(frameUnreadable)
	if err != nil {
		t.Fatalf("DecodeTelemetry: %v", err)
	}
	if overridden == nil {
		t.Fatal("the empty snapshot should be present")
	}
	if overridden.Brightness != nil {
		t.Errorf("brightness = %v, want nil after an unreadable snapshot", overridden.Brightness)
	}

	// Reset (a new handshake) clears it: a settings-less frame yields nil again.
	link.ResetSettings()
	_, cleared, err := link.DecodeTelemetry(frameWithout)
	if err != nil {
		t.Fatalf("DecodeTelemetry: %v", err)
	}
	if cleared != nil {
		t.Errorf("settings after reset = %+v, want nil", cleared)
	}
}

// Link frames must fail closed on a wrong key and still decode unencrypted
// reports.
func TestLinkRejectsWrongKeyAndAcceptsPlaintext(t *testing.T) {
	secret := make([]byte, 32)
	for i := range secret {
		secret[i] = byte(i)
	}
	keys, err := NewKeysFromSecret(secret)
	if err != nil {
		t.Fatalf("NewKeysFromSecret: %v", err)
	}
	tampered := telemetryFrame(t, OpcodeRealtimeReport, keys, NewTLV(FieldA5, portStruct(1, 5000, 1000, 500)))
	tampered[len(tampered)-2] ^= 0x01
	tampered[len(tampered)-1] = FrameChecksum(tampered[:len(tampered)-1])
	if _, _, err := NewLink(keys).DecodeTelemetry(tampered); err == nil {
		t.Error("tampered frame accepted")
	} else if kind := cryptoErrKind(t, err); kind != CryptoErrAuthenticationFailed {
		t.Errorf("kind = %v", kind)
	}

	plaintext := append([]byte{0x00}, EncodeTLVs([]TLV{NewTLV(FieldA5, portStruct(1, 5000, 1000, 500))})...)
	unencrypted := EncodePacket(NewFrame(SessionResponsePattern(), (OpcodeRealtimeReport | FlagResponse), plaintext))
	reading, _, err := NewLink(keys).DecodeTelemetry(unencrypted)
	if err != nil {
		t.Fatalf("plaintext frame: %v", err)
	}
	if len(reading.Ports) != 3 {
		t.Errorf("ports = %d, want 3", len(reading.Ports))
	}
	if c1, ok := reading.Port(product.PortC1); !ok || c1.Watts != 5 {
		t.Errorf("C1 = %+v/%v", c1, ok)
	}

	// A frame sealed with the static negotiation key is accepted through the
	// fallback, mirroring the session's key choice.
	fallbackFrame := negotiationResponseFrame(t, OpcodeRealtimeReport, plaintext, NegotiationKeys())
	fallbackReading, _, err := NewLink(keys).DecodeTelemetry(fallbackFrame)
	if err != nil {
		t.Fatalf("negotiation-key fallback: %v", err)
	}
	if c1, ok := fallbackReading.Port(product.PortC1); !ok || c1.Watts != 5 {
		t.Errorf("fallback C1 = %+v/%v", c1, ok)
	}
}

// DecodeResponse is the primitive a session uses for command confirmation.
func TestDecodeResponse(t *testing.T) {
	secret := make([]byte, 32)
	keys, err := NewKeysFromSecret(secret)
	if err != nil {
		t.Fatalf("NewKeysFromSecret: %v", err)
	}
	okFrame := sessionResponseFrame(t, OpcodePortOutput, []byte{0x00}, keys)
	frame, payload, err := DecodeResponse(okFrame, keys)
	if err != nil {
		t.Fatalf("DecodeResponse: %v", err)
	}
	if frame.Opcode() != OpcodePortOutput || !payload.IsOK() {
		t.Errorf("response = %+v / %+v", frame, payload)
	}
	refusal := sessionResponseFrame(t, OpcodePortOutput, []byte{0x11}, keys)
	_, payload, err = DecodeResponse(refusal, keys)
	if err != nil {
		t.Fatalf("DecodeResponse: %v", err)
	}
	if payload.IsOK() {
		t.Error("a 0x11 refusal must not be OK")
	}
	if status, ok := payload.StatusCode(); !ok || status != 0x11 {
		t.Errorf("status = 0x%02X/%v, want 0x11", status, ok)
	}
}

// A bind ack carries no port data: the raw state keeps it, and the product
// bridge reports it as ErrNoPortData so the session keeps the previous reading.
func TestLinkKeepsFramesWithoutPortData(t *testing.T) {
	secret := make([]byte, 32)
	keys, err := NewKeysFromSecret(secret)
	if err != nil {
		t.Fatalf("NewKeysFromSecret: %v", err)
	}
	frame := telemetryFrame(t, OpcodeBindSuccess, keys, NewTLV(FieldA1, []byte{0x31}))
	state, err := NewLink(keys).DecodeStateAt(frame, commandEpoch())
	if err != nil {
		t.Fatalf("DecodeStateAt: %v", err)
	}
	if state.HasPortData() {
		t.Error("bind ack must not carry port data")
	}
	if got, ok := state.AllFields.Field(FieldA1); !ok || !reflect.DeepEqual(got, []byte{0x31}) {
		t.Errorf("A1 = %x/%v", got, ok)
	}
	reading, _, err := NewLink(keys).DecodeTelemetryAt(frame, commandEpoch())
	if !errors.Is(err, ErrNoPortData) {
		t.Errorf("DecodeTelemetryAt error = %v, want ErrNoPortData", err)
	}
	if len(reading.Ports) != 0 {
		t.Errorf("reading ports = %d, want 0", len(reading.Ports))
	}
}

// telemetryFrame builds an encrypted device session frame carrying a status-0
// payload plus the given fields.
func telemetryFrame(tb testing.TB, opcode uint16, keys Keys, fields ...TLV) []byte {
	tb.Helper()
	plaintext := append([]byte{0x00}, EncodeTLVs(fields)...)
	return sessionResponseFrame(tb, opcode, plaintext, keys)
}

// errors.Is / errors.As work through the typed error wrappers.
func TestErrorTaxonomy(t *testing.T) {
	// A buffer that is neither a status-prefixed TLV list nor a TLV list fails
	// all three heuristic branches.
	if _, err := ParsePayload([]byte{0x10, 0xA1, 0x04, 0x01}); err == nil {
		t.Error("expected a TLV error")
	} else {
		var tlvErr *TLVError
		if !errors.As(err, &tlvErr) {
			t.Errorf("error type = %T", err)
		}
	}
	// A lone non-zero byte parses as a refusal with no fields; that is by design.
	payload, err := ParsePayload([]byte{0x11})
	if err != nil {
		t.Fatalf("ParsePayload(0x11): %v", err)
	}
	if status, ok := payload.StatusCode(); !ok || status != 0x11 || payload.IsOK() {
		t.Errorf("bare refusal = %+v", payload)
	}
}
