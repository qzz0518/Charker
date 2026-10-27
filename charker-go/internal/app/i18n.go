package app

// The shell produces a handful of user-facing strings itself (tray menu,
// toasts, notices) before a page exists. Pages localize everything through
// t()/strings.js; these are the Go-side twins, chosen by the app locale.

type translated struct {
	zh, en string
}

var (
	textDeviceLost   = translated{"连接已断开", "Connection lost"}
	textChargerError = translated{"充电器错误：%s", "Charger error: %s"}
	textScanFailed   = translated{"扫描失败：%s", "Scan failed: %s"}
	textExportDone   = translated{"已导出到 %s", "Exported to %s"}
	textExportFailed = translated{"导出失败：%s", "Export failed: %s"}
	textExportTitle  = translated{"导出能耗数据", "Export energy data"}

	// The tray's context menu (StatusItemController.showMenu).
	textTrayShow = translated{"打开 Charker", "Open Charker"}
	textTrayDemo = translated{"演示模式", "Demo Mode"}
	textTrayQuit = translated{"退出", "Quit"}

	// SessionPhase.shortLabel, and the words of StatusTemplate.offlineTitle.
	textStateIdle       = translated{"未启动", "Not Started"}
	textStateScan       = translated{"搜索中", "Searching"}
	textStateConnecting = translated{"连接中", "Connecting"}
	textStateHandshake  = translated{"握手中", "Setting Up"}
	textStateConn       = translated{"已连接", "Connected"}
	textStateLink       = translated{"重连中", "Reconnecting"}
	textStateError      = translated{"出错", "Error"}
	textStateFail       = translated{"离线", "Offline"}

	// Built-in copy of menu bar items (MenuBarItem.SystemContent).
	textPortsActive = translated{"%d 口", "%d active"}
	textSampleText  = translated{"文本", "Text"}

	// Settings pages (service_settings.go).
	textDiagnosticsSaved = translated{"诊断已保存", "Diagnostics Saved"}
	textDiagnosticsName  = translated{"charker-诊断.txt", "charker-diagnostics.txt"}
	textDiagnosticsTitle = translated{"导出诊断…", "Export Diagnostics…"}
	textDiagnosticsHead  = translated{"Charker 诊断报告", "Charker Diagnostics Report"}
	textLoginFailed      = translated{"无法设置登录时启动：%s", "Couldn’t change Launch at Login: %s"}
	textWritesOff        = translated{"请在「高级」中允许端口开关", "Allow port switching in Advanced first"}
)

// tr resolves one translated string for the current UI locale.
func (a *App) tr(t translated) string {
	if a.locale() == "en" {
		return t.en
	}
	return t.zh
}
