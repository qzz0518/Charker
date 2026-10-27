package a2687

import (
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"time"
)

// Cover-transfer arithmetic and frame builders.
//
// These commands write a JPEG into the charger's persistent storage, and there
// is no known BLE command to undo them. The official app deletes covers through
// its cloud. Callers must tell the user that before sending anything; the
// acknowledged-irreversible gate belongs to the session layer.
//
// Evidence grade is lower than the rest of this package: the layout was recovered
// by a third party exploiting the firmware's reused GCM nonce on one machine and
// one firmware. The pure parts below (chunk size, CRC-32, geometry) are
// corroborated by replayed captures; the TLV layouts are consistent but not
// proven.

const (
	// CoverChunkPayloadSize is the JPEG byte count per 0x0221 frame. The last
	// chunk is zero-padded to it so every frame on the wire is the same size.
	CoverChunkPayloadSize = 156
	// CoverAcknowledgeEvery is the firmware's ACK cadence: every 10th chunk.
	CoverAcknowledgeEvery = 10
	// CoverScreenPixelSize is the square panel size. Anything else is cropped,
	// never letterboxed.
	CoverScreenPixelSize = 240
	// CoverDeviceSlotCount is the number of resident pixel slots; a fifth push
	// evicts the oldest (not the one on screen).
	CoverDeviceSlotCount = 4
	// CoverURLPlaceholder is the literal that goes in the FD slot of 0x021F.
	CoverURLPlaceholder = "SmallChargingUrl"
	// CoverCustomScreensaverType is the screenSaverType value selecting a
	// user-supplied image.
	CoverCustomScreensaverType byte = 3
)

// Cover errors. Messages are short and stable.
var (
	// ErrCoverImageEmpty means there is no JPEG data to transfer.
	ErrCoverImageEmpty = errors.New("cover: empty image")
	// ErrCoverTooManyChunks means the image needs more chunks than a u16 can name.
	ErrCoverTooManyChunks = errors.New("cover: too many chunks")
	// ErrCoverURLTooLong means the FD text value cannot fit a one-byte TLV length.
	ErrCoverURLTooLong = errors.New("cover: url too long")
	// ErrCoverChunkPayload means a chunk payload is not exactly 156 bytes.
	ErrCoverChunkPayload = errors.New("cover: chunk payload must be 156 bytes")
	// ErrCoverChunkIndex means a chunk index is outside its transfer.
	ErrCoverChunkIndex = errors.New("cover: chunk index out of range")
	// ErrCoverHashMismatch means a reference's hash is not the hash of the bytes
	// its plan was built from.
	ErrCoverHashMismatch = errors.New("cover: image hash does not match plan")
)

// CoverChunkCount is the number of 0x0221 frames an image of byteCount bytes
// needs. Zero bytes is not a transfer; the firmware has no representation for an
// empty image.
func CoverChunkCount(byteCount int) int {
	if byteCount <= 0 {
		return 0
	}
	return (byteCount + CoverChunkPayloadSize - 1) / CoverChunkPayloadSize
}

// CoverChunk returns the payload of one chunk, zero-padded to
// CoverChunkPayloadSize. Past the end it returns nil: a caller that walked off
// the end has a bug, and a silently empty frame would be sent as image data.
func CoverChunk(data []byte, index int) ([]byte, bool) {
	if index < 0 || index >= CoverChunkCount(len(data)) {
		return nil, false
	}
	start := index * CoverChunkPayloadSize
	end := start + CoverChunkPayloadSize
	if end > len(data) {
		end = len(data)
	}
	payload := make([]byte, CoverChunkPayloadSize)
	copy(payload, data[start:end])
	return payload, true
}

// CRC32 is the IEEE CRC-32 of the image bytes: reflected polynomial 0xEDB88320,
// init/final XOR 0xFFFFFFFF, i.e. zlib.crc32. This is the hash_code the cloud
// stores and the charger checks.
func CRC32(data []byte) uint32 { return crc32.ChecksumIEEE(data) }

// CoverPlan is everything the 0x0220 header has to declare about a transfer,
// computed once so the start frame and the chunk loop cannot disagree.
type CoverPlan struct {
	ByteCount  int
	ChunkCount int
	// Hash is the CRC-32 of the image bytes.
	Hash uint32
	// Padding is the number of trailing zero bytes in the final chunk.
	Padding int
}

// NewCoverPlan builds a plan for a JPEG. Empty input yields no plan.
func NewCoverPlan(jpeg []byte) (CoverPlan, bool) {
	if len(jpeg) == 0 {
		return CoverPlan{}, false
	}
	chunks := CoverChunkCount(len(jpeg))
	return CoverPlan{
		ByteCount:  len(jpeg),
		ChunkCount: chunks,
		Hash:       CRC32(jpeg),
		Padding:    chunks*CoverChunkPayloadSize - len(jpeg),
	}, true
}

// CoverImageReference names a picture, the hash the charger should find, and the
// URL slot contents.
type CoverImageReference struct {
	// PictureID is the cloud picture id, also what 0xE1 reports once the pixels
	// land.
	PictureID uint32
	// Hash is the CRC-32 of the JPEG bytes. 0x021F and 0x0220 must agree on it;
	// CoverTransferTicket enforces that.
	Hash uint32
	// URLKey is the contents of the FD slot in 0x021F.
	URLKey string
}

// NewCoverImageReference builds a reference with the placeholder URL slot.
func NewCoverImageReference(pictureID, hash uint32) CoverImageReference {
	return CoverImageReference{PictureID: pictureID, Hash: hash, URLKey: CoverURLPlaceholder}
}

// NewCoverImageReferenceWithURL builds a reference with an explicit URL slot.
func NewCoverImageReferenceWithURL(pictureID, hash uint32, urlKey string) CoverImageReference {
	return CoverImageReference{PictureID: pictureID, Hash: hash, URLKey: urlKey}
}

// NewCoverImageReferenceForJPEG derives the hash from the very bytes that will be
// sent: the only way to build a reference that cannot disagree with its own
// transfer.
func NewCoverImageReferenceForJPEG(pictureID uint32, jpeg []byte) CoverImageReference {
	return CoverImageReference{PictureID: pictureID, Hash: CRC32(jpeg), URLKey: CoverURLPlaceholder}
}

// ReportedID is the id as 0xE1 reports it. The field is a u16, so an id above
// 65535 aliases onto another picture's low half.
func (r CoverImageReference) ReportedID() uint16 { return uint16(r.PictureID) }

// CoverTransferTicket is a picture and the transfer that will carry it, proven to
// describe the same image. 0x0220 takes one of these rather than an id and a
// plan, so the id in 0x021F and the id in 0x0220 are one stored property read
// twice, and their two hashes were compared before either frame exists.
type CoverTransferTicket struct {
	Image CoverImageReference
	Plan  CoverPlan
}

// NewCoverTransferTicket builds a ticket, refusing a reference whose hash is not
// the plan's own and plans the protocol cannot represent.
func NewCoverTransferTicket(image CoverImageReference, plan CoverPlan) (CoverTransferTicket, error) {
	if image.Hash != plan.Hash {
		return CoverTransferTicket{}, ErrCoverHashMismatch
	}
	if plan.ByteCount <= 0 || plan.ChunkCount <= 0 {
		return CoverTransferTicket{}, ErrCoverImageEmpty
	}
	// 0x0220 declares the chunk count as a u16, so a bigger transfer would be
	// truncated into a valid-looking header for the wrong geometry.
	if plan.ChunkCount > 0xFFFF {
		return CoverTransferTicket{}, ErrCoverTooManyChunks
	}
	return CoverTransferTicket{Image: image, Plan: plan}, nil
}

// CoverChunkAcknowledged reports whether the firmware answers the slice at
// index: every tenth slice plus the final one. The frame builder and the send
// loop must ask the same function about the same pair, or the transport waits
// for nothing while the firmware waits to be read.
func CoverChunkAcknowledged(index, chunkCount int) bool {
	return index == chunkCount-1 || (index+1)%CoverAcknowledgeEvery == 0
}

// CoverChunkStep is one step of a precomputed transfer schedule.
type CoverChunkStep struct {
	Index      int
	ChunkCount int
	Payload    []byte
	// Checkpoint is true when the firmware acknowledges this slice and the
	// sender must wait for it.
	Checkpoint bool
}

// BuildCoverSteps precomputes the whole transfer schedule up front: the chunk
// payloads, and which slices are checkpoints. Recomputing inside the send loop
// is the failure mode that produced the observed overrun (status 0x12 wedged at
// index 10).
func BuildCoverSteps(jpeg []byte, plan CoverPlan) ([]CoverChunkStep, error) {
	if plan.ByteCount == 0 || plan.ChunkCount == 0 {
		return nil, ErrCoverImageEmpty
	}
	if plan.ChunkCount > 0xFFFF {
		return nil, ErrCoverTooManyChunks
	}
	if plan.ByteCount != len(jpeg) {
		return nil, fmt.Errorf("cover: plan describes %d bytes, image has %d", plan.ByteCount, len(jpeg))
	}
	steps := make([]CoverChunkStep, 0, plan.ChunkCount)
	for index := 0; index < plan.ChunkCount; index++ {
		payload, ok := CoverChunk(jpeg, index)
		if !ok {
			return nil, ErrCoverImageEmpty
		}
		steps = append(steps, CoverChunkStep{
			Index:      index,
			ChunkCount: plan.ChunkCount,
			Payload:    payload,
			Checkpoint: CoverChunkAcknowledged(index, plan.ChunkCount),
		})
	}
	return steps, nil
}

// coverMessage assembles a cover command. It deliberately does not reuse
// sessionMessage: cover commands carry the epoch as a typed u32 (FE 05 03 …)
// while other session commands send four bare bytes (FE 04 …). Reusing the
// normal builder produces a frame one byte short with a missing type tag, which
// the firmware answers with silence. 0x0221 chunks carry no FE at all.
func coverMessage(opcode uint16, fields []TLV, at time.Time) OutgoingMessage {
	epoch := uint32(at.Unix())
	all := make([]TLV, 0, len(fields)+2)
	all = append(all, NewTLV(FieldA1, []byte{SessionAction}))
	all = append(all, fields...)
	all = append(all, NewTLV(FieldFE, U32Value(epoch).Encoded()))
	return OutgoingMessage{
		Group:           GroupSession,
		Opcode:          opcode,
		Plaintext:       EncodeTLVs(all),
		Encryption:      EncryptionSession,
		ExpectsResponse: true,
	}
}

// SelectCover builds 0x021F — show the picture this reference names. The
// plaintext is 47 bytes.
//
// Sending this for an image whose pixels are not on the device is not an error:
// the firmware acknowledges it and leaves the display alone, which is why an ACK
// proves nothing and the caller has to read 0xE1 back.
func SelectCover(image CoverImageReference, at time.Time) (OutgoingMessage, error) {
	// TLV lengths are one byte and the encoder truncates; a too-long URL would
	// misalign every later field, including the epoch, in a command that writes
	// to storage with no erase. 254 bytes is the last legal text value.
	if len(image.URLKey) > 254 {
		return OutgoingMessage{}, ErrCoverURLTooLong
	}
	return coverMessage(OpcodeSetScreensaver, []TLV{
		NewTLV(FieldA3, U8Value(CoverCustomScreensaverType).Encoded()),
		NewTLV(FieldA4, BytesValue(u32LE(image.PictureID)).Encoded()),
		NewTLV(FieldA5, BytesValue(u32LE(image.Hash)).Encoded()),
		NewTLV(FieldFD, TextValue(image.URLKey).Encoded()),
	}, at), nil
}

// StartTransfer builds 0x0220 — announce the upload. The plaintext is 49 bytes.
// Takes the ticket, not an id and a plan: the id and hash here are the ones
// SelectCover named, proven by the ticket before either frame exists.
func StartTransfer(ticket CoverTransferTicket, at time.Time) OutgoingMessage {
	plan := ticket.Plan
	return coverMessage(OpcodeCoverTransferStart, []TLV{
		NewTLV(FieldA2, U8Value(1).Encoded()),
		NewTLV(FieldA3, BytesValue(u32LE(ticket.Image.PictureID)).Encoded()),
		NewTLV(FieldA4, BytesValue(u32LE(plan.Hash)).Encoded()),
		NewTLV(FieldA5, U32Value(uint32(plan.ByteCount)).Encoded()),
		NewTLV(FieldA6, U8Value(CoverAcknowledgeEvery).Encoded()),
		NewTLV(FieldA7, U16Value(CoverChunkPayloadSize).Encoded()),
		NewTLV(FieldA8, U16Value(uint16(plan.ChunkCount)).Encoded()),
	}, at)
}

// TransferChunk builds 0x0221 — one slice. The plaintext is 167 bytes, the same
// for every chunk including the last, which is zero-padded rather than sent
// short. There is no epoch trailer on chunk frames; the at parameter is kept for
// symmetry with the other builders and is not encoded.
//
// ExpectsResponse is derived from the slice's position, never passed in: a legal
// frame with the wrong flag is how the sender overruns the charger.
func TransferChunk(sequence, chunkCount int, payload []byte, at time.Time) (OutgoingMessage, error) {
	_ = at // chunk frames carry no epoch; see CoverCommands.transferChunk
	if len(payload) != CoverChunkPayloadSize {
		return OutgoingMessage{}, ErrCoverChunkPayload
	}
	if chunkCount < 1 || chunkCount > 0xFFFF {
		return OutgoingMessage{}, ErrCoverTooManyChunks
	}
	if sequence < 0 || sequence >= chunkCount {
		return OutgoingMessage{}, ErrCoverChunkIndex
	}
	fields := []TLV{
		NewTLV(FieldA1, []byte{SessionAction}),
		NewTLV(FieldA2, U16Value(uint16(sequence)).Encoded()),
		NewTLV(FieldA3, BytesValue(payload).Encoded()),
	}
	return OutgoingMessage{
		Group:           GroupSession,
		Opcode:          OpcodeCoverTransferChunk,
		Plaintext:       EncodeTLVs(fields),
		Encryption:      EncryptionSession,
		ExpectsResponse: CoverChunkAcknowledged(sequence, chunkCount),
	}, nil
}

// NextChunkIndex extracts the next index the firmware wants from a 0x0221 ACK.
//
// The observed reply is 00 A1 01 31 A2=<next index>. Whether A2 carries the
// usual type prefix is not recorded, so both shapes are accepted: a typed scalar
// first, then a bare little-endian pair. Returns false when the reply carries no
// A2, which the caller must treat as "progress unverified", not "progress fine".
func NextChunkIndex(payload Payload) (int, bool) {
	raw, ok := payload.Field(FieldA2)
	if !ok {
		return 0, false
	}
	if scalar, ok := DecodeTypedValue(raw).Scalar(); ok {
		return int(scalar), true
	}
	if len(raw) == 2 {
		return int(binary.LittleEndian.Uint16(raw)), true
	}
	return 0, false
}

// u32LE is the little-endian byte block used where the protocol carries a raw
// four-byte number rather than a typed integer.
func u32LE(value uint32) []byte {
	out := make([]byte, 4)
	binary.LittleEndian.PutUint32(out, value)
	return out
}
