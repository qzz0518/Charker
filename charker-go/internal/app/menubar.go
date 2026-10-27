package app

import (
	"fmt"
	"slices"
	"strings"
	"unicode/utf16"

	"charker/internal/prefs"
	"charker/internal/product"
	"charker/internal/session"
)

// The menu bar readout (CharkerCore MenuBarConfig.render and AppModel's
// statusTitle). Windows has no text in the notification area, so the same
// title is the tray icon's tooltip; the settings page previews it with its
// twin in web/js/pages/menubar.js.

// readoutInput is what one render reads.
type readoutInput struct {
	// ports are the active product's ports (MenuBarConfig's product-aware
	// list): a port item of another product elides.
	ports         []product.PortID
	telemetry     *session.Telemetry
	stateLabel    string
	deviceName    string
	decimals      int
	hideIdlePorts bool
	nicknames     []string
	// portsText formats the active port count of an activePortsCount item
	// ("%d 口"); sampleText is the built-in text item's copy ("文本").
	portsText  func(int) string
	sampleText string
}

const readoutPlaceholder = "—"

// port finds the reading of the port with raw value index; ok is false
// when the product has no such port.
func (in readoutInput) port(index int) (p *session.PortTelemetry, ok bool) {
	if index < 0 || index >= len(prefs.PortLabels) {
		return nil, false
	}
	label := prefs.PortLabels[index]
	if !slices.Contains(in.ports, product.PortID(label)) {
		return nil, false
	}
	if in.telemetry == nil {
		return nil, true
	}
	for i := range in.telemetry.Ports {
		if in.telemetry.Ports[i].Port == label {
			return &in.telemetry.Ports[i], true
		}
	}
	return nil, true
}

func portIsOn(p *session.PortTelemetry) bool { return p != nil && p.StatusCode != 0 }

func portIsDelivering(p *session.PortTelemetry) bool {
	return portIsOn(p) && p.Current > 0.02 && p.Voltage > 3.0
}

// displayItem is MenuBarConfig.display: one item against live data, or
// ok=false when it elides (an idle port under hideIdlePorts, empty text).
func displayItem(item prefs.MenuBarItem, in readoutInput) (string, bool) {
	format := func(watts float64) string {
		decimals := in.decimals
		if item.Decimals != nil {
			decimals = *item.Decimals
		}
		decimals = min(max(decimals, 0), 3)
		number := fmt.Sprintf("%.*f", decimals, watts)
		if item.ShowsUnit {
			return number + " W"
		}
		return number
	}
	prefixed := func(value string, label *string) string {
		if label == nil || *label == "" {
			return value
		}
		return *label + " " + value
	}

	switch item.Kind {
	case prefs.KindTotalPower:
		value := readoutPlaceholder
		if in.telemetry != nil {
			var total float64
			for i := range in.telemetry.Ports {
				if p := &in.telemetry.Ports[i]; portIsOn(p) {
					total += p.Power
				}
			}
			value = format(total)
		}
		return prefixed(value, item.Label), true
	case prefs.KindPortPower:
		if item.Port == nil {
			return "", false
		}
		index := *item.Port
		p, ok := in.port(index)
		if !ok {
			return "", false
		}
		name := prefs.PortLabels[index]
		if index < len(in.nicknames) && in.nicknames[index] != "" {
			name = in.nicknames[index]
		}
		if item.Label != nil {
			name = *item.Label
		}
		var label *string
		if item.ShowsPortName {
			label = &name
		}
		if p == nil {
			return prefixed(readoutPlaceholder, label), true
		}
		if in.hideIdlePorts && !portIsDelivering(p) {
			return "", false
		}
		watts := 0.0
		if portIsOn(p) {
			watts = p.Power
		}
		return prefixed(format(watts), label), true
	case prefs.KindPortsCount:
		count := 0
		if in.telemetry != nil {
			for i := range in.telemetry.Ports {
				if portIsDelivering(&in.telemetry.Ports[i]) {
					count++
				}
			}
		}
		if item.Label != nil {
			return prefixed(fmt.Sprint(count), item.Label), true
		}
		if item.SystemContent != nil && *item.SystemContent == "activePortsCount" && in.portsText != nil {
			return in.portsText(count), true
		}
		return fmt.Sprint(count), true
	case prefs.KindState:
		return in.stateLabel, true
	case prefs.KindDeviceName:
		if in.deviceName != "" {
			return in.deviceName, true
		}
		return "Charker", true
	case prefs.KindSeparator:
		if item.Label != nil {
			return *item.Label, true
		}
		return "·", true
	case prefs.KindText:
		if item.Label != nil {
			return *item.Label, *item.Label != ""
		}
		if item.SystemContent != nil && *item.SystemContent == "sampleText" && in.sampleText != "" {
			return in.sampleText, true
		}
		return "", false
	}
	return "", false
}

// renderReadout is MenuBarConfig.render: separator-delimited runs collapse,
// so hiding an idle port takes its label and, when the whole run goes, the
// run's separator with it.
func renderReadout(items []prefs.MenuBarItem, in readoutInput) string {
	type run struct {
		parts          []string
		portItems      int
		elided         int
		separatorAfter string
	}
	var runs []run
	current := run{}
	for _, item := range items {
		if item.Kind == prefs.KindSeparator {
			current.separatorAfter = "·"
			if item.Label != nil {
				current.separatorAfter = *item.Label
			}
			runs = append(runs, current)
			current = run{}
			continue
		}
		if item.Kind == prefs.KindPortPower {
			current.portItems++
		}
		if text, ok := displayItem(item, in); ok {
			current.parts = append(current.parts, text)
		} else if item.Kind == prefs.KindPortPower {
			current.elided++
		}
	}
	runs = append(runs, current)

	var kept []run
	for _, r := range runs {
		if len(r.parts) == 0 || (r.portItems > 0 && r.portItems == r.elided) {
			continue
		}
		kept = append(kept, r)
	}
	var out strings.Builder
	for i, r := range kept {
		out.WriteString(strings.Join(r.parts, " "))
		if i < len(kept)-1 {
			sep := r.separatorAfter
			if sep == "" {
				sep = "·"
			}
			out.WriteString(" " + sep + " ")
		}
	}
	return out.String()
}

// statusTitle is AppModel.statusTitle for the A2687: words while nothing
// is live, else the rendered layout. On Windows it is the tooltip, which
// stays when the icon's digits are off (showIconOnly).
func (a *App) statusTitle(st AppState) string {
	p := st.Prefs
	s := st.Session
	if s.Phase != PhasePolling || s.Telemetry == nil {
		return a.offlineTitle(s.Phase)
	}
	return renderReadout(p.MenuBarLayout(), readoutInput{
		ports:         activeProduct(st).PortIDs(),
		telemetry:     s.Telemetry,
		stateLabel:    a.phaseShortLabel(s.Phase),
		deviceName:    activeDisplayName(st),
		decimals:      p.Decimals,
		hideIdlePorts: p.HideIdlePorts,
		nicknames:     p.PortNicknames,
		portsText:     func(n int) string { return fmt.Sprintf(a.tr(textPortsActive), n) },
		sampleText:    a.tr(textSampleText),
	})
}

// activeProduct is AppModel.activeProduct. AppState does not carry the
// product yet: the A2345 (cloud) port sets it here, and the readout, the
// taskbar page and the flyout follow its ports.
func activeProduct(st AppState) product.ChargerProduct {
	_ = st
	return product.ProductA2687
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

// trayToolTipLimit is what Windows shows of a notification-area tooltip
// (NOTIFYICONDATA.szTip holds 128 UTF-16 units with the terminator).
const trayToolTipLimit = 127

// trayToolTip is the tray icon's hover text: the menu bar title the Mac
// would show, after the app name.
func (a *App) trayToolTip(st AppState) string {
	title := a.statusTitle(st)
	if title == "" {
		return "Charker"
	}
	return truncateUTF16("Charker · "+title, trayToolTipLimit)
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
