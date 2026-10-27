package app

import (
	"context"
	"fmt"
	"log"
	"regexp"
	"strconv"
	"strings"

	"github.com/egoist/mygo"
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

// The About page's links, and the release pages an update check offers.
const (
	githubURL   = "https://github.com/qzz0518/Charker"
	xURL        = "https://x.com/zerah_eth"
	releasesAPI = "https://api.github.com/repos/qzz0518/Charker/releases?per_page=30"
)

func externalURLAllowed(url string) bool {
	return url == githubURL || url == xURL || strings.HasPrefix(url, githubURL+"/releases/")
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

// UpdateCheck is the answer of CheckForUpdates.
type UpdateCheck struct {
	// Current is the running version; Latest the newest Windows release
	// ("" when there is none yet).
	Current string `json:"current"`
	Latest  string `json:"latest"`
	// Available is true when Latest is newer than Current.
	Available bool `json:"available"`
	// URL is the release page to download Latest from.
	URL string `json:"url"`
}

// CheckForUpdates asks GitHub for the newest release that ships the
// Windows archive. The repository's releases are shared with the macOS app.
func (s *Charker) CheckForUpdates(ctx context.Context) (UpdateCheck, error) {
	check := UpdateCheck{Current: s.app.version}
	latest, available, err := s.app.checkForUpdate(ctx)
	if err != nil {
		return check, err
	}
	check.Latest = latest.version
	check.Available = available
	check.URL = latest.page
	if !externalURLAllowed(check.URL) {
		check.URL = githubURL + "/releases"
	}
	return check, nil
}

// InstallUpdate downloads the newest release, checks its signature, puts
// it in place and restarts Charker.
func (s *Charker) InstallUpdate(ctx context.Context) (any, error) {
	return nil, s.app.installUpdate(context.WithoutCancel(ctx))
}

type githubRelease struct {
	TagName    string `json:"tag_name"`
	HTMLURL    string `json:"html_url"`
	Draft      bool   `json:"draft"`
	Prerelease bool   `json:"prerelease"`
	Assets     []struct {
		Name string `json:"name"`
		URL  string `json:"browser_download_url"`
	} `json:"assets"`
}

var versionPattern = regexp.MustCompile(`^v?(\d+)\.(\d+)(?:\.(\d+))?`)

// parseVersion reads "v1.2.3" / "1.2" as [1 2 3]; nil when it is none.
func parseVersion(v string) []int {
	m := versionPattern.FindStringSubmatch(strings.TrimSpace(v))
	if m == nil {
		return nil
	}
	out := make([]int, 3)
	for i := range 3 {
		out[i], _ = strconv.Atoi(m[i+1])
	}
	return out
}

// versionNewer reports whether a is a higher version than b. A version that
// does not parse (a dev build) is older than any release.
func versionNewer(a, b string) bool {
	va, vb := parseVersion(a), parseVersion(b)
	if va == nil {
		return false
	}
	if vb == nil {
		return true
	}
	for i := range va {
		if va[i] != vb[i] {
			return va[i] > vb[i]
		}
	}
	return false
}
