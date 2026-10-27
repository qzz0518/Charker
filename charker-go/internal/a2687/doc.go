// Package a2687 is the pure Go port of the macOS app's A2687Protocol module: the
// wire protocol of the Anker Prime 160W charger (advertised service FF09).
//
// The package is deliberately free of OS, BLE, UI and clock dependencies. It
// consumes bytes and produces bytes, readings and settings; callers own the
// link, the timers and the retry policy. It mirrors Charker/Sources/A2687Protocol
// file by file; the Swift sources are the reference.
//
// Layout:
//
//	frame.go      Frame/FramePattern/PacketCodec/FrameReassembler (FF09 framing)
//	tlv.go        TLV, TypedValue, Payload (status-byte heuristic)
//	crypto.go     AES-128-GCM + P-256 ECDH; negotiation and session key schedules
//	handshake.go  HandshakeEngine ladder + a frame-level Handshake adapter
//	opcodes.go    GATT ids, opcodes, TLV ids, port and group constants
//	commands.go   session command encoders and write-side enums
//	telemetry.go  telemetry/settings decoder and the product.* mapping
//	cover.go      cover image transfer arithmetic, commands and ACK parsing
//	link.go       post-handshake link facade (seal/open/telemetry/product)
//	redact.go     log redaction helpers
//
// Three protocol facts drive most of this package and are worth stating once:
//
//  1. The device response status is the leading byte of the decrypted payload,
//     not TLV A1. On real firmware A1 is a constant 0x31 ("bare"), so looking
//     for the result code in A1 silently turns every refusal into success. Use
//     Payload.Status.
//  2. AES-GCM is used with one fixed nonce per key schedule and does not cover
//     the frame header in the AAD. That is a protocol weakness we must tolerate;
//     it is why Open is strictly fail-closed and callers must additionally
//     validate opcode, TLV shape and session state. Keys are never logged:
//     Keys implements fmt.Stringer with a redacted representation.
//  3. Settings (A8/A9/AA/AF/B2) are a handshake-time snapshot, not live values.
//     A telemetry frame that omits them does not mean "settings gone": keep the
//     last non-nil snapshot of the link (Link does this) and clear it on every
//     new handshake.
//
// Spec ambiguities resolved here, with the choice made:
//
//   - "Screen on/off" has no A2687 command. The Swift encoder only knows the
//     display *timeout* (0x0203), brightness, orientation and gyroscope; this
//     package implements those and does not invent a screen-power opcode.
//     "Auto-lock" in the UI is that same 0x0203 timeout command.
//   - product.Settings.ScreenTimeout/ChargingMode/AutoRotate are mapped in the
//     vocabulary the settings UI and session SetSetting accept: screen timeout
//     "30s"/"1m"/"5m"/"30m"/"12h", charging mode "ai"/"standard"/"custom", with
//     raw decimal code strings for values the protocol does not name.
//     product.Settings.AutoLock stays nil because it is a lossy bool for the
//     five-value timeout enum (the session's write path treats 12h as off).
//   - ChargingMode custom = 2 (app 3.24.0), not the Smi-tagged 4 sometimes seen
//     in decompiled constants. The Swift source is canonical.
package a2687
