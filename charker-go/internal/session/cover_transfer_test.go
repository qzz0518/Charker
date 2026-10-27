package session

import (
	"context"
	"errors"
	"testing"
	"time"

	"charker/internal/a2687"
)

// fakeCoverLink is a charger that acknowledges every checkpoint with the next
// index and shows whatever was last selected once the last slice landed.
type fakeCoverLink struct {
	shown       uint16
	shownKnown  bool
	selected    uint16
	chunkCount  int
	fills       []int
	checkpoints []int
	nextOffset  int // added to the reported next index (0 = honest)
	onFill      func(index int)
}

func ok() a2687.Payload {
	status := byte(0)
	return a2687.Payload{Status: &status}
}

func (f *fakeCoverLink) SelectCover(image a2687.CoverImageReference) (a2687.Payload, error) {
	f.selected = image.ReportedID()
	return ok(), nil
}

func (f *fakeCoverLink) BeginCoverTransfer(ticket a2687.CoverTransferTicket) (a2687.Payload, error) {
	f.chunkCount = ticket.Plan.ChunkCount
	return ok(), nil
}

func (f *fakeCoverLink) SendFill(step a2687.CoverChunkStep) error {
	f.fills = append(f.fills, step.Index)
	if f.onFill != nil {
		f.onFill(step.Index)
	}
	return nil
}

func (f *fakeCoverLink) SendCheckpoint(step a2687.CoverChunkStep, _ time.Duration) (a2687.Payload, error) {
	f.checkpoints = append(f.checkpoints, step.Index)
	status := byte(0)
	if step.Index == step.ChunkCount-1 {
		status = coverTransferComplete
		f.shown, f.shownKnown = f.selected, true
	}
	next := uint16(step.Index + 1 + f.nextOffset)
	p := a2687.Payload{Status: &status, Fields: []a2687.TLV{a2687.NewTLV(a2687.FieldA2, a2687.U16Value(next).Encoded())}}
	return p, nil
}

func (f *fakeCoverLink) ReadCoverPictureID() (uint16, bool, error) {
	return f.shown, f.shownKnown, nil
}

func fastOptions() CoverTransferOptions {
	o := DefaultCoverTransferOptions()
	o.SettleAfterSelect, o.SettleAfterStart, o.ChunkSpacing = 0, 0, 0
	o.SettleBeforeVerify, o.VerifyRetryDelay = 0, 0
	return o
}

func testJPEG(n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(i * 7)
	}
	return b
}

func TestCoverPushPacingAndWitness(t *testing.T) {
	jpeg := testJPEG(156*25 + 3) // 26 slices
	link := &fakeCoverLink{shown: 7, shownKnown: true}
	image := a2687.NewCoverImageReferenceForJPEG(0x0001_1234, jpeg)
	var last CoverProgress
	out, err := NewCoverTransfer(link, fastOptions()).Push(context.Background(), jpeg, image, true, func(p CoverProgress) { last = p })
	if err != nil {
		t.Fatalf("Push: %v", err)
	}
	// Every tenth slice and the last one wait for an answer; the rest do not.
	want := []int{9, 19, 25}
	if len(link.checkpoints) != len(want) {
		t.Fatalf("checkpoints = %v, want %v", link.checkpoints, want)
	}
	for i, idx := range want {
		if link.checkpoints[i] != idx {
			t.Fatalf("checkpoints = %v, want %v", link.checkpoints, want)
		}
	}
	if len(link.fills)+len(link.checkpoints) != 26 {
		t.Fatalf("sent %d slices, want 26", len(link.fills)+len(link.checkpoints))
	}
	if !out.Witnessed() || out.Before != 7 || out.ReportedPictureID != 0x1234 {
		t.Fatalf("outcome = %+v, want witnessed 7 -> 0x1234", out)
	}
	if out.IndexedCheckpoints != 3 || last.Stage != CoverStageFinished || last.ChunksSent != 26 {
		t.Fatalf("outcome %+v, last progress %+v", out, last)
	}
}

func TestCoverPushRefusesWithoutAcknowledgement(t *testing.T) {
	link := &fakeCoverLink{}
	jpeg := testJPEG(400)
	_, err := NewCoverTransfer(link, fastOptions()).Push(context.Background(), jpeg, a2687.NewCoverImageReferenceForJPEG(1, jpeg), false, nil)
	var ce *CoverTransferError
	if !errors.As(err, &ce) || ce.Kind != CoverIrreversibilityNotAcknowledged || ce.PixelsMayHaveLanded() {
		t.Fatalf("err = %v, want irreversibility refusal", err)
	}
	if link.selected != 0 || len(link.fills) != 0 {
		t.Fatal("frames were sent without the acknowledgement")
	}
}

func TestCoverPushProgressMismatchAndCancel(t *testing.T) {
	jpeg := testJPEG(156 * 30)
	link := &fakeCoverLink{nextOffset: 1}
	_, err := NewCoverTransfer(link, fastOptions()).Push(context.Background(), jpeg, a2687.NewCoverImageReferenceForJPEG(2, jpeg), true, nil)
	var ce *CoverTransferError
	if !errors.As(err, &ce) || ce.Kind != CoverProgressMismatch || !ce.PixelsMayHaveLanded() {
		t.Fatalf("err = %v, want progress mismatch", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	link = &fakeCoverLink{onFill: func(i int) {
		if i == 4 {
			cancel()
		}
	}}
	_, err = NewCoverTransfer(link, fastOptions()).Push(ctx, jpeg, a2687.NewCoverImageReferenceForJPEG(3, jpeg), true, nil)
	if !errors.As(err, &ce) || ce.Kind != CoverCancelled || ce.Sent != 5 {
		t.Fatalf("err = %v, want cancelled after 5 slices", err)
	}
}

func TestCoverPictureIDFromReadAll(t *testing.T) {
	status := byte(0)
	p := a2687.Payload{Status: &status, Fields: []a2687.TLV{
		a2687.NewTLV(coverStateField, a2687.BytesValue([]byte{0x05, 0x00, 0x34, 0x12}).Encoded()),
	}}
	id, ok := CoverPictureID(p)
	if !ok || id != 0x1234 {
		t.Fatalf("id = %x %v, want 1234", id, ok)
	}
}
