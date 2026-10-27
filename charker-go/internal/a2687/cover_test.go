package a2687

import (
	"errors"
	"reflect"
	"testing"
	"time"
)

// V1: chunk counts match the recorded transfers.
func TestChunkCountMatchesTheRecordedTransfers(t *testing.T) {
	cases := map[int]int{25397: 163, 20876: 134, 18539: 119, 1: 1, 155: 1, 156: 1, 157: 2, 312: 2}
	for byteCount, want := range cases {
		if got := CoverChunkCount(byteCount); got != want {
			t.Errorf("CoverChunkCount(%d) = %d, want %d", byteCount, got, want)
		}
	}
	if got := CoverChunkCount(0); got != 0 {
		t.Errorf("CoverChunkCount(0) = %d, want 0", got)
	}
}

// V2: the final chunk is zero-padded so every frame is the same size.
func TestFinalChunkIsZeroPaddedToAFullFrame(t *testing.T) {
	jpeg := make([]byte, 25397)
	for i := range jpeg {
		jpeg[i] = 0xAB
	}
	plan, ok := NewCoverPlan(jpeg)
	if !ok {
		t.Fatal("NewCoverPlan failed")
	}
	if plan.ChunkCount != 163 {
		t.Errorf("chunkCount = %d, want 163", plan.ChunkCount)
	}
	if plan.Padding != 31 {
		t.Errorf("padding = %d, want 31", plan.Padding)
	}
	last, ok := CoverChunk(jpeg, 162)
	if !ok {
		t.Fatal("chunk 162 missing")
	}
	if len(last) != CoverChunkPayloadSize {
		t.Fatalf("last chunk length = %d", len(last))
	}
	if !reflect.DeepEqual(last[:125], filled(0xAB, 125)) {
		t.Errorf("last chunk prefix = %x…", last[:8])
	}
	if !reflect.DeepEqual(last[125:], make([]byte, 31)) {
		t.Errorf("last chunk padding = %x", last[125:])
	}
}

func filled(value byte, count int) []byte {
	out := make([]byte, count)
	for i := range out {
		out[i] = value
	}
	return out
}

// V3: an exact multiple needs no padding.
func TestExactMultipleNeedsNoPadding(t *testing.T) {
	jpeg := filled(0x5A, 156*4)
	plan, ok := NewCoverPlan(jpeg)
	if !ok {
		t.Fatal("NewCoverPlan failed")
	}
	if plan.ChunkCount != 4 || plan.Padding != 0 {
		t.Errorf("chunkCount/padding = %d/%d", plan.ChunkCount, plan.Padding)
	}
	last, ok := CoverChunk(jpeg, 3)
	if !ok || last[len(last)-1] != 0x5A {
		t.Errorf("last chunk tail = %x", last[len(last)-1:])
	}
}

// V4: walking off the end is refused, not returned as an empty frame.
func TestOutOfRangeChunkIsRejected(t *testing.T) {
	jpeg := filled(1, 200)
	if got := CoverChunkCount(200); got != 2 {
		t.Fatalf("chunkCount = %d, want 2", got)
	}
	if _, ok := CoverChunk(jpeg, 1); !ok {
		t.Error("chunk 1 should exist")
	}
	for _, index := range []int{2, -1, 99} {
		if chunk, ok := CoverChunk(jpeg, index); ok || chunk != nil {
			t.Errorf("chunk %d = %x/%v, want nil/false", index, chunk, ok)
		}
	}
}

// V5: an empty image is not a transfer.
func TestEmptyImageIsNotATransfer(t *testing.T) {
	if got := CoverChunkCount(0); got != 0 {
		t.Errorf("chunkCount = %d", got)
	}
	if _, ok := NewCoverPlan(nil); ok {
		t.Error("empty image produced a plan")
	}
	if _, ok := NewCoverPlan([]byte{}); ok {
		t.Error("empty image produced a plan")
	}
}

// V6: the canonical IEEE CRC-32 check value.
func TestCRC32MatchesTheStandardCheckValue(t *testing.T) {
	cases := []struct {
		data []byte
		want uint32
	}{
		{[]byte("123456789"), 0xCBF43926},
		{nil, 0},
		{[]byte{0x00}, 0xD202EF8D},
	}
	for _, tc := range cases {
		if got := CRC32(tc.data); got != tc.want {
			t.Errorf("CRC32(%x) = 0x%08X, want 0x%08X", tc.data, got, tc.want)
		}
	}
}

// V7: the plan is self-consistent for every recorded size.
func TestPlanIsSelfConsistent(t *testing.T) {
	for _, size := range []int{1, 155, 156, 157, 18539, 20876, 25397} {
		jpeg := make([]byte, size)
		for i := range jpeg {
			jpeg[i] = byte(i % 251)
		}
		plan, ok := NewCoverPlan(jpeg)
		if !ok {
			t.Fatalf("NewCoverPlan(%d) failed", size)
		}
		if plan.ByteCount != size {
			t.Errorf("byteCount = %d, want %d", plan.ByteCount, size)
		}
		if plan.ChunkCount*CoverChunkPayloadSize != plan.ByteCount+plan.Padding {
			t.Errorf("size %d: chunk grid mismatch", size)
		}
		var rebuilt []byte
		for index := 0; index < plan.ChunkCount; index++ {
			chunk, ok := CoverChunk(jpeg, index)
			if !ok {
				t.Fatalf("size %d: chunk %d missing", size, index)
			}
			rebuilt = append(rebuilt, chunk...)
		}
		if !reflect.DeepEqual(rebuilt[:size], jpeg) {
			t.Errorf("size %d: reassembly mismatch", size)
		}
		if !reflect.DeepEqual(rebuilt[size:], make([]byte, plan.Padding)) {
			t.Errorf("size %d: padding mismatch", size)
		}
	}
}

// V8: the select plaintext, pinned byte for byte (spec-protocol §8.3).
func TestSelectCoverPlaintextPinned(t *testing.T) {
	at := time.Unix(0x12345678, 0)
	message, err := SelectCover(NewCoverImageReference(24551, 0xDEADBEEF), at)
	if err != nil {
		t.Fatalf("SelectCover: %v", err)
	}
	if len(message.Plaintext) != 47 {
		t.Errorf("plaintext length = %d, want 47", len(message.Plaintext))
	}
	if message.Opcode != OpcodeSetScreensaver {
		t.Errorf("opcode = 0x%04X", message.Opcode)
	}
	if message.Group != GroupSession || message.Encryption != EncryptionSession {
		t.Errorf("group/encryption = 0x%02X/%v", message.Group, message.Encryption)
	}
	// The complete 47-byte plaintext. The spec-protocol §8.3 table shows 06 as
	// the length byte of A4/A5, which does not parse: an id/hash is four bytes
	// wrapped in the 0x04 typed-bytes tag, so the TLV length is 5. The Swift
	// tests pin the field values (and the 47-byte total), which is what this
	// string reproduces.
	want := "a10121a3020103a40504e75f0000a50504efbeaddefd1100536d616c6c4368617267696e6755726cfe050378563412"
	if got := hexStr(message.Plaintext); got != want {
		t.Errorf("select plaintext = %s\nwant               %s", got, want)
	}
}

// V9/V13/V14: the start frame declares id, hash and geometry with mixed wrapping.
func TestStartTransferPlaintext(t *testing.T) {
	plan, ok := NewCoverPlan(filled(0, 25397))
	if !ok {
		t.Fatal("NewCoverPlan failed")
	}
	ticket, err := NewCoverTransferTicket(NewCoverImageReference(24551, plan.Hash), plan)
	if err != nil {
		t.Fatalf("ticket: %v", err)
	}
	message := StartTransfer(ticket, time.Unix(0x12345678, 0))
	if len(message.Plaintext) != 49 {
		t.Errorf("plaintext length = %d, want 49", len(message.Plaintext))
	}
	if message.Opcode != OpcodeCoverTransferStart {
		t.Errorf("opcode = 0x%04X", message.Opcode)
	}
	fields := mustPayload(t, hexStr(message.Plaintext))
	checks := []struct {
		id   byte
		want []byte
	}{
		{FieldA2, []byte{0x01, 0x01}},
		{FieldA3, append([]byte{0x04}, u32LE(24551)...)},
		{FieldA4, append([]byte{0x04}, u32LE(plan.Hash)...)},
		{FieldA5, append([]byte{0x03}, u32LE(25397)...)},
		{FieldA6, []byte{0x01, 0x0A}},
		{FieldA7, []byte{0x02, 0x9C, 0x00}},
		{FieldA8, []byte{0x02, 0xA3, 0x00}},
	}
	for _, check := range checks {
		got, ok := fields.Field(check.id)
		if !ok || !reflect.DeepEqual(got, check.want) {
			t.Errorf("field 0x%02X = %x/%v, want %x", check.id, got, ok, check.want)
		}
	}
	if plan.ChunkCount != 163 {
		t.Errorf("chunkCount = %d", plan.ChunkCount)
	}
}

// V10/V15: chunk plaintext length and fields (no epoch trailer).
func TestChunkCarriesSequenceAndPayloadOnly(t *testing.T) {
	payload := filled(0, CoverChunkPayloadSize)
	payload[0] = 0xFF
	payload[155] = 0x11
	message, err := TransferChunk(258, 1000, payload, time.Unix(0x12345678, 0))
	if err != nil {
		t.Fatalf("TransferChunk: %v", err)
	}
	if len(message.Plaintext) != 167 {
		t.Errorf("plaintext length = %d, want 167", len(message.Plaintext))
	}
	if message.Opcode != OpcodeCoverTransferChunk {
		t.Errorf("opcode = 0x%04X", message.Opcode)
	}
	fields := mustPayload(t, hexStr(message.Plaintext))
	if len(fields.Fields) != 3 {
		t.Errorf("fields = %d, want 3", len(fields.Fields))
	}
	if _, ok := fields.Field(FieldFE); ok {
		t.Error("chunk frames carry no epoch")
	}
	if got, _ := fields.Field(FieldA2); !reflect.DeepEqual(got, []byte{0x02, 0x02, 0x01}) {
		t.Errorf("A2 = %x, want 02 02 01", got)
	}
	slice, _ := fields.Field(FieldA3)
	if len(slice) != 157 || slice[0] != TypedBytesType {
		t.Errorf("A3 = %d bytes, first=%02X; want 157/0x04", len(slice), slice[0])
	}
	if !reflect.DeepEqual(slice[1:], payload) {
		t.Error("A3 payload mismatch")
	}
}

// V11: the cover epoch trailer is a typed u32 (FE 05 03 …), unlike the session
// commands' four bare bytes.
func TestCoverEpochIsATypedU32(t *testing.T) {
	message, err := SelectCover(NewCoverImageReference(1, 2), time.Unix(0x12345678, 0))
	if err != nil {
		t.Fatalf("SelectCover: %v", err)
	}
	fields := mustPayload(t, hexStr(message.Plaintext))
	trailer := fields.Fields[len(fields.Fields)-1]
	if trailer.ID != FieldFE {
		t.Fatalf("last field id = 0x%02X, want FE", trailer.ID)
	}
	want := []byte{TypedU32Type, 0x78, 0x56, 0x34, 0x12}
	if !reflect.DeepEqual(trailer.Value, want) {
		t.Errorf("trailer = %x, want %x", trailer.Value, want)
	}
	if len(trailer.Value) != 5 {
		t.Errorf("trailer length = %d, want 5 (not the 4 of a bare stamp)", len(trailer.Value))
	}
}

// V12/V19: the URL slot is text-tagged and its length byte closes exactly, up to
// the last legal value.
func TestURLSlotShape(t *testing.T) {
	at := time.Unix(0x12345678, 0)
	message, err := SelectCover(NewCoverImageReference(1, 2), at)
	if err != nil {
		t.Fatalf("SelectCover: %v", err)
	}
	fields := mustPayload(t, hexStr(message.Plaintext))
	slot, ok := fields.Field(FieldFD)
	if !ok {
		t.Fatal("missing FD")
	}
	if len(slot) != 17 || slot[0] != TypedTextType {
		t.Errorf("FD = %d bytes first %02X, want 17/0x00", len(slot), slot[0])
	}
	if got := string(slot[1:]); got != "SmallChargingUrl" {
		t.Errorf("FD text = %q", got)
	}
	if got := len(CoverURLPlaceholder); got != 16 {
		t.Errorf("placeholder length = %d, want 16", got)
	}

	longURL := string(filled('k', 254))
	message, err = SelectCover(NewCoverImageReferenceWithURL(1, 2, longURL), at)
	if err != nil {
		t.Fatalf("SelectCover with a 254-byte URL: %v", err)
	}
	fields = mustPayload(t, hexStr(message.Plaintext))
	slot, _ = fields.Field(FieldFD)
	if len(slot) != 255 {
		t.Errorf("long FD = %d bytes, want 255", len(slot))
	}
	// The epoch still parses: that is what a wrong length byte breaks.
	if fields.Fields[len(fields.Fields)-1].ID != FieldFE {
		t.Error("epoch no longer parses after the long URL")
	}

	// 255 bytes would overflow the one-byte TLV length; refuse rather than build
	// a frame that writes garbage to storage with no erase.
	if _, err := SelectCover(NewCoverImageReferenceWithURL(1, 2, string(filled('k', 255))), at); err == nil {
		t.Error("a 255-byte URL must be refused")
	} else if !errors.Is(err, ErrCoverURLTooLong) {
		t.Errorf("error = %v, want ErrCoverURLTooLong", err)
	}
}

// V16/V17/V18: which slices are checkpoints.
func TestChunkAcknowledgementRules(t *testing.T) {
	const count = 163
	acknowledged := make([]int, 0, count)
	for index := 0; index < count; index++ {
		if CoverChunkAcknowledged(index, count) {
			acknowledged = append(acknowledged, index)
		}
	}
	if len(acknowledged) != 17 {
		t.Errorf("acknowledged count = %d, want 17", len(acknowledged))
	}
	if acknowledged[0] != 9 || acknowledged[len(acknowledged)-1] != count-1 {
		t.Errorf("acknowledged = %v", acknowledged)
	}
	if !CoverChunkAcknowledged(0, 1) {
		t.Error("a single-slice image is all checkpoint")
	}
	if CoverChunkAcknowledged(0, 2) {
		t.Error("index 0 of 2 is not a checkpoint")
	}

	// The frame derives its expectsResponse flag from the same rule.
	for index := 0; index < count; index++ {
		message, err := TransferChunk(index, count, filled(0, CoverChunkPayloadSize), commandEpoch())
		if err != nil {
			t.Fatalf("TransferChunk(%d): %v", index, err)
		}
		if message.ExpectsResponse != CoverChunkAcknowledged(index, count) {
			t.Fatalf("index %d expectsResponse = %v", index, message.ExpectsResponse)
		}
	}
}

// V20/V21: one id and one hash across select and start; a mismatched hash cannot
// become a ticket.
func TestTicketKeepsTheIDAndHashConsistent(t *testing.T) {
	jpeg := filled(3, 1000)
	image := NewCoverImageReferenceForJPEG(0x5FE7, jpeg)
	plan, ok := NewCoverPlan(jpeg)
	if !ok {
		t.Fatal("NewCoverPlan failed")
	}
	if image.Hash != plan.Hash {
		t.Fatalf("image hash = 0x%08X, plan hash = 0x%08X", image.Hash, plan.Hash)
	}
	ticket, err := NewCoverTransferTicket(image, plan)
	if err != nil {
		t.Fatalf("ticket: %v", err)
	}

	at := time.Unix(0x12345678, 0)
	selectMessage, err := SelectCover(ticket.Image, at)
	if err != nil {
		t.Fatalf("SelectCover: %v", err)
	}
	startMessage := StartTransfer(ticket, at)
	selectFields := mustPayload(t, hexStr(selectMessage.Plaintext))
	startFields := mustPayload(t, hexStr(startMessage.Plaintext))

	// A4 in the select and A3 in the start carry the same bytes.
	selected, _ := selectFields.Field(FieldA4)
	declared, _ := startFields.Field(FieldA3)
	if !reflect.DeepEqual(selected, declared) {
		t.Errorf("id mismatch: select %x, start %x", selected, declared)
	}
	if !reflect.DeepEqual(selected[1:], u32LE(image.PictureID)) {
		t.Errorf("id bytes = %x", selected)
	}
	// A5 in the select and A4 in the start carry the same hash.
	selectHash, _ := selectFields.Field(FieldA5)
	startHash, _ := startFields.Field(FieldA4)
	if !reflect.DeepEqual(selectHash, startHash) {
		t.Errorf("hash mismatch: select %x, start %x", selectHash, startHash)
	}

	// A reference whose hash is not the plan's cannot become a ticket at all.
	if _, err := NewCoverTransferTicket(NewCoverImageReference(1, 0xDEADBEEF), plan); err == nil {
		t.Error("mismatched hash produced a ticket")
	} else if !errors.Is(err, ErrCoverHashMismatch) {
		t.Errorf("error = %v", err)
	}
	if _, err := NewCoverTransferTicket(NewCoverImageReference(1, plan.Hash), plan); err != nil {
		t.Errorf("matching hash refused: %v", err)
	}
	// Plans the protocol cannot express are refused before any frame exists.
	if _, err := NewCoverTransferTicket(NewCoverImageReference(1, 0), CoverPlan{}); !errors.Is(err, ErrCoverImageEmpty) {
		t.Errorf("empty plan error = %v", err)
	}
	if _, err := NewCoverTransferTicket(NewCoverImageReference(1, 0), CoverPlan{ByteCount: 1, ChunkCount: 0x10000}); !errors.Is(err, ErrCoverTooManyChunks) {
		t.Errorf("oversized plan error = %v", err)
	}
	if got := NewCoverImageReference(0x12345, 0).ReportedID(); got != 0x2345 {
		t.Errorf("reportedID = 0x%04X", got)
	}
}

// V22: ACK parsing accepts the typed scalar and the bare u16 shapes.
func TestNextChunkIndexParsing(t *testing.T) {
	cases := []struct {
		name   string
		fields []TLV
		want   int
		wantOK bool
	}{
		{"bare", []TLV{NewTLV(FieldA2, []byte{0x0A, 0x00})}, 10, true},
		{"typedU16", []TLV{NewTLV(FieldA2, U16Value(163).Encoded())}, 163, true},
		{"typedU8", []TLV{NewTLV(FieldA2, U8Value(7).Encoded())}, 7, true},
		{"missing", nil, 0, false},
		{"malformed", []TLV{NewTLV(FieldA2, []byte{0x04, 0x01, 0x02})}, 0, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			payload := NewPayload(bytePtr(0), tc.fields)
			got, ok := NextChunkIndex(payload)
			if ok != tc.wantOK || (ok && got != tc.want) {
				t.Errorf("NextChunkIndex = %d/%v, want %d/%v", got, ok, tc.want, tc.wantOK)
			}
		})
	}
}

// The precomputed schedule marks exactly the checkpoint slices.
func TestBuildCoverSteps(t *testing.T) {
	jpeg := filled(0x42, 25397)
	plan, ok := NewCoverPlan(jpeg)
	if !ok {
		t.Fatal("NewCoverPlan failed")
	}
	steps, err := BuildCoverSteps(jpeg, plan)
	if err != nil {
		t.Fatalf("BuildCoverSteps: %v", err)
	}
	if len(steps) != 163 {
		t.Fatalf("steps = %d, want 163", len(steps))
	}
	checkpoints := 0
	for index, step := range steps {
		if step.Index != index || step.ChunkCount != 163 {
			t.Errorf("step %d = %+v", index, step)
		}
		if len(step.Payload) != CoverChunkPayloadSize {
			t.Errorf("step %d payload = %d", index, len(step.Payload))
		}
		if step.Checkpoint != CoverChunkAcknowledged(index, 163) {
			t.Errorf("step %d checkpoint = %v", index, step.Checkpoint)
		}
		if step.Checkpoint {
			checkpoints++
		}
	}
	if checkpoints != 17 {
		t.Errorf("checkpoints = %d, want 17", checkpoints)
	}
	if _, err := BuildCoverSteps(nil, CoverPlan{}); err == nil {
		t.Error("an empty image must not build steps")
	}
	if _, err := BuildCoverSteps(jpeg, CoverPlan{ByteCount: len(jpeg), ChunkCount: 70000}); err == nil {
		t.Error("a chunk count beyond u16 must be refused")
	}
	if _, err := BuildCoverSteps(jpeg, CoverPlan{ByteCount: len(jpeg) - 1, ChunkCount: plan.ChunkCount}); err == nil {
		t.Error("a plan that disagrees with the image must be refused")
	}
}

func TestTransferChunkValidation(t *testing.T) {
	if _, err := TransferChunk(0, 1, make([]byte, 155), commandEpoch()); !errors.Is(err, ErrCoverChunkPayload) {
		t.Errorf("short payload error = %v", err)
	}
	if _, err := TransferChunk(0, 1, make([]byte, 157), commandEpoch()); !errors.Is(err, ErrCoverChunkPayload) {
		t.Errorf("long payload error = %v", err)
	}
	if _, err := TransferChunk(0, 0, make([]byte, 156), commandEpoch()); !errors.Is(err, ErrCoverTooManyChunks) {
		t.Errorf("zero chunk count error = %v", err)
	}
	if _, err := TransferChunk(1, 1, make([]byte, 156), commandEpoch()); !errors.Is(err, ErrCoverChunkIndex) {
		t.Errorf("index == count error = %v", err)
	}
	if _, err := TransferChunk(-1, 1, make([]byte, 156), commandEpoch()); !errors.Is(err, ErrCoverChunkIndex) {
		t.Errorf("negative index error = %v", err)
	}
	message, err := TransferChunk(0, 1, make([]byte, 156), commandEpoch())
	if err != nil {
		t.Fatalf("valid chunk: %v", err)
	}
	if !message.ExpectsResponse {
		t.Error("the only slice of a single-slice image must wait for its ACK")
	}
}

// Every cover message starts with the action marker.
func TestCoverCommandsStartWithTheActionMarker(t *testing.T) {
	at := time.Unix(0x12345678, 0)
	plan, _ := NewCoverPlan(filled(3, 1000))
	image := NewCoverImageReference(1, plan.Hash)
	ticket, _ := NewCoverTransferTicket(image, plan)
	selectMessage, _ := SelectCover(image, at)
	startMessage := StartTransfer(ticket, at)
	chunkMessage, _ := TransferChunk(0, 1, filled(0, 156), at)
	for _, message := range []OutgoingMessage{selectMessage, startMessage, chunkMessage} {
		fields := mustPayload(t, hexStr(message.Plaintext))
		first := fields.Fields[0]
		if first.ID != FieldA1 || !reflect.DeepEqual(first.Value, []byte{SessionAction}) {
			t.Errorf("opcode 0x%04X first field = %+v", message.Opcode, first)
		}
	}
}
