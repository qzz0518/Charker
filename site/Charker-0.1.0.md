<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
<p align="center">
  <img src="https://raw.githubusercontent.com/qzz0518/Charker/main/Resources/Screenshots/app-icon-rounded.png" width="96" alt="Charker icon" />
</p>

<h2 align="center">Charker</h2>
<p align="center">把 Anker Prime 160W 的实时功率、能耗记录和设备控制带到 Mac。</p>

## 更新日志

1. **原生实时总览**：通过加密 CoreBluetooth 会话读取 C1 / C2 / C3 的电压、电流、功率、线材能力与充电协议，并用三维数字孪生和功率时间线集中展示。
2. **完整能耗记录**：按会话、今天、本周、本月或全部历史查看能量、峰值、平均功率、端口构成与负载分布，支持电价估算、分维度清空及 CSV / JSON 导出。
3. **菜单栏监控与设备控制**：可自定义菜单栏读数，控制端口开关和倒计时；屏幕语言、亮度、自动锁屏、方向和自动旋转均已在验证固件上实测。
4. **更可靠的连接体验**：提供首次连接指引、记住与重新连接；成功连接后停止持续扫描，避免蓝牙设备密集环境中的页面卡顿。
5. **无硬件也能体验**：模拟充电器覆盖实时数据、端口状态、能耗历史与控制流程，并与真实历史隔离。
6. **安全分发**：Universal 2 应用与 DMG 均已完成 Developer ID 签名、Apple 公证和票据装订，并提供 Sparkle EdDSA 签名更新源。

## Changelog

1. **Native live overview**: encrypted CoreBluetooth telemetry for C1 / C2 / C3, including voltage, current, power, cable capability, and charging protocol, presented through a 3D digital twin and power timeline.
2. **Complete energy history**: sessions, today, this week, this month, or all history with energy, peak and average power, port composition, load distribution, electricity-cost estimates, scoped clearing, and CSV / JSON export.
3. **Menu bar monitoring and controls**: customizable menu bar readings, port output, and shutdown timers. Display language, brightness, auto-lock, orientation, and auto-rotation are hardware-verified on the tested firmware.
4. **More reliable connection flow**: first-run guidance, remembering, and reconnecting. Scanning stops after connection to prevent UI churn in busy Bluetooth environments.
5. **Try it without hardware**: the simulated charger exercises live telemetry, port states, energy history, and controls without mixing data into real history.
6. **Secure distribution**: the Universal 2 app and DMG are Developer ID-signed, Apple-notarized, and stapled, with an EdDSA-signed Sparkle update feed.

## 安装 / Install

### Homebrew

```bash
brew install --cask qzz0518/tap/charker
```

### DMG

下载下方的 `Charker-0.1.0.dmg`，打开后将 Charker 拖入 Applications。

Download `Charker-0.1.0.dmg` below, open it, and drag Charker into Applications.

### 从临时预览包更新 / Updating from the temporary preview

如果你已通过 Homebrew 安装过公证完成前的 `v0.1.0` 预览包，请执行一次：

```console
brew update
brew reinstall --cask qzz0518/tap/charker
```

If you installed the `v0.1.0` preview through Homebrew before notarization completed, run the commands
above once to replace it with the final build.

## 兼容性 / Compatibility

- macOS 14 或更高版本 / macOS 14 or later
- Universal 2（Apple Silicon + Intel）；Intel 真机蓝牙连接仍待验收
- 已在 Anker Prime 160W（A2687）、BLE 固件 `v0.0.5.2` 上完成实机验证
- Universal 2 (Apple Silicon + Intel); real Bluetooth use on Intel remains unverified
- Hardware-verified with Anker Prime 160W (A2687), BLE firmware `v0.0.5.2`

> [!IMPORTANT]
> Charker 是独立的互操作性项目，与 Anker 无关联、未获其背书。
> Charker is an independent interoperability project and is not affiliated with or endorsed by Anker.

## SHA-256

```text
661b7e0bb734971ab11e3a797ba1598383f4d266382fbcd4ec7fe88fdde0964a  Charker-0.1.0.dmg
```

## Thanks

协议研究与测试向量参考了 [SolixBLE](https://github.com/flip-dots/SolixBLE)、
[Anker Prime 160W WebBLE](https://github.com/Hyper-Beast/Anker_Prime_160W_WebBLE)、
[Anker Prime BLE hacking](https://github.com/atc1441/Anker_Prime_BLE_hacking) 和
[anker-solix-api](https://github.com/thomluther/anker-solix-api)。感谢这些项目的公开工作。
