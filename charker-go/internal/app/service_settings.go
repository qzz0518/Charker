package app

import (
	"context"
	"fmt"
	"log"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/plugins/updater"
)

// Calls of the 菜单栏 / 高级 / 关于 pages and of the tray flyout.

// ShowMainWindow brings the main window forward and closes the tray flyout
// (the popover's 打开主窗口).
func (s *Charker) ShowMainWindow() (any, error) {
	if !mygo.App.IsReady() {
		return nil, nil
	}
	s.app.showMainWindow()
	s.app.closeTrayPanel()
	return nil, nil
}

// TrayIconPreview is the tray icon as the taskbar shows it now, for the
// taskbar page's preview.
func (s *Charker) TrayIconPreview() (TrayPreview, error) { return s.app.trayPreview(), nil }

// Quit quits Charker; the charger keeps its output.
func (s *Charker) Quit() (any, error) {
	if !mygo.App.IsReady() {
		log.Printf("app: quit needs the Windows host")
		return nil, nil
	}
	s.app.quit()
	return nil, nil
}

// OpenExternal opens one of the About page's links in the browser.
func (s *Charker) OpenExternal(url string) (any, error) {
	if !externalURLAllowed(url) {
		return nil, fmt.Errorf("open: %q is not a Charker link", url)
	}
	if !mygo.App.IsReady() {
		log.Printf("app: open %s needs the Windows host", url)
		return nil, nil
	}
	return nil, mygo.Shell.OpenExternal(url)
}

// The About page's links.
const (
	githubURL = "https://github.com/qzz0518/Charker"
	xURL      = "https://x.com/zerah_eth"
)

func externalURLAllowed(url string) bool {
	return url == githubURL || url == xURL
}

// RefreshLaunchAtLogin reads whether Windows still starts Charker at login
// (Task Manager can turn the Run entry off) into the preference, as the
// Advanced page refreshes the login item status when it appears.
func (s *Charker) RefreshLaunchAtLogin() (any, error) {
	if !mygo.App.IsReady() {
		return nil, nil
	}
	on := mygo.App.OpenAtLogin()
	a := s.app
	a.mu.Lock()
	changed := a.prefs.LaunchAtLogin != on
	a.prefs.LaunchAtLogin = on
	a.mu.Unlock()
	if changed {
		a.savePrefs()
		a.publishNow()
	}
	return nil, nil
}

// ExportDiagnostics saves the diagnostics report through a Save dialog and
// returns the path, or "" when the user canceled.
func (s *Charker) ExportDiagnostics(ctx context.Context) (string, error) {
	return s.app.exportDiagnostics(ctx)
}

// RevealDiagnosticsLog shows the app log in File Explorer.
func (s *Charker) RevealDiagnosticsLog() (any, error) {
	return nil, s.app.revealDiagnosticsLog()
}

// CheckForUpdates opens MyGo's update window, which checks at once and
// says what it found. Development builds say they do not update.
func (s *Charker) CheckForUpdates() (any, error) {
	if mygo.App.IsReady() {
		updater.CheckForUpdates()
	}
	return nil, nil
}
