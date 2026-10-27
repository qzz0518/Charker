package app

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"

	"charker/internal/energy"
	"charker/internal/product"
)

func feed(e *EnergyService, start time.Time, seconds int, mock bool) {
	for s := 0; s <= seconds; s++ {
		e.RecordAt(start.Add(time.Duration(s)*time.Second).UnixMilli(), 60, [6]float64{40, 20}, mock)
	}
}

func TestEnergyServiceDemoNeverTouchesTheLedger(t *testing.T) {
	dir := t.TempDir()
	e := NewEnergyService(dir, 0, "CNY", true)
	feed(e, time.Now().Add(-time.Minute), 30, true)
	sum := e.Summary()
	if !sum.Ephemeral || !sum.HasActiveSession || len(sum.Scopes) != 4 || sum.Scopes["month"].Wh <= 0 {
		t.Fatalf("demo summary = %+v", sum)
	}
	if ok, _ := e.ClearAll(); ok {
		t.Fatal("demo data must not be cleared")
	}
	if _, err := e.exportBytes("csv", "zh"); err == nil {
		t.Fatal("demo data must not be exported")
	}
	if !e.EndSession() || e.Summary().HasActiveSession {
		t.Fatal("ending the demo run")
	}
	e.mu.Lock()
	e.syncDemoLocked(false)
	e.mu.Unlock()
	if s := e.Summary(); s.Ephemeral || s.Scopes["month"].Wh != 0 {
		t.Fatalf("real ledger picked up demo data: %+v", s)
	}
	data, _ := os.ReadFile(filepath.Join(dir, energy.ArchiveFileName))
	if bytes.Contains(data, []byte(`"energyWh":1`)) || bytes.Contains(data, []byte(`"sampleCount":3`)) {
		t.Fatalf("archive holds demo data: %s", data)
	}
}

func TestEnergyServiceRealLedger(t *testing.T) {
	dir := t.TempDir()
	e := NewEnergyService(dir, 0.6, "CNY", false)
	feed(e, time.Now().Add(-time.Minute), 30, false)
	s := e.Summary()
	if !s.HasActiveSession || s.Scopes["session"].Cost == nil || len(s.Scopes["day"].PerPort) != 3 {
		t.Fatalf("summary = %+v", s)
	}
	rep := e.Report("session")
	if rep.ActiveSessionID == "" || len(rep.Sessions) != 1 || rep.Sessions[0].ID != rep.ActiveSessionID || !rep.Exportable || !rep.CanClear {
		t.Fatalf("report = %+v", rep)
	}
	csv, err := e.exportBytes("csv", "zh")
	if err != nil || !bytes.HasPrefix(csv, []byte{0xEF, 0xBB, 0xBF, '#'}) {
		t.Fatalf("csv = %q, %v", csv[:8], err)
	}
	if !e.EndSession() || e.EndSession() {
		t.Fatal("EndSession reports whether a run was open")
	}
	if rep := e.Report("day"); len(rep.Sessions) != 1 || rep.ActiveSessionID != "" {
		t.Fatalf("after end: %+v", rep.Sessions)
	}
	if ok, err := e.ClearRange("day"); !ok || err != nil {
		t.Fatalf("clear day = %v %v", ok, err)
	}
	if rep := e.Report("all"); len(rep.Sessions) != 0 || rep.Summary.EnergyWh != 0 {
		t.Fatalf("after clear: %+v", rep.Summary)
	}
	feed(e, time.Now(), 5, false)
	if ok, err := e.ClearAll(); !ok || err != nil {
		t.Fatalf("clear all = %v %v", ok, err)
	}
	if _, err := os.Stat(filepath.Join(dir, energy.ArchiveFileName)); !os.IsNotExist(err) {
		t.Fatal("archive still on disk")
	}
}

func TestEnergyServiceSixPortProduct(t *testing.T) {
	e := NewEnergyService(t.TempDir(), 0, "CNY", true)
	e.SetProducts(product.ProductA2345, product.ProductA2345)
	s := e.Summary()
	if s.Product != "A2345" || len(s.Ports) != 6 || len(s.Scopes["month"].PerPort) != 6 || s.Scopes["month"].PerPort[5] <= 0 {
		t.Fatalf("six-port summary = %+v", s)
	}
	if rep := e.Report("week"); rep.RatedWatts != 250 || len(rep.Ports) != 6 {
		t.Fatalf("report = %+v", rep)
	}
}
