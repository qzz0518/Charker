// Package product is the transport-neutral charger model shared by the
// protocol, session and UI layers of Charker for Windows.
//
// It mirrors CharkerCore.ChargerProduct, ChargerPortID and ChargerReading in
// the macOS app, minus the Swift protocols: decoders fill Readings from either
// the A2687 BLE telemetry or the A2345 cloud payload.
package product

import (
	"fmt"
	"math"
	"time"
)

// ChargerProduct identifies a supported charger model.
type ChargerProduct string

const (
	// ProductA2687 is the Anker Prime 160W desktop charger (BLE).
	ProductA2687 ChargerProduct = "a2687"
	// ProductA2345 is the Anker Prime 250W charger (cloud only).
	ProductA2345 ChargerProduct = "a2345"
)

// DisplayName is the product name shown in the UI.
func (p ChargerProduct) DisplayName() string {
	switch p {
	case ProductA2687:
		return "Anker Prime 160W"
	case ProductA2345:
		return "Anker Prime 250W"
	}
	return string(p)
}

// PortCount is the number of ports the model has: 3 for the 160W, 6 for the
// 250W (four USB-C and two USB-A).
func (p ChargerProduct) PortCount() int {
	switch p {
	case ProductA2345:
		return 6
	}
	return 3
}

// PortIDs returns the ports of the product in display order.
func (p ChargerProduct) PortIDs() []PortID {
	if p == ProductA2345 {
		return []PortID{PortC1, PortC2, PortC3, PortC4, PortA1, PortA2}
	}
	return []PortID{PortC1, PortC2, PortC3}
}

// PortID names a charging port.
type PortID string

const (
	PortC1 PortID = "C1"
	PortC2 PortID = "C2"
	PortC3 PortID = "C3"
	PortC4 PortID = "C4"
	PortA1 PortID = "A1"
	PortA2 PortID = "A2"
)

// PortIDs lists every port of every supported model.
var PortIDs = []PortID{PortC1, PortC2, PortC3, PortC4, PortA1, PortA2}

// Valid reports whether p is a known port.
func (p PortID) Valid() bool {
	switch p {
	case PortC1, PortC2, PortC3, PortC4, PortA1, PortA2:
		return true
	}
	return false
}

// String implements fmt.Stringer.
func (p PortID) String() string { return string(p) }

// PortReading is the live state of one port.
type PortReading struct {
	// Enabled is the port's output switch ("port on").
	Enabled bool `json:"enabled"`
	// Status is the raw protocol status byte; 1 means a device is negotiated
	// and drawing power on the A2687. Zero means idle/off.
	Status int `json:"status"`
	// Watts, Volts and Amps are the measured output, zero when idle.
	Watts float64 `json:"watts"`
	Volts float64 `json:"volts"`
	Amps  float64 `json:"amps"`
	// Protocol is the negotiated charging protocol, e.g. "PD", "EPR",
	// "PPS", "Apple", or "" when unknown.
	Protocol string `json:"protocol,omitempty"`
	// EPR is true for USB PD Extended Power Range.
	EPR bool `json:"epr,omitempty"`
	// DeviceKind is the attached device's advertised name/identity, e.g.
	// "Apple", "Notebook" or "" when the charger did not report it.
	DeviceKind string `json:"deviceKind,omitempty"`
	// VID and PID identify the attached USB device when known (A2687 TLV B4);
	// both are zero when unknown.
	VID uint16 `json:"vid,omitempty"`
	PID uint16 `json:"pid,omitempty"`
	// Cable is the cable capability label when the charger reports one.
	Cable string `json:"cable,omitempty"`
}

// Reading is one full telemetry sample of a charger.
type Reading struct {
	Product ChargerProduct `json:"product"`
	Ports   []PortReading  `json:"ports"`
	// TotalWatts is the sum of the port watts measured locally.
	TotalWatts float64 `json:"totalWatts"`
	// ReceivedAt is when the reading was decoded.
	ReceivedAt time.Time `json:"receivedAt"`
}

// TotalWattsOf sums the port readings in place.
func (r *Reading) TotalWattsOf() {
	var sum float64
	for _, p := range r.Ports {
		sum += p.Watts
	}
	r.TotalWatts = round2(sum)
}

// Port returns the reading of port id, and whether the port exists. Decoders
// lay Ports out in Product.PortIDs() order.
func (r Reading) Port(id PortID) (PortReading, bool) {
	i := indexOf(r.Product.PortIDs(), id)
	if i < 0 || i >= len(r.Ports) {
		return PortReading{}, false
	}
	return r.Ports[i], true
}

func indexOf(ids []PortID, id PortID) int {
	for i, v := range ids {
		if v == id {
			return i
		}
	}
	return -1
}

// Settings is the charger's user configuration as last reported by the device.
// Pointer fields are nil when the device did not report that setting in the
// current snapshot.
type Settings struct {
	ScreenOn        *bool   `json:"screenOn,omitempty"`
	Brightness      *int    `json:"brightness,omitempty"`
	Language        *string `json:"language,omitempty"`
	Orientation     *string `json:"orientation,omitempty"`
	AutoLock        *bool   `json:"autoLock,omitempty"`
	Theme           *string `json:"theme,omitempty"`
	FixedAllocation *bool   `json:"fixedAllocation,omitempty"`
	// ScreenTimeout is the screen's auto-off timeout code/mode as the device
	// reports it (A2687 0x0203), e.g. "1min", "5min", "off".
	ScreenTimeout *string `json:"screenTimeout,omitempty"`
	// ChargingMode is the charger's charging mode as the device reports it
	// (A2687 TLV AA): "smart", "custom", or a raw numeric code as a string.
	ChargingMode *string `json:"chargingMode,omitempty"`
	// AutoRotate reports whether the screen rotates with the charger (A2687 B2).
	AutoRotate *bool `json:"autoRotate,omitempty"`
	// PortControls carries per-port switch/countdown/timer configuration.
	PortControls map[PortID]PortControl `json:"portControls,omitempty"`
}

// PortControl is the writable configuration of one port.
type PortControl struct {
	Enabled          bool `json:"enabled"`
	CountdownMinutes int  `json:"countdownMinutes"`
	TimerMinutes     int  `json:"timerMinutes"`
}

// SessionStats aggregates the current charging session for the stats row.
type SessionStats struct {
	PeakW       float64 `json:"peakW"`
	AvgW        float64 `json:"avgW"`
	EnergyWh    float64 `json:"energyWh"`
	ConnectedMs int64   `json:"connectedMs"`
}

// Sample is one point of the power timeline.
type Sample struct {
	T int64   `json:"t"` // epoch milliseconds
	W float64 `json:"w"`
}

// Decimate reduces samples to at most budget points, keeping the minimum and
// maximum of each bucket in time order and always the last sample, so spikes
// and troughs survive while the window slides. Mirrors
// PowerSample.decimated(budget:) from the macOS app.
func Decimate(samples []Sample, budget int) []Sample {
	if budget < 2 || len(samples) <= budget {
		return samples
	}
	first, last := samples[0].T, samples[len(samples)-1].T
	span := last - first
	if span <= 0 {
		return samples[len(samples)-1:]
	}
	// Bucket widths from 1s doubling up, chosen so the number of buckets fits
	// the budget; the grid is anchored to the first sample.
	const baseMs = int64(1000)
	width := baseMs
	for buckets := span/width + 1; buckets > int64(budget); buckets = span/width + 1 {
		width *= 2
	}
	var out []Sample
	for i := 0; i < len(samples); {
		bucketEnd := ((samples[i].T-first)/width + 1) * width
		minS, maxS := samples[i], samples[i]
		j := i
		for j < len(samples) && samples[j].T-first < bucketEnd {
			if samples[j].W < minS.W {
				minS = samples[j]
			}
			if samples[j].W > maxS.W {
				maxS = samples[j]
			}
			j++
		}
		if minS.T <= maxS.T {
			out = append(out, minS, maxS)
		} else {
			out = append(out, maxS, minS)
		}
		i = j
	}
	if len(out) == 0 || out[len(out)-1].T != samples[len(samples)-1].T {
		out = append(out, samples[len(samples)-1])
	}
	if len(out) > budget {
		out = append(out[:budget-1], out[len(out)-1])
	}
	return out
}

// FormatWatts formats w with one decimal place, as the dashboard does.
func FormatWatts(w float64) string { return fmt.Sprintf("%.1f", w) }

func round2(v float64) float64 { return math.Round(v*100) / 100 }
