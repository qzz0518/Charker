package a2345

import (
	"reflect"
	"testing"
)

func fieldIDs(f Frame) []byte {
	ids := make([]byte, len(f.Fields))
	for i, field := range f.Fields {
		ids[i] = field.ID
	}
	return ids
}

func TestDecodesFrameWithIncrementAndStrictTLVs(t *testing.T) {
	f := mustDecode(t, fxRealtimeOldFirmware)
	if f.MessageType != MsgRealtime {
		t.Errorf("type = 0x%04X", f.MessageType)
	}
	if f.Pattern != (FramePattern{Version: 3, Speaker: 1, Group: 15}) {
		t.Errorf("pattern = %+v", f.Pattern)
	}
	if f.Increment == nil || *f.Increment != 1 {
		t.Errorf("increment = %v", f.Increment)
	}
	want := []byte{0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xFE}
	if got := fieldIDs(f); !reflect.DeepEqual(got, want) {
		t.Errorf("ids = %x", got)
	}
	if f.EncodedLength != 100 {
		t.Errorf("length = %d", f.EncodedLength)
	}
}

func TestDecodesSixtyTwoByteFrameWithoutIncrement(t *testing.T) {
	b := mustHex(t, fxVersionInfo)
	if len(b) != 62 {
		t.Fatalf("len = %d", len(b))
	}
	f, err := Decode(b)
	if err != nil {
		t.Fatal(err)
	}
	if f.MessageType != MsgVersionInfo || f.Increment != nil {
		t.Errorf("type 0x%04X increment %v", f.MessageType, f.Increment)
	}
	if got := fieldIDs(f); !reflect.DeepEqual(got, []byte{0xA1, 0xA2, 0xA3, 0xA4, 0xA5}) {
		t.Errorf("ids = %x", got)
	}
}

func TestDecodeRejections(t *testing.T) {
	ack := func() []byte { return mustHex(t, fxRealtimeAcknowledgement) }
	old := func() []byte { return mustHex(t, fxRealtimeOldFirmware) }
	fix := func(b []byte) []byte { b[len(b)-1] = Checksum(b[:len(b)-1]); return b }
	cases := []struct {
		name  string
		input []byte
		check func(*FrameError) bool
	}{
		{"bad header", func() []byte { b := old(); b[0] = 0xFE; return b }(),
			func(e *FrameError) bool { return e.Kind == FrameErrBadHeader }},
		{"length mismatch", func() []byte { b := old(); b[2]--; return b }(),
			func(e *FrameError) bool {
				return e.Kind == FrameErrLengthMismatch && e.Encoded == 99 && e.Actual == 100
			}},
		{"bad xor", func() []byte { b := old(); b[40] ^= 1; return b }(),
			func(e *FrameError) bool { return e.Kind == FrameErrBadChecksum }},
		{"version after checksum repaired", func() []byte { b := ack(); b[4] = 4; return fix(b) }(),
			func(e *FrameError) bool { return e.Kind == FrameErrUnsupportedVersion && e.Version == 4 }},
		// A1 claims two bytes but only one remains before the checksum.
		{"truncated TLV", func() []byte { b := ack(); b[11] = 2; return fix(b) }(),
			func(e *FrameError) bool { return e.Kind == FrameErrTruncatedTLV && e.At == 10 }},
		{"too short", []byte{0xFF, 0x09},
			func(e *FrameError) bool { return e.Kind == FrameErrTooShort && e.Size == 2 }},
		{"too large", make([]byte, MaxFrameLength+1),
			func(e *FrameError) bool { return e.Kind == FrameErrTooLarge && e.Size == MaxFrameLength+1 }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Decode(tc.input)
			if err == nil {
				t.Fatal("decoded")
			}
			if e := frameKind(t, err); !tc.check(e) {
				t.Errorf("error = %+v", e)
			}
		})
	}
}

func TestEveryTruncatedPrefixIsRejected(t *testing.T) {
	b := mustHex(t, fxRealtimeNewFirmware)
	for end := 0; end < len(b); end++ {
		if _, err := Decode(b[:end]); err == nil {
			t.Errorf("prefix length %d unexpectedly decoded", end)
		}
	}
}

func messageTypes(frames []Frame) []uint16 {
	out := []uint16{}
	for _, f := range frames {
		out = append(out, f.MessageType)
	}
	return out
}

func TestReassemblesEverySplitBoundary(t *testing.T) {
	b := mustHex(t, fxRealtimeNewFirmware)
	for split := 1; split < len(b); split++ {
		var r Reassembler
		if got := r.Append(b[:split]); len(got) != 0 {
			t.Fatalf("split %d: early frames", split)
		}
		if got := messageTypes(r.Append(b[split:])); !reflect.DeepEqual(got, []uint16{MsgRealtime}) {
			t.Fatalf("split %d: %x", split, got)
		}
	}
}

func TestSplitsCoalescedFramesAndRetainsTrailingHeaderByte(t *testing.T) {
	first := mustHex(t, fxRealtimeAcknowledgement)
	second := mustHex(t, fxVersionInfo)
	var r Reassembler
	in := append(append(append([]byte{}, first...), second...), 0xFF)
	if got := messageTypes(r.Append(in)); !reflect.DeepEqual(got, []uint16{0x0A0B, 0x0830}) {
		t.Fatalf("types = %x", got)
	}
	if r.DroppedBytes() != 0 {
		t.Errorf("dropped = %d", r.DroppedBytes())
	}
	if got := messageTypes(r.Append(first[1:])); !reflect.DeepEqual(got, []uint16{0x0A0B}) {
		t.Errorf("third = %x", got)
	}
}

func TestRecoversValidFrameAfterMalformedCandidate(t *testing.T) {
	corrupt := mustHex(t, fxRealtimeAcknowledgement)
	corrupt[len(corrupt)-1] ^= 1
	var r Reassembler
	got := r.Append(append(corrupt, mustHex(t, fxVersionInfo)...))
	if !reflect.DeepEqual(messageTypes(got), []uint16{MsgVersionInfo}) {
		t.Fatalf("types = %x", messageTypes(got))
	}
	if r.RejectedFrames() != 1 {
		t.Errorf("rejected = %d", r.RejectedFrames())
	}
	if err, _ := r.LastRejection(); err == nil {
		t.Error("no rejection recorded")
	}
}

func TestImplausibleLengthDoesNotStallStream(t *testing.T) {
	var r Reassembler
	if got := r.Append([]byte{0xFF, 0x09, 0x02, 0x00}); len(got) != 0 {
		t.Fatal("frames from garbage")
	}
	got := r.Append(mustHex(t, fxRealtimeAcknowledgement))
	if !reflect.DeepEqual(messageTypes(got), []uint16{MsgRealtimeAck}) {
		t.Fatalf("types = %x", messageTypes(got))
	}
	if r.RejectedFrames() != 1 {
		t.Errorf("rejected = %d", r.RejectedFrames())
	}
}

func TestPlausibleFalseLengthRecoversWhenLaterFrameFullyValidates(t *testing.T) {
	var r Reassembler
	falseCandidate := []byte{0xFF, 0x09, 0x00, 0x08}
	got := r.Append(append(append([]byte{}, falseCandidate...), mustHex(t, fxRealtimeAcknowledgement)...))
	if !reflect.DeepEqual(messageTypes(got), []uint16{MsgRealtimeAck}) {
		t.Fatalf("types = %x", messageTypes(got))
	}
	if r.RejectedFrames() != 1 || r.DroppedBytes() != len(falseCandidate) {
		t.Errorf("rejected %d dropped %d", r.RejectedFrames(), r.DroppedBytes())
	}
	err, head := r.LastRejection()
	if err == nil || err.Kind != FrameErrLengthMismatch || err.Encoded != 2048 || err.Actual != len(falseCandidate) {
		t.Errorf("last rejection = %+v", err)
	}
	if !reflect.DeepEqual(head, falseCandidate) {
		t.Errorf("head = %x", head)
	}
}
