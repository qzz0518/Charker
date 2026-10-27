package session

import (
	"time"

	"charker/internal/product"
)

// Phase is the session lifecycle phase shown by the UI.
type Phase string

// Session phases (contract §3/§4.1).
const (
	PhaseIdle         Phase = "idle"
	PhaseScanning     Phase = "scanning"
	PhaseConnecting   Phase = "connecting"
	PhaseHandshake    Phase = "handshake"
	PhasePolling      Phase = "polling"
	PhaseReconnecting Phase = "reconnecting"
	PhaseFailed       Phase = "failed"
)

// Device is the session-facing charger summary. The app maps it to the frozen
// AppState `device`/`devices` entries.
type Device struct {
	ID        string                 `json:"id"`
	Name      string                 `json:"name"`
	Product   product.ChargerProduct `json:"product"`
	Address   string                 `json:"address"`
	RSSI      int                    `json:"rssi"`
	Connected bool                   `json:"connected"`
	Saved     bool                   `json:"saved"`
	Mock      bool                   `json:"mock"`
	// ProductName, Firmware, Serial and MAC come from the base-info exchange.
	ProductName string `json:"productName,omitempty"`
	Firmware    string `json:"firmware,omitempty"`
	Serial      string `json:"serial,omitempty"`
	MAC         string `json:"mac,omitempty"`
}

// Snapshot is the immutable session state published to the app. Snapshot()
// is cheap and safe from any goroutine; every field is either a value or an
// immutable slice/pointer that is never mutated after publication.
type Snapshot struct {
	Phase     Phase            `json:"phase"`
	Scanning  bool             `json:"scanning"`
	Device    *Device          `json:"device,omitempty"`
	Devices   []Device         `json:"devices"`
	Reading   *product.Reading `json:"reading,omitempty"`
	Telemetry *Telemetry       `json:"telemetry,omitempty"`
	History   []HistorySample  `json:"history"`
	// Stage is the handshake stage while Phase is handshake.
	Stage string `json:"stage,omitempty"`
	// Attempt is the reconnect attempt while Phase is reconnecting.
	Attempt       int                  `json:"attempt,omitempty"`
	Stats         product.SessionStats `json:"stats"`
	Settings      product.Settings     `json:"settings"`
	Err           string               `json:"err,omitempty"`
	Warning       string               `json:"warning,omitempty"`
	ConnectedAtMs int64                `json:"connectedAtMs,omitempty"`
	IsStale       bool                 `json:"isStale"`
	LimitWatts    float64              `json:"limitWatts"`
	LastUpdatedMs int64                `json:"lastUpdatedMs"`
}

// Live reports whether the snapshot carries fresh telemetry.
func (s Snapshot) Live() bool {
	return s.Phase == PhasePolling && s.Reading != nil && !s.IsStale
}

// ports returns the current reading's ports in product order.
func (s Snapshot) ports() []product.PortReading {
	if s.Reading == nil {
		return nil
	}
	return s.Reading.Ports
}

// statsFromSamples is the fallback stats derivation; the manager keeps a
// running integrator, this helper is exposed for tests and adapters.
func msOf(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UnixMilli()
}
