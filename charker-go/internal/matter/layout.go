// Package matter publishes the charger's ports to Apple Home through the
// charker-matter helper (the Rust crate in ../Matter), a child process that
// speaks JSON lines over stdin/stdout.
//
// It mirrors MatterService.swift and MatterAccessory.swift in the macOS app:
// Layout says what each accessory exposes, PortSync what the helper has been
// told, Service runs one helper and Home runs the two every charger gets.
package matter

import (
	"fmt"
	"math"

	"charker/internal/product"
)

// Kind is one of the two accessories each charger family is published as,
// each paired on its own.
type Kind int

const (
	// Grouped is one accessory with the ports as its endpoints; Home shows
	// the charger's total power.
	Grouped Kind = iota
	// Bridged is a bridge with every port as an accessory of its own, so
	// each gets its own tile with watts.
	Bridged
)

// Target is the outlet behind one helper port index: the charger ports its
// switch drives. A1 and A2 share one switch on the A2345, so USB-A is one
// outlet over both.
type Target struct {
	Ports []product.PortID
	Label string
}

// Layout is what one accessory exposes for one charger family.
type Layout struct {
	Product product.ChargerProduct
	Kind    Kind
	Targets []Target
}

// NewLayout lays out p: the 160W as C1-C3, the 250W as C1-C4 and USB-A.
func NewLayout(p product.ChargerProduct, kind Kind) Layout {
	l := Layout{Product: p, Kind: kind}
	if p == product.ProductA2345 {
		for _, id := range []product.PortID{product.PortC1, product.PortC2, product.PortC3, product.PortC4} {
			l.Targets = append(l.Targets, Target{Ports: []product.PortID{id}, Label: string(id)})
		}
		l.Targets = append(l.Targets, Target{Ports: []product.PortID{product.PortA1, product.PortA2}, Label: "USB-A"})
		return l
	}
	for _, id := range []product.PortID{product.PortC1, product.PortC2, product.PortC3} {
		l.Targets = append(l.Targets, Target{Ports: []product.PortID{id}, Label: string(id)})
	}
	return l
}

// Name is BasicInformation ProductName and the mDNS instance name (at most
// 32 bytes). The bridged names are the macOS localization keys; Home runs
// them through its Localize option.
func (l Layout) Name() string {
	watts := l.watts()
	if l.Kind == Bridged {
		return fmt.Sprintf("Charker %dW 端口", watts)
	}
	return fmt.Sprintf("Charker %dW", watts)
}

// StorageName is the folder of the accessory's pairing. Each family and kind
// keeps its own, so switching products never hands one charger's Home
// accessory to the other.
func (l Layout) StorageName() string {
	family := "a2687"
	if l.Product == product.ProductA2345 {
		family = "a2345"
	}
	if l.Kind == Bridged {
		return family + "-ports"
	}
	return family
}

// UDPPort is fixed per kind, so the two accessories never swap ports across
// restarts and leave a controller dialing the wrong one. The helper falls
// back to a free port only if this one is taken.
func (l Layout) UDPPort() uint16 {
	if l.Kind == Bridged {
		return 5541
	}
	return 5540
}

// Labels are the helper's port labels. A bridged port's label is its tile
// name in Home, so it says which charger it is on (at most 32 bytes).
func (l Layout) Labels() []string {
	labels := make([]string, len(l.Targets))
	for i, t := range l.Targets {
		if l.Kind == Bridged {
			labels[i] = fmt.Sprintf("%dW %s", l.watts(), t.Label)
		} else {
			labels[i] = t.Label
		}
	}
	return labels
}

// Target returns the outlet at a helper port index.
func (l Layout) Target(index int) (Target, bool) {
	if index < 0 || index >= len(l.Targets) {
		return Target{}, false
	}
	return l.Targets[index], true
}

func (l Layout) watts() int {
	if l.Product == product.ProductA2345 {
		return 250
	}
	return 160
}

// States lays out every outlet's state in index order.
//
//   - r is the latest reading (nil before the first); live is false while
//     the link is down or the reading is stale, which zeroes V/I/P.
//   - switches holds the charger's own port controls where known (A2345
//     settings, keyed by each target's first port); nil before the first
//     settings snapshot.
//   - previous is the last list sent; it supplies `on` for an outlet nothing
//     currently describes, so a dropped connection does not flip Home.
func (l Layout) States(r *product.Reading, live bool, switches map[product.PortID]bool, previous []PortState) []PortState {
	states := make([]PortState, len(l.Targets))
	for i, t := range l.Targets {
		earlier := i < len(previous) && previous[i].On
		var readings []product.PortReading
		if r != nil {
			for _, id := range t.Ports {
				if pr, ok := r.Port(id); ok {
					readings = append(readings, pr)
				}
			}
		}
		if l.Product == product.ProductA2345 {
			var sw *bool
			if switches != nil {
				if on, ok := switches[t.Ports[0]]; ok {
					sw = &on
				}
			}
			states[i] = StateA2345(sw, switches != nil, live, readings, earlier)
		} else {
			var pr *product.PortReading
			if len(readings) > 0 {
				pr = &readings[0]
			}
			states[i] = StateA2687(pr, live, earlier)
		}
	}
	return states
}

// PortState is one outlet as the helper exposes it: an On/Off switch plus
// electrical measurement, in the helper's integer milli-units.
type PortState struct {
	On        bool
	VoltageMV int
	CurrentMA int
	PowerMW   int
}

// StateA2687 is a 160W port. `on` is the telemetry's on flag (the status
// byte being non-zero, which on this firmware may mean "something is plugged
// in"; it is what the dashboard shows, so Home shows the same). Readings only
// count while live.
func StateA2687(r *product.PortReading, live, previousOn bool) PortState {
	if r == nil {
		return PortState{On: previousOn}
	}
	if !live || !r.Enabled {
		return PortState{On: r.Enabled}
	}
	return PortState{On: true, VoltageMV: milli(r.Volts), CurrentMA: milli(r.Amps), PowerMW: milli(r.Watts)}
}

// StateA2345 is a 250W outlet. The switch comes from the charger's own port
// control (sw; haveSettings is false before the first settings snapshot).
// Before that, live output proves an outlet on; no output does not prove it
// off. USB-A reads as the sum of its two sockets at the higher voltage.
func StateA2345(sw *bool, haveSettings, live bool, readings []product.PortReading, previousOn bool) PortState {
	var active []product.PortReading
	if live {
		for _, r := range readings {
			if r.Enabled {
				active = append(active, r)
			}
		}
	}
	on := previousOn
	switch {
	case sw != nil:
		on = *sw
	case haveSettings:
	case live:
		on = previousOn || len(active) > 0
	}
	s := PortState{On: on}
	for _, r := range active {
		s.VoltageMV = max(s.VoltageMV, milli(r.Volts))
		s.CurrentMA += milli(r.Amps)
		s.PowerMW += milli(r.Watts)
	}
	return s
}

// milli turns V, A or W into the helper's milli-units. Non-finite and
// negative readings become 0; the ceiling keeps a corrupt frame in range.
func milli(v float64) int {
	if math.IsNaN(v) || math.IsInf(v, 0) || v <= 0 {
		return 0
	}
	return int(math.Round(math.Min(v*1000, math.MaxInt32)))
}
