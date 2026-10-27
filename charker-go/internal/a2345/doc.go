// Package a2345 is the pure Go port of the macOS app's A2345Protocol module:
// the unencrypted FF09 frames the Anker Prime 250W charger (A2345) exchanges
// over Anker's MQTT relay.
//
// The package is free of OS, network, UI and clock dependencies. It consumes
// bytes and produces readings, settings and request frames; callers own the
// MQTT link, the timers and the retry policy. It mirrors
// Charker/Sources/A2345Protocol file by file, plus the pure parts of
// CharkerCore/A2345Control.swift; the Swift sources are the reference.
//
// Layout:
//
//	frame.go       FramePattern, TLV, Frame, Decode (strict FF09 framing)
//	reassembler.go Reassembler for split or coalesced MQTT chunks
//	messages.go    0303 realtime, 0A00 snapshot, 0830 version, ACK decoding
//	settings.go    DeviceSettings, 03xx/0A02 change messages, write ACKs
//	commands.go    request encoder and the closed Command set
//	control.go     WriteKey matching, optimistic Applying, demo settings
//
// Protocol facts worth stating once:
//
//  1. Requests carry no encryption on the MQTT path. Every request is
//     FF 09 | len | 03 00 0F | type | A1 01 22 | TLVs by tag | FE 05 03 epoch | XOR.
//  2. The byte after the message type is optional: acknowledgements and
//     0x08xx carry an "a0" status byte there, 0x03xx pushes do not. Field ids
//     all live in A0…FF, so a smaller byte is that status, never a TLV id.
//  3. Mainland firmware 1.4.0.2 grew every per-port field from 8 to 11 bytes.
//     Port fields are read "at least seven payload bytes, take the first
//     seven"; an exact length is never required.
package a2345
