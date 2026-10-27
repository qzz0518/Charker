//go:build !charkerdev

package main

// Release builds write their log to %LOCALAPPDATA%\\Charker\\charker.log;
// -H=windowsgui means there is no console to print to, and mygo.App.Path may not
// be usable this early in main, so the directory is resolved directly.
// The dev-only hooks (auto-quit, screenshot, mock switch, page diagnostics) are
// compiled out.

import (
	"os"
	"path/filepath"
	"time"

	"github.com/egoist/mygo"
)

// logFile opens charker.log in the app's log directory, truncating it for this
// run. It returns nil when no directory is writable.
func logFile() *os.File {
	dirs := []string{}
	if dir, err := os.UserCacheDir(); err == nil {
		dirs = append(dirs, filepath.Join(dir, "Charker"))
	}
	if dir, err := os.UserConfigDir(); err == nil {
		dirs = append(dirs, filepath.Join(dir, "Charker"))
	}
	dirs = append(dirs, os.TempDir())
	for _, dir := range dirs {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			continue
		}
		f, err := os.OpenFile(filepath.Join(dir, "charker.log"), os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
		if err != nil {
			continue
		}
		return f
	}
	return nil
}

// logPath is where logFile tries to write, for the error dialog when the page
// never loads.
func logPath() string {
	dir, err := os.UserCacheDir()
	if err != nil {
		dir = os.TempDir()
	}
	return filepath.Join(dir, "Charker", "charker.log")
}

func devAutoQuit() time.Duration { return 0 }

func devForceMock() bool { return false }

func devScreenshot(path string) bool { return false }

func devPreloadScript() string { return "" }

var _ = mygo.Version
