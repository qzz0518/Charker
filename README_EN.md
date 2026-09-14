<div align="center">
  <img src="Resources/Screenshots/app-icon-rounded.png" width="128" alt="Charker icon" />
  <h1>Charker</h1>
  <p><strong>Monitor the Anker Prime 160W and 250W from your Mac.</strong></p>
  <p>A native, lightweight, local-first macOS companion.</p>
  <p><a href="README.md">简体中文</a> · English</p>
  <p>
    <a href="https://github.com/qzz0518/Charker/stargazers"><img src="https://img.shields.io/github/stars/qzz0518/Charker?style=flat-square" alt="GitHub Stars" /></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple" alt="macOS 14+" />
    <img src="https://img.shields.io/badge/Swift-6.0-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.0" />
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License" /></a>
    <a href="https://x.com/zerah_eth"><img src="https://img.shields.io/badge/follow-%40zerah__eth-111111?style=flat-square&logo=x&logoColor=white" alt="Follow @zerah_eth on X" /></a>
  </p>
</div>

<p align="center">
  <img src="Resources/Screenshots/overview.png" width="1100" alt="Charker overview with live power, the 3D device, port status, and power timeline" />
</p>

Charker is an unofficial macOS app for the **Anker Prime 160W (A2687)** and **Anker Prime Charger
250W (A2345)**. The A2687 uses a direct encrypted CoreBluetooth session. The A2345 discovers devices
bound to your Anker account and uses an encrypted MQTT session to subscribe to and actively request
read-only Wi-Fi telemetry.
Both appear in a native window, the menu bar, and local energy history. No data is routed through a
Charker server.

> [!IMPORTANT]
> Charker is an independent interoperability project. It is not affiliated with or endorsed by Anker.
> Hardware validation currently covers an A2687 on BLE firmware `v0.0.5.2`. The A2345 cloud protocol
> and six-port packet fields were validated with firmware `2.1.1.6` and a JP account. Charker's sign-in,
> subscription, fixed read requests, and UI path are implemented but still await end-to-end
> hardware acceptance.

## Features

- **Live overview**: three USB-C ports on the A2687, or C1–C4 plus A1/A2 on the A2345, with voltage,
  current, power, a native 3D device view, and a live timeline.
- **Menu bar monitoring**: keep total or per-port readings visible without leaving the main window open;
  combine icons, values, separators, and custom text.
- **Energy and cost**: inspect sessions, today, this week, this month, or all history, including energy,
  peak and average power, port composition, and load distribution. Configure a currency and electricity
  rate, clear the selected period, or export CSV / JSON.
- **Device and connection management**: nearby Bluetooth discovery for A2687; account sign-in, Keychain
  session storage, and Wi-Fi cloud status for A2345. Bluetooth scanning stops after a successful connection.
- **Device controls**: A2687 port output and shutdown timers use confirmation, ACK handling, and state
  readback. Display language, brightness, auto-lock, orientation, and auto-rotation are hardware-verified.
  A2345 remains strictly read-only and exposes no unverified write controls.
- **Screen personalization**: edit the digital twin display and experimentally transfer a custom image
  to the charger's physical screen.
- **Simulated charger**: explore either the A2687 three-port or A2345 six-port interface without hardware.
  Simulated data is kept separate from real history.
- **Secure updates**: check for and install EdDSA-signed releases through Sparkle while keeping the installer
  inside the macOS sandbox and Developer ID trust chain.
- **Chinese and English**: the window, menu bar, status messages, permission copy, and diagnostics are localized.

## Quick Start

### Requirements

- macOS 14 or later
- An Apple Silicon Mac (hardware-verified); release builds are Universal 2, while real Bluetooth use on Intel remains unverified
- An Anker Prime 160W (A2687) or Prime Charger 250W (A2345) for a real connection; the simulator works without either

### Homebrew

```bash
brew install --cask qzz0518/tap/charker
```

To update later:

```bash
brew upgrade --cask charker
```

### Install from DMG

Download the latest `Charker-*.dmg` listed on
[Releases](https://github.com/qzz0518/Charker/releases), open it, and drag Charker into Applications.

Homebrew and Releases use the same Universal 2 DMG, signed with Developer ID and notarized by Apple.

### Build from Source

Building from source requires Xcode Command Line Tools and Swift 6.0+:

```bash
git clone https://github.com/qzz0518/Charker.git
cd Charker
mise run verify
open dist/Charker.app
```

`mise run verify` builds every target, runs the tests, checks both localization tables, and assembles
the locally signed `dist/Charker.app`. Without mise, run:

```bash
swift test
CONFIG=release Scripts/make-app.sh
open dist/Charker.app
```

> [!NOTE]
> Test real Bluetooth through the signed `.app`. `swift run Charker` is useful for UI and simulator work,
> but it has no complete app bundle, Bluetooth usage description, or entitlement and is not a valid
> real-device test.

## First Connection

Charker supports mainland China phone login: select **China (CN)**, enter the phone
number bound to your device, choose **Get Code**, and enter the SMS code. Other regions still use
email and password. Phone numbers, SMS codes, and passwords are not saved. A2687 keeps only the
account ID; A2345 login tokens are stored in macOS Keychain.

### A2687 · Bluetooth

1. Power the charger and fully quit the official Anker app or any other client using it.
2. Open Charker, follow the empty-state guidance to **Devices & Connection**, and select the charger.
3. If the firmware requires the bound identity, use the one-time helper under **Anker Account ID** or
   enter your own `user_id` manually. Charker stores only that ID, never the password or login token.
4. If no charger is available, start **Simulated Charger** from the connection guide or Advanced settings.

The A2687 accepts only one client at a time and may stop advertising entirely while another client is
connected. A missing device often means the official app, another computer, or another Charker instance
still owns the connection.

### A2345 · Read-only Wi-Fi cloud connection

1. Bind the charger and finish Wi-Fi setup in the official Anker app first.
2. Choose A2345 under **Devices & Connection** and sign in with the account that owns it; choose JP for a JP account.
3. Charker stores the short-lived access token in macOS Keychain. The temporary MQTT client certificate and RSA
   private key form an in-memory identity for the current connection only; they are released on disconnect and are
   never imported into a persistent Keychain.
4. After the subscription is ready, Charker sends only two allowlisted read requests: `0200` requests a six-port
   `0A00` snapshot, while `020B` triggers `0303` realtime frames. Neither request changes a port or device setting.

Signing out deletes the Keychain token. It does not unbind the charger or remove local energy history.

## Verified Scope

| Capability | Status | Boundary |
| --- | --- | --- |
| Encrypted session and three-port telemetry | Hardware-verified | A2687 / BLE `v0.0.5.2` / macOS 15.7.7, roughly 1 Hz |
| Six-port Wi-Fi telemetry and MQTT subscription | Protocol and packet fields hardware-verified; app path awaits acceptance | A2345 / firmware `2.1.1.6` / JP account; Charker implements fixed `0200`/`020B` reads and `0A00`/`0303` decoding; C1–C4 were load-tested individually, while A1/A2 still need independent load validation |
| Display language, brightness, lock, orientation, auto-rotation | Hardware-verified | Brightness is limited to 25%–100% |
| Port output and shutdown timer | Guarded flow implemented | Interrupts power immediately; verify behavior on your firmware |
| Custom display image transfer | Experimental | The charger has 4 slots and no delete command; each transfer occupies a slot until later transfers replace it |
| Simulated charger | Covered by automated tests | No Bluetooth connection and no writes to real energy history |
| A2345 writes | Not exposed | Only fixed `0200`/`020B` reads are allowed; no arbitrary MQTT PUBLISH, port-output, or settings interface is exposed, and candidate `A8` metadata is not shown |

## Privacy and Network Use

| Data | How Charker handles it |
| --- | --- |
| A2687 live telemetry | Read over local Bluetooth and decoded in memory |
| A2345 live telemetry | Read from Anker's encrypted MQTT service and decoded in memory; never routed through a Charker server |
| Energy history and preferences | Stored only in this Mac's app data |
| Anker account | Passwords are used only for the login request and never persisted; A2687 keeps only `user_id`, while A2345 stores a short-lived token in macOS Keychain |
| Temporary MQTT identity | Memory-only and released after disconnect; never stored in preferences, diagnostics, or the repository |
| Software updates | Sparkle periodically reads a signed appcast from GitHub Pages and downloads a user-approved release only from GitHub Releases |
| Diagnostic export | Masks serial numbers and Bluetooth addresses by default; raw packet logging is opt-in |
| Analytics and tracking | No Charker server, analytics SDK, or telemetry upload |

The GitHub and X buttons only open those pages in your default browser. A2687 monitoring and controls do
not require internet access. A2345 Wi-Fi telemetry depends on the Anker account HTTP API and MQTT service.

## Development

Charker uses SwiftPM. Common tasks are defined in [`mise.toml`](mise.toml):

| Command | Purpose |
| --- | --- |
| `mise run build` | Build every target |
| `mise run test` | Run protocol and session tests |
| `mise run i18n` | Validate Chinese and English keys and format placeholders |
| `mise run release-config` | Validate Sparkle, sandbox, and release metadata without reading secrets |
| `mise run bundle` | Assemble and ad-hoc sign the local app |
| `mise run bundle-universal` | Assemble and ad-hoc sign a Universal 2 app |
| `mise run release-dry-run` | Create an unnotarized Universal 2 candidate DMG with Developer ID |
| `mise run release` | Build from a clean tag, sign, notarize, staple, and generate the signed appcast |
| `mise run verify` | Build, test, validate localization/release config, and verify the host-architecture development app |

```text
Sources/
├── A2687Protocol/  Frames, TLV, cryptographic handshake, commands, and telemetry
├── A2345Protocol/  Fixed FF09 read requests plus six-port snapshot, realtime telemetry, and version decoding
├── CharkerCore/    Bluetooth/cloud connections, sessions, history, preferences, diagnostics, and simulation
├── CharkerApp/     SwiftUI / AppKit interface and menu bar
└── CharkerDraco/   Draco adapter for the 3D model
Tests/              Protocol, session, history, settings, and transfer tests
```

An ad-hoc build can appear as a new Bluetooth permission principal whenever the binary changes. To keep
a stable local development identity:

```bash
Scripts/make-signing-identity.sh
IDENTITY="Charker Dev" CONFIG=release Scripts/make-app.sh
```

This remains a development identity. Public distribution still requires Developer ID signing, Hardened
Runtime, notarization, and stapling.

### For Release Maintainers

Formal releases use the Developer ID identity, the `Charker-Notary` keychain profile, and Sparkle's EdDSA
private key. None of them are stored in this repository. `mise run release` requires a clean working tree
and a version-matching tag on `HEAD`. The pipeline notarizes and staples the App before sealing it into a
separately signed, notarized, and stapled DMG. That same final DMG is shared by GitHub Releases, Sparkle,
and the Homebrew Cask so every channel points to identical bytes.

## Contributing

Issues and pull requests are welcome. For protocol or hardware changes, include the model, BLE firmware,
reproduction steps, and redacted diagnostics. Never publish account IDs, full serial numbers, Bluetooth
addresses, keys, or private raw captures.

- [Report an issue](https://github.com/qzz0518/Charker/issues)
- [Browse the source](https://github.com/qzz0518/Charker)
- [Follow @zerah_eth on X](https://x.com/zerah_eth)

## Acknowledgements

Protocol facts and test vectors were informed by these public projects. Charker's Swift implementation
was written independently:

- [flip-dots/SolixBLE](https://github.com/flip-dots/SolixBLE)
- [Hyper-Beast/Anker_Prime_160W_WebBLE](https://github.com/Hyper-Beast/Anker_Prime_160W_WebBLE)
- [atc1441/Anker_Prime_BLE_hacking](https://github.com/atc1441/Anker_Prime_BLE_hacking)
- [thomluther/anker-solix-api](https://github.com/thomluther/anker-solix-api)

See [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) for exact sources, revisions, and licenses.

## License

Project-authored code is released under the [MIT License](LICENSE). Anker trademarks, product images,
3D models, and other third-party materials are not relicensed under MIT; their respective owners retain
their rights. See [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
