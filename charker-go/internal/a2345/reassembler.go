package a2345

import "errors"

// Reassembler turns split or coalesced MQTT byte chunks into strict FF09
// frames. Garbage and malformed candidates are dropped, never repaired. The
// zero value is ready to use; it is not safe for concurrent use.
type Reassembler struct {
	buffer         []byte
	droppedBytes   int
	rejectedFrames int
	lastErr        *FrameError
	lastHead       []byte
}

// Reset discards buffered bytes; counters are kept.
func (r *Reassembler) Reset() { r.buffer = r.buffer[:0] }

// DroppedBytes counts bytes discarded while resynchronising.
func (r *Reassembler) DroppedBytes() int { return r.droppedBytes }

// RejectedFrames counts candidates that failed validation.
func (r *Reassembler) RejectedFrames() int { return r.rejectedFrames }

// LastRejection returns the last validation error and up to 12 leading bytes
// of its candidate, or nil when none has been recorded.
func (r *Reassembler) LastRejection() (*FrameError, []byte) {
	return r.lastErr, append([]byte(nil), r.lastHead...)
}

func (r *Reassembler) drop(n int) {
	r.droppedBytes += n
	r.buffer = r.buffer[n:]
}

// Append adds one chunk and returns every frame it completed.
func (r *Reassembler) Append(chunk []byte) []Frame {
	r.buffer = append(r.buffer, chunk...)
	var frames []Frame
	for {
		headerOffset, ok := r.nextHeaderOffset()
		if !ok {
			r.preservePossibleHeaderPrefix()
			break
		}
		if headerOffset > 0 {
			r.drop(headerOffset)
		}
		if len(r.buffer) < 4 {
			break
		}
		length := int(r.buffer[2]) | int(r.buffer[3])<<8
		if length < MinFrameLength || length > MaxFrameLength {
			r.rejectedFrames++
			r.drop(2)
			continue
		}
		if len(r.buffer) < length {
			// A plausible but corrupt length can otherwise pin the stream
			// forever: the buffer may already contain a later, complete,
			// checksum-valid frame. Only resynchronise when that later
			// candidate fully validates, so FF09 bytes inside a legitimate
			// fragmented payload cannot cause an eager drop.
			recovery, ok := r.nextCompleteValidFrameOffset(2)
			if !ok {
				break
			}
			r.rejectedFrames++
			r.lastErr = &FrameError{Kind: FrameErrLengthMismatch, Encoded: length, Actual: recovery}
			r.lastHead = append([]byte(nil), r.buffer[:min(12, recovery)]...)
			r.drop(recovery)
			continue
		}
		candidate := append([]byte(nil), r.buffer[:length]...)
		frame, err := Decode(candidate)
		if err != nil {
			r.rejectedFrames++
			var fe *FrameError
			if errors.As(err, &fe) {
				r.lastErr = fe
				r.lastHead = append([]byte(nil), candidate[:min(12, len(candidate))]...)
			}
			// Drop only the bad marker. If a corrupt declared length spans
			// another valid frame, the next scan can still recover it.
			r.drop(2)
			continue
		}
		frames = append(frames, frame)
		r.buffer = r.buffer[length:]
	}
	if len(r.buffer) == 0 {
		r.buffer = nil
	}
	return frames
}

func (r *Reassembler) nextHeaderOffset() (int, bool) {
	for i := 0; i+1 < len(r.buffer); i++ {
		if r.buffer[i] == Header[0] && r.buffer[i+1] == Header[1] {
			return i, true
		}
	}
	return 0, false
}

func (r *Reassembler) nextCompleteValidFrameOffset(start int) (int, bool) {
	if len(r.buffer) < start+MinFrameLength {
		return 0, false
	}
	for i := start; i+1 < len(r.buffer); i++ {
		if r.buffer[i] != Header[0] || r.buffer[i+1] != Header[1] || i+4 > len(r.buffer) {
			continue
		}
		length := int(r.buffer[i+2]) | int(r.buffer[i+3])<<8
		if length < MinFrameLength || length > MaxFrameLength || i+length > len(r.buffer) {
			continue
		}
		if _, err := Decode(r.buffer[i : i+length]); err == nil {
			return i, true
		}
	}
	return 0, false
}

func (r *Reassembler) preservePossibleHeaderPrefix() {
	if n := len(r.buffer); n > 0 && r.buffer[n-1] == Header[0] {
		r.droppedBytes += n - 1
		r.buffer = []byte{Header[0]}
		return
	}
	r.droppedBytes += len(r.buffer)
	r.buffer = nil
}
