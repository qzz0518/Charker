package app

type EnergyPeriod struct {
	Wh       float64 `json:"wh"`
	Cost     float64 `json:"cost"`
	Currency string  `json:"currency"`
}

// EnergySummary is the "energy" object of AppState — cheap cached aggregates;
// the energy screen calls Charker.EnergyReport for the detailed series.
type EnergySummary struct {
	Day   EnergyPeriod `json:"day"`
	Week  EnergyPeriod `json:"week"`
	Month EnergyPeriod `json:"month"`
}

type EnergyBucket struct {
	T  int64   `json:"t"`
	Wh float64 `json:"wh"`
}

// EnergySession is one charging session of an EnergyReport ledger.
type EnergySession struct {
	StartMs int64   `json:"startMs"`
	EndMs   int64   `json:"endMs"`
	Wh      float64 `json:"wh"`
	PeakW   float64 `json:"peakW"`
}

// EnergyReport is the detailed energy series returned by Charker.EnergyReport.
type EnergyReport struct {
	Range    string          `json:"range"`
	Buckets  []EnergyBucket  `json:"buckets"`
	TotalWh  float64         `json:"totalWh"`
	Cost     float64         `json:"cost"`
	Currency string          `json:"currency"`
	Sessions []EnergySession `json:"sessions"`
}

// Toast is the payload of the "toast" event.
