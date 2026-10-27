package cloudsession

import (
	"context"
	"math"
	"time"

	"charker/internal/a2345"
	"charker/internal/anker"
	"charker/internal/product"
)

// DemoSerial is the simulated charger's serial.
const DemoSerial = "A2345-DEMO"

// startDemo is AppModel.startA2345Demo: a monitoring snapshot of a simulated
// charger with every control available, account data in place and a reading
// every two seconds. Writes apply locally; nothing touches the network.
func (e *Engine) startDemo() {
	e.stopDemo()
	st := &e.st
	st.devices = nil
	e.resetSnapshot()
	st.phase = PhaseMonitoring
	online := true
	st.device = &Device{
		Serial: DemoSerial, Name: product.ProductA2345.DisplayName(), Firmware: "2.1.1.6",
		WiFiOnline: &online, Product: string(product.ProductA2345), ProductName: product.ProductA2345.DisplayName(),
	}
	st.isDemo = true
	settings := a2345.DemoSettings()
	st.settings = &settings
	st.cloudSettings = &anker.CloudSettings{
		CustomModeEnabled: boolPtr(true), MaxCompatibility: boolPtr(false), DeviceIdentification: boolPtr(true),
	}
	mode := anker.ChargingModeTemplate(1, e.opts.DemoModeName, false)
	mode.ID = 1
	st.modes, st.modesLoaded = []anker.CloudChargingMode{mode}, true
	st.themes, st.themesLoaded = []anker.CloudTheme{}, true
	st.pictures, st.picturesLoaded = []anker.CloudTheme{}, true

	ctx, cancel := context.WithCancel(context.Background())
	st.demoCancel = cancel
	go func() {
		ticker := time.NewTicker(e.opts.DemoInterval)
		defer ticker.Stop()
		for tick := 0; ; tick++ {
			e.post(func() {
				if ctx.Err() == nil {
					e.demoTick(tick)
				}
			})
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
}

func (e *Engine) stopDemo() {
	if e.st.demoCancel != nil {
		e.st.demoCancel()
		e.st.demoCancel = nil
	}
}

func (e *Engine) demoTick(tick int) {
	st := &e.st
	now := e.now()
	r := demoReading(tick, now, st.settings)
	// The simulated charger runs its countdowns too.
	if st.settings != nil {
		next := st.settings.Clone()
		changed := false
		for _, g := range a2345.PortGroups {
			if remaining, ok := countdownRemaining(st.settings, st.reported, g, now); ok && remaining == 0 {
				next.Apply(a2345.PortOutputUpdate(g, false))
				changed = true
			}
		}
		if changed {
			st.settings = &next
		}
	}
	st.phase = PhaseMonitoring
	e.record(r)
}

// demoReading is makeA2345DemoReading: smooth loads on C1–C3, C4 and the
// USB-A ports coming and going, nothing on a switched-off group.
func demoReading(tick int, at time.Time, settings *a2345.DeviceSettings) *reading {
	t := float64(tick) * 2
	raw := []float64{
		68 + 8*math.Sin(t/13),
		36 + 5*math.Sin(t/9+0.8),
		18 + 3*math.Sin(t/7+1.7),
		0, 0, 0,
	}
	if tick%42 < 28 {
		raw[3] = 9 + 2*math.Sin(t/5)
	}
	if tick%30 < 18 {
		raw[4] = 5.4
	}
	if tick%54 < 12 {
		raw[5] = 7.5
	}
	r := &reading{receivedAt: at}
	for i, port := range a2345.Ports {
		on := true
		if settings != nil {
			if c, ok := settings.PortControls[a2345.GroupOf(port)]; ok {
				on = c.IsOn
			}
		}
		power := 0.0
		if on {
			power = max(0, raw[i])
		}
		pv := portValue{port: port, power: power}
		if power > 0 {
			pv.status = 1
			pv.voltage = 5
			if i < 4 {
				pv.voltage = 20
			}
			pv.current = power / pv.voltage
		}
		if i < 3 && power > 0 {
			pv.hasIdentity = true
			pv.vendor = 0x05AC
			pv.productID = uint16(0x7309 + i)
		}
		r.ports = append(r.ports, pv)
	}
	return r
}
