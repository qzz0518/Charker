package app

import (
	"errors"
	"fmt"

	"charker/internal/matter"
)

// The Apple 家庭 page (pages/home.js). Its state is AppState.home.

// SetHomeEnabled turns Apple Home on or off (preferences.matterEnabled).
func (s *Charker) SetHomeEnabled(on bool) (any, error) {
	return nil, s.app.SetPrefs(fmt.Appendf(nil, `{"matterEnabled":%t}`, on))
}

// AllowHomeFirewall asks for administrator rights once and lets the Home
// helper through Windows Firewall on private networks. It returns whether
// the rules allow it now.
func (s *Charker) AllowHomeFirewall() (bool, error) {
	err := s.app.ensureHomeFirewall(true)
	allowed := s.app.home.firewallState() == "allowed"
	if errors.Is(err, errFirewallDeclined) {
		return allowed, nil
	}
	return allowed, err
}

// ResetHomePairing removes one accessory, "whole" or "ports", from every
// Home it was added to; it shows a fresh setup code next.
func (s *Charker) ResetHomePairing(kind string) (any, error) {
	switch kind {
	case "whole":
		s.app.ResetHomePairing(matter.Grouped)
	case "ports":
		s.app.ResetHomePairing(matter.Bridged)
	default:
		return nil, fmt.Errorf("reset pairing: unknown accessory %q", kind)
	}
	return nil, nil
}
