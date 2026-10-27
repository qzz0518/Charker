# Charker for Windows

A Windows port of [Charker](https://github.com/qzz0518/Charker) — the unofficial macOS
companion app for the **Anker Prime 160W (A2687)** charger — built with
[MyGo](https://github.com/egoist/mygo), Go and a plain HTML/CSS/JS frontend in WebView2.

The port keeps the original UI (dark "slate" design, sidebar, dashboard with the 3D charger,
port cards, power timeline, energy history, settings, tray readout) and the original protocol
implementation (A2687 BLE: framing, TLV, P-256/AES-GCM handshake, telemetry, control commands).
It is a single small exe, no Electron, no bundled browser, no installer required.

![Overview](shots/final-overview.png)

## Run it

**Installed build (recommended).** The app is installed for the current user at
`%LOCALAPPDATA%\Programs\Charker\Charker.exe`, with a **Charker** shortcut on the Desktop.
If you have the repo, `.\install.ps1` (re)installs it (and `-Uninstall` removes it):

```powershell
cd charker-go
.\build.ps1 -Mode release
.\install.ps1
```

Then:

1. The app starts in **演示模式 (demo mode)** so the UI is usable without a charger, exactly like
   Charker's mock charger. Open **设备与连接** and press **退出模拟** (or toggle demo mode off) to
   scan for a real Anker Prime 160W over Bluetooth.
2. For real control writes (port on/off, countdown, screen settings) enable
   **高级 → 允许端口开关**, like the original app.
3. Closing the window hides Charker to the tray; the tray icon restores it or quits.

The app keeps its data in `%APPDATA%\Charker` (preferences, window state), `%LOCALAPPDATA%\Charker`
(WebView2 profile, `charker.log`) and the energy ledger in the app's user-data folder. No account,
no cloud, no telemetry.

> **Note for this build environment:** this workspace is managed by the coding agent's sandbox,
> and Windows keeps the sandbox ACLs on files built inside it. An exe run **directly from this
> workspace** therefore cannot write its WebView2 profile and shows a black window. The installed
> copy (and `dist\Charker.exe`, whose ACL was reset) work normally; `install.ps1` does that
> automatically. On a normal machine a `build\Charker.exe` built and run there works as-is.

## What is ported

| Area | Status |
|---|---|
| A2687 BLE protocol (frames, TLV, crypto handshake, commands, telemetry, cover transfer) | ✅ Go port, 209 table tests from the Swift fixtures |
| BLE transport | ✅ Windows WinRT via `tinygo.org/x/bluetooth` (scan/connect/subscribe/write/reconnect) |
| Session engine (scan, connect, handshake, 1 Hz telemetry, polls, staleness, reconnect) | ✅ |
| Dashboard (3D charger via three.js + Draco, port cards, timeline, stats) | ✅ |
| Port controls (switch, countdown/timer, screen timeout, brightness, orientation, language, fixed allocation, charging mode, auto-rotate) | ✅ protocol + UI; requires 允许端口开关 |
| Energy history (day/week/month, session ledger, cost, CSV/JSON export) | ✅ |
| Menu bar readout | ✅ as a Windows tray icon/flyout layout editor (Windows cannot draw a numeric tray title) |
| Preferences, saved chargers, window state, zh/en localization | ✅ |
| A2345 (250W) via Anker cloud | ❌ out of scope (needs the unofficial cloud/MQTT stack; shown as a capability notice) |
| Apple Home / Matter | ❌ not available on Windows |
| In-app auto update | ❌ (upstream uses Sparkle) |
| Cover/screen image upload | protocol ported, not exposed in the UI yet |

The protocol, session and energy layers are pure Go and OS independent; only the BLE backend is
Windows-specific.

## Build

Requirements: Windows 10/11, Go 1.27.3+ (the repo uses the workspace toolchain wrapper
`tools\go.cmd`), no cgo, no Bun/npm/Node needed at build time.

```powershell
cd charker-go
.\build.ps1                 # dev build  -> build\charker-dev.exe (console, logs, inspector)
.\build.ps1 -Mode release   # release exe -> build\Charker.exe (GUI subsystem, ~24 MB)
```

The frontend lives in `web/` and is embedded into the exe with `//go:embed all:web`
(`mygo.SetFrontend`); there is no frontend build step. Vendored libraries: three.js + Draco
decoder in `web/vendor/three` (MIT / Apache-2.0).

```powershell
..\tools\go.cmd test ./...     # protocol, session, mock charger, prefs, energy
..\tools\go.cmd build ./...    # whole module
```

## Layout

```
charker-go/
  main.go                 mygo app: window, single instance, embed frontend, tray
  internal/a2687/         A2687 protocol (pure Go, ported 1:1 from Charker/Sources/A2687Protocol)
  internal/transport/     Transport interface, mock charger, winble (Windows BLE)
  internal/session/       session engine (single owner goroutine, snapshots, writes)
  internal/prefs/         preferences, saved chargers, menu-bar layout
  internal/energy/        energy integration, history store, CSV/JSON export
  internal/product/       transport-neutral charger model
  internal/app/           AppState, bindings, windows, tray, settings
  web/                    frontend: HTML/CSS/ES modules, no build step
  .devrun/                one-time dev bridge used by the coding agent for screenshots
```

## Development notes

* The app's Go ↔ JS contract is `docs/port/contract.md`; specs used for the port (protocol,
  UI, mygo, BLE) are in `docs/port/`.
* `mygo` is consumed through `replace github.com/egoist/mygo => ../mygo` (the checkout this port
  was built against, mygo 0.7.1). That checkout carries one local Windows fix the port needs:
  `internal/windows/webview.go` `resizeWebView()` divides the client rect by the window's DPI
  scale before `ICoreWebView2Controller::put_Bounds`, because the WebView2 bounds API takes
  device-independent pixels while `GetClientRect` returns physical ones — without it the page is
  laid out at twice the window width on a 200 % display (the right half is clipped). If you build
  against upstream mygo, re-apply that fix or the window renders zoomed on high-DPI screens.
* The main window sizes itself in physical pixels (`spec` sizes × display scale factor, clamped
  to the work area) for the same reason; see `internal/app/window.go` `fitWindowToWorkArea`.
* Visual checks used headless Chromium screenshots (`charker-go/shots/`); see
  `tools/shot.mjs`, `tools/shot-run.mjs` and `tools/appshot.mjs` (the latter attaches to the
  running app's WebView2 over `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9222`).
* Known mygo 0.7.1 quirks on Windows: `Page.Eval`/`Window.CapturePage` deadlock, so the port
  reports page state through a bound method instead.

## Credits and licenses

This is a derivative work of [Charker](https://github.com/qzz0518/Charker) (MIT, © 2026
qzz0518). Charker's design, the A2687 protocol findings, the localization strings and the 3D
assets come from that project. The Go/Windows port itself is MIT licensed — see
[LICENSE](LICENSE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Charker is an independent project, not affiliated with Anker. Anker, Anker Prime are trademarks
of Anker Innovations. The product images/3D models are used only to identify the hardware this
app talks to.
