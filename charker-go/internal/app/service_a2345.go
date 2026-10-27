package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"charker/internal/a2345"
	"charker/internal/anker"
	"charker/internal/cloudsession"
)

// The 250W overview's writes (A2345DashboardView, A2345PortControls and
// A2345CustomModeSheet): thin wrappers around the running cloud engine. A
// refusal comes back as the error, its text the Mac's source string.

// errA2345NotRunning: the 250W is not the product on screen.
var errA2345NotRunning = errors.New("需要先连上充电器")

func (s *Charker) a2345DashEngine() (*cloudsession.Engine, error) {
	eng := s.app.Cloud()
	if eng == nil {
		return nil, errA2345NotRunning
	}
	return eng, nil
}

// a2345DashGroup parses a group label as the snapshot carries it: "C1" …
// "C4", "A1/A2"; "A1" or "A2" alone also name the shared USB-A group.
func a2345DashGroup(label string) (a2345.PortGroup, error) {
	switch strings.ToUpper(strings.TrimSpace(label)) {
	case "A1", "A2", "A", "USBA":
		return a2345.GroupUSBA, nil
	}
	for _, g := range a2345.PortGroups {
		if strings.EqualFold(g.Label(), strings.TrimSpace(label)) {
			return g, nil
		}
	}
	return 0, fmt.Errorf("unknown port group %q", label)
}

// SetA2345PortOutput switches one port group (A2345PortControls' switch).
func (s *Charker) SetA2345PortOutput(group string, on bool) (any, error) {
	g, err := a2345DashGroup(group)
	if err != nil {
		return nil, err
	}
	eng, err := s.a2345DashEngine()
	if err != nil {
		return nil, err
	}
	return nil, eng.SetPortOutput(g, on)
}

// SetA2345PortCountdown arms a group's countdown for seconds; 0 cancels it.
func (s *Charker) SetA2345PortCountdown(group string, seconds int) (any, error) {
	g, err := a2345DashGroup(group)
	if err != nil {
		return nil, err
	}
	eng, err := s.a2345DashEngine()
	if err != nil {
		return nil, err
	}
	return nil, eng.SetPortCountdown(g, seconds)
}

// a2345DashSchedule is one daily slot as the schedule editor sends it.
type a2345DashSchedule struct {
	Enabled  bool `json:"enabled"`
	Hour     int  `json:"hour"`
	Minute   int  `json:"minute"`
	Weekdays int  `json:"weekdays"`
}

// SetA2345PortSchedule writes one daily slot ("powerOn" or "powerOff") of a
// group: {enabled, hour, minute, weekdays (bit0 = Monday)}.
func (s *Charker) SetA2345PortSchedule(group, slot string, schedule json.RawMessage) (any, error) {
	g, err := a2345DashGroup(group)
	if err != nil {
		return nil, err
	}
	var which a2345.ScheduleSlot
	switch slot {
	case "powerOn":
		which = a2345.SlotPowerOn
	case "powerOff":
		which = a2345.SlotPowerOff
	default:
		return nil, fmt.Errorf("unknown schedule slot %q", slot)
	}
	var v a2345DashSchedule
	if err := json.Unmarshal(schedule, &v); err != nil {
		return nil, fmt.Errorf("schedule: %w", err)
	}
	if v.Hour < 0 || v.Hour > 23 || v.Minute < 0 || v.Minute > 59 {
		return nil, fmt.Errorf("schedule: %02d:%02d is not a time", v.Hour, v.Minute)
	}
	eng, err := s.a2345DashEngine()
	if err != nil {
		return nil, err
	}
	ps := a2345.NewPortSchedule(v.Enabled, byte(v.Hour), byte(v.Minute), byte(v.Weekdays&0x7F))
	return nil, eng.SetPortSchedule(g, which, ps)
}

// RetryA2345 (retryA2345Connection) is in service_account.go.

// ---- Custom modes (A2345CustomModeSheet) ----------------------------------

func a2345DashMode(raw json.RawMessage) (anker.CloudChargingMode, error) {
	var mode anker.CloudChargingMode
	if err := json.Unmarshal(raw, &mode); err != nil {
		return mode, fmt.Errorf("charging mode: %w", err)
	}
	return mode, nil
}

// a2345DashMainland is a2345IsMainland from the running engine's snapshot.
func a2345DashMainland(eng *cloudsession.Engine) bool {
	return eng.Snapshot().A2345.Mainland
}

// a2345DashModeGroup is A2345CustomModeEditor.group(_:): the group a power
// setting names, else its index.
func a2345DashModeGroup(setting anker.ChargingModePortSetting, index int) a2345.PortGroup {
	name := strings.ToUpper(setting.Name)
	for i, n := range anker.ChargingModePortNames {
		if n == name {
			return a2345.PortGroups[i]
		}
	}
	if index >= 0 && index < len(a2345.PortGroups) {
		return a2345.PortGroups[index]
	}
	return a2345.GroupC1
}

// A2345ChargingModeTemplate is a new profile with the official editor's
// defaults (A2345CloudChargingMode.template).
func (s *Charker) A2345ChargingModeTemplate(number int, name string) (anker.CloudChargingMode, error) {
	eng, err := s.a2345DashEngine()
	if err != nil {
		return anker.CloudChargingMode{}, err
	}
	return anker.ChargingModeTemplate(number, name, a2345DashMainland(eng)), nil
}

// ApplyA2345ChargingMode makes a stored profile the active custom mode.
func (s *Charker) ApplyA2345ChargingMode(raw json.RawMessage) (any, error) {
	mode, err := a2345DashMode(raw)
	if err != nil {
		return nil, err
	}
	eng, err := s.a2345DashEngine()
	if err != nil {
		return nil, err
	}
	return nil, eng.ApplyChargingMode(mode)
}

// SaveA2345ChargingMode stores a profile in the account, normalised as the
// editor's save() does: trimmed name, protocols on, the 250 W total limit,
// each port's own maximum, and no SCP on overseas ports limited to 15–20 W.
func (s *Charker) SaveA2345ChargingMode(raw json.RawMessage, isNew bool) (any, error) {
	mode, err := a2345DashMode(raw)
	if err != nil {
		return nil, err
	}
	eng, err := s.a2345DashEngine()
	if err != nil {
		return nil, err
	}
	mainland := a2345DashMainland(eng)
	mode.Name = strings.TrimSpace(mode.Name)
	mode.HasChargeProtocol = true
	mode.MaxTotalPower = a2345.CustomTotalLimit
	for i := range mode.PowerSettings {
		g := a2345DashModeGroup(mode.PowerSettings[i], i)
		mode.PowerSettings[i].MaxPower = int(a2345.MaximumWatts(g, mainland))
		if p := mode.PowerSettings[i].Power; !mainland && p >= 15 && p <= 20 {
			mode.PowerSettings[i].SCP = false
		}
	}
	return nil, eng.SaveChargingMode(mode, isNew)
}

// DeleteA2345ChargingMode removes a stored profile.
func (s *Charker) DeleteA2345ChargingMode(raw json.RawMessage) (any, error) {
	mode, err := a2345DashMode(raw)
	if err != nil {
		return nil, err
	}
	eng, err := s.a2345DashEngine()
	if err != nil {
		return nil, err
	}
	return nil, eng.DeleteChargingMode(mode)
}
