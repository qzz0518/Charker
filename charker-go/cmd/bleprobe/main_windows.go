//go:build windows

// Command bleprobe is the hardware acceptance tool for the Windows BLE
// transport (internal/transport/winble). It is the tool from
// docs/port/spec-ble.md §8.5, rebuilt against the real package:
//
//	bleprobe                              # scan 10 s and print every device
//	bleprobe -seconds 5                   # shorter scan
//	bleprobe -connect AA:BB:CC:DD:EE:FF   # scan, then connect to that charger
//	bleprobe -connect auto                # scan, then connect to the strongest candidate
//	bleprobe -connect auto -writesize 20  # ...and write a 20-byte frame
//	bleprobe -connect auto -writesize 100
//	bleprobe -connect auto -writesize 193 # largest A2687 frame (cover chunk)
//	bleprobe -connect auto -writesize 193 -without-response
//
// It talks to tinygo.org/x/bluetooth directly on purpose: the probe must show
// what the radio and the WinRT backend do (services, manufacturer data,
// properties, MTU, write sizes, raw notification hex), independently of the
// session-facing transport wrapper. Matching uses winble.MatchAdvertisement so
// the probe and the transport agree on what an A2687 advertisement looks like.
package main

import (
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"tinygo.org/x/bluetooth"

	"charker/internal/product"
	"charker/internal/transport/winble"
)

// errNotScanning is what StopScan returns when the watcher already stopped.
const errNotScanning = "there is no scan in progress"

// observation is one device seen during the scan, kept for the summary table
// and for connecting.
type observation struct {
	id       string
	addr     bluetooth.Address
	name     string
	rssi     int16
	services []string
	mfg      []string
	updates  int
	product  product.ChargerProduct
	reasons  []winble.MatchReason
}

func (o *observation) candidate() bool { return o.product != "" }

func main() {
	os.Exit(run())
}

func run() int {
	seconds := flag.Int("seconds", 10, "scan duration in seconds")
	connect := flag.String("connect", "", `MAC of the charger to connect to after the scan, or "auto" for the strongest Anker candidate`)
	writeSize := flag.Int("writesize", 0, "after connecting, write one frame of this many bytes (0 = the 16-byte 0x0001 initialConnect frame)")
	withoutResponse := flag.Bool("without-response", false, "use write-without-response instead of write-with-response")
	nameFilter := flag.String("name", "", "only print devices whose local name contains this (case-insensitive)")
	flag.Parse()

	if *seconds < 0 {
		fmt.Fprintln(os.Stderr, "bleprobe: -seconds must be >= 0")
		return 2
	}
	if *writeSize != 0 && *writeSize < 10 {
		fmt.Fprintln(os.Stderr, "bleprobe: -writesize must be 0 or at least 10 (the A2687 frame header is 10 bytes)")
		return 2
	}

	fmt.Printf("bleprobe: %s %s/%s\n", runtime.Version(), runtime.GOOS, runtime.GOARCH)

	adapter := bluetooth.DefaultAdapter
	if err := adapter.Enable(); err != nil {
		fmt.Fprintf(os.Stderr, "bleprobe: adapter.Enable: %v\n", err)
		fmt.Fprintln(os.Stderr, "bleprobe: if the message says the function is incorrect, this process already initialized COM (harmless); otherwise Bluetooth is unavailable.")
		return 2
	}
	fmt.Println("adapter: enabled (RoInitialize MTA)")

	devices, scanErr := scan(adapter, time.Duration(*seconds)*time.Second, strings.ToLower(*nameFilter))
	fmt.Printf("\nscan ended: err=%v devices=%d candidates=%d\n", scanErr, len(devices), countCandidates(devices))
	if scanErr != nil {
		fmt.Println("scan: no radio, radio off, a driver problem, or the watcher failed to start (see error above)")
	}

	if *connect == "" {
		return 0
	}
	target := pickTarget(devices, *connect)
	if target == nil {
		fmt.Printf("connect: no target for %q\n", *connect)
		return 1
	}
	return gattProbe(adapter, target, *writeSize, *withoutResponse)
}

// countCandidates counts the devices that matched an A2687 rule.
func countCandidates(devices []*observation) int {
	n := 0
	for _, d := range devices {
		if d.candidate() {
			n++
		}
	}
	return n
}

// pickTarget resolves the -connect value: a MAC, or "auto" for the strongest
// candidate.
func pickTarget(devices []*observation, want string) *observation {
	if strings.EqualFold(want, "auto") {
		var best *observation
		for _, d := range devices {
			if !d.candidate() {
				continue
			}
			if best == nil || d.rssi > best.rssi {
				best = d
			}
		}
		return best
	}
	want = strings.TrimSpace(want)
	for _, d := range devices {
		if strings.EqualFold(d.id, want) {
			return d
		}
	}
	// A MAC that did not advertise in the scan window can still be resolved if
	// the system has it cached; connect by a parsed address.
	if mac, err := bluetooth.ParseMAC(strings.ToUpper(want)); err == nil {
		return &observation{id: strings.ToUpper(want), addr: bluetooth.Address{MACAddress: bluetooth.NewMACAddress(mac, false)}, product: product.ProductA2687}
	}
	return nil
}

// scan runs the unfiltered active scan and prints every device it sees.
func scan(adapter *bluetooth.Adapter, window time.Duration, nameFilter string) ([]*observation, error) {
	var (
		mu    sync.Mutex
		byID  = map[string]*observation{}
		order []string
	)
	errCh := make(chan error, 1)
	go func() {
		errCh <- adapter.Scan(func(_ *bluetooth.Adapter, r bluetooth.ScanResult) {
			// The ScanResult payload is only valid inside this callback: copy it.
			id := r.Address.String()
			name := r.LocalName()
			services := make([]string, 0, len(r.ServiceUUIDs()))
			for _, u := range r.ServiceUUIDs() {
				services = append(services, u.String())
			}
			var (
				mfg     []string
				rawMfg  [][]byte
				svcData int
			)
			for _, m := range r.ManufacturerData() {
				raw := make([]byte, 0, 2+len(m.Data))
				raw = append(raw, byte(m.CompanyID), byte(m.CompanyID>>8))
				raw = append(raw, m.Data...)
				rawMfg = append(rawMfg, raw)
				mfg = append(mfg, fmt.Sprintf("company=0x%04X data=%s", m.CompanyID, hex.EncodeToString(m.Data)))
			}
			svcData = len(r.ServiceData())
			prod, reasons, _ := winble.MatchAdvertisement(name, services, rawMfg)

			mu.Lock()
			o, ok := byID[id]
			if !ok {
				o = &observation{id: id, addr: r.Address}
				byID[id] = o
				order = append(order, id)
			}
			o.name, o.rssi, o.services, o.mfg = name, r.RSSI, services, mfg
			o.product, o.reasons = prod, reasons
			o.updates++
			first := !ok
			mu.Unlock()

			if first && (nameFilter == "" || strings.Contains(strings.ToLower(name), nameFilter)) {
				extra := ""
				if svcData > 0 {
					// The Windows backend never fills ServiceData today; if a future
					// version does, show it rather than silently dropping it.
					extra = fmt.Sprintf(" svcData=%d", svcData)
				}
				fmt.Printf("[seen] %-17s rssi=%4d name=%q svc=%v mfg=[%s] match=%v%s\n",
					id, r.RSSI, name, services, strings.Join(mfg, "; "), reasons, extra)
			}
		})
	}()

	timer := time.AfterFunc(window, func() {
		if err := adapter.StopScan(); err != nil && !strings.Contains(err.Error(), errNotScanning) {
			fmt.Printf("bleprobe: StopScan: %v\n", err)
		}
	})
	scanErr := <-errCh
	timer.Stop()
	if scanErr != nil && strings.Contains(scanErr.Error(), errNotScanning) {
		scanErr = nil // a watcher stopped by StopScan reports this, not a failure
	}

	mu.Lock()
	devices := make([]*observation, 0, len(order))
	for _, id := range order {
		devices = append(devices, byID[id])
	}
	mu.Unlock()
	sort.SliceStable(devices, func(i, j int) bool {
		if devices[i].candidate() != devices[j].candidate() {
			return devices[i].candidate() // candidates first
		}
		return devices[i].rssi > devices[j].rssi
	})

	fmt.Printf("\n%-17s %-22s %5s %5s %s\n", "ADDRESS (= id)", "NAME", "RSSI", "PKTS", "MATCH")
	for _, o := range devices {
		fmt.Printf("%-17s %-22s %5d %5d %v\n",
			o.id, truncate(o.name, 22), o.rssi, o.updates, o.reasons)
	}
	return devices, scanErr
}

// gattProbe walks the GATT path the transport needs: connect, discover the
// A2687 service and characteristics, print MTU/properties, subscribe, write one
// frame of the requested size, then report notifications for two seconds.
func gattProbe(adapter *bluetooth.Adapter, target *observation, writeSize int, withoutResponse bool) int {
	fmt.Printf("\n=== GATT probe against %s (%s) ===\n", target.id, target.name)
	dev, err := adapter.Connect(target.addr, bluetooth.ConnectionParams{
		Priority: bluetooth.ConnectionPriorityThroughput,
	})
	if err != nil {
		fmt.Printf("connect : FAILED: %v\n", err)
		return 1
	}
	fmt.Println("connect : ok")
	defer func() {
		if err := dev.Disconnect(); err != nil {
			fmt.Printf("disconnect: %v\n", err)
		} else {
			fmt.Println("disconnect: ok")
		}
	}()

	svcUUID, err := bluetooth.ParseUUID(winble.PrimaryService)
	if err != nil {
		fmt.Printf("service : bad UUID constant: %v\n", err)
		return 1
	}
	writeUUID, err := bluetooth.ParseUUID(winble.WriteCharacteristic)
	if err != nil {
		fmt.Printf("characteristic: bad UUID constant: %v\n", err)
		return 1
	}
	notifyUUID, err := bluetooth.ParseUUID(winble.NotifyCharacteristic)
	if err != nil {
		fmt.Printf("characteristic: bad UUID constant: %v\n", err)
		return 1
	}

	services, err := dev.DiscoverServices([]bluetooth.UUID{svcUUID})
	if err != nil {
		fmt.Printf("service : FAILED (not an A2687?): %v\n", err)
		return 1
	}
	fmt.Printf("service : %s ok\n", services[0].UUID())

	chars, err := services[0].DiscoverCharacteristics([]bluetooth.UUID{writeUUID, notifyUUID})
	if err != nil {
		fmt.Printf("chars   : FAILED: %v\n", err)
		return 1
	}
	for _, c := range chars {
		mtu, mtuErr := c.GetMTU()
		mtuText := fmt.Sprintf("%d", mtu)
		if mtuErr != nil {
			mtuText = fmt.Sprintf("error(%v)", mtuErr)
		}
		fmt.Printf("char    : %s props=0x%04X MTU=%s maxWriteLength(without response)=%d\n",
			c.UUID(), c.Properties(), mtuText, int(mtu)-3)
	}

	var (
		mu       sync.Mutex
		notifies int
		notifyB  int
		samples  []string
	)
	if err := chars[1].EnableNotifications(func(buf []byte) {
		// WinRT thread: copy, count, print a few samples.
		data := append([]byte(nil), buf...)
		mu.Lock()
		notifies++
		notifyB += len(data)
		n := notifies
		if len(samples) < 8 {
			samples = append(samples, hex.EncodeToString(data))
		}
		mu.Unlock()
		fmt.Printf("[notify #%d] %d B %s\n", n, len(data), hex.EncodeToString(data))
	}); err != nil {
		fmt.Printf("subscribe: FAILED: %v\n", err)
		return 1
	}
	fmt.Println("subscribe: ok")

	frame := probeFrame(writeSize, time.Now())
	if frame == nil {
		fmt.Printf("frame   : cannot build a %d-byte frame\n", writeSize)
		return 2
	}
	fmt.Printf("write   : %d B with response=%v\n", len(frame), !withoutResponse)
	start := time.Now()
	var n int
	if withoutResponse {
		n, err = chars[0].WriteWithoutResponse(frame)
	} else {
		n, err = chars[0].Write(frame)
	}
	elapsed := time.Since(start).Round(time.Millisecond)
	if err != nil {
		fmt.Printf("write   : FAILED after %d B in %s: %v\n", n, elapsed, err)
		if withoutResponse {
			fmt.Println("write   : (a write command cannot be fragmented; the transport chunks this case at MTU-3)")
		}
	} else {
		fmt.Printf("write   : ok, %d B in %s\n", n, elapsed)
	}

	time.Sleep(2 * time.Second)
	mu.Lock()
	fmt.Printf("notifications in 2s: %d value(s), %d byte(s)\n", notifies, notifyB)
	if len(samples) > 0 {
		fmt.Printf("notification samples: %v\n", samples)
	}
	mu.Unlock()
	return 0
}

// probeFrame builds one A2687-shaped frame of exactly size bytes: the 16-byte
// initialConnect frame when size is 0, otherwise the 0x0001 negotiation frame
// with a payload padded to size-10. Header and XOR checksum are valid so the
// write exercises the radio path, not the frame parser.
func probeFrame(size int, now time.Time) []byte {
	if size == 0 {
		return initialConnectFrame(now)
	}
	if size < 10 {
		return nil
	}
	payload := make([]byte, size-10)
	if len(payload) >= 2 {
		payload[0] = 0xA1
		payload[1] = 0x04
	}
	if len(payload) >= 6 {
		ts := uint32(now.Unix())
		payload[2] = byte(ts)
		payload[3] = byte(ts >> 8)
		payload[4] = byte(ts >> 16)
		payload[5] = byte(ts >> 24)
	}
	return encodeFrame(0x01, 0x0001, payload)
}

// initialConnectFrame builds the 16-byte 0x0001 frame from A2687Protocol's
// PacketCodec: FF 09 <len LE16> 03 00 01 00 01 A1 04 <epoch LE32> <xor>.
func initialConnectFrame(now time.Time) []byte {
	ts := uint32(now.Unix())
	payload := []byte{0xA1, 0x04, byte(ts), byte(ts >> 8), byte(ts >> 16), byte(ts >> 24)}
	return encodeFrame(0x01, 0x0001, payload)
}

// encodeFrame builds one FF09 frame (header, little-endian length, group, raw
// command, payload, XOR checksum).
func encodeFrame(group byte, rawCommand uint16, payload []byte) []byte {
	length := 10 + len(payload)
	out := make([]byte, 0, length)
	out = append(out, 0xFF, 0x09, byte(length&0xFF), byte(length>>8), 0x03, 0x00, group,
		byte(rawCommand>>8), byte(rawCommand&0xFF))
	out = append(out, payload...)
	var checksum byte
	for _, b := range out {
		checksum ^= b
	}
	return append(out, checksum)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
