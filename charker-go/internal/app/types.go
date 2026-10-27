// Package app is the MyGo application shell of Charker for Windows: the
// AppState the pages render, the "Charker" bound service, the push events,
// the main window and tray icon, and the persisted app settings.
//
// The JSON shapes here are the frozen Go/JS contract from
// docs/port/contract.md §4 — the tags are the wire format, not style.
package app

import "charker/internal/product"

// AppInfo is the "app" object of AppState.
type AppInfo struct {
	Version  string `json:"version"`
	Locale   string `json:"locale"`
	Theme    string `json:"theme"`
	Mock     bool   `json:"mock"`
	Platform string `json:"platform"`
}

// DeviceInfo is one charger in "device" and "devices" of AppState.
type DeviceInfo struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Product   string `json:"product"`
	Address   string `json:"address"`
	RSSI      int    `json:"rssi"`
	Connected bool   `json:"connected"`
	Saved     bool   `json:"saved"`
	Mock      bool   `json:"mock"`
}

// PortInfo is one charging port of AppState.
type PortInfo struct {
	ID             string  `json:"id"`
	Label          string  `json:"label"`
	Enabled        bool    `json:"enabled"`
	Status         int     `json:"status"`
	Watts          float64 `json:"watts"`
	Volts          float64 `json:"volts"`
	Amps           float64 `json:"amps"`
	Protocol       string  `json:"protocol"`
	EPR            bool    `json:"epr"`
	DeviceKind     string  `json:"deviceKind"`
	DeviceName     string  `json:"deviceName"`
	BarPct         float64 `json:"barPct"`
	ConfigLabel    string  `json:"configLabel"`
	CountdownEndMs int64   `json:"countdownEndMs"`
	TimerMinutes   int     `json:"timerMinutes"`
	Cable          string  `json:"cable"`
}

// Totals is the "totals" object of AppState.
type Totals struct {
	Watts          float64 `json:"watts"`
	Limit          float64 `json:"limit"`
	ChargingCount  int     `json:"chargingCount"`
	ConnectedCount int     `json:"connectedCount"`
}

// DeviceSettings is the "settings" object of AppState: the charger's own
// display settings as last reported by the device.
type DeviceSettings struct {
	ScreenOn        bool   `json:"screenOn"`
	Brightness      int    `json:"brightness"`
	Language        string `json:"language"`
	Orientation     string `json:"orientation"`
	AutoLock        bool   `json:"autoLock"`
	Theme           string `json:"theme"`
	FixedAllocation bool   `json:"fixedAllocation"`
	ScreenTimeout   string `json:"screenTimeout"`
	ChargingMode    string `json:"chargingMode"`
	AutoRotate      bool   `json:"autoRotate"`
	// WritesEnabled is the port-switching opt-in (Advanced screen): false by
	// default, like the macOS app.
	WritesEnabled bool `json:"writesEnabled"`
}

// MenuBarItem is one entry of the tray readout configuration.
type MenuBarItem struct {
	Kind     string `json:"kind"`
	Port     string `json:"port,omitempty"`
	Decimals int    `json:"decimals"`
}

// MenuBar is the "menuBar" object of AppState.
type MenuBar struct {
	Items []MenuBarItem `json:"items"`
}

// EnergyPeriod is one cached energy aggregate ("day", "week", "month").
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

// Notice is the "notice" object of AppState: nil when there is nothing to say.
type Notice struct {
	Kind string `json:"kind"`
	Text string `json:"text"`
}

// AppState is the complete state the frontend renders (contract §4.1).
type AppState struct {
	App           AppInfo             `json:"app"`
	Phase         Phase               `json:"phase"`
	Scanning      bool                `json:"scanning"`
	Device        *DeviceInfo         `json:"device"`
	Devices       []DeviceInfo        `json:"devices"`
	Ports         []PortInfo          `json:"ports"`
	Totals        Totals              `json:"totals"`
	History       []product.Sample    `json:"history"`
	Stats         product.SessionStats `json:"stats"`
	Settings      DeviceSettings      `json:"settings"`
	MenuBar       MenuBar             `json:"menuBar"`
	Energy        EnergySummary       `json:"energy"`
	Notice        *Notice             `json:"notice"`
	LastUpdatedMs int64               `json:"lastUpdatedMs"`
}

// EnergyBucket is one point of an EnergyReport series.
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
type Toast struct {
	Kind string `json:"kind"`
	Text string `json:"text"`
}

// DeviceLost is the payload of the "deviceLost" event.
type DeviceLost struct {
	ID string `json:"id"`
}
