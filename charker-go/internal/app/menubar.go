package app

import (
	"fmt"
	"strconv"
	"strings"
)

// renderMenuBar renders the ordered menuBar items against one AppState, the
// same way the macOS menu-bar readout reads (spec-ui §1.6). Windows has no
// text next to a notification-area icon, so the shell shows this rendered
// string in the tray tooltip; the page's editor preview uses its own renderer.
func (a *App) renderMenuBar(st AppState) string {
	a.mu.Lock()
	items := append([]MenuBarItem(nil), a.settings.MenuBar...)
	a.mu.Unlock()
	parts := make([]string, 0, len(items))
	for _, it := range items {
		switch it.Kind {
		case "total":
			parts = append(parts, formatWatts(st.Totals.Watts, it.Decimals))
		case "port":
			for _, p := range st.Ports {
				if p.ID == it.Port {
					parts = append(parts, p.ID+" "+formatWatts(p.Watts, it.Decimals))
					break
				}
			}
		case "device":
			if st.Device != nil && st.Device.Name != "" {
				parts = append(parts, st.Device.Name)
			} else {
				parts = append(parts, a.tr(textNoDevice))
			}
		case "state":
			parts = append(parts, a.stateText(st))
		}
	}
	return strings.Join(parts, "  ")
}

// stateText is the short word the tray shows for the current phase.
func (a *App) stateText(st AppState) string {
	switch st.Phase {
	case PhasePolling:
		if st.Totals.ChargingCount > 0 {
			return a.tr(textStateCharge)
		}
		return a.tr(textStateConn)
	case PhaseScanning:
		return a.tr(textStateScan)
	case PhaseConnecting, PhaseHandshake, PhaseReconnecting:
		return a.tr(textStateLink)
	case PhaseFailed:
		return a.tr(textStateFail)
	}
	return a.tr(textStateIdle)
}

// formatWatts renders watts with the requested number of decimals.
func formatWatts(w float64, decimals int) string {
	decimals = clampInt(decimals, 0, 3)
	s := strconv.FormatFloat(w, 'f', decimals, 64)
	if strings.HasPrefix(s, "-") && s == "-0" {
		s = "0"
	}
	return s + " W"
}

// trayToolTip builds the tray hover text: the app name plus the rendered
// readout and connection state.
func (a *App) trayToolTip(st AppState) string {
	title := "Charker"
	if parts := a.renderMenuBar(st); parts != "" {
		return fmt.Sprintf("%s · %s", title, parts)
	}
	return fmt.Sprintf("%s · %s", title, a.stateText(st))
}
