package app

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"charker/internal/a2687"

	"github.com/egoist/mygo"
)

// The diagnostics export of the Advanced page (AppModel.exportDiagnostics
// and DiagnosticsLog.export). The Windows session keeps no frame trace of
// its own; what it has is this run's app log, which carries the session's
// phase changes, the Bluetooth transport's notes and errors. The export is
// the Mac's header followed by that log, with addresses redacted.

// diagnosticsLogLines bounds the exported log: the newest lines win.
const diagnosticsLogLines = 4000

// appLogPath is the log file of this run: dev builds write dev.log beside
// the exe, release builds charker.log in the user cache directory.
func appLogPath() string {
	if exe, err := os.Executable(); err == nil {
		dev := filepath.Join(filepath.Dir(exe), "dev.log")
		if _, err := os.Stat(dev); err == nil {
			return dev
		}
	}
	return diagnosticLogPath()
}

// diagnosticsHeader is the Mac export's header for the A2687.
func (a *App) diagnosticsHeader(st AppState) map[string]string {
	mode := "bluetooth"
	if st.Prefs.DemoMode {
		mode = "demo-a2687"
	}
	version := st.App.Version
	if version == "" {
		version = "dev"
	}
	device, firmware, serial, mac := "unknown", "unknown", "", ""
	if d := st.Session.Device; d != nil {
		if d.ProductName != "" {
			device = d.ProductName
		}
		if d.Firmware != "" {
			firmware = d.Firmware
		}
		serial, mac = d.Serial, d.MAC
	}
	return map[string]string{
		"app":      "Charker " + version,
		"windows":  osVersionText(),
		"mode":     mode,
		"device":   device,
		"firmware": firmware,
		"serial":   a2687.RedactIdentifier(serial),
		"mac":      a2687.RedactMAC(mac),
		"phase":    a.phaseShortLabel(st.Session.Phase),
	}
}

// diagnosticsReport renders the export: header, blank line, log.
func (a *App) diagnosticsReport(st AppState, logText string) string {
	header := a.diagnosticsHeader(st)
	keys := make([]string, 0, len(header))
	for k := range header {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	lines := []string{"# " + a.tr(textDiagnosticsHead)}
	for _, k := range keys {
		lines = append(lines, k+": "+header[k])
	}
	lines = append(lines, "")
	if logText = strings.TrimRight(redactLog(logText), "\n"); logText != "" {
		lines = append(lines, logText)
	}
	return strings.Join(lines, "\n") + "\n"
}

// readLogTail returns the last n lines of the log file, "" when it cannot.
func readLogTail(path string, n int) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

var (
	macPattern = regexp.MustCompile(`\b[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\b`)
	// Serial numbers in log lines ("serial=…", "sn …").
	serialPattern = regexp.MustCompile(`(?i)\b(serial|sn)([=: ]+)([A-Z0-9]{8,})`)
)

// redactLog masks Bluetooth addresses and serial numbers, as the Mac's
// Redact does for everything that reaches its trace.
func redactLog(text string) string {
	text = macPattern.ReplaceAllStringFunc(text, a2687.RedactMAC)
	return serialPattern.ReplaceAllStringFunc(text, func(m string) string {
		parts := serialPattern.FindStringSubmatch(m)
		return parts[1] + parts[2] + a2687.RedactIdentifier(parts[3])
	})
}

// exportDiagnostics saves the report through the native Save dialog and
// returns the saved path, or "" when the user canceled.
func (a *App) exportDiagnostics(ctx context.Context) (string, error) {
	text := a.diagnosticsReport(a.currentState(), readLogTail(appLogPath(), diagnosticsLogLines))
	if !mygo.App.IsReady() {
		// The browser dev server has no dialogs.
		log.Printf("app: diagnostics export (%d bytes) needs the Windows host", len(text))
		return "", nil
	}
	name := a.tr(textDiagnosticsName)
	defaultPath := name
	if docs, err := mygo.App.Path(mygo.PathDocuments); err == nil && docs != "" {
		defaultPath = filepath.Join(docs, name)
	}
	path, err := mygo.Dialog.Save(mygo.SaveDialogOptions{
		Parent:      mygo.CallerWindow(ctx),
		Title:       strings.TrimSuffix(a.tr(textDiagnosticsTitle), "…"),
		DefaultPath: defaultPath,
		Filters:     []mygo.FileFilter{{Name: "Text", Extensions: []string{"txt"}}},
	})
	if err != nil {
		a.toast("error", fmt.Sprintf(a.tr(textExportFailed), err))
		return "", err
	}
	if path == "" {
		return "", nil
	}
	if filepath.Ext(path) == "" {
		path += ".txt"
	}
	if err := writeFileAtomic(path, []byte(text)); err != nil {
		log.Printf("app: writing %s: %v", path, err)
		a.toast("error", fmt.Sprintf(a.tr(textExportFailed), err))
		return "", err
	}
	a.toast("info", a.tr(textDiagnosticsSaved))
	return path, nil
}

// revealDiagnosticsLog selects the log file in File Explorer, or opens its
// folder when there is no file yet.
func (a *App) revealDiagnosticsLog() error {
	path := appLogPath()
	if !mygo.App.IsReady() {
		log.Printf("app: reveal %s needs the Windows host", path)
		return nil
	}
	if _, err := os.Stat(path); err != nil {
		dir := filepath.Dir(path)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		return mygo.Shell.OpenPath(dir)
	}
	mygo.Shell.ShowItemInFolder(path)
	return nil
}
