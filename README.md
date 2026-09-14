<div align="center">
  <img src="Resources/Screenshots/app-icon-rounded.png" width="128" alt="Charker 图标" />
  <h1>Charker</h1>
  <p><strong>在 Mac 上查看 Anker Prime 160W 与 250W 的实时功率和能耗。</strong></p>
  <p>原生、轻量、本地优先的 macOS 伴侣应用。</p>
  <p>简体中文 · <a href="README_EN.md">English</a></p>
  <p>
    <a href="https://github.com/qzz0518/Charker/stargazers"><img src="https://img.shields.io/github/stars/qzz0518/Charker?style=flat-square" alt="GitHub Stars" /></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple" alt="macOS 14+" />
    <img src="https://img.shields.io/badge/Swift-6.0-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.0" />
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License" /></a>
    <a href="https://x.com/zerah_eth"><img src="https://img.shields.io/badge/follow-%40zerah__eth-111111?style=flat-square&logo=x&logoColor=white" alt="在 X 关注 @zerah_eth" /></a>
  </p>
</div>

<p align="center">
  <img src="Resources/Screenshots/overview.png" width="1100" alt="Charker 总览：实时功率、三维设备、端口状态与功率时间线" />
</p>

Charker 是一款面向 **Anker Prime 160W（A2687）** 与 **Anker Prime Charger 250W
（A2345）** 的非官方 macOS 应用。A2687 通过 CoreBluetooth 与 Mac 建立加密会话；A2345
则使用 Anker 账号发现已绑定设备，并通过加密 MQTT 会话订阅、主动请求只读 Wi-Fi 遥测。两种设备都能在
原生主窗口、菜单栏和本地能耗历史中查看，数据不会经过 Charker 服务器。

> [!IMPORTANT]
> Charker 是独立的互操作性项目，与 Anker 无关联、未获其背书。当前实机验证覆盖运行
> BLE 固件 `v0.0.5.2` 的 A2687。A2345 已在固件 `2.1.1.6`、JP 区账号上完成云端协议与
> 六口报文字段验证；Charker 的登录、订阅、固定只读请求与界面链路已实现，仍待实机端到端验收。

## 功能

- **实时总览**：A2687 显示三个 USB-C 口；A2345 显示 C1–C4、A1、A2 六个端口的
  电压、电流与功率。两种型号都有原生 3D 设备视图和功率时间线。
- **菜单栏监控**：无需保持主窗口打开，即可组合总功率、逐口功率、图标、分隔符和自定义文字。
- **能耗与电费**：按会话、今天、本周、本月或全部记录查看能量、峰值、平均功率、端口构成和负载分布；
  支持自定义币种与每度电价格、按当前维度清空，以及 CSV / JSON 导出。
- **设备与连接**：A2687 提供附近蓝牙设备列表；A2345 提供账号登录、钥匙串会话与
  Wi-Fi 云端状态。蓝牙连接成功后会停止持续扫描，避免设备密集环境下的无意义刷新。
- **设备控制**：A2687 支持端口开关与倒计时，并为会中断供电的操作提供确认、ACK 和状态回读；
  屏幕语言、亮度、自动锁屏、方向与自动旋转均已在验证固件上实测。A2345 当前严格只读，
  不显示未经验证的写入控件。
- **屏幕个性化**：可编辑数字孪生上的屏幕图片，并以实验功能推送到充电器的实体屏幕。
- **模拟充电器**：没有硬件也能分别体验 A2687 三端口与 A2345 六端口界面；模拟数据与真实历史隔离。
- **安全更新**：通过 Sparkle 检查并安装 EdDSA 签名的新版本，安装器仍受 macOS 沙盒与
  Developer ID 校验保护。
- **中英双语**：主界面、菜单栏、状态信息、权限说明和诊断提示均提供简体中文与 English。

## 快速开始

### 系统要求

- macOS 14 或更高版本
- Apple Silicon Mac（实机验证）；发行流水线会生成 Universal 2，Intel 真机蓝牙连接仍待验收
- 真实连接需要 Anker Prime 160W（A2687）或 Prime Charger 250W（A2345）；只体验界面时可使用模拟充电器

### Homebrew

```bash
brew install --cask qzz0518/tap/charker
```

后续更新使用：

```bash
brew upgrade --cask charker
```

### DMG 安装

前往 [Releases](https://github.com/qzz0518/Charker/releases) 下载页面列出的最新
`Charker-*.dmg`，打开后将 Charker 拖入 Applications。

Homebrew 与 Releases 使用同一份经过 Developer ID 签名和 Apple 公证的 Universal 2 DMG。

### 从源码构建

源码构建需要 Xcode Command Line Tools 与 Swift 6.0+：

```bash
git clone https://github.com/qzz0518/Charker.git
cd Charker
mise run verify
open dist/Charker.app
```

`mise run verify` 会依次构建、运行测试、检查中英文资源，并组装本地签名的
`dist/Charker.app`。不使用 mise 时可以直接运行：

```bash
swift test
CONFIG=release Scripts/make-app.sh
open dist/Charker.app
```

> [!NOTE]
> 请通过签名后的 `.app` 测试真实蓝牙。`swift run Charker` 适合界面与模拟模式开发，
> 但没有完整 App bundle、蓝牙用途说明和 entitlement，不能代表真实连接结果。

## 第一次连接

支持中国大陆手机号登录：选择「中国大陆（CN）」，输入已绑定设备的手机号，
点击「获取验证码」后填写短信验证码。其他地区仍使用邮箱和密码。手机号、验证码和密码
不保存；A2687 仅保存账号 ID，A2345 的登录令牌保存在 macOS 钥匙串。

### A2687 · 蓝牙

1. 给充电器通电，并完全退出手机上的 Anker App 或其他正在连接它的客户端。
2. 打开 Charker，按空状态页的指引前往「设备与连接」，在附近设备中选择充电器。
3. 如果固件要求绑定身份，在「Anker 账号 ID」中使用一次性获取，或手动填写自己的
   `user_id`。Charker 只保存这个 ID，不保存密码和登录令牌。
4. 没有充电器时，在连接指引或「高级」中启用「模拟充电器」。

A2687 同一时间只接受一个客户端，而且被其他客户端连接时可能完全停止广播。因此“搜不到”
通常不是蓝牙坏了，而是官方 App、另一台设备或另一个 Charker 实例仍占用连接。

### A2345 · Wi-Fi 云端只读

1. 先在官方 Anker App 中完成设备绑定与 Wi-Fi 配网。
2. 在 Charker 的「设备与连接」选择 A2345，并使用绑定设备的 Anker 账号登录；JP 账号选择 JP。
3. Charker 把短期访问令牌保存到 macOS 钥匙串；临时 MQTT 客户端证书与 RSA 私钥只在
   当前连接的内存中组成身份，断开后释放，不导入持久钥匙串。
4. 订阅建立后，Charker 只发送白名单内的两种读取请求：`0200` 请求 `0A00`
   六口全量快照，`020B` 触发 `0303` 实时帧。两者都不修改端口或设备设置。

退出账号会删除钥匙串令牌，但不会解除官方 App 中的绑定，也不会删除本地能耗历史。

## 已验证范围

| 能力 | 当前状态 | 边界 |
| --- | --- | --- |
| 三口实时遥测与加密会话 | 实机验证 | A2687 / BLE `v0.0.5.2` / macOS 15.7.7，约 1 Hz |
| 六口 Wi-Fi 遥测与 MQTT 订阅 | 协议与报文实机验证；App 链路待验收 | A2345 / 固件 `2.1.1.6` / JP 区账号；Charker 已实现 `0200`/`020B` 固定读取与 `0A00`/`0303` 解析；C1–C4 字段与缩放已逐口带载确认，A1/A2 仍待独立带载复核 |
| 屏幕语言、亮度、锁屏、方向、自动旋转 | 实机验证 | 亮度范围为 25%–100% |
| 端口开关与倒计时 | 已实现保护流程 | 会立即影响供电，仍应按自己的固件谨慎验证 |
| 自定义屏幕图片传输 | 实验功能 | 机内只有 4 个位置，没有删除命令；每次推送都会占用一个位置，直到被后续推送覆盖 |
| 模拟充电器 | 自动化测试覆盖 | 不连接蓝牙，不写入真实能耗记录 |
| A2345 写入控制 | 未开放 | 仅允许 `0200`/`020B` 固定读取；不对外暴露任意 MQTT PUBLISH 或端口、设置控制接口；`A8` 候选元数据也不对外展示 |

## 隐私与网络

| 数据 | Charker 的处理方式 |
| --- | --- |
| A2687 实时充电数据 | 仅通过本机蓝牙读取，在内存中解析 |
| A2345 实时充电数据 | 从 Anker MQTT 云端加密订阅读取，在内存中解析；不经过 Charker 服务器 |
| 能耗历史与偏好 | 仅保存在当前 Mac 的应用数据中 |
| Anker 账号 | 密码只用于登录请求且不落盘；A2687 只保存 `user_id`，A2345 的短期令牌存入 macOS 钥匙串 |
| MQTT 临时证书 | 仅驻留进程内存，断开连接后释放；仓库、偏好与诊断中都不保存 |
| 软件更新 | Sparkle 定期读取 GitHub Pages 上的签名 appcast，并仅从 GitHub Release 下载用户确认的新版本 |
| 诊断导出 | 默认隐藏序列号和蓝牙地址；原始报文记录必须由用户主动开启 |
| 分析与追踪 | 没有 Charker 服务器、分析 SDK 或遥测上报 |

应用中的 GitHub 与 X 按钮只会在默认浏览器打开对应页面。A2687 的监控与控制无需互联网；
A2345 的 Wi-Fi 遥测依赖 Anker 账号、Anker HTTP 接口与 MQTT 服务。

## 开发

项目使用 SwiftPM，常用任务已经写入 [`mise.toml`](mise.toml)：

| 命令 | 用途 |
| --- | --- |
| `mise run build` | 构建全部 target |
| `mise run test` | 运行协议与会话测试 |
| `mise run i18n` | 检查中英文键值与格式占位符 |
| `mise run release-config` | 检查 Sparkle、沙盒与发布元数据，不读取任何密钥 |
| `mise run bundle` | 组装并 ad-hoc 签名本地 App |
| `mise run bundle-universal` | 组装并 ad-hoc 签名 Universal 2 App |
| `mise run release-dry-run` | 用 Developer ID 生成未公证的 Universal 2 候选 DMG |
| `mise run release` | 从干净 tag 构建、签名、公证、staple 并生成签名 appcast |
| `mise run verify` | 构建、测试、检查本地化/发布配置并验证本机架构的开发 App |

```text
Sources/
├── A2687Protocol/  帧、TLV、加密握手、命令与遥测解码
├── A2345Protocol/  FF09 固定读取请求、六端口快照/实时遥测与版本解码
├── CharkerCore/    蓝牙/云端连接、会话、历史、偏好、诊断与模拟设备
├── CharkerApp/     SwiftUI / AppKit 界面与菜单栏
└── CharkerDraco/   3D 模型的 Draco 解码适配
Tests/              协议、会话、历史、设置与传输测试
```

本地 ad-hoc 构建每次改变二进制后，macOS 可能把它视为新的蓝牙授权主体。需要稳定的本地身份时：

```bash
Scripts/make-signing-identity.sh
IDENTITY="Charker Dev" CONFIG=release Scripts/make-app.sh
```

这仍是开发签名，不是公开发行所需的 Developer ID、Hardened Runtime、公证与 stapling 流程。

### 发行维护者

正式发行使用钥匙串中的 Developer ID 身份、`Charker-Notary` 公证凭据和 Sparkle EdDSA 私钥；
三者都不会写入仓库。`mise run release` 要求工作树干净，且 `HEAD` 已有与版本一致的 tag。
流水线会先公证并 staple App 本体，再封装、签名、公证并 staple DMG。最终同一个 DMG 会
同时用于 GitHub Release、Sparkle 和 Homebrew Cask，避免不同渠道的字节与校验值漂移。

## 参与项目

欢迎提交 Issue 和 Pull Request。涉及协议或真实设备行为的改动，请同时注明设备型号、BLE 固件版本、
复现步骤与脱敏后的诊断证据；不要上传账号 ID、完整序列号、蓝牙地址、密钥或原始私人抓包。

- [报告问题](https://github.com/qzz0518/Charker/issues)
- [查看源码](https://github.com/qzz0518/Charker)
- [在 X 关注 @zerah_eth](https://x.com/zerah_eth)

## 致谢

协议事实与测试向量参考了以下公开项目，Charker 的 Swift 实现为独立编写：

- [flip-dots/SolixBLE](https://github.com/flip-dots/SolixBLE)
- [Hyper-Beast/Anker_Prime_160W_WebBLE](https://github.com/Hyper-Beast/Anker_Prime_160W_WebBLE)
- [atc1441/Anker_Prime_BLE_hacking](https://github.com/atc1441/Anker_Prime_BLE_hacking)
- [thomluther/anker-solix-api](https://github.com/thomluther/anker-solix-api)

完整来源、版本与许可证说明见 [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。

## 许可证

项目自行编写的代码以 [MIT License](LICENSE) 发布。Anker 商标、产品图片、3D 模型及其他第三方材料
不因此转换为 MIT 许可，其权利归各自权利人所有，详见
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。
