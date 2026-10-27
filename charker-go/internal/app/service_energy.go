package app

import (
	"context"
	"fmt"
	"strings"
)

// The energy page's calls (EnergyHistoryView + AppModel's energy actions).

// EnergyReport returns the energy page's digest for "session", "day",
// "week", "month" or "all".
func (s *Charker) EnergyReport(rangeArg string) (EnergyReport, error) {
	rangeArg = strings.ToLower(strings.TrimSpace(rangeArg))
	switch rangeArg {
	case "session", "day", "week", "month", "all":
	default:
		return EnergyReport{}, fmt.Errorf("unknown energy range %q", rangeArg)
	}
	return s.app.energyService().Report(rangeArg), nil
}

// ExportEnergy writes the whole ledger as "csv" or "json" through the
// native Save dialog and returns the saved path, or "" when the user
// canceled. Demo data is never exported.
func (s *Charker) ExportEnergy(ctx context.Context, format string) (string, error) {
	return s.app.exportEnergy(ctx, format)
}

// EndEnergySession ends the local energy segment (AppModel.
// endCurrentEnergySession) without touching the charger, and posts the
// Mac's action message either way.
func (s *Charker) EndEnergySession() (bool, error) {
	a := s.app
	ended := a.energyService().EndSession()
	if ended {
		a.toast("info", a.tr(textEnergyEnded))
	} else {
		a.toast("info", a.tr(textEnergyNoSession))
	}
	a.publishNow()
	return ended, nil
}

// ClearEnergyHistory permanently clears the whole local ledger
// (AppModel.clearEnergyHistory()). Refused in demo mode.
func (s *Charker) ClearEnergyHistory() (bool, error) {
	ok, err := s.clear("all")
	if ok {
		s.app.toast("info", s.app.tr(textEnergyCleared))
	}
	return ok, err
}

// ClearEnergyHistoryIn clears one HistoryClearScope: "day", "week",
// "month" or "all". On success the page posts the scope's own message.
func (s *Charker) ClearEnergyHistoryIn(scope string) (bool, error) {
	scope = strings.ToLower(strings.TrimSpace(scope))
	switch scope {
	case "day", "week", "month", "all":
	default:
		return false, fmt.Errorf("unknown energy scope %q", scope)
	}
	return s.clear(scope)
}

func (s *Charker) clear(scope string) (bool, error) {
	a := s.app
	es := a.energyService()
	var (
		ok  bool
		err error
	)
	if scope == "all" {
		ok, err = es.ClearAll()
	} else {
		ok, err = es.ClearRange(scope)
	}
	if err != nil {
		a.toast("error", fmt.Sprintf(a.tr(textEnergyClearFail), err))
	}
	a.publishNow()
	return ok, err
}
