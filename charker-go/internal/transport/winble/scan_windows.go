//go:build windows

package winble

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"tinygo.org/x/bluetooth"

	"charker/internal/product"
	"charker/internal/transport"
)

// Scanner timings. Adapter.Scan blocks until StopScan (or a watcher error), so
// the scan runs in its own goroutine and StopScan is observable through the
// scan's context.
const (
	// scanStartGrace is how long Scan waits to learn that the WinRT watcher
	// could not start (radio off, no adapter). Such a failure returns from
	// adapter.Scan almost immediately; after this grace the scan counts as
	// running and Scan returns instead of blocking.
	scanStartGrace = 150 * time.Millisecond
	// scanStopWait bounds how long StopScan waits for the watcher to end.
	scanStopWait = 5 * time.Second
	// scanStopRetry/scanStopDeadline cover the small window between calling
	// adapter.Scan in its goroutine and the watcher actually existing: StopScan
	// reports errNotScanning until then, so it is retried briefly.
	scanStopRetry    = 10 * time.Millisecond
	scanStopDeadline = 2 * time.Second
	// scanAnnounceMaxAge/scanAnnounceRSSI are the macOS advertisement
	// de-duplication thresholds: forward a device again only when it is new,
	// moved by more than 6 dBm, or has not been reported for 3 s.
	scanAnnounceMaxAge = 3 * time.Second
	scanAnnounceRSSI   = 6
)

// announce is the de-duplication state of one device in one scan.
type announce struct {
	rssi int
	at   time.Time
}

// scanState is one scan lifetime. Adapter.Scan blocks, so the scan runs in a
// goroutine and this value is how Scan/StopScan/Connect talk to it.
type scanState struct {
	ctx    context.Context
	cancel context.CancelFunc
	done   chan struct{}

	// product is the model to match advertisements against; empty means "do not
	// match candidates", which is what a connect scan uses.
	product product.ChargerProduct
	// emit forwards EventDiscovered for candidates (a picker scan) or stays
	// silent (a connect scan).
	emit bool
	// wantID, when set, is the exact MAC a connect scan waits for.
	wantID string
	// found receives the address of the wanted MAC (buffered 1).
	found chan bluetooth.Address
	// startResult receives nil once the watcher is running, or the mapped error
	// when it failed to start. Buffered so the scan never blocks on a caller
	// that already gave up.
	startResult chan error

	mu        sync.Mutex
	announced map[string]announce
}

// newScan builds one scan state around parent.
func (t *Transport) newScan(parent context.Context, p product.ChargerProduct, wantID string, emit bool) *scanState {
	ctx, cancel := context.WithCancel(parent)
	return &scanState{
		ctx:         ctx,
		cancel:      cancel,
		done:        make(chan struct{}),
		product:     p,
		emit:        emit,
		wantID:      strings.ToUpper(strings.TrimSpace(wantID)),
		found:       make(chan bluetooth.Address, 1),
		startResult: make(chan error, 1),
		announced:   make(map[string]announce),
	}
}

// Scan implements transport.Transport: it starts an unfiltered, active scan and
// matches advertisements in code (the WinRT watcher filter only matches
// advertised service UUIDs, which A2687 units may omit). It returns once the
// scan is running or with the reason it could not start; discovery arrives as
// EventDiscovered and the end of the scan as EventScanStopped.
//
// The scan runs until ctx is done or StopScan is called. Calling Scan again
// while a scan for the same product is running is a no-op.
func (t *Transport) Scan(ctx context.Context, p product.ChargerProduct) error {
	if t.closed.Load() {
		return transport.ErrClosed
	}
	if p != product.ProductA2687 {
		return fmt.Errorf("winble: Bluetooth discovery supports the A2687 only (got %q): %w",
			p, transport.ErrUnsupported)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := t.enableAdapter(); err != nil {
		return err
	}

	t.scanMu.Lock()
	cur := t.scan
	t.scanMu.Unlock()
	if cur != nil {
		if cur.product == p && cur.wantID == "" {
			return nil // already scanning for this product
		}
		if err := t.StopScan(); err != nil {
			return err
		}
	}

	sc := t.newScan(ctx, p, "", true)
	t.scanMu.Lock()
	t.scan = sc
	t.scanMu.Unlock()
	go t.runScan(sc)

	select {
	case err := <-sc.startResult:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

// StopScan implements transport.Transport. It is a no-op when no scan runs and
// returns once the WinRT watcher has actually stopped, so a following Scan can
// start cleanly.
func (t *Transport) StopScan() error {
	t.scanMu.Lock()
	sc := t.scan
	t.scanMu.Unlock()
	if sc == nil {
		return nil
	}
	sc.cancel()
	select {
	case <-sc.done:
		return nil
	case <-time.After(scanStopWait):
		return fmt.Errorf("winble: scan did not stop within %s: %w", scanStopWait, transport.ErrTimeout)
	}
}

// runScan owns one adapter.Scan call for the lifetime of sc.
func (t *Transport) runScan(sc *scanState) {
	defer close(sc.done)
	defer func() {
		t.scanMu.Lock()
		if t.scan == sc {
			t.scan = nil
		}
		t.scanMu.Unlock()
	}()

	errs := make(chan error, 1)
	go func() {
		errs <- t.adapter.Scan(t.scanCallback(sc))
	}()

	// A watcher that cannot start returns from Scan almost immediately. Waiting
	// that long here lets Scan report radio-off / no-adapter synchronously
	// instead of pretending to scan.
	select {
	case err := <-errs:
		mapped := mapScanError(err)
		sc.reportStart(mapped)
		t.finishScan(sc, mapped)
		return
	case <-time.After(scanStartGrace):
		sc.reportStart(nil)
	}

	var scanErr error
	select {
	case scanErr = <-errs:
		// The watcher stopped on its own: radio toggled, system cancelled the
		// scan, or the adapter failed.
	case <-sc.ctx.Done():
		scanErr = t.stopWatcher(errs)
	}
	t.finishScan(sc, mapScanError(scanErr))
}

// finishScan reports the end of a scan to the event stream. Connect scans stay
// silent so they cannot disturb the session's view of a picker scan.
func (t *Transport) finishScan(sc *scanState, err error) {
	if !sc.emit {
		return
	}
	ev := transport.Event{Kind: transport.EventScanStopped}
	if err != nil {
		ev.Err = err
	}
	t.emit(ev)
}

// stopWatcher asks the adapter to stop and waits for adapter.Scan to return.
// StopScan on an already stopped watcher reports errNotScanning, which is not
// an error here; the retry loop covers the window before the watcher exists.
func (t *Transport) stopWatcher(errs <-chan error) error {
	deadline := time.Now().Add(scanStopDeadline)
	for {
		err := t.adapter.StopScan()
		if err == nil || !isNoScan(err) {
			break
		}
		if time.Now().After(deadline) {
			break
		}
		select {
		case scanErr := <-errs:
			if isNoScan(scanErr) {
				return nil
			}
			return scanErr
		case <-time.After(scanStopRetry):
		}
	}
	select {
	case err := <-errs:
		if isNoScan(err) {
			return nil
		}
		return err
	case <-time.After(scanStopWait):
		return errors.New("winble: scan did not stop after StopScan")
	}
}

// scanCallback copies one advertisement and decides what to do with it. The
// ScanResult's payload is only valid until the callback returns.
func (t *Transport) scanCallback(sc *scanState) func(*bluetooth.Adapter, bluetooth.ScanResult) {
	return func(_ *bluetooth.Adapter, result bluetooth.ScanResult) {
		id := result.Address.String()
		name := result.LocalName()
		services := make([]string, 0, len(result.ServiceUUIDs()))
		for _, u := range result.ServiceUUIDs() {
			services = append(services, u.String())
		}
		manufacturer := make([][]byte, 0, len(result.ManufacturerData()))
		for _, m := range result.ManufacturerData() {
			// Rebuild the macOS manufacturer-data layout: little-endian Company
			// ID followed by the payload. The product type may straddle that
			// boundary in theory, and Swift searched the whole buffer.
			raw := make([]byte, 0, 2+len(m.Data))
			raw = append(raw, byte(m.CompanyID), byte(m.CompanyID>>8))
			raw = append(raw, m.Data...)
			manufacturer = append(manufacturer, raw)
		}

		// The address is reused by a later Connect, so keep it even for devices
		// that are not A2687 candidates (a saved charger may advertise no A2687
		// signal but is still connectable by MAC).
		t.remember(id, seenEntry{addr: result.Address, name: name, rssi: int(result.RSSI)})

		if sc.wantID != "" && strings.EqualFold(id, sc.wantID) {
			select {
			case sc.found <- result.Address:
			default: // already found
			}
		}
		if sc.product == "" {
			return
		}

		prod, reasons, ok := MatchAdvertisement(name, services, manufacturer)
		if !ok || prod != sc.product {
			return
		}
		t.logf("winble: seen %s name=%q rssi=%d services=%v reasons=%v",
			id, name, result.RSSI, services, reasons)
		if !sc.forward(id, int(result.RSSI)) {
			return
		}
		if sc.emit {
			t.emit(transport.Event{
				Kind: transport.EventDiscovered,
				Device: transport.Discovered{
					ID:      id,
					Name:    name,
					Address: id,
					RSSI:    int(result.RSSI),
					Product: prod,
				},
			})
		}
	}
}

// reportStart hands the scan startup result to a waiting Scan exactly once.
func (sc *scanState) reportStart(err error) {
	select {
	case sc.startResult <- err:
	default:
	}
}

// forward de-duplicates advertisements like the macOS transport: a device is
// reported again only when it is new, moved more than 6 dBm, or aged more than
// 3 s.
func (sc *scanState) forward(id string, rssi int) bool {
	now := time.Now()
	sc.mu.Lock()
	defer sc.mu.Unlock()
	if prev, ok := sc.announced[id]; ok {
		if absInt(prev.rssi-rssi) <= scanAnnounceRSSI && now.Sub(prev.at) <= scanAnnounceMaxAge {
			return false
		}
	}
	sc.announced[id] = announce{rssi: rssi, at: now}
	return true
}

// scanForID runs a bounded connect scan for one exact MAC and returns the
// address it advertised under. It ends the scan before returning so the link
// comes up without a watcher running.
func (t *Transport) scanForID(ctx context.Context, id string) (bluetooth.Address, error) {
	// A picker scan cannot be joined, so it is ended first: the connect scan
	// below watches for this one device and emits no discovery events.
	if err := t.StopScan(); err != nil {
		return bluetooth.Address{}, err
	}
	window := t.cfg.ScanWindow
	if deadline, ok := ctx.Deadline(); ok {
		if remaining := time.Until(deadline); remaining < window {
			window = remaining
		}
	}
	if window <= 0 {
		return bluetooth.Address{}, fmt.Errorf("winble: connect %s: %w: no time left for a scan", id, transport.ErrNotFound)
	}
	t.logf("winble: %s is not in the scan cache; scanning up to %s for it", id, window)

	sc := t.newScan(ctx, "", id, false)
	t.scanMu.Lock()
	t.scan = sc
	t.scanMu.Unlock()
	go t.runScan(sc)
	if err := <-sc.startResult; err != nil {
		return bluetooth.Address{}, err
	}

	timer := time.NewTimer(window)
	defer timer.Stop()
	var (
		addr  bluetooth.Address
		found bool
	)
	select {
	case addr = <-sc.found:
		found = true
	case <-timer.C:
	case <-ctx.Done():
	}
	sc.cancel()
	<-sc.done

	if found {
		return addr, nil
	}
	if err := ctx.Err(); err != nil {
		return bluetooth.Address{}, fmt.Errorf("winble: connect %s: %w", id, err)
	}
	return bluetooth.Address{}, fmt.Errorf(
		"winble: charger %s not found after %s (out of range, held by another app, or advertising under a different address): %w",
		id, window, transport.ErrNotFound)
}
