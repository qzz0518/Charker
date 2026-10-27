// Package winble implements transport.Transport for a Bluetooth LE central on
// Windows through tinygo.org/x/bluetooth (WinRT, no cgo).
//
// Behaviour mirrors Charker's CoreBluetoothTransport
// (Charker/Sources/CharkerCore/CoreBluetoothTransport.swift):
//
//   - scanning is unfiltered at the OS level and matched in code, because a
//     filtered WinRT scan only sees advertised service UUIDs and A2687 units may
//     advertise only a name or only manufacturer data;
//   - Connect resolves a saved charger by MAC from the scan cache first and
//     falls back to a bounded scan, because WinRT's BluetoothLEDevice resolves
//     only paired or recently seen addresses;
//   - one GATT write with response carries a whole A2687 frame: Windows turns a
//     value larger than the ATT MTU into an ATT long write (prepare/execute),
//     which is the same path CoreBluetooth uses. The write-without-response
//     fallback has no fragmentation in ATT, so that path chunks at MTU-3;
//   - link loss arrives from the adapter's connect handler and a 3 s
//     Device.Connected() poll, and is reported once as EventDisconnected.
//
// Everything Windows-specific lives behind a `//go:build windows` tag; the
// !windows file is a stub returning transport.ErrUnsupported so the module
// still builds on non-Windows hosts (and lets GOOS=linux go build pass).
//
// One Transport is one link. Callers keep all Transport methods on the session's
// owner goroutine; the implementation is nevertheless mutex-guarded and its
// WinRT callbacks only copy buffers and hand events to a buffered channel.
package winble
