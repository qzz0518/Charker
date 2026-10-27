package a2687

import (
	"reflect"
	"testing"
	"time"
)

const commandEpochHex = "00f15365"

// M1: the whole charging-mode plaintext is pinned byte for byte.
func TestChargingModePlaintextPinned(t *testing.T) {
	message := SetChargingMode(ChargingModeStandard, commandEpoch())
	if message.Group != GroupSession {
		t.Errorf("group = 0x%02X, want 0x0F", message.Group)
	}
	if message.Opcode != OpcodeChargingMode {
		t.Errorf("opcode = 0x%04X, want 0x0206", message.Opcode)
	}
	if message.Encryption != EncryptionSession {
		t.Errorf("encryption = %v, want session", message.Encryption)
	}
	if !message.ExpectsResponse {
		t.Error("a session write expects a response")
	}
	// a1 01 21   action, the bare 0x21 every session command carries
	// a2 02 01 01  typed u8, the mode
	// fe 04 …      the bare four-byte epoch
	want := "a10121a2020101fe04" + commandEpochHex
	if got := hexStr(message.Plaintext); got != want {
		t.Errorf("plaintext = %s, want %s", got, want)
	}
}

// M2: each mode sends its own code (custom is 2, not the Smi-tagged 4).
func TestEachChargingModeSendsItsOwnCode(t *testing.T) {
	cases := []struct {
		mode ChargingMode
		code string
	}{
		{ChargingModeAI, "00"},
		{ChargingModeStandard, "01"},
		{ChargingModeCustom, "02"},
		{ChargingMode(0x04), "04"},
		{ChargingMode(0x07), "07"},
		{ChargingMode(0xFF), "ff"},
	}
	for _, tc := range cases {
		want := "a10121a20201" + tc.code + "fe04" + commandEpochHex
		if got := hexStr(SetChargingMode(tc.mode, commandEpoch()).Plaintext); got != want {
			t.Errorf("mode %v plaintext = %s, want %s", tc.mode, got, want)
		}
	}
}

// M3: custom mode sends mode 2 plus the five power bytes.
func TestCustomModeSendsModeTwoAndThePowerArray(t *testing.T) {
	power := NewCustomChargingPower(true, [3]byte{100, 40, 20})
	if !power.IsValid() {
		t.Error("100/40/20 should be valid")
	}
	want := "a10121a2020102a306040101642814fe04" + commandEpochHex
	if got := hexStr(SetCustomChargingMode(power, commandEpoch()).Plaintext); got != want {
		t.Errorf("custom plaintext = %s, want %s", got, want)
	}

	invalid := []CustomChargingPower{
		NewCustomChargingPower(false, [3]byte{100, 50, 20}), // 170 W total
		NewCustomChargingPower(false, [3]byte{10, 0, 0}),    // inside the 1-14 W gap
		NewCustomChargingPower(false, [3]byte{0, 141, 0}),   // above 140
	}
	for _, value := range invalid {
		if value.IsValid() {
			t.Errorf("%v should be invalid", value.Watts)
		}
	}
	valid := []CustomChargingPower{
		NewCustomChargingPower(false, [3]byte{0, 0, 0}),
		NewCustomChargingPower(false, [3]byte{140, 0, 0}),
		NewCustomChargingPower(true, [3]byte{100, 40, 20}),
		NewCustomChargingPower(false, [3]byte{15, 0, 0}),
	}
	for _, value := range valid {
		if !value.IsValid() {
			t.Errorf("%v should be valid", value.Watts)
		}
	}
	if got, want := power.Bytes(), []byte{1, 1, 100, 40, 20}; !reflect.DeepEqual(got, want) {
		t.Errorf("bytes = %v, want %v", got, want)
	}
	if got := NewCustomChargingPower(false, [3]byte{}).Number; got != 1 {
		t.Errorf("default profile number = %d, want 1", got)
	}
}

// M4: fixed allocation uses the single-setting shape; its read-back is unknown.
func TestFixedAllocationUsesTheSingleSettingShape(t *testing.T) {
	if got := FixedAllocationSetting(FixedAllocationC1Priority).Opcode(); got != 0x0205 {
		t.Errorf("opcode = 0x%04X, want 0x0205", got)
	}
	want := "a10121a2020101fe04" + commandEpochHex
	if got := hexStr(SetChargerSetting(FixedAllocationSetting(FixedAllocationDualLaptop), commandEpoch()).Plaintext); got != want {
		t.Errorf("plaintext = %s, want %s", got, want)
	}
	if _, defined := FixedAllocationSetting(FixedAllocationC1Priority).ReadbackMatches(nil); defined {
		t.Error("fixed allocation has no discovered read-back")
	}
	if _, defined := FixedAllocationSetting(FixedAllocationC1Priority).ReadbackMatches(&DeviceSettings{}); defined {
		t.Error("fixed allocation read-back must stay undefined")
	}
}

// M5: the display-setting family — same shape, different opcode and value.
func TestChargerSettingFamily(t *testing.T) {
	cases := []struct {
		name    string
		setting ChargerSetting
		opcode  uint16
		value   byte
	}{
		{"languageEnglish", LanguageSetting(DeviceLanguageEnglish), 0x0202, 0},
		{"languageZh", LanguageSetting(DeviceLanguageSimplifiedChinese), 0x0202, 1},
		{"timeout1min", ScreenTimeoutSetting(ScreenTimeoutOneMinute), 0x0203, 1},
		{"brightness100", BrightnessSetting(100), 0x0204, 100},
		{"brightness25", BrightnessSetting(25), 0x0204, 25},
		{"orientationRight", OrientationSetting(ScreenOrientationRight), 0x020B, 3},
		{"gyroOn", GyroscopeSetting(true), 0x020D, 1},
		{"gyroOff", GyroscopeSetting(false), 0x020D, 0},
		{"fixedAllocation", FixedAllocationSetting(FixedAllocationDualLaptop), 0x0205, 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			message := SetChargerSetting(tc.setting, commandEpoch())
			if message.Group != GroupSession {
				t.Errorf("group = 0x%02X, want 0x0F", message.Group)
			}
			if message.Opcode != tc.opcode {
				t.Errorf("opcode = 0x%04X, want 0x%04X", message.Opcode, tc.opcode)
			}
			if message.Encryption != EncryptionSession || !message.ExpectsResponse {
				t.Errorf("encryption=%v expectsResponse=%v", message.Encryption, message.ExpectsResponse)
			}
			want := "a10121a20201" + hexStr([]byte{tc.value}) + "fe04" + commandEpochHex
			if got := hexStr(message.Plaintext); got != want {
				t.Errorf("plaintext = %s, want %s", got, want)
			}
			payload, err := ParsePayload(message.Plaintext)
			if err != nil {
				t.Fatalf("ParsePayload: %v", err)
			}
			typed, ok := payload.Typed(FieldA2)
			if !ok {
				t.Fatal("missing A2")
			}
			if scalar, ok := typed.Scalar(); !ok || scalar != uint32(tc.value) {
				t.Errorf("A2 typed = %+v (scalar %d/%v)", typed, scalar, ok)
			}
		})
	}
}

// M6/M7: the mode argument is typed u8 and the epoch trailer is four bare bytes.
func TestModeArgumentAndEpochTrailerShapes(t *testing.T) {
	payload, err := ParsePayload(SetChargingMode(ChargingModeStandard, commandEpoch()).Plaintext)
	if err != nil {
		t.Fatalf("ParsePayload: %v", err)
	}
	if got, ok := payload.Field(FieldA2); !ok || !reflect.DeepEqual(got, []byte{0x01, 0x01}) {
		t.Errorf("A2 = %v/%v, want 01 01", got, ok)
	}
	if typed, ok := payload.Typed(FieldA2); !ok {
		t.Fatal("missing A2")
	} else if scalar, ok := typed.Scalar(); !ok || scalar != 1 {
		t.Errorf("A2 scalar = %d/%v, want 1/true", scalar, ok)
	}

	trailer, ok := payload.Field(FieldFE)
	if !ok {
		t.Fatal("missing FE")
	}
	if len(trailer) != 4 {
		t.Errorf("trailer length = %d, want 4", len(trailer))
	}
	if !reflect.DeepEqual(trailer, mustHex(t, commandEpochHex)) {
		t.Errorf("trailer = %x, want %x", trailer, mustHex(t, commandEpochHex))
	}
	if trailer[0] == TypedU32Type {
		t.Error("FE must not carry the cover commands' u32 type tag")
	}
}

// M8/M9: port output vectors from the reference implementations.
func TestPortOutputMatchesReferenceImplementations(t *testing.T) {
	cases := []struct {
		name   string
		port   Port
		on     bool
		prefix string
	}{
		{"c1on", PortC1, true, "a10121a2020100a3020101fe04"},
		{"c3off", PortC3, false, "a10121a2020102a3020100fe04"},
		{"c2on", PortC2, true, "a10121a2020101a3020101fe04"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			message := SetPortOutput(tc.port, tc.on, commandEpoch())
			if message.Group != GroupSession || message.Opcode != OpcodePortOutput {
				t.Errorf("group/opcode = 0x%02X/0x%04X", message.Group, message.Opcode)
			}
			if message.Encryption != EncryptionSession {
				t.Errorf("encryption = %v", message.Encryption)
			}
			want := tc.prefix + commandEpochHex
			if got := hexStr(message.Plaintext); got != want {
				t.Errorf("plaintext = %s, want %s", got, want)
			}
		})
	}
}

// M10: the timer countdown is a four-byte little-endian number.
func TestTimerUsesAFourByteLittleEndianCountdown(t *testing.T) {
	message := SetPortTimer(PortC2, 1800, commandEpoch())
	if message.Opcode != OpcodePortTimer {
		t.Errorf("opcode = 0x%04X, want 0x0209", message.Opcode)
	}
	want := "a10121a2020101a3050408070000" + "fe04" + commandEpochHex
	if got := hexStr(message.Plaintext); got != want {
		t.Errorf("plaintext = %s, want %s", got, want)
	}
	// Zero cancels, and must still be a full four-byte block.
	cancel := SetPortTimer(PortC1, 0, commandEpoch())
	payload, err := ParsePayload(cancel.Plaintext)
	if err != nil {
		t.Fatalf("ParsePayload: %v", err)
	}
	a3, ok := payload.Field(FieldA3)
	if !ok || !reflect.DeepEqual(a3, []byte{0x04, 0, 0, 0, 0}) {
		t.Errorf("cancel A3 = %x/%v, want 04 00 00 00 00", a3, ok)
	}
}

// M11: read-all carries the session action and a four-byte epoch.
func TestReadAllCarriesTheSessionActionAndEpoch(t *testing.T) {
	message := ReadAll(commandEpoch())
	if message.Opcode != OpcodeReadAll || message.Encryption != EncryptionSession || !message.ExpectsResponse {
		t.Errorf("message = %+v", message)
	}
	payload, err := ParsePayload(message.Plaintext)
	if err != nil {
		t.Fatalf("ParsePayload: %v", err)
	}
	if a1, ok := payload.Field(FieldA1); !ok || !reflect.DeepEqual(a1, []byte{SessionAction}) {
		t.Errorf("A1 = %x/%v", a1, ok)
	}
	if trailer, ok := payload.Field(FieldFE); !ok || len(trailer) != 4 {
		t.Errorf("FE = %x/%v", trailer, ok)
	}
	want := "a10121fe04" + commandEpochHex
	if got := hexStr(message.Plaintext); got != want {
		t.Errorf("plaintext = %s, want %s", got, want)
	}
}

// The opening-burst builders are pinned by spec-protocol §2.4.
func TestOpeningBurstPlaintexts(t *testing.T) {
	probe := RealtimeProbe("CN", "", commandEpoch())
	if probe.Opcode != OpcodeBindSuccess || probe.Group != GroupSession {
		t.Errorf("probe = %+v", probe)
	}
	if got, want := hexStr(probe.Plaintext), "a10121a20304434ea5020101fe04"+commandEpochHex; got != want {
		t.Errorf("probe plaintext = %s, want %s", got, want)
	}

	trigger := RealtimeTrigger(commandEpoch())
	if trigger.Opcode != OpcodeRealtimeTrigger {
		t.Errorf("trigger opcode = 0x%04X", trigger.Opcode)
	}
	// The A2 block is 9 bytes wrapped in the 0x04 typed-bytes tag, so the TLV
	// value is 10 bytes and the frame holds no room for the extra 00 that the
	// spec-protocol §8.3 table shows (its string is one byte longer than its own
	// length byte; the Swift source and the capture lengths are canonical).
	if got, want := hexStr(trigger.Plaintext), "a10121a20a04010003150101000000fe04"+commandEpochHex; got != want {
		t.Errorf("trigger plaintext = %s, want %s", got, want)
	}
	if len(trigger.Plaintext) != 21 {
		t.Errorf("trigger plaintext length = %d, want 21", len(trigger.Plaintext))
	}
}

// The probe includes the owner id only when one is supplied.
func TestRealtimeProbeOwnerField(t *testing.T) {
	const owner = "0123456789abcdef0123456789abcdef01234567"
	message := RealtimeProbe("CN", owner, commandEpoch())
	payload, err := ParsePayload(message.Plaintext)
	if err != nil {
		t.Fatalf("ParsePayload: %v", err)
	}
	a3, ok := payload.Field(FieldA3)
	if !ok {
		t.Fatal("missing A3")
	}
	if want := BytesValue([]byte(owner)).Encoded(); !reflect.DeepEqual(a3, want) {
		t.Errorf("A3 = %x, want %x", a3, want)
	}
}

// userAuth is a negotiation-group message sealed with the session key.
func TestUserAuthShape(t *testing.T) {
	message := UserAuth("abc", nil, commandEpoch())
	if message.Group != GroupNegotiation || message.Opcode != OpcodeUserAuth {
		t.Errorf("message = %+v", message)
	}
	if message.Encryption != EncryptionSession {
		t.Errorf("encryption = %v, want session", message.Encryption)
	}
	want := "a104" + commandEpochHex + "a203616263"
	if got := hexStr(message.Plaintext); got != want {
		t.Errorf("plaintext = %s, want %s", got, want)
	}
	withPassword := UserAuth("abc", []byte{0x01, 0x02}, commandEpoch())
	payload, err := ParsePayload(withPassword.Plaintext)
	if err != nil {
		t.Fatalf("ParsePayload: %v", err)
	}
	if got, ok := payload.Field(FieldA3); !ok || !reflect.DeepEqual(got, []byte{0x01, 0x02}) {
		t.Errorf("A3 = %x/%v", got, ok)
	}
}

func TestTimestampBytes(t *testing.T) {
	got := TimestampBytes(commandEpoch())
	if want := mustHex(t, commandEpochHex); !reflect.DeepEqual(got, want) {
		t.Errorf("TimestampBytes = %x, want %x", got, want)
	}
	if got := TimestampBytes(commandEpoch().Add(time.Second)); !reflect.DeepEqual(got, []byte{0x01, 0xF1, 0x53, 0x65}) {
		t.Errorf("TimestampBytes+1s = %x", got)
	}
}

// M12-adjacent enum behaviour: codes round-trip and only observed modes claim
// to be observed.
func TestChargingModeCodesAndEvidence(t *testing.T) {
	if got := []ChargingMode{ParseChargingMode(0), ParseChargingMode(1), ParseChargingMode(2)}; !reflect.DeepEqual(got, []ChargingMode{ChargingModeAI, ChargingModeStandard, ChargingModeCustom}) {
		t.Errorf("modes = %v", got)
	}
	for code := 0; code < 256; code++ {
		if got := ParseChargingMode(byte(code)).Code(); got != byte(code) {
			t.Fatalf("code %d round-trips to %d", code, got)
		}
	}
	if !ChargingModeAI.IsObservedOnHardware() || !ChargingModeStandard.IsObservedOnHardware() {
		t.Error("AI and standard were observed on hardware")
	}
	for _, mode := range []ChargingMode{ChargingModeCustom, ChargingMode(4), ChargingMode(0xFF)} {
		if mode.IsObservedOnHardware() {
			t.Errorf("%v must not claim hardware evidence", mode)
		}
	}
	if got := ChargingMode(7).String(); got != "unknown(0x07)" {
		t.Errorf("String = %q", got)
	}
}

func TestSettingEnums(t *testing.T) {
	if got := []DeviceLanguage{DeviceLanguageEnglish, DeviceLanguageSimplifiedChinese, DeviceLanguageJapanese, DeviceLanguageGerman}; !reflect.DeepEqual(got, []DeviceLanguage{0, 1, 2, 3}) {
		t.Errorf("languages = %v", got)
	}
	if got := []ScreenTimeout{ScreenTimeoutThirtySeconds, ScreenTimeoutOneMinute, ScreenTimeoutFiveMinutes, ScreenTimeoutThirtyMinutes, ScreenTimeoutTwelveHours}; !reflect.DeepEqual(got, []ScreenTimeout{0, 1, 2, 3, 4}) {
		t.Errorf("timeouts = %v", got)
	}
	if got := []ScreenOrientation{ScreenOrientationUp, ScreenOrientationLeft, ScreenOrientationDown, ScreenOrientationRight}; !reflect.DeepEqual(got, []ScreenOrientation{0, 1, 2, 3}) {
		t.Errorf("orientations = %v", got)
	}
	if got := []FixedAllocation{FixedAllocationC1Priority, FixedAllocationDualLaptop}; !reflect.DeepEqual(got, []FixedAllocation{0, 1}) {
		t.Errorf("allocations = %v", got)
	}
	if got := ScreenOrientationRight.String(); got != "right" {
		t.Errorf("orientation right = %q", got)
	}
	// These strings are the UI/session vocabulary for the setting; they travel
	// through product.Settings.ScreenTimeout and SetSetting("screenTimeout", ...).
	timeoutStrings := map[ScreenTimeout]string{
		ScreenTimeoutThirtySeconds: "30s",
		ScreenTimeoutOneMinute:     "1m",
		ScreenTimeoutFiveMinutes:   "5m",
		ScreenTimeoutThirtyMinutes: "30m",
		ScreenTimeoutTwelveHours:   "12h",
	}
	for timeout, want := range timeoutStrings {
		if got := timeout.String(); got != want {
			t.Errorf("timeout %d = %q, want %q", uint8(timeout), got, want)
		}
	}
	if got := ScreenTimeout(9).String(); got != "unknown(9)" {
		t.Errorf("unknown timeout = %q", got)
	}
}

// Every setting with a read-back field is confirmed by a matching snapshot and
// refuted by a differing one; language and fixed allocation are undefined.
func TestChargerSettingReadbackMatches(t *testing.T) {
	snapshot := &DeviceSettings{
		ScreenTimeout:     bytePtr(1),
		ScreenBrightness:  bytePtr(100),
		ScreenOrientation: bytePtr(3),
		GyroscopeEnabled:  boolPtr(true),
	}
	cases := []struct {
		setting ChargerSetting
		want    bool
		defined bool
	}{
		{LanguageSetting(DeviceLanguageEnglish), false, false},
		{FixedAllocationSetting(FixedAllocationC1Priority), false, false},
		{ScreenTimeoutSetting(ScreenTimeoutOneMinute), true, true},
		{ScreenTimeoutSetting(ScreenTimeoutFiveMinutes), false, true},
		{BrightnessSetting(100), true, true},
		{BrightnessSetting(25), false, true},
		{OrientationSetting(ScreenOrientationRight), true, true},
		{OrientationSetting(ScreenOrientationUp), false, true},
		{GyroscopeSetting(true), true, true},
		{GyroscopeSetting(false), false, true},
	}
	for _, tc := range cases {
		got, defined := tc.setting.ReadbackMatches(snapshot)
		if got != tc.want || defined != tc.defined {
			t.Errorf("setting %+v readback = %v/%v, want %v/%v", tc.setting, got, defined, tc.want, tc.defined)
		}
	}
	// A nil snapshot cannot confirm or deny anything that has a field.
	if got, defined := ScreenTimeoutSetting(ScreenTimeoutOneMinute).ReadbackMatches(nil); got || defined {
		t.Errorf("nil snapshot readback = %v/%v, want false/false", got, defined)
	}
	// A present-but-empty snapshot yields "no match" with the field defined.
	if got, defined := BrightnessSetting(100).ReadbackMatches(&DeviceSettings{}); got || !defined {
		t.Errorf("empty snapshot readback = %v/%v, want false/true", got, defined)
	}
}
