package app

import (
	"math"

	"charker/internal/product"
)

// buildStateLocked maps the current session snapshot plus settings and energy
// aggregates into the AppState the pages render. a.mu must be held.
func (a *App) buildStateLocked(nowMs int64) AppState {
	snap := a.snap
	settings := a.settings
	energy := a.energySummaryLocked()

	st := AppState{
		App: AppInfo{
			Version:  a.version,
			Locale:   settings.Locale,
			Theme:    settings.Theme,
			Mock:     settings.Mock,
			Platform: "windows",
		},
		Phase:         snap.Phase,
		Scanning:      snap.Scanning,
		Devices:       []DeviceInfo{},
		Ports:         []PortInfo{},
		History:       []product.Sample{},
		Stats:         snap.Stats,
		Settings:      mapDeviceSettings(snap.Settings),
		MenuBar:       MenuBar{Items: append([]MenuBarItem(nil), settings.MenuBar...)},
		Energy:        energy,
		LastUpdatedMs: nowMs,
	}
	if st.Phase == "" {
		st.Phase = PhaseIdle
	}
	// The port-switching opt-in is an app preference, not device state.
	st.Settings.WritesEnabled = settings.WritesEnabled

	limit := snapshotLimit(snap)
	st.Totals = Totals{Limit: limit}

	if snap.Device != nil {
		d := mapDevice(*snap.Device)
		d.Connected = snap.Phase == PhasePolling
		st.Device = &d
	}
	st.Devices = mapDevices(snap.Devices, st.Device)

	st.Ports, st.Totals.ChargingCount, st.Totals.ConnectedCount, st.Totals.Watts =
		mapPorts(snap.Reading, snap.Settings, nowMs, limit)
	if snap.Reading != nil && snap.Reading.TotalWatts > 0 {
		st.Totals.Watts = snap.Reading.TotalWatts
	}

	st.History = product.Decimate(snap.History, historyBudget)
	if st.History == nil {
		st.History = []product.Sample{}
	}

	if snap.Err != "" {
		kind := "warn"
		if st.Phase == PhaseFailed {
			kind = "error"
		}
		st.Notice = &Notice{Kind: kind, Text: snap.Err}
	} else if snap.Warning != "" {
		st.Notice = &Notice{Kind: "warn", Text: snap.Warning}
	} else if a.startupNotice != nil {
		st.Notice = a.startupNotice
	}

	return st
}

// historyBudget is the maximum number of power samples AppState.history
// carries (contract: decimated; UI needs at most 180).
const historyBudget = 180

// snapshotLimit returns the charger's rated power for the totals rail.
func snapshotLimit(snap Snapshot) float64 {
	if snap.LimitWatts > 0 {
		return snap.LimitWatts
	}
	if snap.Reading != nil {
		switch snap.Reading.Product {
		case product.ProductA2345:
			return 250
		}
	}
	return 160
}

// mapDevice converts one session device into the AppState shape.
func mapDevice(d Device) DeviceInfo {
	return DeviceInfo{
		ID:        d.ID,
		Name:      d.Name,
		Product:   string(d.Product),
		Address:   d.Address,
		RSSI:      d.RSSI,
		Connected: d.Connected,
		Saved:     d.Saved,
		Mock:      d.Mock,
	}
}

// mapDevices merges the session's scan/saved list with the current device so
// the UI always sees the connected charger among the devices.
func mapDevices(devices []Device, current *DeviceInfo) []DeviceInfo {
	out := make([]DeviceInfo, 0, len(devices)+1)
	seen := make(map[string]bool, len(devices)+1)
	if current != nil {
		out = append(out, *current)
		seen[current.ID] = true
	}
	for _, d := range devices {
		if seen[d.ID] {
			continue
		}
		seen[d.ID] = true
		out = append(out, mapDevice(d))
	}
	for i := range out {
		if current != nil && out[i].ID == current.ID {
			out[i].Connected = current.Connected
		}
	}
	return out
}

// mapPorts lays the reading out in product port order, filling the
// configuration from the device's last reported settings.
func mapPorts(r *product.Reading, settings product.Settings, nowMs int64, limit float64) (ports []PortInfo, charging, connected int, total float64) {
	prod := product.ProductA2687
	if r != nil && r.Product != "" {
		prod = r.Product
	}
	ids := prod.PortIDs()
	ports = make([]PortInfo, 0, len(ids))
	for _, id := range ids {
		var pr product.PortReading
		if r != nil {
			if v, ok := r.Port(id); ok {
				pr = v
			}
		}
		ctrl := product.PortControl{}
		if settings.PortControls != nil {
			if v, ok := settings.PortControls[id]; ok {
				ctrl = v
			}
		}
		p := PortInfo{
			ID:           string(id),
			Label:        string(id),
			Enabled:      pr.Enabled || ctrl.Enabled,
			Status:       pr.Status,
			Watts:        pr.Watts,
			Volts:        pr.Volts,
			Amps:         pr.Amps,
			Protocol:     pr.Protocol,
			EPR:          pr.EPR,
			DeviceKind:   pr.DeviceKind,
			Cable:        pr.Cable,
			TimerMinutes: ctrl.TimerMinutes,
		}
		if limit > 0 {
			p.BarPct = math.Max(0, math.Min(1, pr.Watts/limit))
		}
		if ctrl.CountdownMinutes > 0 {
			p.CountdownEndMs = nowMs + int64(ctrl.CountdownMinutes)*60_000
		}
		if pr.Status != 0 {
			connected++
		}
		if pr.Status != 0 && pr.Watts > 0.02 {
			charging++
		}
		total += pr.Watts
		ports = append(ports, p)
	}
	return ports, charging, connected, math.Round(total*100) / 100
}

// mapDeviceSettings flattens the device-reported settings to the AppState
// shape, keeping sensible defaults for values the charger did not report.
func mapDeviceSettings(s product.Settings) DeviceSettings {
	d := DeviceSettings{
		ScreenOn:    true,
		Brightness:  80,
		Language:    "zh",
		Orientation: "auto",
	}
	if s.ScreenOn != nil {
		d.ScreenOn = *s.ScreenOn
	}
	if s.Brightness != nil {
		d.Brightness = clampInt(*s.Brightness, 0, 100)
	}
	if s.Language != nil && *s.Language != "" {
		d.Language = *s.Language
	}
	if s.Orientation != nil && *s.Orientation != "" {
		d.Orientation = *s.Orientation
	}
	if s.AutoLock != nil {
		d.AutoLock = *s.AutoLock
	}
	if s.Theme != nil {
		d.Theme = *s.Theme
	}
	if s.FixedAllocation != nil {
		d.FixedAllocation = *s.FixedAllocation
	}
	if s.ScreenTimeout != nil {
		d.ScreenTimeout = *s.ScreenTimeout
	}
	if s.ChargingMode != nil {
		d.ChargingMode = *s.ChargingMode
	}
	if s.AutoRotate != nil {
		d.AutoRotate = *s.AutoRotate
	}
	return d
}
