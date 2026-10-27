# Charker for Windows

Charker 的 Windows 版。界面、协议和功能与 macOS 版保持一致，版本号也与 macOS 版同步。
用 Go 和 [MyGo](https://github.com/egoist/mygo) 编写，界面在系统自带的 WebView2 里渲染，
蓝牙走 WinRT。

支持 Anker Prime 160W（A2687，蓝牙直连）和 Anker Prime 250W（A2345，Wi-Fi 云端），
也能把充电器接入 Apple 家庭。需要 Windows 10/11；A2687 需要电脑支持低功耗蓝牙。

## 构建

需要 Go 1.27 或更新版本。在 Windows 上：

```powershell
cd charker-go
.\build.ps1                 # 开发版 build\charker-dev.exe（带控制台和调试工具）
.\build.ps1 -Mode release   # 发布版，用 mygo build 生成 build\windows-amd64\
```

两种都会先用 cargo 构建 Apple 家庭辅助进程 `../Matter`（`charker-matter.exe`）；需要 rustup 和
MSVC 工具链，开发版没有的话加 `-SkipMatter`（交叉编译的办法见 `build.ps1` 开头）。

版本号取自 `../Resources/Info.plist` 的 `CFBundleShortVersionString`，发 macOS 版时改那一处即可。

## 发布

发布版用 MyGo 打包（配置在 `mygo.config.ts`），在 macOS 上也能做（需要 `brew install makensis`）：

```sh
CHARKER_MATTER_EXE=<交叉编译好的 charker-matter.exe> go tool mygo build -platform windows/amd64
```

`build/windows-amd64/` 里会有：

- `charker-setup-<版本>-amd64.exe`：安装包，装到 `%LOCALAPPDATA%\Programs\Charker`，不需要管理员权限；
  `charker-matter.exe` 和许可证随程序一起装进去
- `charker-<版本>-windows-amd64.tar.gz` 和 `update-windows-amd64.json`：应用内更新用的签名包和清单
- `install.ps1`、`../SHA256SUMS`

这些文件都上传到和 macOS 版同一个 GitHub Release（`v<版本>`）。应用内更新读的是最新 Release 里的
`update-windows-amd64.json`，所以每次发版都要带上 Windows 的这几个文件，否则 Windows 版检查更新会失败。

签更新包的私钥由 `go tool mygo keygen` 生成，在发版 Mac 的
`~/Library/Application Support/mygo/update-keys/charker/`，别处用环境变量 `MYGO_UPDATER_PRIVATE_KEY` 提供。
丢了私钥，已安装的版本就再也收不到更新。

## 数据位置

- 偏好设置、已保存的充电器、能耗记录：`%APPDATA%\Charker`
- WebView2 配置和日志 `charker.log`：`%LOCALAPPDATA%\Charker`

## 开发

```sh
go test ./...
go run ./cmd/webdev            # 在浏览器里调页面：http://127.0.0.1:8765/
bun tools/shot.ts out.png dashboard   # 无头截图，对照 macOS 版
go run ./tools/l10n            # 从 macOS 版的 en.lproj 重新生成 web/l10n/en.json
```

`cmd/webdev` 跑的是同一套 App 层和模拟充电器，只是把页面交给普通浏览器，改完页面刷新即可。

| 目录 | 内容 |
|---|---|
| `internal/a2687` | A2687 协议：帧、TLV、握手加密、遥测、控制命令（对应 `Sources/A2687Protocol`） |
| `internal/session` | 连接引擎：扫描、握手、轮询、重连、写入 |
| `internal/transport` | 蓝牙传输：`winble`（WinRT）和 `mock`（演示设备） |
| `internal/energy` | 能耗记录 |
| `internal/matter` | Apple 家庭：启动 `charker-matter.exe` 并对接它的行协议（对应 `MatterService.swift`、`MatterAccessory.swift`） |
| `internal/prefs` | 偏好设置和已保存的充电器 |
| `internal/app` | 窗口、托盘、页面调用的服务 |
| `web/` | 页面（Preact + htm，无构建步骤），文案取自 macOS 版的本地化表 |
