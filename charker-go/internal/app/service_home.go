package app

import (
	"fmt"

	"charker/internal/matter"
)

// The Apple 家庭 page (pages/home.js). Its state is AppState.home.

// SetHomeEnabled turns Apple Home on or off (preferences.matterEnabled).
func (s *Charker) SetHomeEnabled(on bool) (any, error) {
	return nil, s.app.SetPrefs(fmt.Appendf(nil, `{"matterEnabled":%t}`, on))
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
