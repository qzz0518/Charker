package app

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/egoist/mygo"
)

// Messages the energy actions post as the app-wide action message
// (AppModel.setActionMessage), so the overview's 结束本次 says the same.
var (
	textEnergyNoSession = translated{"当前没有正在记录的能耗段", "No Energy Session Is Being Recorded"}
	textEnergyEnded     = translated{"本次能耗记录已结束；下一次采样会开始新记录", "The Current Energy Session Ended; the Next Sample Will Start a New One"}
	textEnergyCleared   = translated{"能耗记录已清空", "Energy History Cleared"}
	textEnergyClearFail = translated{"能耗历史清空失败：%s", "Couldn’t Clear Energy History: %s"}
)

// FeedEnergy routes the session's telemetry samples into the energy
// service, tagging each with whether it came from the simulator (the
// snapshot's device), like AppModel.recordEnergy's snapshot.isDemo. A
// sample with no device on record (mid mode switch) is dropped.
func FeedEnergy(h *SessionHost, e *EnergyService) {
	if h == nil || e == nil {
		return
	}
	h.SetOnSample(func(atUnixMs int64, totalWatts float64, perPortWatts [6]float64) {
		d := h.Snapshot().Device
		if d == nil {
			return
		}
		e.RecordAt(atUnixMs, totalWatts, perPortWatts, d.Mock)
	})
}

// energyService returns the concrete service, or nil.
func (a *App) energyService() *EnergyService {
	es, _ := a.energy.(*EnergyService)
	return es
}

// exportEnergy renders the ledger and saves it through the native Save
// dialog under the Mac's suggested name ("charker-能耗.csv"). It returns
// the saved path, or "" when the user canceled. MyGo's dialogs block, so
// the page calls this from a user action only.
func (a *App) exportEnergy(ctx context.Context, format string) (string, error) {
	format = strings.ToLower(strings.TrimSpace(format))
	if format != "csv" && format != "json" {
		return "", fmt.Errorf("unknown export format %q", format)
	}
	es := a.energyService()
	if es == nil {
		return "", errors.New("energy history is not available")
	}
	// Without the native app (the browser dev server) there is no dialog,
	// and MyGo would wait for one forever.
	if !mygo.App.IsReady() {
		return "", errors.New("the save dialog needs the Windows app")
	}
	locale := a.locale()
	data, err := es.exportBytes(format, locale)
	if err != nil {
		return "", err
	}
	name := "charker-能耗." + format
	if locale == "en" {
		name = "charker-energy." + format
	}
	defaultPath := name
	if docs, derr := mygo.App.Path(mygo.PathDocuments); derr == nil && docs != "" {
		defaultPath = filepath.Join(docs, name)
	}
	path, err := mygo.Dialog.Save(mygo.SaveDialogOptions{
		Parent:      mygo.CallerWindow(ctx),
		DefaultPath: defaultPath,
		Filters:     []mygo.FileFilter{{Name: strings.ToUpper(format), Extensions: []string{format}}},
	})
	if err != nil {
		log.Printf("app: save dialog: %v", err)
		return "", err
	}
	if path == "" {
		return "", nil // canceled
	}
	if !strings.HasSuffix(strings.ToLower(path), "."+format) {
		path += "." + format
	}
	if err := writeFileAtomic(path, data); err != nil {
		log.Printf("app: writing %s: %v", path, err)
		return "", err
	}
	return path, nil
}

// writeFileAtomic writes data through a temporary file next to path and
// renames it, so a crash or a scanner holding the file never leaves a
// half-written export.
func writeFileAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
