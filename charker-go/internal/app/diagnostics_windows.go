package app

import (
	"fmt"

	"golang.org/x/sys/windows"
)

// osVersionText is the Windows version for the diagnostics header, as the
// Mac report carries ProcessInfo.operatingSystemVersionString.
func osVersionText() string {
	v := windows.RtlGetVersion()
	return fmt.Sprintf("Windows %d.%d (build %d)", v.MajorVersion, v.MinorVersion, v.BuildNumber)
}
