//go:build windows

package matter

import (
	"os/exec"
	"syscall"
)

const helperName = "charker-matter.exe"

// createNoWindow keeps the console helper from getting a console window of
// its own when the app is a GUI exe.
const createNoWindow = 0x08000000

func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
}
