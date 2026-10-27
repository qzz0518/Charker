//go:build !windows

package app

import "runtime"

// osVersionText names the system for the diagnostics header (the browser
// dev server and tests run off Windows).
func osVersionText() string { return runtime.GOOS + "/" + runtime.GOARCH }
