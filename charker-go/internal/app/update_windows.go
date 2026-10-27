//go:build windows

package app

import (
	"time"

	"golang.org/x/sys/windows"
)

// waitForExit waits for process pid to end, at most timeout.
func waitForExit(pid int, timeout time.Duration) {
	h, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(pid))
	if err != nil {
		return // already gone
	}
	defer windows.CloseHandle(h)
	windows.WaitForSingleObject(h, uint32(timeout/time.Millisecond))
}
