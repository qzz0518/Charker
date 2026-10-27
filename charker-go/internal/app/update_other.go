//go:build !windows

package app

import "time"

// waitForExit only matters where the app installs updates (Windows).
func waitForExit(int, time.Duration) {}
