package winble

import (
	"strings"

	"charker/internal/product"
)

// A2687 GATT identifiers (Charker/docs/port/spec-protocol.md §2.1).
const (
	// AdvertisedService is the 16-bit service shared by the Anker Solix/Prime
	// family. It is a discovery hint, not proof of model.
	AdvertisedService = "FF09"
	// PrimaryService is the only service the transport talks to.
	PrimaryService = "8C850001-0302-41C5-B46E-CF057C562025"
	// WriteCharacteristic takes host->charger frames.
	WriteCharacteristic = "8C850002-0302-41C5-B46E-CF057C562025"
	// NotifyCharacteristic carries charger->host frames.
	NotifyCharacteristic = "8C850003-0302-41C5-B46E-CF057C562025"
	// NamePrefix is the observed advertised-name prefix.
	NamePrefix = "ASHDJW"
)

// MatchReason says why an advertisement is believed to be an Anker charger.
// The Windows backend cannot observe every signal the macOS app uses: WinRT
// fills LocalName, ServiceUUIDs and ManufacturerData only (no service data, no
// overflow service list, no connectable flag), see docs/port/spec-ble.md §7 R4.
type MatchReason string

const (
	// MatchAdvertisedService: the advertised service list contains FF09 or the
	// 128-bit primary service.
	MatchAdvertisedService MatchReason = "advertisedService"
	// MatchProductType: the manufacturer data embeds product type B4 05, the
	// Anker device-table entry for the A2687.
	MatchProductType MatchReason = "productType"
	// MatchNamePrefix: the advertised name contains an Anker/Prime fragment.
	MatchNamePrefix MatchReason = "namePrefix"
)

// String implements fmt.Stringer.
func (r MatchReason) String() string { return string(r) }

// nameHints are the lowercase fragments the macOS transport accepts. They are
// deliberately broader than NamePrefix: "ASHDJW" is the observed prefix, but
// name-only advertisements vary by firmware.
var nameHints = []string{"ashdjw", "ashd", "anker", "prime", "a2687", "solix"}

// productTypeA2687 is "B405", the Anker device-table product type for the
// A2687. The macOS matcher searches for it anywhere in the manufacturer data.
var productTypeA2687 = []byte{0xB4, 0x05}

// bluetoothBaseSuffix is how a 16-bit UUID expands to a 128-bit one (Bluetooth
// Base UUID).
const bluetoothBaseSuffix = "-0000-1000-8000-00805f9b34fb"

// MatchAdvertisement decides whether one advertisement belongs to an A2687.
//
// name is the advertised local name; serviceUUIDs are as the backend prints them
// (16-bit UUIDs expanded through the Bluetooth Base UUID); manufacturerData are
// the raw manufacturer-specific payloads *including* the two little-endian
// Company ID bytes, matching the macOS CBAdvertisementDataManufacturerDataKey
// layout the Swift matcher searches.
//
// It returns the product the advertisement matched, the reasons that made it a
// candidate, and whether it is a candidate at all. The rules are the Windows
// subset of the macOS MatchReason ladder (spec-ble §2.3): service data and the
// overflow service list cannot be observed here.
func MatchAdvertisement(name string, serviceUUIDs []string, manufacturerData [][]byte) (product.ChargerProduct, []MatchReason, bool) {
	var reasons []MatchReason

	for _, svc := range serviceUUIDs {
		if isAnkerServiceUUID(svc) {
			reasons = append(reasons, MatchAdvertisedService)
			break
		}
	}

	for _, mfg := range manufacturerData {
		if containsBytes(mfg, productTypeA2687) {
			reasons = append(reasons, MatchProductType)
			break
		}
	}

	lowerName := strings.ToLower(name)
	for _, hint := range nameHints {
		if strings.Contains(lowerName, hint) {
			reasons = append(reasons, MatchNamePrefix)
			break
		}
	}

	if len(reasons) == 0 {
		return "", nil, false
	}
	return product.ProductA2687, reasons, true
}

// isAnkerServiceUUID reports whether one printed UUID is the advertised 16-bit
// FF09 service or the 128-bit primary service.
func isAnkerServiceUUID(u string) bool {
	u = strings.ToLower(strings.TrimSpace(u))
	if u == "" {
		return false
	}
	if u == "ff09" || u == "0000ff09"+bluetoothBaseSuffix {
		return true
	}
	// Other spellings of a 16-bit UUID (for example a backend that prints
	// "0000ff09") should not be missed.
	if strings.HasSuffix(u, bluetoothBaseSuffix) {
		base := strings.TrimSuffix(u, bluetoothBaseSuffix)
		if len(base) == 8 && base[:4] == "0000" && base[4:] == "ff09" {
			return true
		}
	}
	return u == strings.ToLower(PrimaryService)
}

// containsBytes reports whether haystack contains needle as a contiguous run.
func containsBytes(haystack, needle []byte) bool {
	if len(needle) == 0 || len(needle) > len(haystack) {
		return false
	}
	for start := 0; start+len(needle) <= len(haystack); start++ {
		match := true
		for i := range needle {
			if haystack[start+i] != needle[i] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}
