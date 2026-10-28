package app

import (
	"charker/internal/cloudsession"
	"charker/internal/prefs"
	"charker/internal/product"
	"charker/internal/session"
)

// buildStateLocked maps the latest session snapshot and the preferences to
// the page's AppState. a.mu must be held.
func (a *App) buildStateLocked(nowMs int64) AppState {
	snap := a.snap
	st := AppState{
		App: AppInfo{
			Version:           a.version,
			Locale:            a.localeLocked(),
			Platform:          "windows",
			Demo:              a.demo,
			Product:           string(a.activeProductLocked()),
			NeedsA2687Account: a.needsA2687AccountLocked(),
		},
		Prefs:         a.prefs,
		SavedChargers: append([]prefs.SavedCharger{}, a.saved...),
		Session: SessionState{
			Phase:        snap.Phase,
			Stage:        snap.Stage,
			Attempt:      snap.Attempt,
			Scanning:     snap.Scanning,
			IsStale:      snap.IsStale,
			AuthRejected: snap.AuthRejected,
			// The simulator may always be switched (SessionHost.spawn).
			WritesEnabled: a.prefs.WritesEnabled || a.demo,
			LastError:     snap.Err,
			Warning:       snap.Warning,
			Nearby:        []DeviceInfo{},
			Telemetry:     snap.Telemetry,
			History:       snap.History,
			ConnectedAtMs: snap.ConnectedAtMs,
		},
		Stats:         snap.Stats,
		Energy:        a.energySummaryLocked(),
		LastUpdatedMs: nowMs,
	}
	if st.Session.Phase == "" {
		st.Session.Phase = PhaseIdle
	}
	if st.Session.History == nil {
		st.Session.History = []session.HistorySample{}
	}
	if snap.Device != nil {
		d := a.deviceInfoLocked(*snap.Device)
		d.Connected = snap.Phase == PhasePolling
		st.Session.Device = &d
	}
	for _, d := range snap.Devices {
		if st.Session.Device != nil && d.ID == st.Session.Device.ID {
			continue
		}
		st.Session.Nearby = append(st.Session.Nearby, a.deviceInfoLocked(d))
	}
	if a.startupNotice != nil {
		st.Notice = a.startupNotice
	}
	st.Devices = a.devicesStateLocked(snap)
	st.Home = a.homeStateLocked()
	if cs := a.cloudSnap; cs != nil && a.activeProductLocked() == product.ProductA2345 {
		a.applyCloudLocked(&st, cs)
	}
	return st
}

// applyCloudLocked fills the product-neutral session fields from the A2345
// engine, so the readout, the tray and the stats work for either charger.
func (a *App) applyCloudLocked(st *AppState, cs *cloudsession.Snapshot) {
	st.A2345 = cs
	st.Session = SessionState{
		Phase:         cs.Phase,
		Stage:         string(cs.Stage),
		Attempt:       cs.Attempt,
		IsStale:       cs.IsStale,
		WritesEnabled: a.prefs.WritesEnabled || a.demo,
		Nearby:        []DeviceInfo{},
		History:       cs.History,
	}
	if st.Session.Phase == "" {
		st.Session.Phase = PhaseIdle
	}
	if st.Session.History == nil {
		st.Session.History = []session.HistorySample{}
	}
	if d := cs.Device; d != nil {
		st.Session.Device = &DeviceInfo{
			ID:          d.Serial,
			Name:        d.Name,
			Serial:      d.Serial,
			Firmware:    d.Firmware,
			ProductName: d.ProductName,
			Connected:   cs.Live,
			Mock:        cs.IsDemo,
		}
	}
	if t := cs.Telemetry; t != nil {
		tel := &session.Telemetry{ReceivedAtMs: t.ReceivedAtMs, Ports: make([]session.PortTelemetry, 0, len(t.Ports))}
		for _, p := range t.Ports {
			tel.Ports = append(tel.Ports, session.PortTelemetry{
				Port:       p.Port,
				StatusCode: p.StatusCode,
				Voltage:    p.Voltage,
				Current:    p.Current,
				Power:      p.Power,
				Control:    p.Control,
				Device:     p.Device,
			})
		}
		st.Session.Telemetry = tel
	}
}

func (a *App) deviceInfoLocked(d Device) DeviceInfo {
	info := DeviceInfo{
		ID:          d.ID,
		Name:        d.Name,
		Address:     d.Address,
		RSSI:        d.RSSI,
		Connected:   d.Connected,
		Mock:        d.Mock,
		ProductName: d.ProductName,
		Firmware:    d.Firmware,
		Serial:      d.Serial,
		MAC:         d.MAC,
	}
	_, info.Saved = prefs.FindSaved(a.saved, d.ID)
	return info
}
