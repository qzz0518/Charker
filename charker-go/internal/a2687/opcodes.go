package a2687

import "fmt"

// GATT identifiers (spec-protocol §2.1).
const (
	// AdvertisedService is the 16-bit service shared by the Anker Solix/Prime
	// family. It is a discovery filter, not proof of model.
	AdvertisedService = "FF09"
	// PrimaryService is the A2687 primary service UUID.
	PrimaryService = "8C850001-0302-41C5-B46E-CF057C562025"
	// WriteCharacteristic accepts command writes.
	WriteCharacteristic = "8C850002-0302-41C5-B46E-CF057C562025"
	// NotifyCharacteristic delivers notifications (frames).
	NotifyCharacteristic = "8C850003-0302-41C5-B46E-CF057C562025"
	// NamePrefix is an advertised-name hint seen in the wild. Shared by the
	// family; treated as a candidate hint only.
	NamePrefix = "ASHDJW"
)

// Frame group bytes. Only the version byte is validated on decode; the group
// must be carried, not asserted: the charger answers session commands with
// 0x11 while the app sends 0x0F.
const (
	// GroupNegotiation is the handshake group.
	GroupNegotiation byte = 0x01
	// GroupSession is the encrypted session-command group.
	GroupSession byte = 0x0F
	// GroupSessionResponse is the group observed on device session responses.
	GroupSessionResponse byte = 0x11
)

// Flag bits in the raw command word (spec-protocol §2.2).
const (
	// FlagEncrypted means the payload is AES-GCM sealed.
	FlagEncrypted uint16 = 0x4000
	// FlagResponse marks a device response/ACK.
	FlagResponse uint16 = 0x0800
	// OpcodeMask strips the flag bits.
	OpcodeMask uint16 = ^(FlagEncrypted | FlagResponse)
)

// Speaker ("slave") values carried in the pattern.
const (
	SpeakerApp    byte = 0x00
	SpeakerDevice byte = 0x01
)

// Logical opcodes. Untyped constants so they compare directly against uint16.
const (
	// Negotiation group (0x01).
	OpcodeInitialConnect = 0x0001
	OpcodeCapability     = 0x0003
	OpcodeSetCapability  = 0x0005
	OpcodePublicKey      = 0x0021
	OpcodeAESMetadata    = 0x0022
	OpcodeUserAuth       = 0x0027
	OpcodeBaseInfo       = 0x0029

	// Session group (0x0F).
	OpcodeReadAll          = 0x0200
	OpcodeDeviceLanguage   = 0x0202
	OpcodeScreenTimeout    = 0x0203
	OpcodeScreenBrightness = 0x0204
	OpcodeFixedAllocation  = 0x0205
	OpcodeChargingMode     = 0x0206
	OpcodePortOutput       = 0x0207
	OpcodePortTimer        = 0x0209
	OpcodeBindSuccess      = 0x020A
	OpcodeRealtimeTrigger  = 0x020B
	// OpcodeScreenOrientation shares 0x020B with the realtime trigger; the
	// typed-u8 A2 payload distinguishes the write from the trigger block.
	OpcodeScreenOrientation = 0x020B
	OpcodePortHistory       = 0x020C
	OpcodeGyroscope         = 0x020D
	OpcodeRealtimeReport    = 0x0300

	// Cover/screensaver (evidence weaker; see CoverCommands).
	OpcodeSetScreensaver     = 0x021F
	OpcodeCoverTransferStart = 0x0220
	OpcodeCoverTransferChunk = 0x0221
)

// TLV field identifiers. A1 is the action/sequence slot in nearly every
// message; FE carries the replay-protection epoch.
const (
	FieldA1 byte = 0xA1
	FieldA2 byte = 0xA2
	FieldA3 byte = 0xA3
	FieldA4 byte = 0xA4
	FieldA5 byte = 0xA5
	FieldA6 byte = 0xA6
	FieldA7 byte = 0xA7
	FieldA8 byte = 0xA8
	// FieldA9 is screen brightness in the settings snapshot.
	FieldA9 byte = 0xA9
	// FieldAA is the charging-mode code in the settings snapshot.
	FieldAA byte = 0xAA
	FieldAC byte = 0xAC
	FieldAD byte = 0xAD
	FieldAE byte = 0xAE
	// FieldAF is the manual screen orientation in the settings snapshot.
	FieldAF byte = 0xAF
	// FieldB2 is the gyroscope auto-rotation switch.
	FieldB2 byte = 0xB2
	// FieldB4 is one 12-byte block of connected-device USB identities.
	FieldB4 byte = 0xB4
	// FieldFD carries the screensaver URL slot.
	FieldFD byte = 0xFD
	// FieldFE is the replay-protection epoch.
	FieldFE byte = 0xFE
)

// SessionAction is the A1 action selector of session commands.
const SessionAction byte = 0x21

// Port is one USB-C port of the A2687. The numeric value is also the wire port
// index used by 0x0207/0x0209 and the slot order of A5-A7/AC-AE/B4.
type Port int

const (
	PortC1 Port = 0
	PortC2 Port = 1
	PortC3 Port = 2
)

// Ports lists the A2687 ports in wire/display order.
var Ports = []Port{PortC1, PortC2, PortC3}

// Valid reports whether p is one of the three A2687 ports.
func (p Port) Valid() bool { return p >= PortC1 && p <= PortC3 }

// Label returns "C1".."C3".
func (p Port) Label() string { return fmt.Sprintf("C%d", int(p)+1) }

// Index returns the wire port index (0..2).
func (p Port) Index() byte { return byte(p) }

// TelemetryField is the TLV id holding this port's live [status,mV,mA,cW] struct.
func (p Port) TelemetryField() byte {
	switch p {
	case PortC2:
		return FieldA6
	case PortC3:
		return FieldA7
	default:
		return FieldA5
	}
}

// CableField is the TLV id holding this port's cable/profile control struct.
func (p Port) CableField() byte {
	switch p {
	case PortC2:
		return FieldAD
	case PortC3:
		return FieldAE
	default:
		return FieldAC
	}
}

// OpcodeName returns a stable human-readable name for diagnostics. Unknown
// opcodes are formatted, never guessed at.
func OpcodeName(op uint16) string {
	switch op {
	case OpcodeInitialConnect:
		return "initialConnect"
	case OpcodeCapability:
		return "capability"
	case OpcodeSetCapability:
		return "setCapability"
	case OpcodePublicKey:
		return "publicKey"
	case OpcodeAESMetadata:
		return "aesMetadata"
	case OpcodeUserAuth:
		return "userAuth"
	case OpcodeBaseInfo:
		return "baseInfo"
	case OpcodeReadAll:
		return "readAll"
	case OpcodeDeviceLanguage:
		return "deviceLanguage"
	case OpcodeScreenTimeout:
		return "screenTimeout"
	case OpcodeScreenBrightness:
		return "screenBrightness"
	case OpcodeFixedAllocation:
		return "fixedAllocation"
	case OpcodeChargingMode:
		return "chargingMode"
	case OpcodePortOutput:
		return "portOutput"
	case OpcodePortTimer:
		return "portTimer"
	case OpcodeBindSuccess:
		return "bindSuccess"
	case OpcodeRealtimeTrigger:
		return "realtimeTrigger/screenOrientation"
	case OpcodePortHistory:
		return "portHistory"
	case OpcodeGyroscope:
		return "gyroscope"
	case OpcodeRealtimeReport:
		return "realtimeReport"
	case OpcodeSetScreensaver:
		return "setScreensaver"
	case OpcodeCoverTransferStart:
		return "coverTransferStart"
	case OpcodeCoverTransferChunk:
		return "coverTransferChunk"
	default:
		return fmt.Sprintf("0x%04X", op)
	}
}
