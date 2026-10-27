package winble

import "time"

// Config tunes the Windows BLE transport. The zero value is usable: every
// duration and the buffer depth fall back to the default documented on the
// field.
type Config struct {
	// ScanWindow bounds the scan Connect runs when the charger is not in the
	// scan cache (no advertisement has been seen yet). Default 10s.
	//
	// Windows resolves a BLE address only for paired or recently seen devices,
	// so a remembered charger has to advertise once before it can be attached;
	// this is the window in which that can happen.
	ScanWindow time.Duration

	// ConnectTimeout bounds one adapter.Connect attempt. The WinRT backend gives
	// up on its own after 10s; the default 12s lets the backend's error surface
	// first instead of ours. Default 12s.
	ConnectTimeout time.Duration

	// WriteTimeout bounds one GATT write-with-response. Windows cannot cancel a
	// write that is in flight, so the bound only frees the caller's goroutine;
	// the eventual result is discarded. Default 5s.
	WriteTimeout time.Duration

	// EventBuffer is the depth of the Events channel. Notifications beyond it
	// are dropped and counted (see Transport.Dropped) rather than blocking the
	// WinRT thread that delivered them. Default 256.
	EventBuffer int

	// Logf, when set, receives diagnostics: advertisements that matched, connect
	// steps, the negotiated MTU, per-write sizes and error classes. Frame
	// payloads are never logged.
	Logf func(format string, args ...any)
}

func (c Config) withDefaults() Config {
	if c.ScanWindow <= 0 {
		c.ScanWindow = 10 * time.Second
	}
	if c.ConnectTimeout <= 0 {
		c.ConnectTimeout = 12 * time.Second
	}
	if c.WriteTimeout <= 0 {
		c.WriteTimeout = 5 * time.Second
	}
	if c.EventBuffer <= 0 {
		c.EventBuffer = 256
	}
	return c
}
