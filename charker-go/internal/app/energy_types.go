package app

import "charker/internal/energy"

// EnergyScopeSummary is one scope of AppState.energy: what the overview's
// energy tile shows for Preferences.dashboardEnergyScope.
type EnergyScopeSummary struct {
	Wh float64 `json:"wh"`
	// Cost is Preferences.estimatedEnergyCost: null while no price is set.
	Cost     *float64 `json:"cost"`
	Currency string   `json:"currency"`
	// PerPort is Wh per port of EnergySummary.Ports: C1 C2 C3 on the
	// A2687, C1 C2 C3 C4 A1 A2 on the A2345.
	PerPort []float64 `json:"perPort"`
}

// EnergySummary is AppState.energy: the displayed ledger (the demo fixture
// in demo mode) reduced to what other pages need. The energy page fetches
// the detail with Charker.EnergyReport whenever Revision changes.
type EnergySummary struct {
	HasActiveSession bool `json:"hasActiveSession"`
	// Ephemeral is AppModel.energyHistoryIsEphemeral: demo data that is
	// never written, exported or cleared.
	Ephemeral bool `json:"ephemeral"`
	// Revision changes whenever the displayed ledger does.
	Revision uint64 `json:"revision"`
	// Product is the displayed ledger's product ("a2687" or "a2345") and
	// Ports its port labels (ChargerProduct.ports), the order of PerPort.
	Product string   `json:"product"`
	Ports   []string `json:"ports"`
	// Scopes holds session, day, week and month (DashboardEnergyScope).
	Scopes map[string]EnergyScopeSummary `json:"scopes"`
}

// EnergyRecord is one session or chart period of an EnergyReport; times
// are epoch milliseconds, PerPortWh has the six ChargerPortID slots
// (C1 C2 C3 C4 A1 A2) whatever the product.
type EnergyRecord struct {
	ID            string    `json:"id,omitempty"`
	StartedAt     int64     `json:"startedAt"`
	EndedAt       int64     `json:"endedAt"`
	EnergyWh      float64   `json:"energyWh"`
	ActiveSeconds float64   `json:"activeSeconds"`
	PeakWatts     float64   `json:"peakWatts"`
	AverageWatts  float64   `json:"averageWatts"`
	PerPortWh     []float64 `json:"perPortWh"`
	SampleCount   int       `json:"sampleCount,omitempty"`
}

// EnergyRangeSummary is EnergyHistorySummary.
type EnergyRangeSummary struct {
	EnergyWh      float64   `json:"energyWh"`
	ActiveSeconds float64   `json:"activeSeconds"`
	PeakWatts     float64   `json:"peakWatts"`
	AverageWatts  float64   `json:"averageWatts"`
	PerPortWh     []float64 `json:"perPortWh"`
	SessionCount  int       `json:"sessionCount"`
}

// EnergyReport is the energy page's digest for one range (session, day,
// week, month or all), as EnergyHistoryView.makeDigest builds it.
type EnergyReport struct {
	Range string `json:"range"`
	// Product, Ports and RatedWatts describe the displayed ledger's charger
	// (ChargerProduct): Ports are labels whose index in C1 C2 C3 C4 A1 A2 is
	// the PerPortWh slot.
	Product    string   `json:"product"`
	Ports      []string `json:"ports"`
	RatedWatts float64  `json:"ratedWatts"`
	NowMs      int64    `json:"nowMs"`
	// RangeStartMs is null for "all", and for "session" with no open run.
	RangeStartMs *int64 `json:"rangeStartMs"`
	// WeekStartMs/WeekEndMs bound the calendar week (its first day follows
	// the ledger's calendar).
	WeekStartMs int64 `json:"weekStartMs"`
	WeekEndMs   int64 `json:"weekEndMs"`

	Summary  EnergyRangeSummary `json:"summary"`
	Periods  []EnergyRecord     `json:"periods"`
	Sessions []EnergyRecord     `json:"sessions"`

	ActiveSessionID      string `json:"activeSessionId"`
	ActiveSessionStartMs *int64 `json:"activeSessionStartMs"`
	ArchivedSessionCount int    `json:"archivedSessionCount"`

	Ephemeral bool `json:"ephemeral"`
	// Warning is displayedEnergyHistoryWarning; SkippedCompaction is
	// skippedCompactionNotice. Both are L10n keys with arguments.
	Warning           *energy.Text `json:"warning"`
	SkippedCompaction *energy.Text `json:"skippedCompaction"`
	// CanClear is AppModel.canClearEnergyHistory; Clearable says which
	// calendar scopes (day, week, month) hold records.
	CanClear   bool            `json:"canClear"`
	Clearable  map[string]bool `json:"clearable"`
	Exportable bool            `json:"exportable"`
	Revision   uint64          `json:"revision"`
}
