package a2687

import (
	"errors"
	"reflect"
	"testing"
)

// T1: parse the real capability response.
func TestParsesRealCapabilityResponse(t *testing.T) {
	payload, err := ParsePayload(mustHex(t, fxPlainDeviceCapability))
	if err != nil {
		t.Fatalf("ParsePayload: %v", err)
	}
	if status, ok := payload.StatusCode(); !ok || status != 0 {
		t.Errorf("status = %v/%v, want 0/true", status, ok)
	}
	if !payload.IsOK() {
		t.Error("IsOK = false, want true")
	}
	cases := map[byte][]byte{
		FieldA1: {0x02},
		FieldA2: {0x29, 0x01}, // MTU 297, little endian
		FieldA3: {0x44},
		FieldA5: {0x02},
	}
	for id, want := range cases {
		got, ok := payload.Field(id)
		if !ok || !reflect.DeepEqual(got, want) {
			t.Errorf("field 0x%02X = %v/%v, want %v", id, got, ok, want)
		}
	}
}

// T2: request payloads carry no status byte.
func TestRequestPayloadHasNoStatusByte(t *testing.T) {
	payload, err := ParsePayload(mustHex(t, fxPlainClientCapability))
	if err != nil {
		t.Fatalf("ParsePayload: %v", err)
	}
	if payload.Status != nil {
		t.Errorf("status = %v, want nil", *payload.Status)
	}
	if !payload.IsOK() {
		t.Error("a request-shaped payload is OK")
	}
	a1, ok := payload.Field(FieldA1)
	if !ok || len(a1) != 4 {
		t.Errorf("A1 = %v/%v, want 4 bytes", a1, ok)
	}
}

// T3: TLV encode/decode round trip.
func TestEncodeDecodeRoundTrip(t *testing.T) {
	records := []TLV{
		NewTLV(FieldA1, []byte{0x21}),
		NewTLV(FieldA2, U8Value(2).Encoded()),
		NewTLV(FieldFE, []byte{1, 2, 3, 4}),
	}
	decoded, err := DecodeTLVs(EncodeTLVs(records))
	if err != nil {
		t.Fatalf("DecodeTLVs: %v", err)
	}
	if !reflect.DeepEqual(decoded, records) {
		t.Errorf("decoded = %v, want %v", decoded, records)
	}
}

// T4: truncated records are errors, never partial results.
func TestRejectsTruncatedRecord(t *testing.T) {
	for _, data := range [][]byte{{0xA1, 0x04, 0x01, 0x02}, {0xA1}} {
		if _, err := DecodeTLVs(data); err == nil {
			t.Errorf("DecodeTLVs(%x) succeeded, want error", data)
		} else {
			var tlvErr *TLVError
			if !errors.As(err, &tlvErr) {
				t.Errorf("error type = %T, want *TLVError", err)
			}
		}
	}
}

// T5: typed values.
func TestTypedValues(t *testing.T) {
	cases := []struct {
		name string
		raw  []byte
		want TypedValue
	}{
		{"text", []byte{0x00, 0x76, 0x31}, TextValue("v1")},
		{"u8", []byte{0x01, 0x07}, U8Value(7)},
		{"u16", []byte{0x02, 0x29, 0x01}, U16Value(297)},
		{"u32", []byte{0x03, 0x01, 0x00, 0x00, 0x00}, U32Value(1)},
		{"bytes", []byte{0x04, 0xAB}, BytesValue([]byte{0xAB})},
		{"unknownType", []byte{0x09, 0xAB}, TypedValue{Kind: TypedKindUnknown, Type: 0x09, Data: []byte{0xAB}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := DecodeTypedValue(tc.raw); !reflect.DeepEqual(got, tc.want) {
				t.Errorf("DecodeTypedValue(%x) = %+v, want %+v", tc.raw, got, tc.want)
			}
		})
	}
}

// T6: a u16 with one byte must not silently become a u8.
func TestShortTypedValueIsNotGuessed(t *testing.T) {
	got := DecodeTypedValue([]byte{0x02, 0x29})
	want := TypedValue{Kind: TypedKindUnknown, Type: 0x02, Data: []byte{0x29}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v, want %+v", got, want)
	}
	if _, ok := got.Scalar(); ok {
		t.Error("an unknown value has no scalar")
	}
}

// T7: typed encoding round-trips.
func TestTypedEncodingRoundTrips(t *testing.T) {
	values := []TypedValue{
		TextValue("GB"),
		U8Value(1),
		U16Value(600),
		U32Value(1_700_000_000),
		BytesValue([]byte{1, 2, 3}),
	}
	for _, value := range values {
		decoded := DecodeTypedValue(value.Encoded())
		if !reflect.DeepEqual(decoded, value) {
			t.Errorf("round trip of %+v = %+v", value, decoded)
		}
	}
	// Text strips NULs and trailing dots, as device strings sometimes carry them.
	if got := DecodeTypedValue([]byte{0x00, 'v', '1', '.', '.', 0x00}); got.Text != "v1" {
		t.Errorf("text = %q, want %q", got.Text, "v1")
	}
}

// T8: scalar accessor.
func TestScalarAccessor(t *testing.T) {
	if got, ok := U16Value(297).Scalar(); !ok || got != 297 {
		t.Errorf("u16 scalar = %d/%v, want 297/true", got, ok)
	}
	if _, ok := TextValue("x").Scalar(); ok {
		t.Error("text must have no scalar")
	}
	if got, ok := (TypedValue{}).Scalar(); ok || got != 0 {
		t.Errorf("zero value scalar = %d/%v", got, ok)
	}
}

// T9: the status-byte heuristic, including the bare refusal shape real firmware
// sends (A1 is a constant 0x31 there, so the leading byte is the result code).
func TestPayloadStatusHeuristic(t *testing.T) {
	cases := []struct {
		name       string
		data       []byte
		wantStatus *byte
		wantFields int
		wantOK     bool
	}{
		{name: "empty", data: nil, wantStatus: nil, wantFields: 0, wantOK: true},
		{name: "successResponse", data: mustHex(t, fxPlainDeviceInitialConnect), wantStatus: bytePtr(0), wantFields: 1, wantOK: true},
		{name: "request", data: mustHex(t, fxPlainClientInitialConnect), wantStatus: nil, wantFields: 1, wantOK: true},
		{name: "bareRefusal", data: []byte{0x11}, wantStatus: bytePtr(0x11), wantFields: 0, wantOK: false},
		{name: "refusalWithFields", data: mustHex(t, "11a10131"), wantStatus: bytePtr(0x11), wantFields: 1, wantOK: false},
		{name: "statusOnly", data: []byte{0x00}, wantStatus: bytePtr(0), wantFields: 0, wantOK: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			payload, err := ParsePayload(tc.data)
			if err != nil {
				t.Fatalf("ParsePayload: %v", err)
			}
			switch {
			case tc.wantStatus == nil && payload.Status != nil:
				t.Errorf("status = %v, want nil", *payload.Status)
			case tc.wantStatus != nil && payload.Status == nil:
				t.Errorf("status = nil, want %v", *tc.wantStatus)
			case tc.wantStatus != nil && *payload.Status != *tc.wantStatus:
				t.Errorf("status = 0x%02X, want 0x%02X", *payload.Status, *tc.wantStatus)
			}
			if len(payload.Fields) != tc.wantFields {
				t.Errorf("fields = %d, want %d", len(payload.Fields), tc.wantFields)
			}
			if payload.IsOK() != tc.wantOK {
				t.Errorf("isOK = %v, want %v", payload.IsOK(), tc.wantOK)
			}
		})
	}

	if _, err := ParsePayload([]byte{0x10, 0xA1, 0x04, 0x01}); err == nil {
		t.Error("an unparseable payload must error")
	}
}

// T10: FrameFields keeps wire order and repeats.
func TestFrameFieldsKeepWireOrderAndRepeats(t *testing.T) {
	fields := NewFrameFields([]TLV{
		NewTLV(FieldA1, []byte{0x21}),
		NewTLV(FieldA5, []byte{0x01}),
		NewTLV(FieldAC, []byte{0x02}),
		NewTLV(FieldA5, []byte{0x03}),
	})
	if got, want := fields.IDs(), []byte{FieldA1, FieldA5, FieldAC}; !reflect.DeepEqual(got, want) {
		t.Errorf("ids = %x, want %x", got, want)
	}
	if got, ok := fields.Field(FieldA5); !ok || !reflect.DeepEqual(got, []byte{0x01}) {
		t.Errorf("first occurrence = %x/%v", got, ok)
	}
	if got := fields.Values(FieldA5); !reflect.DeepEqual(got, [][]byte{{0x01}, {0x03}}) {
		t.Errorf("values = %v", got)
	}
	if got := fields.Occurrences(FieldA5); got != 2 {
		t.Errorf("occurrences = %d, want 2", got)
	}
	if fields.IsEmpty() {
		t.Error("fields should not be empty")
	}
	if !NewFrameFields(nil).IsEmpty() {
		t.Error("nil fields should be empty")
	}
}

func TestTLVEncodeTruncatesLengthLikeSwift(t *testing.T) {
	// UInt8(truncatingIfNeeded:) is the Swift behaviour; the encoder must not
	// start failing for values callers are told to keep under 255.
	encoded := EncodeTLVs([]TLV{NewTLV(0xA1, make([]byte, 258))})
	if encoded[1] != 2 {
		t.Errorf("length byte = %d, want 2", encoded[1])
	}
	if len(encoded) != 2+258 {
		t.Errorf("encoded length = %d", len(encoded))
	}
}

// Typed-value boundaries: encoding must round-trip every scalar width and the
// byte/text cases, including the maximum values.
func TestTypedValueBoundaries(t *testing.T) {
	cases := []struct {
		name  string
		value TypedValue
	}{
		{"u8Zero", U8Value(0)},
		{"u8Max", U8Value(0xFF)},
		{"u16Max", U16Value(0xFFFF)},
		{"u32Max", U32Value(0xFFFFFFFF)},
		{"textEmpty", TextValue("")},
		{"textAscii", TextValue("SmallChargingUrl")},
		{"bytesEmpty", BytesValue(nil)},
		{"bytes16", BytesValue([]byte{0, 1, 2, 3, 0xFF, 0xFE, 0xFD, 0xFC, 9, 8, 7, 6, 5, 4, 3, 2})},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			decoded := DecodeTypedValue(tc.value.Encoded())
			if !reflect.DeepEqual(decoded, tc.value) {
				t.Errorf("round trip = %+v, want %+v", decoded, tc.value)
			}
		})
	}
}
