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

	textTrayShow    = translated{"显示主窗口", "Show Charker"}
	textTrayHide    = translated{"隐藏主窗口", "Hide Charker"}
	textTrayQuit    = translated{"退出 Charker", "Quit Charker"}
	textTrayStatus  = translated{"Charker", "Charker"}
	textStateIdle   = translated{"未连接", "Not connected"}
	textStateScan   = translated{"搜索中", "Searching"}
	textStateLink   = translated{"重连中", "Reconnecting"}
	textStateFail   = translated{"离线", "Offline"}
	textStateCharge = translated{"充电中", "Charging"}
	textStateConn   = translated{"已连接", "Connected"}
	textNoDevice    = translated{"未连接充电器", "No charger connected"}
	textWritesOff   = translated{"请在「高级」中允许端口开关", "Allow port switching in Advanced first"}
)

// tr resolves one translated string for the current UI locale.
func (a *App) tr(t translated) string {
	a.mu.Lock()
	en := a.settings.Locale == "en"
	a.mu.Unlock()
	if en {
		return t.en
	}
	return t.zh
}
