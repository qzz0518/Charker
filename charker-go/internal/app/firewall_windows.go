//go:build windows

package app

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"syscall"
	"unicode/utf16"
)

// Windows Firewall and the Matter helper. The first time a program listens,
// Windows asks with a security alert; Cancel there leaves inbound block
// rules behind, after which Home can find the charger but never reach it.
// The app asks first instead: one UAC prompt that removes those rules and
// allows the helper's UDP on private networks.

const createNoWindow = 0x08000000

// firewallGatesHome: the helpers wait for the rules.
const firewallGatesHome = true

// homeFirewallRule names the rule the app adds.
const homeFirewallRule = "Charker Apple Home"

// homeFirewall reports what Windows Firewall does with the helper's
// inbound traffic on a private network: "allowed", "blocked" (a block rule,
// which wins over any allow) or "missing". Reading the rules needs no
// elevation.
func homeFirewall(helper string) string {
	script := fmt.Sprintf(`$rules = Get-NetFirewallApplicationFilter -Program %s -ErrorAction SilentlyContinue |
  Get-NetFirewallRule -ErrorAction SilentlyContinue |
  Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' -and ($_.Profile -match 'Private|Any') }
if ($rules | Where-Object Action -eq 'Block') { 'blocked' }
elseif ($rules | Where-Object Action -eq 'Allow') { 'allowed' }
else { 'missing' }`, psQuote(helper))
	out, err := powershell(script).Output()
	if err != nil {
		return "missing"
	}
	switch s := strings.TrimSpace(string(out)); s {
	case "allowed", "blocked":
		return s
	}
	return "missing"
}

// errFirewallDeclined is a UAC prompt the user said no to.
var errFirewallDeclined = errors.New("firewall: the administrator prompt was declined")

// allowHomeFirewall asks for administrator rights once (UAC) and replaces
// the helper's inbound rules with one that allows its UDP on private and
// domain networks.
func allowHomeFirewall(helper string) error {
	inner := fmt.Sprintf(`$p = %s
Get-NetFirewallApplicationFilter -Program $p -ErrorAction SilentlyContinue |
  Get-NetFirewallRule -ErrorAction SilentlyContinue |
  Where-Object Direction -eq 'Inbound' | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName %s -Direction Inbound -Program $p -Protocol UDP -Action Allow -Profile Private,Domain | Out-Null`,
		psQuote(helper), psQuote(homeFirewallRule))
	outer := fmt.Sprintf(`try {
  $p = Start-Process powershell -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList '-NoProfile','-NonInteractive','-EncodedCommand','%s'
  exit $p.ExitCode
} catch { exit 1223 }`, encodePS(inner))
	err := powershell(outer).Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == 1223 {
		return errFirewallDeclined
	}
	return err
}

// powershell runs a script without a console window.
func powershell(script string) *exec.Cmd {
	cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encodePS(script))
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	return cmd
}

// encodePS is PowerShell's -EncodedCommand form: base64 of UTF-16LE.
func encodePS(script string) string {
	u := utf16.Encode([]rune(script))
	b := make([]byte, 2*len(u))
	for i, c := range u {
		b[2*i], b[2*i+1] = byte(c), byte(c>>8)
	}
	return base64.StdEncoding.EncodeToString(b)
}

// psQuote is a single-quoted PowerShell string literal.
func psQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }
