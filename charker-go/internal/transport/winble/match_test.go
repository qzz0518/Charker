package winble

import (
	"reflect"
	"testing"

	"charker/internal/product"
)

func TestMatchAdvertisement(t *testing.T) {
	tests := []struct {
		name       string
		localName  string
		services   []string
		manufact   [][]byte
		wantOK     bool
		wantReason []MatchReason
	}{
		{
			name:       "advertised 16-bit FF09 expanded to the base UUID",
			services:   []string{"0000ff09-0000-1000-8000-00805f9b34fb"},
			wantOK:     true,
			wantReason: []MatchReason{MatchAdvertisedService},
		},
		{
			name:       "advertised FF09 in short form",
			services:   []string{"FF09"},
			wantOK:     true,
			wantReason: []MatchReason{MatchAdvertisedService},
		},
		{
			name:       "advertised primary service, mixed case",
			services:   []string{"8c850001-0302-41c5-b46e-cf057c562025"},
			wantOK:     true,
			wantReason: []MatchReason{MatchAdvertisedService},
		},
		{
			name:     "unrelated service does not match",
			services: []string{"0000fe59-0000-1000-8000-00805f9b34fb"},
			wantOK:   false,
		},
		{
			name:     "write characteristic is not an advertised service",
			services: []string{WriteCharacteristic},
			wantOK:   false,
		},
		{
			name:       "product type B405 in manufacturer data",
			manufact:   [][]byte{{0x69, 0x09, 0xB4, 0x05, 0x01}},
			wantOK:     true,
			wantReason: []MatchReason{MatchProductType},
		},
		{
			// CBAdvertisementDataManufacturerDataKey starts with the little-endian
			// Company ID, so a payload whose high byte is 0xB4 and whose first
			// data byte is 0x05 straddles the boundary; the macOS matcher searched
			// the whole buffer and found it.
			name:       "product type straddling the company ID boundary",
			manufact:   [][]byte{{0x00, 0xB4, 0x05, 0x00}},
			wantOK:     true,
			wantReason: []MatchReason{MatchProductType},
		},
		{
			name:     "manufacturer data without B405 does not match",
			manufact: [][]byte{{0x4C, 0x00, 0x0F, 0x05}},
			wantOK:   false,
		},
		{name: "name prefix ASHDJW", localName: "ASHDJW-012345", wantOK: true, wantReason: []MatchReason{MatchNamePrefix}},
		{name: "name contains Anker", localName: "Anker Prime 160W", wantOK: true, wantReason: []MatchReason{MatchNamePrefix}},
		{name: "name contains prime", localName: "PRIME-TOWER", wantOK: true, wantReason: []MatchReason{MatchNamePrefix}},
		{name: "name contains a2687", localName: "A2687", wantOK: true, wantReason: []MatchReason{MatchNamePrefix}},
		{name: "name contains solix", localName: "SOLIX C1000", wantOK: true, wantReason: []MatchReason{MatchNamePrefix}},
		{name: "unrelated name does not match", localName: "Quest 3", wantOK: false},
		{name: "empty advertisement does not match", wantOK: false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			prod, reasons, ok := MatchAdvertisement(tc.localName, tc.services, tc.manufact)
			if ok != tc.wantOK {
				t.Fatalf("MatchAdvertisement ok = %v, want %v (reasons %v)", ok, tc.wantOK, reasons)
			}
			if !ok {
				if prod != "" || reasons != nil {
					t.Fatalf("no match returned product %q reasons %v, want zero values", prod, reasons)
				}
				return
			}
			if prod != product.ProductA2687 {
				t.Fatalf("product = %q, want %q", prod, product.ProductA2687)
			}
			if !reflect.DeepEqual(reasons, tc.wantReason) {
				t.Fatalf("reasons = %v, want %v", reasons, tc.wantReason)
			}
		})
	}
}

func TestMatchAdvertisementAllSignalsAtOnce(t *testing.T) {
	prod, reasons, ok := MatchAdvertisement("ASHDJW-1", []string{"0000ff09-0000-1000-8000-00805f9b34fb"}, [][]byte{{0x00, 0x00, 0xB4, 0x05}})
	if !ok || prod != product.ProductA2687 {
		t.Fatalf("MatchAdvertisement = (%q, %v, %v), want an A2687 match", prod, reasons, ok)
	}
	want := []MatchReason{MatchAdvertisedService, MatchProductType, MatchNamePrefix}
	if !reflect.DeepEqual(reasons, want) {
		t.Fatalf("reasons = %v, want %v", reasons, want)
	}
}

func TestIsAnkerServiceUUID(t *testing.T) {
	yes := []string{
		"FF09",
		"0000FF09-0000-1000-8000-00805F9B34FB",
		"0000ff09-0000-1000-8000-00805f9b34fb",
		" 8c850001-0302-41c5-b46e-cf057c562025 ",
		"8C850001-0302-41C5-B46E-CF057C562025",
	}
	for _, u := range yes {
		if !isAnkerServiceUUID(u) {
			t.Errorf("isAnkerServiceUUID(%q) = false, want true", u)
		}
	}
	no := []string{
		"",
		"FE59",
		"0000fe59-0000-1000-8000-00805f9b34fb",
		"8c850002-0302-41c5-b46e-cf057c562025",
		"0000ff0a-0000-1000-8000-00805f9b34fb",
		"8c850001-0302-41c5-b46e-cf057c562026",
	}
	for _, u := range no {
		if isAnkerServiceUUID(u) {
			t.Errorf("isAnkerServiceUUID(%q) = true, want false", u)
		}
	}
}

func TestContainsBytes(t *testing.T) {
	tests := []struct {
		haystack []byte
		needle   []byte
		want     bool
	}{
		{[]byte{0xB4, 0x05}, []byte{0xB4, 0x05}, true},
		{[]byte{0x00, 0xB4, 0x05, 0x00}, []byte{0xB4, 0x05}, true},
		{[]byte{0x00, 0xB4}, []byte{0xB4, 0x05}, false},
		{[]byte{}, []byte{0xB4, 0x05}, false},
		{nil, nil, false},
		{[]byte{1}, nil, false},
	}
	for _, tc := range tests {
		if got := containsBytes(tc.haystack, tc.needle); got != tc.want {
			t.Errorf("containsBytes(%v, %v) = %v, want %v", tc.haystack, tc.needle, got, tc.want)
		}
	}
}
