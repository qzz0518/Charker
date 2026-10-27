# Porting the macOS views to charker-go

The Windows app is a translation of the macOS app, not a redesign. Every page
is the SwiftUI view under `../Sources/CharkerApp/Views/` (and the helpers it
uses under `Design/` and `../Sources/CharkerCore/`) rewritten as Preact + htm
components. Same layout, same spacing and type steps, same copy, same states,
same behaviour. Both products are in scope — Anker Prime 160W (A2687, BLE)
and Anker Prime 250W (A2345, Wi-Fi cloud) — and so is Apple Home. Only what
Windows has no counterpart for is left out (Dock icon, Sparkle); the menu bar
became the Taskbar page and the tray (live wattage in the icon, the item
layout as its tooltip, a flyout). Never write "not supported on Windows" copy.

## Layout of the code

```
main.go, dev.go, release.go   process entry; dev build = -tags charkerdev
internal/a2687                A2687 protocol (port of Sources/A2687Protocol)
internal/session              BLE session engine; Snapshot, Telemetry, HistorySample
internal/transport/{mock,winble}  simulated charger (plays the Mac demo script) / Windows BLE
internal/prefs                Preferences (mirrors CharkerCore/Preferences.swift), saved chargers
internal/energy               energy ledger
internal/app                  AppState, the bound "Charker" service, window and tray
cmd/webdev                    browser dev server (see below)
web/index.html                loads css/*.css and js/main.js
web/js/lib.js                 Preact + hooks + htm (vendored, no build step)
web/js/core/l10n.js           t('中文原串'), tf('%@ …', args)  == L10n.text / L10n.format
web/js/core/store.js          useStore(), call(), setPrefs(), selectSection(), setActionMessage()
web/js/core/model.js          SessionPhase labels, port predicates/texts, sessionStats, PowerChartScale
web/js/ui/components.js       SlateCard, Chip, StateDot, PowerRail, TotalReadout, ConnectionLadder,
                              CopyIconButton, ActionButton, Segmented, Toggle, MenuButton/openMenu,
                              confirmDialog, Icon (SF Symbol names -> icons.js)
web/js/ui/icons.js            inline SVG registry; registerIcons({...}) for page glyphs
web/js/main.js                RootView: sidebar, routing, action message
web/js/pages/<page>.js        one module per section, default export = page component({state})
web/css/base.css              Theme.swift tokens (--c-*, --s-*, --r-*), .t-* type steps, shared controls
web/css/<page>.css            page styles
web/l10n/en.json              generated from the Mac .strings (go run ./tools/l10n) — do not edit
web/l10n/windows/<page>.json  English for strings only the Windows app has
```

## AppState (what `state` holds)

`internal/app/types.go`. In JS: `const [state, ui] = useStore()` or the
`state` prop of a page.

- `state.app`: `version`, `locale` ("zh"/"en"), `platform`, `demo`, `product`
  ("A2687"/"A2345", AppModel.activeProduct: `demoProduct` in demo mode, else
  `connectionMode` "cloud" → A2345). In JS use `activeProduct(state)` from
  `core/model.js` ({id, displayName, ports, ratedWatts}); never hard-code three
  ports where Swift uses `product.ports`. Persisted per-port data uses the six
  slots C1 C2 C3 C4 A1 A2 (`PORT_SLOTS`, ChargerPortID raw values).
- `state.prefs`: `prefs.Preferences` — same keys as the Swift `Preferences`
  (`decimals`, `hideIdlePorts`, `showIconOnly`, `compactMenuBar`,
  `menuBarItems` (raw JSON), `showsMenuBarIcon`, `menuBarIconSymbol`,
  `launchAtLogin`, `demoMode`, `pollSeconds`, `writesEnabled`,
  `captureRawPayloads`, `lastSection`, `dashboardEnergyScope`,
  `a2687PowerChartMaximum`, `energyCurrencyCode`, `energyPricePerKWh`,
  `modelHomeCamera`, `modelScreenStyle`, `modelScreenCustomSlot`,
  `portNicknames` [6], `appearance`, `locale`, `demoProduct`,
  `connectionMode`, `a2345SelectedSerial`, `matterEnabled`,
  `a2345PowerChartMaximum`, `a2345ModelHomeCamera`). Change them with
  `setPrefs({key: value})`; Go normalizes, saves and applies side effects.
- `state.savedChargers`: `[{id, nickname, serialNumber, lastConnectedAt, name, address, product}]`.
- `state.session` (the Swift `SessionSnapshot`): `phase` (idle, scanning,
  connecting, handshake, polling = monitoring, reconnecting, failed), `stage`,
  `attempt`, `scanning`, `isStale`, `writesEnabled`, `lastError`, `warning`,
  `device` ({id, name, address, rssi, connected, saved, mock, productName,
  firmware, serial, mac}), `nearby` [devices], `telemetry`, `history`,
  `connectedAtMs`.
- `state.session.telemetry`: `{receivedAtMs, ports: [{port: "C1", statusCode,
  voltage, current, power, cableCode, cableLabel, profileCode, profileLabel,
  control: {switchStatus, countdownTaskStatus, countdownTotal,
  countdownRemaining, running}, device: {vendorId, productId, noIdentity}}],
  settings: {screenTimeout, screenBrightness, chargingMode, screenOrientation,
  gyroscopeEnabled}}` — raw codes as the Swift `PortTelemetry` /
  `DeviceSettings` carry them; use `core/model.js` for the derived values.
- `state.session.history`: `[{t, total, perPort: [c1, c2, c3]}]`, decimated to ~180.
- `state.energy`: `{hasActiveSession, ephemeral, revision, product, ports,
  scopes: {session|day|week|month: {wh, cost|null, currency, perPort}}}`.
- `state.devices`: the devices page's AppModel state (service_devices.go).

Calls (`call('Method', ...args)`, `internal/app/service*.go`): `State`,
`SetPrefs`, `Scan`, `StopScan`, `Connect(id)`, `Disconnect`, `Reconnect`,
`SetPortEnabled(port, on)`, `SetPortTimer(port, seconds)` (0 cancels),
`SetChargerSetting(key, value)`, `EnergyReport(range)`, `ExportEnergy(format)`,
`EndEnergySession`, `ClearEnergyHistoryIn(scope)`, and the page services in
`service_devices.go` / `service_settings.go` / `service_energy.go`.
Demo mode is `setPrefs({demoMode: true|false})`.

## Rules

1. Translate, don't design. Open the Swift view, go top to bottom, and write
   the same structure. Keep Swift's numbers: `Space.l` is `var(--s-l)` (16px),
   `Typo.caption` is `.t-caption`, `Radius.card` is `var(--r-card)`. One pt
   on macOS is one CSS px here.
2. Copy is the Mac's Chinese source string, passed through `t()`/`tf()`
   exactly as the Swift `L10n.text`/`L10n.format` key (that is what makes the
   English table hit). A string only the Windows app has goes in
   `l10n/windows/<page>.json` as `"中文": "English"`. No explanatory filler
   the Mac app doesn't have.
3. Behaviour too: confirmation dialogs, disabled states, help tooltips
   (`title=`), hover states, what happens in demo mode, empty/disconnected/
   stale states. Read the Swift for every `if`.
4. Missing data or calls: add them in Go. Put new bound methods in
   `internal/app/service_<page>.go` (methods on `*Charker`), not in
   `service.go`. Do not edit files another page owns (see the brief you were
   given).
5. Icons: SF Symbol names go through `Icon` (`components.js` maps them). A
   glyph the registry lacks: `registerIcons()` from your page module, Lucide
   style (ISC), never SF Symbols artwork.
6. Charts and the 3D stage are canvas/SVG/three.js; draw them to match the
   Swift Charts/SceneKit output in the reference screenshots.

## Dev loop (no window, no focus stealing)

```sh
GOTOOLCHAIN=go1.27.3 go run ./cmd/webdev -addr 127.0.0.1:<port> &   # leave running; restart after Go changes
bun tools/shot.ts /path/out.png <section> --port <port> [--size 969x840] [--theme light]
     [--click '<css>'] [--eval '<js>']   # interactions, in order
```

Sections: `dashboard`, `energy`, `devices`, `menuBar`, `advanced`, `about`.
Page JS/CSS edits need only a new shot; Go edits need the server restarted.
The server runs the same app layer on the simulated charger in a fresh data
directory each start. Page console errors are printed by `shot.ts`.

The macOS reference screenshots (demo mode, dark, 969 px wide, 2x) are in the
scratchpad given in your brief. Compare yours side by side at the same size
until they match. Do not launch the Mac app or GUI windows yourself, and do
not use the Windows machine; the lead verifies on Windows.

Check: `GOTOOLCHAIN=go1.27.3 go vet ./... && go test ./...` and
`GOOS=windows go vet ./...` pass.
