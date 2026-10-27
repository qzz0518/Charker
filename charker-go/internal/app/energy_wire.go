package app

import (
	"bytes"
	"fmt"
	"log"
	"time"

	"charker/internal/energy"
)

// EnergyService adapts charker/internal/energy (owned by core-session) to the
// app's Energy seam: cached AppState aggregates, the detailed range report and
// the CSV/JSON export.
type EnergyService struct {
	hist    *energy.History
	store   *energy.Store
	warning string
}

// NewEnergyService loads the energy history under baseDir (mygo's user-data
// directory). It returns nil when baseDir is empty: the app then shows zero
// aggregates instead of writing an archive next to the executable.
func NewEnergyService(baseDir string, pricePerKWh float64, currency string) *EnergyService {
	if baseDir == "" {
		return nil
	}
	store := energy.NewStoreForBaseDir(baseDir)
	hist, warning := store.Load(energy.Options{PricePerKWh: pricePerKWh, Currency: currency})
	if warning != "" {
		log.Printf("app: energy history: %s", warning)
	}
	return &EnergyService{hist: hist, store: store, warning: warning}
}

// Warning is a human-readable note about a recovered/corrupt archive, "" when
// the history loaded cleanly.
func (e *EnergyService) Warning() string { return e.warning }

// RecordAt feeds one telemetry sample into the ledger (session OnSample hook).
func (e *EnergyService) RecordAt(atUnixMs int64, totalWatts float64, perPortWatts [6]float64) {
	if e == nil {
		return
	}
	e.hist.Record(time.UnixMilli(atUnixMs), totalWatts, perPortWatts)
}

// SetPrice updates the electricity price used for cost estimates.
func (e *EnergyService) SetPrice(pricePerKWh float64, currency string) {
	if e == nil {
		return
	}
	e.hist.SetPrice(pricePerKWh, currency)
}

// Finish closes the open charging session and writes the archive; call it on
// exit.
func (e *EnergyService) Finish() error {
	if e == nil {
		return nil
	}
	e.hist.FinishCurrentSession()
	return e.store.Save(e.hist)
}

// Save writes the archive; call it on exit.
func (e *EnergyService) Save() error {
	if e == nil {
		return nil
	}
	return e.store.Save(e.hist)
}

// Summary returns the cheap cached aggregates for AppState.energy.
func (e *EnergyService) Summary() EnergySummary {
	if e == nil {
		return EnergySummary{}
	}
	ae := e.hist.AppEnergy(time.Now())
	return EnergySummary{
		Day:   energyCard(ae.Day),
		Week:  energyCard(ae.Week),
		Month: energyCard(ae.Month),
	}
}

// energyCard converts one energy aggregate.
func energyCard(c energy.EnergyCard) EnergyPeriod {
	return EnergyPeriod{Wh: c.Wh, Cost: c.Cost, Currency: c.Currency}
}

// Report returns the detailed series for "day", "week" or "month".
func (e *EnergyService) Report(rangeArg string) EnergyReport {
	out := EnergyReport{Range: rangeArg, Buckets: []EnergyBucket{}, Sessions: []EnergySession{}}
	if e == nil {
		return out
	}
	rep, err := e.hist.Report(rangeArg, time.Now())
	if err != nil {
		log.Printf("app: energy report %q: %v", rangeArg, err)
		return out
	}
	out.Range = rep.Range
	out.TotalWh = rep.TotalWh
	out.Cost = rep.Cost
	out.Currency = rep.Currency
	for _, b := range rep.Buckets {
		out.Buckets = append(out.Buckets, EnergyBucket{T: b.T, Wh: b.Wh})
	}
	for _, s := range rep.Sessions {
		out.Sessions = append(out.Sessions, EnergySession{StartMs: s.StartMs, EndMs: s.EndMs, Wh: s.Wh, PeakW: s.PeakW})
	}
	return out
}

// Export renders the archive as CSV or JSON with the energy package's own
// exporters (the range names the file; the archive holds every range). CSV is
// UTF-8 with a BOM and CRLF line endings so Excel opens it directly, like the
// macOS export.
func (e *EnergyService) Export(rangeArg, format string) ([]byte, error) {
	if e == nil {
		return nil, fmt.Errorf("energy history is not available")
	}
	var buf bytes.Buffer
	now := time.Now()
	switch format {
	case "json":
		if err := e.hist.ExportJSON(&buf, now); err != nil {
			return nil, err
		}
	case "csv":
		if err := e.hist.ExportCSV(&buf, now); err != nil {
			return nil, err
		}
	default:
		return nil, fmt.Errorf("unknown export format %q", format)
	}
	_ = rangeArg
	return buf.Bytes(), nil
}
