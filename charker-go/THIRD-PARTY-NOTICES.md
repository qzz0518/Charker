# Third-Party Notices

Charker for Windows is released under the MIT license (see `LICENSE`). It is a derivative work
of **Charker** (<https://github.com/qzz0518/Charker>, MIT, © 2026 qzz0518): the design, the
A2687 protocol findings, the localization strings and the 3D/UI assets originate there.

## Runtime libraries bundled in the binary

| Component | Version / source | License |
|---|---|---|
| MyGo (desktop framework) | <https://github.com/egoist/mygo> 0.7.1 | MIT |
| purego | <https://github.com/ebitengine/purego> v0.11.1 | Apache License 2.0 |
| tinygo.org/x/bluetooth (Windows WinRT BLE) | `v0.16.1-0.20261027103605-831ad63d251f` | BSD-3-Clause (Copyright © TinyGo Authors) |
| saltosystems/winrt-go | `v0.0.0-20261015065339-8ef619c103a3` | MIT |
| go-ole/go-ole | v1.2.6 | MIT |
| sirupsen/logrus | v1.9.3 | MIT |
| godbus/dbus/v5 | v5.1.0 | BSD-2-Clause |
| golang.org/x/{net,sys,text,image,exp} | — | BSD-3-Clause |

Full license texts are in the Go module cache (`go mod download`); the binary statically links
these modules, and their notices are reproduced here by reference.

## Frontend

| Component | Version / source | License |
|---|---|---|
| three.js | r180, <https://threejs.org> | MIT (Copyright © 2010-2025 three.js authors) |
| Draco 3D decoder | <https://github.com/google/draco> | Apache License 2.0 |
| Lucide icons (paths adapted) | <https://lucide.dev> | ISC |
| Segoe UI Variable / Microsoft YaHei UI | Windows system fonts | Microsoft font license (not redistributed) |

three.js and the Draco decoder are vendored under `web/vendor/three/`; their license files are
kept next to the sources.

## Assets and trademarks

- The A2687 3D model (`A2687.glb`), product render (`A2687.webp`, stored as PNG), and the A2345
  assets are from the Anker official product pages, as documented by the Charker project
  (`Resources/Model3D/`). Copyright © Anker Innovations; used only to identify and display the
  hardware this app controls.
- `Anker.svg` is the Anker wordmark, also from Anker Innovations. `GitHub.svg` / `X.svg` are
  brand icons of their owners. Their use identifies a service, not an endorsement.
- The app icon comes from Charker (`Resources/AppIcon.png`).
- Anker, Anker Prime and Anker Innovations are trademarks of Anker Innovations. This project is
  not affiliated with, endorsed by, or sponsored by Anker.

## Protocol references

Charker's A2687 implementation is independent but was informed by these community projects
(listed in Charker's notices): `flip-dots/SolixBLE` (MIT), `Hyper-Beast/Anker_Prime_160W_WebBLE`
(protocol facts only), `atc1441/Anker_Prime_BLE_hacking` (background only), and
`thomluther/anker-solix-api`. Only protocol facts (UUIDs, opcodes, byte layouts) were used.

## WebView2

The app renders its UI with the Microsoft Edge WebView2 runtime, which is a Microsoft
component distributed with Windows and not bundled here.
