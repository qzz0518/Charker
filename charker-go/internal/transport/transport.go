// Package transport defines the seam between the session engine and a
// concrete charger link: Bluetooth LE on Windows, or the simulator.
package transport

import (
	"context"
	"errors"

	"charker/internal/product"
)

// Errors a transport returns. The session engine treats them as fatal for the
// current attempt and starts its reconnect ladder.
var (
	ErrClosed      = errors.New("transport: closed")
	ErrNotConnected = errors.New("transport: not connected")
	ErrUnsupported = errors.New("transport: unsupported on this platform")
	ErrNotFound    = errors.New("transport: charger not found")
	ErrTimeout     = errors.New("transport: timeout")
)

// Discovered is a charger seen by a scan or remembered from a previous run.
type Discovered struct {
	// ID is the stable identifier used to connect: the BLE MAC address on
	// Windows ("AA:BB:CC:DD:EE:FF"), or a mock id such as "mock-a2687".
	ID string
	// Name is the advertised name, if any.
	Name string
	// Address is the transport address (BLE MAC), empty for mock.
	Address string
	// RSSI is the last advertisement's signal strength, in dBm.
	RSSI int
	// Product is the charger model the advertisement matched.
	Product product.ChargerProduct
	// Saved is true for a charger remembered from a previous connection.
	Saved bool
	// Mock marks simulator entries.
	Mock bool
}

// EventKind discriminates Event.
type EventKind int

const (
	// EventDiscovered reports one advertisement (also emitted for saved
	// chargers at the start of a scan).
	EventDiscovered EventKind = iota
	// EventScanStopped reports the end of a scan.
	EventScanStopped
	// EventConnected reports that the link is up.
	EventConnected
	// EventDisconnected reports that the link went down; Err says why.
	EventDisconnected
	// EventData carries one notification/indication frame.
	EventData
	// EventError reports a non-fatal transport error worth showing to the
	// user (the session keeps going unless it also emits EventDisconnected).
	EventError
)

// Event is one transport event.
type Event struct {
	Kind   EventKind
	Device Discovered
	Data   []byte
	Err    error
}

// Transport is one link to one charger. Implementations must be safe to call
// from a single owner goroutine; the session engine serialises all calls.
type Transport interface {
	// Scan starts looking for chargers matching the product. Discovered
	// devices arrive as EventDiscovered. Scan may be called again after
	// StopScan, including while connected.
	Scan(ctx context.Context, p product.ChargerProduct) error
	// StopScan ends the current scan; it is a no-op when not scanning.
	StopScan() error
	// Connect connects to the charger with the given id and subscribes to its
	// notification characteristic. It returns once the link is ready to
	// receive the protocol handshake, or with an error.
	Connect(ctx context.Context, id string) error
	// Disconnect closes the link. It is idempotent.
	Disconnect() error
	// Write sends one protocol frame as a GATT write with response.
	Write(ctx context.Context, data []byte) error
	// Events returns the channel events are delivered on. It is created once
	// and closed when the transport is closed.
	Events() <-chan Event
	// Close releases the adapter and ends the event stream.
	Close() error
}

// Name is a human-readable description of the transport, for diagnostics.
type Name string

const (
	NameBLE  Name = "bluetooth"
	NameMock Name = "mock"
	NameNone Name = "none"
)
