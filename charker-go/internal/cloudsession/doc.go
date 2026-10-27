// Package cloudsession is the A2345 (Anker Prime 250W) session engine: the
// Go counterpart of the A2345 half of the macOS AppModel. It drives the
// Anker account, the MQTT subscription and the writes — or the simulator —
// and publishes Snapshots shaped like the A2687 engine's so the pages stay
// product-neutral.
//
// Behaviour kept from AppModel:
//
//   - Start loads the stored token (expired → deleted, sign in again), lists
//     the bound A2345s (none → failure; several and none chosen → failure
//     asking to choose; a vanished choice with one left → automatic switch),
//     fetches the temporary MQTT identity and subscribes. On SUBACK the
//     subscriber sends 0x0200, 0x0202 and 0x020B, then 0x020B every 8 s.
//   - Only realtime and status-snapshot frames count as telemetry: they set
//     monitoring, append history, feed OnSample, renew the 45 s telemetry
//     watchdog (which recycles a silent subscription) and reset the retry
//     budget. 15 s without one marks the reading stale. While settings are
//     still missing a realtime frame re-requests 0x0200/0x0202 at most every
//     10 s. 0x0301 (new firmware) triggers a full readback.
//   - A dropped subscription is retried with 1, 2, 4, 8 s delays; the fifth
//     consecutive failure is terminal. Each retry marks the reading stale and
//     clears the settings and pending writes. An expired token deletes the
//     stored record.
//   - Writes apply optimistically, wait for 0x0ANN (resent once after 1.5 s,
//     given up after 3 s more; priority once for 4 s; custom profile 3 s + 4 s)
//     and read the state back 800 ms after settling. Port switches,
//     countdowns and schedules need WritesEnabled, like the A2687.
//   - Account-side data (lab switches, custom profiles, clock themes, custom
//     pictures) loads in up to three attempts 20 s apart; account writes go to
//     the cloud first and then to the charger, in the official app's order.
//
// The demo (Options.Demo) is AppModel.startA2345Demo: a monitoring
// "A2345-DEMO" with a2345.DemoSettings, a reading every 2 s and local writes.
package cloudsession
