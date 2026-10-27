// Package app is the Windows shell around the session engine: it owns the
// preferences, maps session snapshots to the AppState the pages render, and
// runs the main window and the tray icon.
package app

import (
	"charker/internal/prefs"
	"charker/internal/product"
	"charker/internal/session"
)

// AppInfo describes the running app.
type AppInfo struct {
	Version string `json:"version"`
	// Locale is the effective UI language, "zh" or "en".
	Locale   string `json:"locale"`
	Platform string `json:"platform"`
	// Demo is true while the simulated charger is running.
	Demo bool `json:"demo"`
}

// DeviceInfo is one charger: the connected one or a nearby advertiser.
type DeviceInfo struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Address     string `json:"address"`
	RSSI        int    `json:"rssi"`
	Connected   bool   `json:"connected"`
	Saved       bool   `json:"saved"`
	Mock        bool   `json:"mock"`
	ProductName string `json:"productName,omitempty"`
	Firmware    string `json:"firmware,omitempty"`
	Serial      string `json:"serial,omitempty"`
	MAC         string `json:"mac,omitempty"`
}

// SessionState is the macOS SessionSnapshot in page form.
type SessionState struct {
	// Phase is idle, scanning, connecting, handshake, polling, reconnecting or
	// failed; polling is the macOS "monitoring".
	Phase         Phase                   `json:"phase"`
	Stage         string                  `json:"stage,omitempty"`
	Attempt       int                     `json:"attempt,omitempty"`
	Scanning      bool                    `json:"scanning"`
	IsStale       bool                    `json:"isStale"`
	WritesEnabled bool                    `json:"writesEnabled"`
	LastError     string                  `json:"lastError,omitempty"`
	Warning       string                  `json:"warning,omitempty"`
	Device        *DeviceInfo             `json:"device"`
	Nearby        []DeviceInfo            `json:"nearby"`
	Telemetry     *session.Telemetry      `json:"telemetry"`
	History       []session.HistorySample `json:"history"`
	ConnectedAtMs int64                   `json:"connectedAtMs,omitempty"`
}

// AppState is everything a page renders, pushed on the "state" event.
type AppState struct {
	App           AppInfo              `json:"app"`
	Prefs         prefs.Preferences    `json:"prefs"`
	SavedChargers []prefs.SavedCharger `json:"savedChargers"`
	Session       SessionState         `json:"session"`
	Stats         product.SessionStats `json:"stats"`
	Energy        EnergySummary        `json:"energy"`
	Notice        *Notice              `json:"notice"`
	LastUpdatedMs int64                `json:"lastUpdatedMs"`

	// Devices is the devices page's AppModel state (service_devices.go).
	Devices DevicesState `json:"devices"`
}

// Notice is a persistent banner: nil when there is nothing to say.
type Notice struct {
	Kind string `json:"kind"`
	Text string `json:"text"`
}

// Toast is a transient notice.
type Toast struct {
	Kind string `json:"kind"`
	Text string `json:"text"`
}

// DeviceLost is sent when the connection to the charger drops.
type DeviceLost struct {
	ID string `json:"id"`
}
