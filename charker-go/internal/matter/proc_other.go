//go:build !windows

package matter

import "os/exec"

const helperName = "charker-matter"

func hideWindow(*exec.Cmd) {}
