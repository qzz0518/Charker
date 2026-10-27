// Package anker is the Go port of the Anker account and cloud side of the
// macOS app's CharkerCore module: everything the A2345 (Anker Prime 250W)
// needs to go from an email/password or a mainland phone number to a live
// MQTT subscription on its device topic.
//
// It mirrors these Swift files, file by file:
//
//	region.go         AnkerRegion.swift (country table, MailDomains)
//	account.go        AnkerAccount.swift (login, password ECDH/AES, server routing)
//	cloud.go          AnkerCloud.swift (authenticated HTTP API, devices, MQTT identity)
//	minipower.go      AnkerMiniPower.swift (lab switches, custom modes, clock themes)
//	payload.go        A2345CloudPayloadDecoder.swift
//	mqtt_codec.go     the MQTT 3.1.1 framing half of A2345MQTT.swift
//	mqtt.go           A2345MQTTSubscriber (on crypto/tls instead of NWConnection)
//	mqtt_commands.go  A2345MQTTCommands.swift (command envelope, SUBACK transition)
//	store*.go         the Keychain store, as DPAPI on Windows and a 0600 file elsewhere
//	text.go           the L10n-shaped user-facing messages
//
// Facts worth stating once:
//
//   - Server routing. Mainland China (CN) signs in by phone on its own server.
//     Of the overseas countries only AR AU BR CA MX NZ US use the `.com`
//     server; every other country is EU-served. A login response can name
//     the account's real home (`domain`, or the `ab_code` country); the login
//     is replayed there exactly once and that server is remembered with the
//     token. No other host can ever be reached: both the response and a
//     stored record are re-validated against the fixed allowlist.
//   - The password never travels in the clear, even inside TLS: it is
//     AES-256-CBC encrypted with an ECDH (P-256) secret shared with Anker's
//     fixed login key. The password is never stored or logged; the auth token
//     only lives in the credential store and is redacted from every String().
//   - The MQTT client is deliberately minimal: CONNECT, one QoS-0 SUBSCRIBE to
//     the device's own topic, QoS-0 PUBLISH of allowlisted a2345.Command
//     values only, PINGREQ, PUBACK for inbound QoS 1, DISCONNECT. There is no
//     API to publish raw bytes or to another topic.
//
// User-facing strings are the macOS app's Chinese source strings, carried as
// Text so the page can translate them with the same tables (see text.go).
package anker
