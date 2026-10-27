package app

import (
	"charker/internal/prefs"
	"charker/internal/session"
)

// buildStateLocked maps the latest session snapshot and the preferences to
// the page's AppState. a.mu must be held.
func (a *App) buildStateLocked(nowMs int64) AppState {
	snap := a.snap
	st := AppState{
		App: AppInfo{
			Version:  a.version,
			Locale:   a.localeLocked(),
			Platform: "windows",
			Demo:     a.demo,
		},
		Prefs:         a.prefs,
		SavedChargers: append([]prefs.SavedCharger{}, a.saved...),
		Session: SessionState{
			Phase:         snap.Phase,
			Stage:         snap.Stage,
			Attempt:       snap.Attempt,
			Scanning:      snap.Scanning,
			IsStale:       snap.IsStale,
			WritesEnabled: a.prefs.WritesEnabled,
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
	return st
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
