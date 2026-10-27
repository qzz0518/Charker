package a2687

import (
	"encoding/binary"
	"fmt"
	"time"
)

// ChargingMode is the charger's power-allocation mode: the byte 0x0206 writes
// into A2, and the same byte that comes back in the AA settings field.
//
// The write side is a typed enum while DeviceSettings.ChargingMode stays a raw
// byte on the read side: a code arriving from the charger has to reach a bug
// report exactly as the device sent it, unnamed if we cannot name it; a code we
// are about to transmit is a decision somebody made.
type ChargingMode uint8

const (
	// ChargingModeAI is code 0, "AI mode 2.0". Observed on hardware.
	ChargingModeAI ChargingMode = 0
	// ChargingModeStandard is code 1. Observed on hardware.
	ChargingModeStandard ChargingMode = 1
	// ChargingModeCustom is code 2. Not observed on this charger: the code comes
	// from the official app 3.24.0, not from a capture. Sending it is a probe.
	//
	// The value 4 sometimes quoted elsewhere was a Smi-tagged constant (2 << 1)
	// read out of the decompiled app; the Swift source is canonical and uses 2.
	ChargingModeCustom ChargingMode = 2
)

// Code returns the wire code.
func (m ChargingMode) Code() byte { return uint8(m) }

// IsObservedOnHardware reports whether this charger has actually been seen in
// this mode. True only for AI and standard; the difference matters to a caller
// that puts modes in front of a user.
func (m ChargingMode) IsObservedOnHardware() bool {
	return m == ChargingModeAI || m == ChargingModeStandard
}

// String implements fmt.Stringer. Unnamed codes are formatted, never guessed.
func (m ChargingMode) String() string {
	switch m {
	case ChargingModeAI:
		return "ai"
	case ChargingModeStandard:
		return "standard"
	case ChargingModeCustom:
		return "custom"
	default:
		return fmt.Sprintf("unknown(0x%02X)", uint8(m))
	}
}

// ParseChargingMode maps a wire code to the typed mode. Every code round-trips
// through Code, so an unnamed code survives a write/read cycle intact.
func ParseChargingMode(code byte) ChargingMode { return ChargingMode(code) }

// Custom-charging limits: C1, C2, C3 in watts, each 0 or 15..140, together at
// most 160.
const (
	CustomPowerTotalLimit = 160
	CustomPowerMinWatts   = 15
	CustomPowerMaxWatts   = 140
)

// CustomChargingPower is the payload of the custom-mode write. With AutoExit,
// plugging a device into a port set to 0 W sends the charger back to AI mode.
type CustomChargingPower struct {
	Number   byte
	AutoExit bool
	Watts    [3]byte
}

// NewCustomChargingPower builds a custom-mode value with profile number 1.
func NewCustomChargingPower(autoExit bool, watts [3]byte) CustomChargingPower {
	return CustomChargingPower{Number: 1, AutoExit: autoExit, Watts: watts}
}

// IsValid reports whether every watt value is 0 or 15..140 and the total is at
// most 160 W.
func (p CustomChargingPower) IsValid() bool {
	total := 0
	for _, w := range p.Watts {
		if w != 0 && (w < CustomPowerMinWatts || w > CustomPowerMaxWatts) {
			return false
		}
		total += int(w)
	}
	return total <= CustomPowerTotalLimit
}

// Bytes is [number, autoExit?1:0, w1, w2, w3].
func (p CustomChargingPower) Bytes() []byte {
	autoExit := byte(0)
	if p.AutoExit {
		autoExit = 1
	}
	return []byte{p.Number, autoExit, p.Watts[0], p.Watts[1], p.Watts[2]}
}

// FixedAllocation is the 0x0205 value offered under standard mode. 0 is C1
// priority and 1 is dual laptop, matching official app 3.24.0.
type FixedAllocation uint8

const (
	// FixedAllocationC1Priority prioritises C1's power budget.
	FixedAllocationC1Priority FixedAllocation = 0
	// FixedAllocationDualLaptop splits the budget across two laptops.
	FixedAllocationDualLaptop FixedAllocation = 1
)

// DeviceLanguage values accepted by the display-language command (0x0202) on
// firmware v0.0.5.2.
type DeviceLanguage uint8

const (
	DeviceLanguageEnglish           DeviceLanguage = 0
	DeviceLanguageSimplifiedChinese DeviceLanguage = 1
	DeviceLanguageJapanese          DeviceLanguage = 2
	DeviceLanguageGerman            DeviceLanguage = 3
)

// String implements fmt.Stringer.
func (l DeviceLanguage) String() string {
	switch l {
	case DeviceLanguageEnglish:
		return "english"
	case DeviceLanguageSimplifiedChinese:
		return "zh-Hans"
	case DeviceLanguageJapanese:
		return "japanese"
	case DeviceLanguageGerman:
		return "german"
	default:
		return fmt.Sprintf("unknown(%d)", uint8(l))
	}
}

// ScreenTimeout values accepted by the display auto-lock command (0x0203) on
// firmware v0.0.5.2.
type ScreenTimeout uint8

const (
	ScreenTimeoutThirtySeconds ScreenTimeout = 0
	ScreenTimeoutOneMinute     ScreenTimeout = 1
	ScreenTimeoutFiveMinutes   ScreenTimeout = 2
	ScreenTimeoutThirtyMinutes ScreenTimeout = 3
	ScreenTimeoutTwelveHours   ScreenTimeout = 4
)

// String implements fmt.Stringer. The values are the UI/session vocabulary for
// this setting (web settings screen TIMEOUT_ITEMS, session parseSetting's
// timeoutCode), not free-form labels: they travel through
// product.Settings.ScreenTimeout and SetSetting("screenTimeout", ...).
func (t ScreenTimeout) String() string {
	switch t {
	case ScreenTimeoutThirtySeconds:
		return "30s"
	case ScreenTimeoutOneMinute:
		return "1m"
	case ScreenTimeoutFiveMinutes:
		return "5m"
	case ScreenTimeoutThirtyMinutes:
		return "30m"
	case ScreenTimeoutTwelveHours:
		return "12h"
	default:
		return fmt.Sprintf("unknown(%d)", uint8(t))
	}
}

// ScreenOrientation values accepted by the manual display-orientation command
// (0x020B) on firmware v0.0.5.2.
type ScreenOrientation uint8

const (
	ScreenOrientationUp    ScreenOrientation = 0
	ScreenOrientationLeft  ScreenOrientation = 1
	ScreenOrientationDown  ScreenOrientation = 2
	ScreenOrientationRight ScreenOrientation = 3
)

// String implements fmt.Stringer; it returns the stable English names the UI
// mapping uses.
func (o ScreenOrientation) String() string {
	switch o {
	case ScreenOrientationUp:
		return "up"
	case ScreenOrientationLeft:
		return "left"
	case ScreenOrientationDown:
		return "down"
	case ScreenOrientationRight:
		return "right"
	default:
		return fmt.Sprintf("unknown(%d)", uint8(o))
	}
}

// SettingKind discriminates ChargerSetting.
type SettingKind int

const (
	SettingLanguage SettingKind = iota + 1
	SettingScreenTimeout
	SettingBrightness
	SettingOrientation
	SettingGyroscope
	SettingFixedAllocation
)

// ChargerSetting is one display setting whose complete command was confirmed on
// the owner's A2687 running firmware v0.0.5.2. Every command uses the same
// single typed-u8 A2 shape; only its opcode and value change.
type ChargerSetting struct {
	Kind SettingKind
	// Value is the byte 0x020x writes into A2.
	Value byte
}

// LanguageSetting is 0x0202 with the language code.
func LanguageSetting(language DeviceLanguage) ChargerSetting {
	return ChargerSetting{Kind: SettingLanguage, Value: uint8(language)}
}

// ScreenTimeoutSetting is 0x0203 with the auto-lock code.
func ScreenTimeoutSetting(timeout ScreenTimeout) ChargerSetting {
	return ChargerSetting{Kind: SettingScreenTimeout, Value: uint8(timeout)}
}

// BrightnessSetting is 0x0204 with a percent value. The product restricts writes
// to 25..100; the protocol itself accepts 0..100.
func BrightnessSetting(percent byte) ChargerSetting {
	return ChargerSetting{Kind: SettingBrightness, Value: percent}
}

// OrientationSetting is 0x020B with the orientation code.
func OrientationSetting(orientation ScreenOrientation) ChargerSetting {
	return ChargerSetting{Kind: SettingOrientation, Value: uint8(orientation)}
}

// GyroscopeSetting is 0x020D with 0 or 1.
func GyroscopeSetting(on bool) ChargerSetting {
	value := byte(0)
	if on {
		value = 1
	}
	return ChargerSetting{Kind: SettingGyroscope, Value: value}
}

// FixedAllocationSetting is 0x0205 with the allocation code.
func FixedAllocationSetting(allocation FixedAllocation) ChargerSetting {
	return ChargerSetting{Kind: SettingFixedAllocation, Value: uint8(allocation)}
}

// Opcode is the logical command opcode for this setting.
func (s ChargerSetting) Opcode() uint16 {
	switch s.Kind {
	case SettingLanguage:
		return OpcodeDeviceLanguage
	case SettingScreenTimeout:
		return OpcodeScreenTimeout
	case SettingBrightness:
		return OpcodeScreenBrightness
	case SettingOrientation:
		return OpcodeScreenOrientation
	case SettingGyroscope:
		return OpcodeGyroscope
	case SettingFixedAllocation:
		return OpcodeFixedAllocation
	default:
		return 0
	}
}

// ReadbackMatches reports whether a fresh handshake snapshot confirms this
// setting, mirroring ChargerSetting.readbackMatches. The second return value is
// false when the protocol has no discovered read-back field for the setting
// (language and fixed allocation); a nil *DeviceSettings yields false, true
// because nothing can match an absent snapshot.
func (s ChargerSetting) ReadbackMatches(settings *DeviceSettings) (matches bool, defined bool) {
	if settings == nil {
		return false, false
	}
	switch s.Kind {
	case SettingLanguage, SettingFixedAllocation:
		return false, false
	case SettingScreenTimeout:
		value, ok := settings.ScreenTimeoutCode()
		if !ok {
			return false, true
		}
		return value == s.Value, true
	case SettingBrightness:
		value, ok := settings.BrightnessPercent()
		if !ok {
			return false, true
		}
		return value == s.Value, true
	case SettingOrientation:
		value, ok := settings.OrientationCode()
		if !ok {
			return false, true
		}
		return value == s.Value, true
	case SettingGyroscope:
		value, ok := settings.GyroEnabled()
		if !ok {
			return false, true
		}
		return uint8(boolToByte(value)) == s.Value, true
	default:
		return false, false
	}
}

func boolToByte(v bool) byte {
	if v {
		return 1
	}
	return 0
}

// TimestampBytes encodes epoch seconds as a little-endian uint32 - the epoch
// trailer of every session command.
func TimestampBytes(at time.Time) []byte {
	seconds := uint32(at.Unix())
	out := make([]byte, 4)
	binary.LittleEndian.PutUint32(out, seconds)
	return out
}

// sessionMessage assembles a group-0x0F message: A1 action, the given fields,
// then the bare four-byte epoch trailer FE 04 <ts>.
func sessionMessage(opcode uint16, fields []TLV, at time.Time) OutgoingMessage {
	all := make([]TLV, 0, len(fields)+2)
	all = append(all, NewTLV(FieldA1, []byte{SessionAction}))
	all = append(all, fields...)
	all = append(all, NewTLV(FieldFE, TimestampBytes(at)))
	return OutgoingMessage{
		Group:           GroupSession,
		Opcode:          opcode,
		Plaintext:       EncodeTLVs(all),
		Encryption:      EncryptionSession,
		ExpectsResponse: true,
	}
}

// ReadAll is 0x0200 - the full device state snapshot.
func ReadAll(at time.Time) OutgoingMessage {
	return sessionMessage(OpcodeReadAll, nil, at)
}

// RealtimeProbe is 0x020A, the "bluetooth bind success" getter. The official app
// puts the account id in A3 whenever it has one; public reference clients drop
// it because they have no correct id to send. ownerUserID may be empty.
func RealtimeProbe(countryCode string, ownerUserID string, at time.Time) OutgoingMessage {
	fields := []TLV{NewTLV(FieldA2, BytesValue([]byte(countryCode)).Encoded())}
	if ownerUserID != "" {
		fields = append(fields, NewTLV(FieldA3, BytesValue([]byte(ownerUserID)).Encoded()))
	}
	fields = append(fields, NewTLV(FieldA5, U8Value(1).Encoded()))
	return sessionMessage(OpcodeBindSuccess, fields, at)
}

// RealtimeTrigger is 0x020B - arms the ~1 Hz realtime stream. The A2 block is
// the enable payload the official app sends; a bare action-only trigger does
// nothing.
func RealtimeTrigger(at time.Time) OutgoingMessage {
	return sessionMessage(OpcodeRealtimeTrigger, []TLV{
		NewTLV(FieldA2, BytesValue([]byte{0x01, 0x00, 0x03, 0x15, 0x01, 0x01, 0x00, 0x00, 0x00}).Encoded()),
	}, at)
}

// UserAuth is 0x0027 - user authentication with an explicit identity and an
// optional password field. It is a negotiation-group message sealed with the
// session key; the builder exists mainly to probe the firmware.
func UserAuth(userID string, password []byte, at time.Time) OutgoingMessage {
	fields := []TLV{
		NewTLV(FieldA1, TimestampBytes(at)),
		NewTLV(FieldA2, []byte(userID)),
	}
	if password != nil {
		fields = append(fields, NewTLV(FieldA3, password))
	}
	return OutgoingMessage{
		Group:           GroupNegotiation,
		Opcode:          OpcodeUserAuth,
		Plaintext:       EncodeTLVs(fields),
		Encryption:      EncryptionSession,
		ExpectsResponse: true,
	}
}

// SetPortOutput is 0x0207 - turn one port on or off.
func SetPortOutput(port Port, on bool, at time.Time) OutgoingMessage {
	state := byte(0)
	if on {
		state = 1
	}
	return sessionMessage(OpcodePortOutput, []TLV{
		NewTLV(FieldA2, U8Value(port.Index()).Encoded()),
		NewTLV(FieldA3, U8Value(state).Encoded()),
	}, at)
}

// SetChargingMode is 0x0206 - switch the charger's power-allocation mode.
//
// The opcode is solid (recovered from the official app 3.18.0 and present in
// both pinned reference clients); the payload shape is structural inference - it
// is the 0x0207 layout with one argument. Reading AA back is how that gap closes.
//
// The FE trailer is the bare four-byte epoch, not the FE 05 03 typed u32 every
// cover command carries. Both live in this protocol and are not interchangeable.
func SetChargingMode(mode ChargingMode, at time.Time) OutgoingMessage {
	return sessionMessage(OpcodeChargingMode, []TLV{
		NewTLV(FieldA2, U8Value(mode.Code()).Encoded()),
	}, at)
}

// SetChargerSetting writes one display setting confirmed on firmware v0.0.5.2.
func SetChargerSetting(setting ChargerSetting, at time.Time) OutgoingMessage {
	return sessionMessage(setting.Opcode(), []TLV{
		NewTLV(FieldA2, U8Value(setting.Value).Encoded()),
	}, at)
}

// SetCustomChargingMode is 0x0206 with mode 2 and the custom power array - the
// official app's setCustomChargeModeParams.
func SetCustomChargingMode(power CustomChargingPower, at time.Time) OutgoingMessage {
	return sessionMessage(OpcodeChargingMode, []TLV{
		NewTLV(FieldA2, U8Value(ChargingModeCustom.Code()).Encoded()),
		NewTLV(FieldA3, BytesValue(power.Bytes()).Encoded()),
	}, at)
}

// SetPortTimer is 0x0209 - auto-off countdown for one port, in seconds. Zero
// cancels it: the official app's "off" item sends exactly that.
func SetPortTimer(port Port, seconds uint32, at time.Time) OutgoingMessage {
	value := make([]byte, 4)
	binary.LittleEndian.PutUint32(value, seconds)
	return sessionMessage(OpcodePortTimer, []TLV{
		NewTLV(FieldA2, U8Value(port.Index()).Encoded()),
		NewTLV(FieldA3, BytesValue(value).Encoded()),
	}, at)
}
