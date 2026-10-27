package app

import (
	"fmt"
	"math"
)

// trayToolTip is the tray icon's hover text: the live total, or the
// connection state when there is none.
func (a *App) trayToolTip(st AppState) string {
	s := st.Session
	if s.Phase == PhasePolling && s.Telemetry != nil && !s.IsStale {
		var total float64
		for _, p := range s.Telemetry.Ports {
			if p.StatusCode != 0 {
				total += p.Power
			}
		}
		d := st.Prefs.Decimals
		return fmt.Sprintf("Charker · %.*f W", d, math.Max(0, total))
	}
	switch s.Phase {
	case PhaseScanning:
		return "Charker · " + a.tr(textStateScan)
	case PhaseReconnecting:
		return "Charker · " + a.tr(textStateLink)
	case PhaseFailed:
		return "Charker · " + a.tr(textStateFail)
	}
	return "Charker · " + a.tr(textStateIdle)
}
