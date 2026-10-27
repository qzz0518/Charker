//go:build windows

package winble

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"tinygo.org/x/bluetooth"

	"charker/internal/product"
	"charker/internal/transport"
)

var _ transport.Transport = (*Transport)(nil)

// Windows GattCharacteristicProperties bits (see
// windows.devices.bluetooth.genericattributeprofile).
const (
	gattPropWriteWithoutResponse = uint32(0x0004)
	gattPropWrite                = uint32(0x0008)
	gattPropNotify               = uint32(0x0010)
	gattPropIndicate             = uint32(0x0020)
)

// linkPollInterval is how often the supervisor asks WinRT whether the link is
// still up, to cover a missed connection-status event. The event handler is the
// primary signal; this is the safety net (spec-ble §7 R11).
const linkPollInterval = 3 * time.Second

var (
	serviceUUID = mustParseUUID(PrimaryService)
	writeUUID   = mustParseUUID(WriteCharacteristic)
	notifyUUID  = mustParseUUID(NotifyCharacteristic)
)

func mustParseUUID(s string) bluetooth.UUID {
	u, err := bluetooth.ParseUUID(s)
	if err != nil {
		panic("winble: invalid UUID constant " + s + ": " + err.Error())
	}
	return u
}

// Adapter initialisation is once per process: Adapter.Enable calls
// RoInitialize and a repeated call returns S_FALSE, which go-ole reports as an
// error ("The function is incorrect"). A second Transport must not treat that
// as "Bluetooth unavailable" (spec-ble §5.1, §6.4).
var (
	enableOnce sync.Once
	enableErr  error
)

// seenEntry is one advertisement kept for scan-then-connect.
type seenEntry struct {
	addr bluetooth.Address
	name string
	rssi int
}

// link is one live GATT connection. All fields are immutable after setup except
// through cancel/Disconnect, which is coordinated by Transport.linkMu.
type link struct {
	ctx      context.Context
	cancel   context.CancelFunc
	loss     chan struct{} // adapter connect handler: link went down
	dev      bluetooth.Device
	id       string
	name     string
	addr     bluetooth.Address
	write    bluetooth.DeviceCharacteristic
	notify   bluetooth.DeviceCharacteristic
	mtu      uint16
	withResp bool
}

// Transport is the Windows BLE implementation of transport.Transport.
//
// One instance owns one adapter and one link. It is safe to call from one owner
// goroutine as the session does; all shared state is mutex-guarded and WinRT
// callbacks only copy their buffers and hand events to a buffered channel.
type Transport struct {
	cfg     Config
	adapter *bluetooth.Adapter
	events  chan transport.Event

	dropped   atomic.Uint64
	closed    atomic.Bool
	closeOnce sync.Once
	emitMu    sync.RWMutex // held for reading by emit, writing by Close

	scanMu sync.Mutex
	scan   *scanState // non-nil while a scan is running

	seenMu sync.Mutex
	seen   map[string]seenEntry // last advertisement per MAC, for Connect

	linkMu sync.Mutex
	link   *link

	writeMu   sync.Mutex // keeps frames in order
	connectMu sync.Mutex // one connect attempt at a time
}

// New returns a transport around the process-wide Bluetooth adapter.
//
// It does not touch WinRT: the adapter is enabled on the first scan, connect or
// Available call. Create one Transport per process; the adapter's link-change
// handler is process-global.
func New(cfg Config) *Transport {
	cfg = cfg.withDefaults()
	t := &Transport{
		cfg:     cfg,
		adapter: bluetooth.DefaultAdapter,
		events:  make(chan transport.Event, cfg.EventBuffer),
		seen:    make(map[string]seenEntry),
	}
	// SetConnectHandler must be installed before adapter.Connect for the handler
	// to fire (tinygo commit 031390ed calls it on disconnect too).
	t.adapter.SetConnectHandler(t.onAdapterLinkChange)
	return t
}

// Events implements transport.Transport. The channel is created once and
// closed by Close. Notifications beyond Config.EventBuffer are dropped and
// counted by Dropped.
func (t *Transport) Events() <-chan transport.Event { return t.events }

// Dropped returns how many events were dropped because the Events buffer was
// full. A steady increase means the consumer is not draining fast enough.
func (t *Transport) Dropped() uint64 { return t.dropped.Load() }

// Available enables the BLE adapter and reports why BLE cannot be used here.
//
// A nil result does not prove that a radio is present: WinRT has no adapter
// power event before a session, so the first Scan/Connect is what really shows
// a missing or powered-off radio (spec-ble §5.1).
func (t *Transport) Available() error {
	if t.closed.Load() {
		return transport.ErrClosed
	}
	if err := t.enableAdapter(); err != nil {
		return err
	}
	t.logf("winble: adapter enabled (RoInitialize MTA)")
	return nil
}

// Close implements transport.Transport. It drops the link, ends any scan and
// closes the Events channel. It is idempotent.
func (t *Transport) Close() error {
	t.closeOnce.Do(func() {
		_ = t.Disconnect()
		t.emitMu.Lock()
		t.closed.Store(true)
		close(t.events)
		t.emitMu.Unlock()
	})
	return nil
}

// Disconnect implements transport.Transport. An explicit disconnect emits no
// EventDisconnected (like the macOS transport: only an unexpected link loss is
// reported). It is idempotent.
func (t *Transport) Disconnect() error {
	_ = t.StopScan()
	t.linkMu.Lock()
	l := t.link
	t.link = nil
	t.linkMu.Unlock()
	if l == nil {
		return nil
	}
	t.logf("winble: disconnect %s", l.id)
	t.teardown(l)
	return nil
}

// Write implements transport.Transport. Frames are sent one at a time in call
// order. The preferred path is one GATT write with response: Windows performs an
// ATT long write for a value larger than one PDU, so a ~193-byte A2687 frame
// needs no chunking. Only when the characteristic lacks the write property does
// the transport fall back to write-without-response, which ATT cannot fragment,
// and chunk at MTU-3.
func (t *Transport) Write(ctx context.Context, data []byte) error {
	if t.closed.Load() {
		return transport.ErrClosed
	}
	if len(data) == 0 {
		return nil
	}
	l := t.currentLink()
	if l == nil {
		return transport.ErrNotConnected
	}

	t.writeMu.Lock()
	defer t.writeMu.Unlock()
	if t.currentLink() != l {
		return transport.ErrNotConnected
	}

	if l.withResp {
		if len(data) > maxGATTValue {
			return fmt.Errorf("%w: %d B > %d B", ErrFrameTooLong, len(data), maxGATTValue)
		}
		return t.writeWithResponse(ctx, l, data)
	}
	return t.writeChunked(ctx, l, data)
}

// Connect implements transport.Transport.
//
// The device must be one seen by a scan in this process: id is the BLE MAC that
// EventDiscovered carried. A cached address is tried first; a stale one (the
// system forgot the device since the scan) and an unknown one fall back to a
// bounded scan that watches for the exact MAC, then connect by the freshly
// observed address. GATT is discovered, notifications are enabled, and only
// then is EventConnected emitted.
func (t *Transport) Connect(ctx context.Context, id string) error {
	if t.closed.Load() {
		return transport.ErrClosed
	}
	macID, err := normalizeDeviceID(id)
	if err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := t.enableAdapter(); err != nil {
		return err
	}

	t.connectMu.Lock()
	defer t.connectMu.Unlock()
	if t.closed.Load() {
		return transport.ErrClosed
	}
	if l := t.currentLink(); l != nil {
		if strings.EqualFold(l.id, macID) {
			t.logf("winble: already connected to %s", macID)
			return nil
		}
		_ = t.Disconnect()
	}

	dev, err := t.resolveAndDial(ctx, macID)
	if err != nil {
		return err
	}
	l, err := t.setupLink(ctx, dev, macID)
	if err != nil {
		_ = dev.Disconnect()
		return err
	}

	t.linkMu.Lock()
	t.link = l
	t.linkMu.Unlock()
	go t.monitorLink(l)

	t.logf("winble: connected %s (MTU %d, with response %v)", l.id, l.mtu, l.withResp)
	t.emit(transport.Event{Kind: transport.EventConnected, Device: t.deviceFrom(l)})
	return nil
}

// normalizeDeviceID accepts a MAC in any case and returns it in the canonical
// upper-case "AA:BB:CC:DD:EE:FF" form the backend prints and parses.
func normalizeDeviceID(id string) (string, error) {
	id = strings.ToUpper(strings.TrimSpace(id))
	if id == "" {
		return "", fmt.Errorf("winble: empty device id: %w", transport.ErrNotFound)
	}
	if _, err := bluetooth.ParseMAC(id); err != nil {
		return "", fmt.Errorf("winble: device id %q is not a Bluetooth MAC address: %w", id, transport.ErrNotFound)
	}
	return id, nil
}

// resolveAndDial tries the address the scan cache holds, then scans for the
// device when the cache misses or the address no longer resolves.
func (t *Transport) resolveAndDial(ctx context.Context, id string) (bluetooth.Device, error) {
	if e, ok := t.cached(id); ok {
		dev, err := t.dial(ctx, e.addr)
		if err == nil {
			return dev, nil
		}
		if !errors.Is(err, transport.ErrNotFound) {
			return bluetooth.Device{}, err
		}
		// FromBluetoothAddressAsync resolves only paired or recently seen
		// devices; a scan refreshes the system cache.
		t.forget(id)
		t.logf("winble: cached address for %s no longer resolves, scanning: %v", id, err)
	}
	addr, err := t.scanForID(ctx, id)
	if err != nil {
		return bluetooth.Device{}, err
	}
	return t.dial(ctx, addr)
}

// dial runs adapter.Connect under a timeout. WinRT ignores ConnectionParams
// except Priority (Windows 11 22000+), whose failure the backend ignores.
func (t *Transport) dial(ctx context.Context, addr bluetooth.Address) (bluetooth.Device, error) {
	dctx, cancel := context.WithTimeout(ctx, t.cfg.ConnectTimeout)
	defer cancel()

	type result struct {
		dev bluetooth.Device
		err error
	}
	done := make(chan result, 1)
	go func() {
		dev, err := t.adapter.Connect(addr, bluetooth.ConnectionParams{
			Priority: bluetooth.ConnectionPriorityThroughput,
		})
		done <- result{dev: dev, err: err}
	}()

	select {
	case r := <-done:
		if r.err != nil {
			return bluetooth.Device{}, mapConnectError(r.err)
		}
		return r.dev, nil
	case <-dctx.Done():
		// adapter.Connect cannot be cancelled; release a device if the backend
		// completes after this caller gave up.
		go func() {
			r := <-done
			if r.err == nil {
				_ = r.dev.Disconnect()
			}
		}()
		if errors.Is(dctx.Err(), context.DeadlineExceeded) {
			return bluetooth.Device{}, fmt.Errorf("winble: connect to %s: %w: %v", addr.String(), transport.ErrTimeout, dctx.Err())
		}
		return bluetooth.Device{}, fmt.Errorf("winble: connect to %s: %w", addr.String(), dctx.Err())
	}
}

// setupLink discovers GATT and subscribes under a timeout; discovery calls are
// WinRT async waits that cannot be cancelled, so a late result is released.
func (t *Transport) setupLink(ctx context.Context, dev bluetooth.Device, id string) (*link, error) {
	type result struct {
		l   *link
		err error
	}
	done := make(chan result, 1)
	go func() {
		l, err := t.configureGATT(dev, id)
		done <- result{l: l, err: err}
	}()

	sctx, cancel := context.WithTimeout(ctx, t.cfg.ConnectTimeout)
	defer cancel()
	select {
	case r := <-done:
		return r.l, r.err
	case <-sctx.Done():
		go func() {
			r := <-done
			if r.l != nil {
				t.teardown(r.l)
			} else {
				_ = dev.Disconnect()
			}
		}()
		return nil, fmt.Errorf("winble: GATT setup for %s: %w: %v", id, transport.ErrTimeout, sctx.Err())
	}
}

// configureGATT discovers the A2687 service and its write/notify
// characteristics and enables notifications.
func (t *Transport) configureGATT(dev bluetooth.Device, id string) (*link, error) {
	services, err := dev.DiscoverServices([]bluetooth.UUID{serviceUUID})
	if err != nil {
		return nil, mapGATTError("discover services", err, errors.Is(err, bluetooth.ErrServiceNotFound))
	}
	if len(services) != 1 {
		return nil, fmt.Errorf("winble: discover services: expected 1 service, got %d: %w", len(services), transport.ErrNotFound)
	}

	chars, err := services[0].DiscoverCharacteristics([]bluetooth.UUID{writeUUID, notifyUUID})
	if err != nil {
		return nil, mapGATTError("discover characteristics", err, errors.Is(err, bluetooth.ErrCharacteristicNotFound))
	}
	if len(chars) != 2 {
		return nil, fmt.Errorf("winble: discover characteristics: expected 2, got %d: %w", len(chars), transport.ErrNotFound)
	}
	writeCh, notifyCh := chars[0], chars[1]

	lctx, lcancel := context.WithCancel(context.Background())
	l := &link{
		ctx:    lctx,
		cancel: lcancel,
		loss:   make(chan struct{}, 1),
		dev:    dev,
		id:     id,
		addr:   dev.Address,
		write:  writeCh,
		notify: notifyCh,
	}
	if e, ok := t.cached(id); ok {
		l.name = e.name
	}

	writeProps := writeCh.Properties()
	l.withResp = writeProps&gattPropWrite != 0
	if !l.withResp && writeProps&gattPropWriteWithoutResponse == 0 {
		lcancel()
		return nil, fmt.Errorf("winble: write characteristic supports neither write nor write-without-response: %w", transport.ErrNotFound)
	}
	notifyProps := notifyCh.Properties()
	if notifyProps&(gattPropNotify|gattPropIndicate) == 0 {
		lcancel()
		return nil, fmt.Errorf("winble: notify characteristic supports neither notify nor indicate: %w", transport.ErrNotFound)
	}

	l.mtu = attMinimumMTU
	if mtu, err := writeCh.GetMTU(); err == nil && mtu >= attMinimumMTU {
		l.mtu = mtu
	} else if err != nil {
		// R3: a conservative value is better than a stale one; the parenthesised
		// write path does not depend on it.
		t.logf("winble: GetMTU: %v (using the ATT minimum 23)", err)
	}

	t.logf("winble: GATT %s: write props=0x%04X (with response %v) notify props=0x%04X MTU=%d maxWriteLength(without response)=%d",
		id, writeProps, l.withResp, notifyProps, l.mtu, payloadLimit(l.mtu))

	if err := notifyCh.EnableNotifications(func(buf []byte) {
		// Runs on a WinRT thread: copy the buffer and return immediately.
		data := append([]byte(nil), buf...)
		t.emit(transport.Event{Kind: transport.EventData, Data: data})
	}); err != nil {
		lcancel()
		return nil, mapGATTError("enable notifications", err, false)
	}
	return l, nil
}

// monitorLink reports the end of the link exactly once and releases it. It runs
// until the link is torn down or lost.
func (t *Transport) monitorLink(l *link) {
	ticker := time.NewTicker(linkPollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-l.ctx.Done():
			return
		case <-l.loss:
			t.linkLost(l, errors.New("winble: Bluetooth link lost"))
			return
		case <-ticker.C:
			connected, err := l.dev.Connected()
			if err != nil {
				t.logf("winble: Connected() poll: %v", err)
				continue
			}
			if !connected {
				t.linkLost(l, errors.New("winble: charger disconnected"))
				return
			}
		}
	}
}

// linkLost tears a link down and emits the one EventDisconnected for it. It is
// a no-op if the link was already replaced or deliberately disconnected.
func (t *Transport) linkLost(l *link, reason error) {
	t.linkMu.Lock()
	if t.link != l {
		t.linkMu.Unlock()
		return
	}
	t.link = nil
	t.linkMu.Unlock()

	dev := t.deviceFrom(l)
	t.teardown(l)
	t.logf("winble: link lost: %v", reason)
	t.emit(transport.Event{Kind: transport.EventDisconnected, Device: dev, Err: reason})
}

// onAdapterLinkChange is installed on the adapter before every Connect. It is
// called on a WinRT thread; it only signals the monitor goroutine.
func (t *Transport) onAdapterLinkChange(dev bluetooth.Device, connected bool) {
	if connected {
		return
	}
	addr := dev.Address.String()
	t.linkMu.Lock()
	l := t.link
	match := l != nil && strings.EqualFold(l.addr.String(), addr)
	t.linkMu.Unlock()
	if !match {
		return
	}
	select {
	case l.loss <- struct{}{}:
	default: // a loss is already pending
	}
}

// teardown releases GATT and the WinRT session. Notifications are disabled
// before the device closes, so the CCCD is restored and no callback runs after
// the transport forgot the link (spec-ble §7 R10).
func (t *Transport) teardown(l *link) {
	l.cancel()
	_ = l.notify.EnableNotifications(nil)
	_ = l.dev.Disconnect()
}

// writeWithResponse sends the whole frame in one GATT write request. Windows
// fragments values larger than the MTU into an ATT long write
// (prepare/execute), which is the path CoreBluetooth uses too.
func (t *Transport) writeWithResponse(ctx context.Context, l *link, data []byte) error {
	wctx, cancel := withTimeout(ctx, t.cfg.WriteTimeout)
	defer cancel()

	type result struct {
		n   int
		err error
	}
	done := make(chan result, 1)
	go func() {
		n, err := l.write.Write(data)
		done <- result{n: n, err: err}
	}()

	select {
	case r := <-done:
		if r.err != nil {
			return mapWriteError(len(data), r.err)
		}
		t.logf("winble: write %d B with response: ok", len(data))
		return nil
	case <-wctx.Done():
		// The WinRT write cannot be cancelled; the buffered goroutine above keeps
		// its result from leaking.
		return fmt.Errorf("winble: write %d B: %w: %v", len(data), transport.ErrTimeout, wctx.Err())
	}
}

// writeChunked is the fallback for a characteristic that only supports
// write-without-response. An ATT write command cannot be fragmented, so the
// frame is split at MTU-3; whether the charger's frame parser reassembles such
// chunks is a hardware question (spec-ble §7 R2) and has to be confirmed on a
// real A2687.
func (t *Transport) writeChunked(ctx context.Context, l *link, data []byte) error {
	limit := payloadLimit(l.mtu)
	segments := segmentFrame(len(data), limit)
	t.logf("winble: write %d B without response in %d chunk(s) of <=%d B (MTU %d)",
		len(data), len(segments), limit, l.mtu)
	for _, seg := range segments {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("winble: write chunk %d..%d of %d: %w", seg[0], seg[1], len(data), err)
		}
		if _, err := l.write.WriteWithoutResponse(data[seg[0]:seg[1]]); err != nil {
			return mapWriteError(len(data), fmt.Errorf("chunk %d..%d: %w", seg[0], seg[1], err))
		}
	}
	return nil
}

// enableAdapter runs adapter.Enable at most once per process.
func (t *Transport) enableAdapter() error {
	enableOnce.Do(func() {
		enableErr = enableOnWorkerThread(t.adapter.Enable)
	})
	if enableErr == nil {
		return nil
	}
	if isRepeatedInit(enableErr) {
		t.logf("winble: adapter already initialized in this process: %v", enableErr)
		return nil
	}
	return fmt.Errorf("winble: Bluetooth is unavailable (cannot initialize WinRT): %w: %v",
		transport.ErrUnsupported, enableErr)
}

// enableOnWorkerThread runs fn on an OS thread whose COM apartment the process
// has not initialized. Adapter.Enable is RoInitialize(RO_INIT_MULTITHREADED),
// which fails with RPC_E_CHANGED_MODE when the calling thread is already in an
// STA -- exactly what a GUI toolkit such as mygo/WebView2 does to its main
// thread (spec-ble §7 R6). A locked worker goroutine is guaranteed to run on a
// different OS thread.
func enableOnWorkerThread(fn func() error) error {
	done := make(chan error, 1)
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		done <- fn()
	}()
	return <-done
}

// withTimeout applies Config.WriteTimeout only when the caller's context has no
// deadline of its own.
func withTimeout(ctx context.Context, d time.Duration) (context.Context, context.CancelFunc) {
	if _, ok := ctx.Deadline(); ok {
		return context.WithCancel(ctx)
	}
	return context.WithTimeout(ctx, d)
}

// currentLink returns the live link, or nil.
func (t *Transport) currentLink() *link {
	t.linkMu.Lock()
	defer t.linkMu.Unlock()
	return t.link
}

// deviceFrom builds the Discovered payload reported for a link.
func (t *Transport) deviceFrom(l *link) transport.Discovered {
	rssi := 0
	if e, ok := t.cached(l.id); ok {
		rssi = e.rssi
	}
	return transport.Discovered{
		ID:      l.id,
		Name:    l.name,
		Address: l.addr.String(),
		RSSI:    rssi,
		Product: product.ProductA2687,
	}
}

// remember stores the advertisement a scan saw, so a later Connect can reuse
// the exact bluetooth.Address value the backend produced rather than re-parse a
// MAC.
func (t *Transport) remember(id string, e seenEntry) {
	id = strings.ToUpper(strings.TrimSpace(id))
	t.seenMu.Lock()
	t.seen[id] = e
	t.seenMu.Unlock()
}

// cached returns the last advertisement for id.
func (t *Transport) cached(id string) (seenEntry, bool) {
	id = strings.ToUpper(strings.TrimSpace(id))
	t.seenMu.Lock()
	defer t.seenMu.Unlock()
	e, ok := t.seen[id]
	return e, ok
}

// forget drops a cached address that no longer resolves.
func (t *Transport) forget(id string) {
	id = strings.ToUpper(strings.TrimSpace(id))
	t.seenMu.Lock()
	delete(t.seen, id)
	t.seenMu.Unlock()
}

// emit never blocks: it is called from WinRT threads that must not stall.
func (t *Transport) emit(e transport.Event) {
	t.emitMu.RLock()
	defer t.emitMu.RUnlock()
	if t.closed.Load() {
		return
	}
	select {
	case t.events <- e:
	default:
		t.dropped.Add(1)
	}
}

func (t *Transport) logf(format string, args ...any) {
	if t.cfg.Logf != nil {
		t.cfg.Logf(format, args...)
	}
}
