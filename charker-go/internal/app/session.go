package app

import (
	"context"

	"charker/internal/product"
	"charker/internal/session"
)

// This file is the seam between the app shell and the session engine
// (charker/internal/session, owned by core-session). The session types are
// aliased so the mapping code speaks the engine's own snapshot without a
// second copy of the structs.
type (
	// Phase is the session lifecycle phase mirrored into AppState.
	Phase = session.Phase
	// Device is a charger the session knows about.
	Device = session.Device
	// Snapshot is one immutable view of the session engine.
	Snapshot = session.Snapshot
)

// Session phases (contract §4.1).
const (
	PhaseIdle         = session.PhaseIdle
	PhaseScanning     = session.PhaseScanning
	PhaseConnecting   = session.PhaseConnecting
	PhaseHandshake    = session.PhaseHandshake
	PhasePolling      = session.PhasePolling
	PhaseReconnecting = session.PhaseReconnecting
	PhaseFailed       = session.PhaseFailed
)

// Session is the subset of session.Manager the app shell drives.
type Session interface {
	// Start starts the engine and returns; it runs until ctx is canceled or
	// Stop is called.
	Start(ctx context.Context) error
	Stop()
	Snapshot() Snapshot
	Subscribe(buffer int) <-chan Snapshot

	Scan() error
	StopScan() error
	Connect(id string) error
	Disconnect() error
	Reconnect() error

	SetPortEnabled(port product.PortID, on bool) error
	SetCountdown(port product.PortID, minutes int) error
	SetSetting(key, value string) error
	UpdateLimits(limitWatts float64) error
	// SetWritesEnabled turns the port-switch/countdown write gate on or off.
	SetWritesEnabled(on bool) error

	// UseMock switches the engine between the simulated charger and real
	// Bluetooth. It exists on the app's session host, not on
	// session.Manager: the host swaps managers.
	UseMock(on bool) error
}

// Energy is the subset of energy.Service the app shell consumes.
type Energy interface {
	// Summary returns the cheap day/week/month aggregates for AppState.
	Summary() EnergySummary
	// Report returns the detailed series for "day", "week" or "month".
	Report(rangeArg string) EnergyReport
	// Export renders the series in "csv" or "json" form.
	Export(rangeArg, format string) ([]byte, error)
}

// rangeValid reports whether r names an energy range.
func rangeValid(r string) bool {
	switch r {
	case "day", "week", "month":
		return true
	}
	return false
}

// formatValid reports whether f names an export format.
func formatValid(f string) bool {
	switch f {
	case "csv", "json":
		return true
	}
	return false
}
