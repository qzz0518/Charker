package session

import (
	"math"
	"time"

	"charker/internal/a2687"
)

// Telemetry is the page-facing copy of one decoded A2687 report: every port
// field the macOS app's views read, kept raw (codes as well as labels) so the
// page can apply the same rules PortCard and the product stage apply.
type Telemetry struct {
	ReceivedAtMs int64            `json:"receivedAtMs"`
	Ports        []PortTelemetry  `json:"ports"`
	Settings     *ChargerSettings `json:"settings,omitempty"`
}

// PortTelemetry mirrors a2687.PortTelemetry.
type PortTelemetry struct {
	Port       string  `json:"port"`
	StatusCode int     `json:"statusCode"`
	Voltage    float64 `json:"voltage"`
	Current    float64 `json:"current"`
	Power      float64 `json:"power"`
	// CableCode is the cable capability code (0 60 W, 1 100 W, 2 EPR 240 W,
	// 3 none); nil when the frame carried no cable field.
	CableCode  *int   `json:"cableCode,omitempty"`
	CableLabel string `json:"cableLabel,omitempty"`
	// ProfileCode is the negotiated charging profile; nil when none.
	ProfileCode  *int         `json:"profileCode,omitempty"`
	ProfileLabel string       `json:"profileLabel,omitempty"`
	Control      *PortControl `json:"control,omitempty"`
	Device       *USBDevice   `json:"device,omitempty"`
}

// PortControl mirrors the 12-byte a2687.PortControl block.
type PortControl struct {
	SwitchStatus        int `json:"switchStatus"`
	CountdownTaskStatus int `json:"countdownTaskStatus"`
	CountdownTotal      int `json:"countdownTotal"`
	CountdownRemaining  int `json:"countdownRemaining"`
	// Running is the charger's own countdown report, validated the way
	// RunningCountdown validates it.
	Running bool `json:"running"`
}

// USBDevice is the B4 identity of the device on a port.
type USBDevice struct {
	VendorID  int `json:"vendorId"`
	ProductID int `json:"productId"`
	// NoIdentity: the port reported the FFFA:FFFB "nothing here" pair.
	NoIdentity bool `json:"noIdentity,omitempty"`
}

// ChargerSettings mirrors a2687.DeviceSettings: the handshake-time values the
// charger reported, nil fields unknown.
type ChargerSettings struct {
	ScreenTimeout     *int  `json:"screenTimeout,omitempty"`
	ScreenBrightness  *int  `json:"screenBrightness,omitempty"`
	ChargingMode      *int  `json:"chargingMode,omitempty"`
	ScreenOrientation *int  `json:"screenOrientation,omitempty"`
	GyroscopeEnabled  *bool `json:"gyroscopeEnabled,omitempty"`
}

// HistorySample is one telemetry sample: the total and each port's power
// (C1..C3, an off port counted as 0), like PowerSample on macOS.
type HistorySample struct {
	T       int64     `json:"t"`
	Total   float64   `json:"total"`
	PerPort []float64 `json:"perPort"`
}

func intPtr(v int) *int { return &v }

func telemetryView(t a2687.ChargerTelemetry, settings *a2687.DeviceSettings) *Telemetry {
	v := &Telemetry{ReceivedAtMs: msOf(t.ReceivedAt), Ports: make([]PortTelemetry, 0, len(t.Ports))}
	for _, p := range t.Ports {
		pv := PortTelemetry{
			Port:       p.Port.Label(),
			StatusCode: int(p.StatusCode),
			Voltage:    p.Voltage,
			Current:    p.Current,
			Power:      p.Power,
		}
		if p.HasCable {
			pv.CableCode = intPtr(int(p.Cable.Code()))
			if label, ok := p.Cable.Label(); ok {
				pv.CableLabel = label
			}
		}
		if p.HasChargingProfile {
			pv.ProfileCode = intPtr(int(p.ChargingProfile.Code()))
			pv.ProfileLabel = p.ChargingProfile.Label()
		}
		if c := p.Control; c != nil {
			_, _, running := c.RunningCountdown()
			pv.Control = &PortControl{
				SwitchStatus:        int(c.SwitchStatus),
				CountdownTaskStatus: int(c.CountdownTaskStatus),
				CountdownTotal:      int(c.CountdownTotal),
				CountdownRemaining:  int(c.CountdownRemaining),
				Running:             running,
			}
		}
		if d := p.ConnectedDevice; d != nil {
			pv.Device = &USBDevice{VendorID: int(d.VendorID), ProductID: int(d.ProductID), NoIdentity: d.IsNoIdentity()}
		}
		v.Ports = append(v.Ports, pv)
	}
	if settings != nil && !settings.IsEmpty() {
		s := &ChargerSettings{}
		if c, ok := settings.ScreenTimeoutCode(); ok {
			s.ScreenTimeout = intPtr(int(c))
		}
		if c, ok := settings.BrightnessPercent(); ok {
			s.ScreenBrightness = intPtr(int(c))
		}
		if c, ok := settings.ModeCode(); ok {
			s.ChargingMode = intPtr(int(c))
		}
		if c, ok := settings.OrientationCode(); ok {
			s.ScreenOrientation = intPtr(int(c))
		}
		if on, ok := settings.GyroEnabled(); ok {
			s.GyroscopeEnabled = &on
		}
		v.Settings = s
	}
	return v
}

// historySample records one report like ChargerSession.recordHistory.
func historySample(t a2687.ChargerTelemetry, at time.Time) HistorySample {
	s := HistorySample{T: at.UnixMilli(), PerPort: make([]float64, len(a2687.Ports))}
	for i, port := range a2687.Ports {
		if p, ok := t.Port(port); ok && p.IsOn() {
			s.PerPort[i] = p.Power
		}
	}
	s.Total = t.TotalPower()
	return s
}

// decimatedHistory is PowerSample.decimated: min/max per bucket of a rounded
// width, budget 180, the last sample always kept.
func decimatedHistory(samples []HistorySample, budget int) []HistorySample {
	if len(samples) <= budget || len(samples) == 0 {
		return append([]HistorySample(nil), samples...)
	}
	first, last := samples[0], samples[len(samples)-1]
	span := float64(last.T-first.T) / 1000
	if span <= 0 {
		return append([]HistorySample(nil), samples...)
	}
	buckets := max(2, budget/2)
	width := roundedInterval(span / float64(buckets))
	out := make([]HistorySample, 0, buckets*2+1)
	var low, high *HistorySample
	bucket := int64(math.MinInt64)
	flush := func() {
		if low == nil || high == nil {
			return
		}
		switch {
		case low.T == high.T:
			out = append(out, *low)
		case low.T < high.T:
			out = append(out, *low, *high)
		default:
			out = append(out, *high, *low)
		}
	}
	for i := range samples {
		s := &samples[i]
		index := int64(math.Floor(float64(s.T) / 1000 / width))
		if index != bucket {
			flush()
			low, high = nil, nil
			bucket = index
		}
		if low == nil || s.Total < low.Total {
			low = s
		}
		if high == nil || s.Total > high.Total {
			high = s
		}
	}
	flush()
	if out[len(out)-1].T != last.T {
		out = append(out, last)
	}
	return out
}

func roundedInterval(minimum float64) float64 {
	if minimum <= 0 {
		return 1
	}
	for _, step := range []float64{1, 2, 5, 10, 15, 20, 30, 60, 120, 300, 600, 900, 1800, 3600} {
		if step >= minimum {
			return step
		}
	}
	step := 3600.0
	for step < minimum {
		step *= 2
	}
	return step
}
