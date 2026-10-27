package winble

// ATT framing constants. One ATT PDU spends three bytes on opcode and
// attribute handle, so an application payload is at most MTU-3 bytes. Write
// commands (without response) have no fragmentation mechanism in ATT: an
// application frame larger than MTU-3 must be split by the sender. Write
// requests (with response) may exceed one PDU because the OS performs an ATT
// long write; the A2687 path relies on that for its ~193-byte frames.
const (
	attOverhead   = 3
	attMinimumMTU = 23
)

// payloadLimit returns the number of application bytes one ATT write command
// can carry at the given negotiated MTU. Values below the ATT minimum (23) are
// treated as the minimum rather than becoming a negative limit.
func payloadLimit(mtu uint16) int {
	if mtu < attMinimumMTU {
		return attMinimumMTU - attOverhead
	}
	return int(mtu) - attOverhead
}

// segmentFrame splits n application bytes into the [start,end) ranges of a
// sequence of write commands of at most chunk bytes each. It is used only for
// write-without-response: a write request may carry the whole frame in one call
// (Windows fragments it into an ATT long write), and splitting a protocol frame
// into separate write requests would break the A2687 frame parser on the
// charger unless the firmware reassembles.
func segmentFrame(n, chunk int) [][2]int {
	if n <= 0 || chunk <= 0 {
		return nil
	}
	segs := make([][2]int, 0, (n+chunk-1)/chunk)
	for off := 0; off < n; off += chunk {
		end := off + chunk
		if end > n {
			end = n
		}
		segs = append(segs, [2]int{off, end})
	}
	return segs
}
