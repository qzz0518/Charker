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

// energyReport returns the detailed series for one range.
func (a *App) energyReport(rangeArg string) (EnergyReport, error) {
	rangeArg = strings.ToLower(strings.TrimSpace(rangeArg))
	if !rangeValid(rangeArg) {
		return EnergyReport{}, fmt.Errorf("unknown energy range %q", rangeArg)
	}
	rep := EnergyReport{Range: rangeArg, Buckets: []EnergyBucket{}, Sessions: []EnergySession{}}
	if a.energy != nil {
		rep = a.energy.Report(rangeArg)
	}
	if rep.Range == "" {
		rep.Range = rangeArg
	}
	if rep.Buckets == nil {
		rep.Buckets = []EnergyBucket{}
	}
	if rep.Sessions == nil {
		rep.Sessions = []EnergySession{}
	}
	if rep.Currency == "" {
		rep.Currency = a.currentSettings().Currency
	}
	return rep, nil
}

// exportEnergy renders the series as CSV or JSON and saves it through the
// native Save dialog. It returns the saved path, or "" when the user canceled.
// MyGo's dialogs block, so the page calls this from a user action, never a
// loop.
func (a *App) exportEnergy(ctx context.Context, rangeArg, format string) (string, error) {
	rangeArg = strings.ToLower(strings.TrimSpace(rangeArg))
	format = strings.ToLower(strings.TrimSpace(format))
	if !rangeValid(rangeArg) {
		return "", fmt.Errorf("unknown energy range %q", rangeArg)
	}
	if !formatValid(format) {
		return "", fmt.Errorf("unknown export format %q", format)
	}
	if a.energy == nil {
		return "", errors.New("energy history is not available")
	}
	data, err := a.energy.Export(rangeArg, format)
	if err != nil {
		log.Printf("app: export %s %s: %v", rangeArg, format, err)
		a.toast("error", fmt.Sprintf(a.tr(textExportFailed), err))
		return "", err
	}

	name := fmt.Sprintf("charker-energy-%s.%s", rangeArg, format)
	defaultPath := name
	if docs, derr := mygo.App.Path(mygo.PathDocuments); derr == nil && docs != "" {
		defaultPath = filepath.Join(docs, name)
	}
	path, err := mygo.Dialog.Save(mygo.SaveDialogOptions{
		Parent:      mygo.CallerWindow(ctx),
		Title:       a.tr(textExportTitle),
		DefaultPath: defaultPath,
		Filters:     []mygo.FileFilter{{Name: strings.ToUpper(format), Extensions: []string{format}}},
	})
	if err != nil {
		log.Printf("app: save dialog: %v", err)
		a.toast("error", fmt.Sprintf(a.tr(textExportFailed), err))
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
		a.toast("error", fmt.Sprintf(a.tr(textExportFailed), err))
		return "", err
	}
	a.toast("info", fmt.Sprintf(a.tr(textExportDone), filepath.Base(path)))
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
