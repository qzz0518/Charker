package app

import (
	"fmt"
	"strings"
	"unicode/utf16"

	"charker/internal/product"
	"charker/internal/session"
)

// The tray icon's hover text: the Windows counterpart of the Mac's menu bar
// title. The icon itself shows the total; the tooltip spells out the charger
// and every port, three to a line, so there is nothing to lay out.

// trayToolTipLimit is what Windows shows of a notification-area tooltip
// (NOTIFYICONDATA.szTip holds 128 UTF-16 units with the terminator).
const trayToolTipLimit = 127

// trayToolTip is the hover text for the state.
func (a *App) trayToolTip(st AppState) string {
	s := st.Session
	if s.Phase != PhasePolling || s.Telemetry == nil {
		return "Charker · " + a.offlineTitle(s.Phase)
	}
	p := st.Prefs
	name := activeDisplayName(st)
	if name == "" {
		name = activeProduct(st).DisplayName()
	}
	total := 0.0
	var ports []string
	for _, id := range activeProduct(st).PortIDs() {
		var t *session.PortTelemetry
		for i := range s.Telemetry.Ports {
			if s.Telemetry.Ports[i].Port == string(id) {
				t = &s.Telemetry.Ports[i]
			}
		}
		if portIsOn(t) {
			total += t.Power
		}
		if p.HideIdlePorts && !portIsDelivering(t) {
			continue
		}
		switch {
		case t == nil:
			ports = append(ports, string(id)+" —")
		case !portIsOn(t):
			ports = append(ports, string(id)+" "+a.tr(textPortOff))
		default:
			ports = append(ports, fmt.Sprintf("%s %s W", id, watts(t.Power, p.Decimals)))
		}
	}
	lines := []string{fmt.Sprintf("%s · %s W", name, watts(total, p.Decimals))}
	if s.IsStale {
		lines[0] += " · " + a.tr(textStale)
	}
	for i := 0; i < len(ports); i += 3 {
		lines = append(lines, strings.Join(ports[i:min(i+3, len(ports))], " · "))
	}
	return truncateUTF16(strings.Join(lines, "\n"), trayToolTipLimit)
}

// watts formats a reading with the user's decimals.
func watts(v float64, decimals int) string {
	return fmt.Sprintf("%.*f", decimals, v)
}

func portIsOn(p *session.PortTelemetry) bool { return p != nil && p.StatusCode != 0 }

func portIsDelivering(p *session.PortTelemetry) bool {
	return portIsOn(p) && p.Current > 0.02 && p.Voltage > 3.0
}

// activeProduct is AppModel.activeProduct as carried by the state.
func activeProduct(st AppState) product.ChargerProduct {
	return product.ParseProduct(st.App.Product)
}

// offlineTitle is StatusTemplate.offlineTitle: words, not punctuation.
func (a *App) offlineTitle(phase Phase) string {
	switch phase {
	case PhasePolling:
		return ""
	case PhaseReconnecting:
		return a.tr(textStateLink)
	case PhaseFailed:
		return a.tr(textStateFail)
	}
	return a.tr(textStateScan)
}

// phaseShortLabel is SessionPhase.shortLabel.
func (a *App) phaseShortLabel(phase Phase) string {
	switch phase {
	case PhaseScanning:
		return a.tr(textStateScan)
	case PhaseConnecting:
		return a.tr(textStateConnecting)
	case PhaseHandshake:
		return a.tr(textStateHandshake)
	case PhasePolling:
		return a.tr(textStateConn)
	case PhaseReconnecting:
		return a.tr(textStateLink)
	case PhaseFailed:
		return a.tr(textStateError)
	}
	return a.tr(textStateIdle)
}

// activeDisplayName is AppModel.activeDisplayName: the charger's name, or
// the nickname the user gave a saved charger.
func activeDisplayName(st AppState) string {
	d := st.Session.Device
	if d == nil {
		return ""
	}
	name := d.Name
	if d.ProductName != "" {
		name = d.ProductName
		if name == "Charging" {
			name = "Anker Prime 160W"
		}
	}
	if name == "" || st.Prefs.DemoMode {
		return name
	}
	for _, c := range st.SavedChargers {
		if c.ID == d.ID && c.Nickname != "" {
			return c.Nickname
		}
	}
	return name
}

// truncateUTF16 shortens s to at most limit UTF-16 units, ending in "…".
func truncateUTF16(s string, limit int) string {
	if len(utf16.Encode([]rune(s))) <= limit {
		return s
	}
	var out []rune
	units := 0
	for _, r := range s {
		n := utf16.RuneLen(r)
		if units+n > limit-1 {
			break
		}
		out = append(out, r)
		units += n
	}
	return strings.TrimRight(string(out), " ") + "…"
}
