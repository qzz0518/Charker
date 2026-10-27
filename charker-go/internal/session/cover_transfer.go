package session

import (
	"context"
	"fmt"
	"sync/atomic"
	"time"

	"charker/internal/a2687"
)

// CoverTransfer drives the three-command dance that puts a custom picture on
// the charger's own screen (CharkerCore/CoverTransferSession.swift): 0x021F
// names it, 0x0220 declares the transfer, 0x0221 carries the JPEG 156 bytes at
// a time. Nothing here touches Bluetooth; every byte leaves through a
// CoverLink, so the pacing can be tested against a fake charger.
//
// The write cannot be undone: no BLE command erases a cover. Push refuses
// outright unless the caller acknowledges that, and the only honest source of
// that acknowledgement is the confirmation the user ticked for this image.

// CoverLink is the transport the state machine writes through
// (CoverTransferLink).
type CoverLink interface {
	// SelectCover sends 0x021F and returns its acknowledgement.
	SelectCover(image a2687.CoverImageReference) (a2687.Payload, error)
	// BeginCoverTransfer sends 0x0220 and returns its acknowledgement.
	BeginCoverTransfer(ticket a2687.CoverTransferTicket) (a2687.Payload, error)
	// SendFill writes a slice the firmware does not answer.
	SendFill(step a2687.CoverChunkStep) error
	// SendCheckpoint writes a slice the firmware answers and returns that
	// answer; sending past an unanswered checkpoint overruns the firmware.
	SendCheckpoint(step a2687.CoverChunkStep, timeout time.Duration) (a2687.Payload, error)
	// ReadCoverPictureID reads the id the panel shows (0xE1, low 16 bits).
	ReadCoverPictureID() (uint16, bool, error)
}

// CoverTransferOptions are the deliberate pauses and limits
// (CoverTransferSession.Options).
type CoverTransferOptions struct {
	SettleAfterSelect      time.Duration
	SettleAfterStart       time.Duration
	ChunkSpacing           time.Duration
	AcknowledgementTimeout time.Duration
	SettleBeforeVerify     time.Duration
	VerifyAttempts         int
	VerifyRetryDelay       time.Duration
	TotalBudget            time.Duration
}

// DefaultCoverTransferOptions returns the Mac's values.
func DefaultCoverTransferOptions() CoverTransferOptions {
	return CoverTransferOptions{
		SettleAfterSelect:      150 * time.Millisecond,
		SettleAfterStart:       200 * time.Millisecond,
		ChunkSpacing:           40 * time.Millisecond,
		AcknowledgementTimeout: 5 * time.Second,
		SettleBeforeVerify:     400 * time.Millisecond,
		VerifyAttempts:         3,
		VerifyRetryDelay:       time.Second,
		TotalBudget:            240 * time.Second,
	}
}

// CoverMinimumDuration is CoverTransferSchedule.minimumDuration: the
// deliberate pauses alone, a floor for "how long will this take".
func CoverMinimumDuration(byteCount int, o CoverTransferOptions) time.Duration {
	chunks := a2687.CoverChunkCount(byteCount)
	checkpoints := 0
	for i := 0; i < chunks; i++ {
		if a2687.CoverChunkAcknowledged(i, chunks) {
			checkpoints++
		}
	}
	return o.SettleAfterSelect + o.SettleAfterStart + o.ChunkSpacing*time.Duration(chunks-checkpoints) + o.SettleBeforeVerify
}

// CoverStage is CoverTransferProgress.Stage.
type CoverStage string

const (
	CoverStageIdle      CoverStage = "idle"
	CoverStageSelecting CoverStage = "selecting"
	CoverStageStarting  CoverStage = "starting"
	CoverStageSending   CoverStage = "sending"
	CoverStageVerifying CoverStage = "verifying"
	CoverStageFinished  CoverStage = "finished"
)

// CoverProgress is one progress report.
type CoverProgress struct {
	Stage      CoverStage `json:"stage"`
	ChunksSent int        `json:"chunksSent"`
	ChunkCount int        `json:"chunkCount"`
}

// CoverErrorKind is CoverTransferError's case.
type CoverErrorKind int

const (
	CoverEmptyImage CoverErrorKind = iota + 1
	CoverTooManyChunks
	CoverAlreadyRunning
	CoverIrreversibilityNotAcknowledged
	CoverHashMismatch
	CoverSelectUnanswered
	CoverSelectRejected
	CoverStartUnanswered
	CoverStartRejected
	CoverChunkSendFailed
	CoverAcknowledgementTimedOut
	CoverChunkRejected
	CoverProgressMismatch
	CoverCancelled
	CoverBudgetExhausted
	CoverNotShownAfterTransfer
)

// CoverTransferError is a failed push. Kind decides what the user is told;
// the numbers only go to the diagnostics.
type CoverTransferError struct {
	Kind       CoverErrorKind
	ChunkIndex int
	Status     byte
	Sent       int
	Total      int
	Expected   int
	Reported   int
	// ReportedKnown is false when 0xE1 could not be read after a transfer.
	ReportedKnown bool
}

func (e *CoverTransferError) Error() string { return "cover: " + e.Diagnostic() }

// PixelsMayHaveLanded separates "nothing was written" from "part of the
// image is in the charger now, and nothing can delete it".
func (e *CoverTransferError) PixelsMayHaveLanded() bool {
	switch e.Kind {
	case CoverChunkSendFailed, CoverAcknowledgementTimedOut, CoverChunkRejected,
		CoverProgressMismatch, CoverCancelled, CoverBudgetExhausted, CoverNotShownAfterTransfer:
		return true
	}
	return false
}

// Diagnostic is the untranslated line for the log.
func (e *CoverTransferError) Diagnostic() string {
	switch e.Kind {
	case CoverEmptyImage:
		return "empty image: no JPEG bytes to send"
	case CoverTooManyChunks:
		return fmt.Sprintf("image needs %d chunks, past the u16 the protocol can express", e.Total)
	case CoverAlreadyRunning:
		return "a cover push is already running"
	case CoverIrreversibilityNotAcknowledged:
		return "caller did not acknowledge the write is irreversible"
	case CoverHashMismatch:
		return "hash mismatch between 0x021F and 0x0220"
	case CoverSelectUnanswered:
		return "0x021F unanswered"
	case CoverSelectRejected:
		return fmt.Sprintf("0x021F rejected, status 0x%02X", e.Status)
	case CoverStartUnanswered:
		return "0x0220 unanswered"
	case CoverStartRejected:
		return fmt.Sprintf("0x0220 rejected, status 0x%02X", e.Status)
	case CoverChunkSendFailed:
		return fmt.Sprintf("chunk %d failed to send", e.ChunkIndex)
	case CoverAcknowledgementTimedOut:
		return fmt.Sprintf("no acknowledgement for chunk %d", e.ChunkIndex)
	case CoverChunkRejected:
		return fmt.Sprintf("chunk %d rejected, status 0x%02X", e.ChunkIndex, e.Status)
	case CoverProgressMismatch:
		return fmt.Sprintf("progress mismatch: expected chunk %d, firmware reports %d", e.Expected, e.Reported)
	case CoverCancelled:
		return fmt.Sprintf("cancelled at chunk %d/%d", e.Sent, e.Total)
	case CoverBudgetExhausted:
		return fmt.Sprintf("budget exhausted at chunk %d/%d", e.Sent, e.Total)
	case CoverNotShownAfterTransfer:
		shown := "nothing"
		if e.ReportedKnown {
			shown = fmt.Sprint(e.Reported)
		}
		return fmt.Sprintf("0xE1 reports %s after the transfer, expected %d", shown, e.Expected)
	}
	return "unknown cover failure"
}

// CoverVerification says whether the screen was seen to change.
type CoverVerification string

const (
	// CoverWitnessed: 0xE1 named another picture before and this one after.
	CoverWitnessed CoverVerification = "witnessed"
	// CoverAlreadyShowing: 0xE1 already named this id before the push.
	CoverAlreadyShowing CoverVerification = "alreadyShowing"
	// CoverBeforeUnreadable: 0xE1 could not be read before the push.
	CoverBeforeUnreadable CoverVerification = "beforeUnreadable"
)

// CoverOutcome is a push that finished with the panel reporting its id.
type CoverOutcome struct {
	PictureID          uint32
	ByteCount          int
	ChunkCount         int
	IndexedCheckpoints int
	CheckpointCount    int
	ReportedPictureID  uint16
	Before             uint16
	Verification       CoverVerification
}

// Witnessed reports whether the push is proven to have changed the screen.
func (o CoverOutcome) Witnessed() bool { return o.Verification == CoverWitnessed }

// Evidence is the diagnostics line (AppModel.coverEvidence).
func (o CoverOutcome) Evidence() string {
	var verdict string
	switch o.Verification {
	case CoverWitnessed:
		verdict = fmt.Sprintf("witnessed: 0xE1 %d -> %d", o.Before, o.ReportedPictureID)
	case CoverAlreadyShowing:
		verdict = fmt.Sprintf("inconclusive: 0xE1 already reported %d before the push", o.Before)
	default:
		verdict = fmt.Sprintf("inconclusive: 0xE1 unreadable before the push, now %d", o.ReportedPictureID)
	}
	return fmt.Sprintf("pushed id %d, %d B, %d chunks, %d/%d checkpoints carried an index; %s",
		o.PictureID, o.ByteCount, o.ChunkCount, o.IndexedCheckpoints, o.CheckpointCount, verdict)
}

// coverTransferComplete is the status the final checkpoint answers with.
const coverTransferComplete byte = 0x10

// CoverTransfer is one push or re-selection.
type CoverTransfer struct {
	link    CoverLink
	opts    CoverTransferOptions
	running atomic.Bool
	cancel  atomic.Bool
}

// NewCoverTransfer builds a transfer over link.
func NewCoverTransfer(link CoverLink, opts CoverTransferOptions) *CoverTransfer {
	return &CoverTransfer{link: link, opts: opts}
}

// Cancel stops at the next slice boundary. It cannot unsend anything.
func (c *CoverTransfer) Cancel() { c.cancel.Store(true) }

// Select re-sends 0x021F for pixels already in the charger and reads 0xE1.
func (c *CoverTransfer) Select(image a2687.CoverImageReference) (uint16, bool, error) {
	reply, err := c.link.SelectCover(image)
	if err != nil {
		return 0, false, &CoverTransferError{Kind: CoverSelectUnanswered}
	}
	if status, ok := reply.StatusCode(); ok && status != 0 {
		return 0, false, &CoverTransferError{Kind: CoverSelectRejected, Status: status}
	}
	id, ok, err := c.link.ReadCoverPictureID()
	if err != nil {
		return 0, false, nil
	}
	return id, ok, nil
}

// Push writes jpeg as image and verifies the panel shows it.
func (c *CoverTransfer) Push(ctx context.Context, jpeg []byte, image a2687.CoverImageReference,
	acknowledgedIrreversible bool, onProgress func(CoverProgress)) (CoverOutcome, error) {
	if !acknowledgedIrreversible {
		return CoverOutcome{}, &CoverTransferError{Kind: CoverIrreversibilityNotAcknowledged}
	}
	if !c.running.CompareAndSwap(false, true) {
		return CoverOutcome{}, &CoverTransferError{Kind: CoverAlreadyRunning}
	}
	defer c.running.Store(false)
	c.cancel.Store(false)

	plan, ok := a2687.NewCoverPlan(jpeg)
	if !ok {
		return CoverOutcome{}, &CoverTransferError{Kind: CoverEmptyImage}
	}
	if plan.ChunkCount > 0xFFFF {
		return CoverOutcome{}, &CoverTransferError{Kind: CoverTooManyChunks, Total: plan.ChunkCount}
	}
	steps, err := a2687.BuildCoverSteps(jpeg, plan)
	if err != nil {
		return CoverOutcome{}, &CoverTransferError{Kind: CoverEmptyImage}
	}
	ticket, err := a2687.NewCoverTransferTicket(image, plan)
	if err != nil {
		return CoverOutcome{}, &CoverTransferError{Kind: CoverHashMismatch}
	}

	total := plan.ChunkCount
	deadline := time.Now().Add(c.opts.TotalBudget)
	sent := 0
	report := func(stage CoverStage) {
		if onProgress != nil {
			onProgress(CoverProgress{Stage: stage, ChunksSent: sent, ChunkCount: total})
		}
	}
	stopIfAsked := func() error {
		if c.cancel.Load() || ctx.Err() != nil {
			return &CoverTransferError{Kind: CoverCancelled, Sent: sent, Total: total}
		}
		if time.Now().After(deadline) {
			return &CoverTransferError{Kind: CoverBudgetExhausted, Sent: sent, Total: total}
		}
		return nil
	}
	pause := func(d time.Duration) error {
		if d <= 0 {
			return nil
		}
		t := time.NewTimer(d)
		defer t.Stop()
		select {
		case <-t.C:
			return nil
		case <-ctx.Done():
			return &CoverTransferError{Kind: CoverCancelled, Sent: sent, Total: total}
		}
	}

	// The id on screen before anything is named: the only witness that the
	// screen changed afterwards.
	before, beforeKnown, beforeErr := c.link.ReadCoverPictureID()
	beforeKnown = beforeKnown && beforeErr == nil

	report(CoverStageSelecting)
	if err := stopIfAsked(); err != nil {
		return CoverOutcome{}, err
	}
	if _, err := c.link.SelectCover(ticket.Image); err != nil {
		return CoverOutcome{}, &CoverTransferError{Kind: CoverSelectUnanswered}
	}
	// 0x021F for pixels not yet resident is acknowledged with a non-zero
	// status on some firmware; the select is only a name, so it is not a
	// refusal here (CoverTransferSession keeps its status for the record).
	if err := pause(c.opts.SettleAfterSelect); err != nil {
		return CoverOutcome{}, err
	}

	report(CoverStageStarting)
	if err := stopIfAsked(); err != nil {
		return CoverOutcome{}, err
	}
	startReply, err := c.link.BeginCoverTransfer(ticket)
	if err != nil {
		return CoverOutcome{}, &CoverTransferError{Kind: CoverStartUnanswered}
	}
	if status, ok := startReply.StatusCode(); ok && status != 0 {
		return CoverOutcome{}, &CoverTransferError{Kind: CoverStartRejected, Status: status}
	}
	if err := pause(c.opts.SettleAfterStart); err != nil {
		return CoverOutcome{}, err
	}

	report(CoverStageSending)
	indexed, checkpoints := 0, 0
	for _, step := range steps {
		if err := stopIfAsked(); err != nil {
			return CoverOutcome{}, err
		}
		if !step.Checkpoint {
			if err := c.link.SendFill(step); err != nil {
				return CoverOutcome{}, &CoverTransferError{Kind: CoverChunkSendFailed, ChunkIndex: step.Index, Sent: sent, Total: total}
			}
			sent++
			report(CoverStageSending)
			if err := pause(c.opts.ChunkSpacing); err != nil {
				return CoverOutcome{}, err
			}
			continue
		}
		checkpoints++
		reply, err := c.link.SendCheckpoint(step, c.opts.AcknowledgementTimeout)
		if err != nil {
			return CoverOutcome{}, &CoverTransferError{Kind: CoverAcknowledgementTimedOut, ChunkIndex: step.Index, Sent: sent, Total: total}
		}
		final := step.Index == total-1
		if status, ok := reply.StatusCode(); ok && status != 0 && !(final && status == coverTransferComplete) {
			return CoverOutcome{}, &CoverTransferError{Kind: CoverChunkRejected, ChunkIndex: step.Index, Status: status, Sent: sent, Total: total}
		}
		if next, ok := a2687.NextChunkIndex(reply); ok {
			if next != step.Index+1 {
				return CoverOutcome{}, &CoverTransferError{Kind: CoverProgressMismatch, Expected: step.Index + 1, Reported: next, Sent: sent, Total: total}
			}
			indexed++
		}
		sent++
		report(CoverStageSending)
	}

	if err := pause(c.opts.SettleBeforeVerify); err != nil {
		return CoverOutcome{}, err
	}
	report(CoverStageVerifying)
	expected := ticket.Image.ReportedID()
	var reported uint16
	reportedKnown := false
	attempts := c.opts.VerifyAttempts
	if attempts < 1 {
		attempts = 1
	}
	for attempt := 0; attempt < attempts; attempt++ {
		if attempt > 0 {
			if err := pause(c.opts.VerifyRetryDelay); err != nil {
				return CoverOutcome{}, err
			}
		}
		id, ok, err := c.link.ReadCoverPictureID()
		reported, reportedKnown = id, ok && err == nil
		if reportedKnown && reported == expected {
			break
		}
	}
	if !reportedKnown || reported != expected {
		return CoverOutcome{}, &CoverTransferError{Kind: CoverNotShownAfterTransfer, Expected: int(expected), Reported: int(reported), ReportedKnown: reportedKnown, Sent: sent, Total: total}
	}

	report(CoverStageFinished)
	verification := CoverWitnessed
	switch {
	case !beforeKnown:
		verification = CoverBeforeUnreadable
	case before == expected:
		verification = CoverAlreadyShowing
	}
	return CoverOutcome{
		PictureID:          ticket.Image.PictureID,
		ByteCount:          plan.ByteCount,
		ChunkCount:         total,
		IndexedCheckpoints: indexed,
		CheckpointCount:    checkpoints,
		ReportedPictureID:  expected,
		Before:             before,
		Verification:       verification,
	}, nil
}

// --- the session's link ---------------------------------------------------------

// coverStateField is 0xE1: bytes 2..3 carry the low 16 bits of the id shown.
const coverStateField byte = 0xE1

// CoverPictureID reads 0xE1 out of a read-all answer.
func CoverPictureID(p a2687.Payload) (uint16, bool) {
	raw, ok := p.Field(coverStateField)
	if !ok || len(raw) < 1 {
		return 0, false
	}
	body := raw[1:] // the typed value's payload
	if len(body) < 4 {
		return 0, false
	}
	return uint16(body[2]) | uint16(body[3])<<8, true
}

// managerCoverLink is CoverTransferAdapter over this session.
type managerCoverLink struct{ m *Manager }

func (k managerCoverLink) SelectCover(image a2687.CoverImageReference) (a2687.Payload, error) {
	return k.m.request(func(l *loop) (outgoingFrame, error) {
		msg, err := a2687.SelectCover(image, l.now())
		if err != nil {
			return outgoingFrame{}, err
		}
		return l.hs.message(msg)
	}, a2687.OpcodeSetScreensaver, k.m.opts.ReplyTimeout)
}

func (k managerCoverLink) BeginCoverTransfer(ticket a2687.CoverTransferTicket) (a2687.Payload, error) {
	return k.m.request(func(l *loop) (outgoingFrame, error) {
		return l.hs.message(a2687.StartTransfer(ticket, l.now()))
	}, a2687.OpcodeCoverTransferStart, k.m.opts.ReplyTimeout)
}

func chunkFrame(step a2687.CoverChunkStep) func(*loop) (outgoingFrame, error) {
	return func(l *loop) (outgoingFrame, error) {
		msg, err := a2687.TransferChunk(step.Index, step.ChunkCount, step.Payload, l.now())
		if err != nil {
			return outgoingFrame{}, err
		}
		return l.hs.message(msg)
	}
}

func (k managerCoverLink) SendFill(step a2687.CoverChunkStep) error {
	return k.m.send(chunkFrame(step))
}

func (k managerCoverLink) SendCheckpoint(step a2687.CoverChunkStep, timeout time.Duration) (a2687.Payload, error) {
	return k.m.request(chunkFrame(step), a2687.OpcodeCoverTransferChunk, timeout)
}

func (k managerCoverLink) ReadCoverPictureID() (uint16, bool, error) {
	p, err := k.m.request(readAllFrame, opRealtime, k.m.opts.ReplyTimeout)
	if err != nil {
		return 0, false, err
	}
	id, ok := CoverPictureID(p)
	return id, ok, nil
}

// PushCover writes one custom screen to the charger's 240x240 panel with the
// poll held (ChargerSession.pushCover). It is gated on a ready session only;
// the irreversibility acknowledgement is the real gate.
// Cancelling ctx stops it at the next slice boundary.
func (m *Manager) PushCover(ctx context.Context, jpeg []byte, image a2687.CoverImageReference,
	acknowledgedIrreversible bool, onProgress func(CoverProgress)) (CoverOutcome, error) {
	if err := m.requireReady(); err != nil {
		return CoverOutcome{}, err
	}
	t := NewCoverTransfer(managerCoverLink{m}, DefaultCoverTransferOptions())
	release := m.holdPolling()
	defer release()
	return t.Push(ctx, jpeg, image, acknowledgedIrreversible, onProgress)
}

// SelectCover re-sends 0x021F for a cover already pushed and returns what
// 0xE1 reports afterwards.
func (m *Manager) SelectCover(image a2687.CoverImageReference) (uint16, bool, error) {
	if err := m.requireReady(); err != nil {
		return 0, false, err
	}
	return NewCoverTransfer(managerCoverLink{m}, DefaultCoverTransferOptions()).Select(image)
}

// ReadCoverPictureID reads the id the panel shows now.
func (m *Manager) ReadCoverPictureID() (uint16, bool, error) {
	if err := m.requireReady(); err != nil {
		return 0, false, err
	}
	return managerCoverLink{m}.ReadCoverPictureID()
}
