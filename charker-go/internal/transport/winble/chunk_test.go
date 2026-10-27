package winble

import "testing"

func TestPayloadLimit(t *testing.T) {
	tests := []struct {
		mtu  uint16
		want int
	}{
		{23, 20}, // ATT minimum
		{0, 20},  // not negotiated yet: conservative
		{22, 20}, // below the ATT minimum
		{24, 21},
		{247, 244},
		{517, 514},
	}
	for _, tc := range tests {
		if got := payloadLimit(tc.mtu); got != tc.want {
			t.Errorf("payloadLimit(%d) = %d, want %d", tc.mtu, got, tc.want)
		}
	}
}

func TestSegmentFrame(t *testing.T) {
	tests := []struct {
		name  string
		n     int
		chunk int
		want  [][2]int
	}{
		{"empty frame", 0, 20, nil},
		{"negative length", -1, 20, nil},
		{"zero chunk", 20, 0, nil},
		{"single short chunk", 16, 20, [][2]int{{0, 16}}},
		{"exactly one chunk", 20, 20, [][2]int{{0, 20}}},
		{"exactly two chunks", 40, 20, [][2]int{{0, 20}, {20, 40}}},
		{"handshake frame at ATT minimum", 80, 20,
			[][2]int{{0, 20}, {20, 40}, {40, 60}, {60, 80}}},
		{"largest A2687 frame at ATT minimum", 193, 20,
			[][2]int{{0, 20}, {20, 40}, {40, 60}, {60, 80}, {80, 100},
				{100, 120}, {120, 140}, {140, 160}, {160, 180}, {180, 193}}},
		{"largest A2687 frame fits a 247 MTU", 193, 244,
			[][2]int{{0, 193}}},
		{"chunk larger than frame", 100, 1024, [][2]int{{0, 100}}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := segmentFrame(tc.n, tc.chunk)
			if len(got) != len(tc.want) {
				t.Fatalf("segmentFrame(%d, %d) = %v, want %v", tc.n, tc.chunk, got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("segmentFrame(%d, %d)[%d] = %v, want %v", tc.n, tc.chunk, i, got[i], tc.want[i])
				}
			}
		})
	}
}

// TestSegmentFrameCoversFrame checks the invariant the chunked write path
// depends on: the ranges are contiguous, start at 0, end at n, and none is
// longer than the chunk.
func TestSegmentFrameCoversFrame(t *testing.T) {
	const n = 193
	segs := segmentFrame(n, payloadLimit(23))
	next := 0
	for _, seg := range segs {
		if seg[0] != next {
			t.Fatalf("segment %v does not start at %d", seg, next)
		}
		if seg[1]-seg[0] > payloadLimit(23) {
			t.Fatalf("segment %v longer than the payload limit %d", seg, payloadLimit(23))
		}
		next = seg[1]
	}
	if next != n {
		t.Fatalf("segments cover %d bytes, want %d", next, n)
	}
}

// TestWritePlanChoices pins the write-path decision the transport documents: a
// write with response may send a whole 193-byte A2687 frame in one call (the OS
// fragments it into an ATT long write), while a write command has to be split.
func TestWritePlanChoices(t *testing.T) {
	const largestA2687Frame = 193
	if got := segmentFrame(largestA2687Frame, largestA2687Frame); len(got) != 1 {
		t.Fatalf("with-response plan = %v, want a single write", got)
	}
	if got := segmentFrame(largestA2687Frame, payloadLimit(23)); len(got) != 10 {
		t.Fatalf("without-response plan at MTU 23 has %d chunks, want 10", len(got))
	}
}
