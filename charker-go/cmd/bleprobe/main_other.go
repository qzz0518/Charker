//go:build !windows

// Command bleprobe is the hardware acceptance tool for the Windows BLE
// transport. Bluetooth LE central mode is only implemented on Windows; on other
// platforms the command exists so `go build ./...` passes and says so.
package main

import (
	"fmt"
	"os"
	"runtime"
)

func main() {
	fmt.Fprintf(os.Stderr, "bleprobe: Bluetooth LE is only implemented on Windows (this is %s/%s)\n", runtime.GOOS, runtime.GOARCH)
	os.Exit(2)
}
