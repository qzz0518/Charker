package energy

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var (
	utc = Calendar{Location: time.UTC}
	t0  = time.Date(2026, 3, 10, 9, 0, 0, 0, time.UTC)
)

func near(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

// run records samples every step seconds from start at constant watts.
func run(h *History, start time.Time, seconds, step int, watts float64, per []float64) {
	for s := 0; s <= seconds; s += step {
		h.Record(NewMeasurement(start.Add(time.Duration(s)*time.Second), watts, per), utc)
	}
}

func TestTrapezoidIntegration(t *testing.T) {
	h := New()
	run(h, t0, 60, 1, 60, []float64{40, 20})
	s := h.CurrentSessionSummary()
	if !near(s.EnergyWh, 1) || !near(s.ActiveSeconds, 60) || !near(s.PeakWatts, 60) || !near(s.AverageWatts(), 60) {
		t.Fatalf("session summary = %+v", s)
	}
	if !near(s.PerPortWh[0], 2.0/3) || !near(s.PerPortWh[1], 1.0/3) {
		t.Fatalf("per port = %v", s.PerPortWh)
	}
	a := h.ActiveSession()
	if a == nil || a.SampleCount != 61 {
		t.Fatalf("active = %+v", a)
	}
	day := h.Summary(nil, t0.Add(time.Hour))
	if !near(day.EnergyWh, 1) || day.SessionCount != 1 {
		t.Fatalf("summary = %+v", day)
	}
}

func TestGapStartsNewSessionWithoutEnergy(t *testing.T) {
	h := New()
	run(h, t0, 60, 1, 60, nil)
	first := h.ActiveSession().ID
	run(h, t0.Add(10*time.Minute), 60, 1, 60, nil)
	if got := h.Sessions(); len(got) != 1 || got[0].ID != first {
		t.Fatalf("finished sessions = %+v", got)
	}
	if h.ActiveSession() == nil || h.ActiveSession().ID == first {
		t.Fatal("the gap must open a new session")
	}
	if s := h.Summary(nil, t0.Add(time.Hour)); !near(s.EnergyWh, 2) || s.SessionCount != 2 {
		t.Fatalf("summary = %+v (the gap must carry no energy)", s)
	}
	// Only one session is ever open.
	open := 0
	for _, r := range h.SessionRecords(nil, t0.Add(time.Hour)) {
		if r.ID == h.ActiveSession().ID {
			open++
		}
	}
	if open != 1 {
		t.Fatalf("open sessions listed = %d", open)
	}
}

func TestFinishCurrentSessionResetsSessionScope(t *testing.T) {
	h := New()
	run(h, t0, 30, 1, 30, nil)
	h.FinishCurrentSession()
	if h.ActiveSession() != nil || h.CurrentSessionSummary().EnergyWh != 0 || h.CurrentSessionPeriod() != nil {
		t.Fatal("finishing must clear 本次")
	}
	// The next sample starts a new run but integrates nothing yet.
	h.Record(NewMeasurement(t0.Add(31*time.Second), 30, nil), utc)
	if a := h.ActiveSession(); a == nil || a.EnergyWh != 0 || a.SampleCount != 1 {
		t.Fatalf("new run = %+v", a)
	}
}

func TestHourSplitInterpolates(t *testing.T) {
	h := New()
	start := t0.Add(-30 * time.Second)
	h.Record(NewMeasurement(start, 0, nil), utc)
	h.Record(NewMeasurement(start.Add(60*time.Second), 120, nil), utc)
	hourly := h.Hourly()
	if len(hourly) != 2 {
		t.Fatalf("buckets = %d", len(hourly))
	}
	// First half ramps 0→60 W over 30 s, second 60→120 W.
	if !near(hourly[0].EnergyWh, 30*30.0/3600) || !near(hourly[1].EnergyWh, 30*90.0/3600) {
		t.Fatalf("buckets = %+v", hourly)
	}
	if !near(hourly[0].PeakWatts, 60) || !hourly[1].StartedAt.Equal(t0) {
		t.Fatalf("buckets = %+v", hourly)
	}
}

func TestPeriodsAggregateByDayAndMonth(t *testing.T) {
	h := New()
	run(h, t0, 60, 10, 36, nil)
	run(h, t0.Add(3*time.Hour), 60, 10, 72, nil)
	run(h, t0.Add(48*time.Hour), 60, 10, 36, nil)
	days := h.Periods(nil, t0.Add(72*time.Hour), Day, utc)
	if len(days) != 2 || !near(days[0].EnergyWh, 1.8) || !near(days[0].PeakWatts, 72) {
		t.Fatalf("days = %+v", days)
	}
	months := h.Periods(nil, t0.Add(72*time.Hour), Month, utc)
	if len(months) != 1 || !months[0].StartedAt.Equal(time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("months = %+v", months)
	}
}

func TestRetentionKeepsTotals(t *testing.T) {
	h := New()
	old := t0.AddDate(-3, 0, 0)
	for d := 0; d < 30; d++ {
		for _, hour := range []time.Duration{0, 6} {
			run(h, old.AddDate(0, 0, d).Add(hour*time.Hour), 60, 10, 60, []float64{60})
			h.FinishCurrentSession()
		}
	}
	// A recent run keeps the clock plausible on the next launch (the skip
	// recorded while it jumped three years ahead is not archived).
	run(h, t0.Add(-24*time.Hour), 60, 10, 60, []float64{60})
	h.FinishCurrentSession()
	before := h.Summary(nil, t0.Add(time.Hour))
	store := NewStoreForBaseDir(t.TempDir())
	if err := store.Save(h); err != nil {
		t.Fatal(err)
	}
	h, _ = store.Load(t0, utc)
	after := h.Summary(nil, t0.Add(time.Hour))
	if !near(before.EnergyWh, after.EnergyWh) || !near(before.ActiveSeconds, after.ActiveSeconds) || before.SessionCount != after.SessionCount {
		t.Fatalf("before %+v after %+v", before, after)
	}
	if len(h.Sessions()) != 1 || h.ArchivedSessionCount() != 60 || h.ArchivedSessionsBefore() == nil {
		t.Fatalf("sessions %d archived %d", len(h.Sessions()), h.ArchivedSessionCount())
	}
	if len(h.Hourly()) > 3 {
		t.Fatalf("hourly not folded: %d", len(h.Hourly()))
	}
	// A range that starts after the watermark does not count folded runs.
	start := t0.AddDate(0, 0, -7)
	if s := h.Summary(&start, t0); s.SessionCount != 1 {
		t.Fatalf("week sessions = %d", s.SessionCount)
	}
}

func TestRunawayClockSkipsCompaction(t *testing.T) {
	h := New()
	run(h, t0, 60, 10, 60, nil)
	h.FinishCurrentSession()
	future := t0.AddDate(5, 0, 0)
	h.RecoverAfterLaunch(future, utc)
	if h.SkippedCompaction() == nil || len(h.Hourly()) != 1 || len(h.Sessions()) != 1 {
		t.Fatalf("compaction ran on a runaway clock: %+v", h.SkippedCompaction())
	}
	h.RecoverAfterLaunch(t0.Add(time.Hour), utc)
	if h.SkippedCompaction() != nil {
		t.Fatal("a corrected clock clears the notice")
	}
}

func TestRemoveRecords(t *testing.T) {
	h := New()
	run(h, t0.Add(-24*time.Hour), 60, 10, 60, nil)
	h.FinishCurrentSession()
	run(h, t0, 60, 10, 60, nil)
	day := utc.DayInterval(t0)
	if !h.HasRecords(day.Start, day.End) {
		t.Fatal("today has records")
	}
	if !h.RemoveRecords(day.Start, day.End) {
		t.Fatal("nothing removed")
	}
	if h.ActiveSession() != nil || len(h.Sessions()) != 1 || len(h.Hourly()) != 1 {
		t.Fatalf("after removal: active %v sessions %d hourly %d", h.ActiveSession(), len(h.Sessions()), len(h.Hourly()))
	}
	if h.RemoveRecords(day.Start, day.End) {
		t.Fatal("second removal changed something")
	}
}

func TestCalendarWeeks(t *testing.T) {
	wed := time.Date(2026, 10, 28, 15, 0, 0, 0, time.UTC)
	if got := utc.WeekStart(wed); !got.Equal(time.Date(2026, 10, 26, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("monday week = %v", got)
	}
	if got := utc.WithFirstWeekday(time.Sunday).WeekStart(wed); !got.Equal(time.Date(2026, 10, 25, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("sunday week = %v", got)
	}
	ist := Calendar{Location: time.FixedZone("IST", 5*3600+1800)}
	at := time.Date(2026, 1, 1, 10, 50, 0, 0, ist.Location)
	if got := ist.HourStart(at); !got.Equal(time.Date(2026, 1, 1, 10, 0, 0, 0, ist.Location)) {
		t.Fatalf("half-hour zone hour = %v", got)
	}
}

func TestStoreRoundTripAndRecovery(t *testing.T) {
	dir := t.TempDir()
	s := NewStoreForBaseDir(dir)
	h := New()
	run(h, t0, 60, 1, 60, []float64{30, 30})
	if err := s.Save(h); err != nil {
		t.Fatal(err)
	}
	loaded, warning := s.Load(t0.Add(time.Minute), utc)
	if warning != nil {
		t.Fatalf("warning %+v", warning)
	}
	// The open run is kept as finished on the next launch.
	if loaded.ActiveSession() != nil || len(loaded.Sessions()) != 1 || loaded.Sessions()[0].ID != h.ActiveSession().ID {
		t.Fatalf("loaded = %+v", loaded.Sessions())
	}
	if !near(loaded.Summary(nil, t0.Add(time.Hour)).EnergyWh, 1) {
		t.Fatal("energy lost in round trip")
	}

	if err := os.WriteFile(s.Path(), []byte("{nope"), 0o600); err != nil {
		t.Fatal(err)
	}
	empty, warning := s.Load(t0, utc)
	if warning == nil || warning.Key != "能耗历史无法读取，%@ %@" || !empty.IsEmpty() {
		t.Fatalf("corrupt load: %+v", warning)
	}
	if _, err := os.Stat(filepath.Join(dir, "energy-history-v1.corrupt.json")); err != nil {
		t.Fatal("recovery copy missing")
	}
	if err := os.WriteFile(s.Path(), []byte(`{"version":7,"history":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, warning = s.Load(t0, utc); warning == nil || warning.Key != "能耗历史来自不受支持的版本，%@" {
		t.Fatalf("version load: %+v", warning)
	}
	if err := s.Clear(); err != nil {
		t.Fatal(err)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Fatalf("clear left %v", entries)
	}
}

func TestLegacyArchiveFoldsIntoHourly(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ArchiveFileName)
	legacy := `{"version":1,"history":{"hourly":[{"startedAt":1773133200000,"endedAt":1773133260000,"energyWh":1,"activeSeconds":60,"peakWatts":60,"perPortWh":[1,0,0,0,0,0]}],
	"daily":[{"startedAt":1765324800000,"endedAt":1765324860000,"energyWh":2,"activeSeconds":60,"peakWatts":60,"perPortWh":[2,0,0,0,0,0]}],
	"sessions":[],"archivedSessionCount":3,"archivedSessionsBefore":0}}`
	if err := os.WriteFile(path, []byte(legacy), 0o600); err != nil {
		t.Fatal(err)
	}
	h, warning := NewStore(path).Load(t0, utc)
	if warning != nil || len(h.Hourly()) != 2 || !near(h.Summary(nil, t0.Add(time.Hour)).EnergyWh, 3) || h.ArchivedSessionsBefore() != nil {
		t.Fatalf("legacy load %+v %d", warning, len(h.Hourly()))
	}
}

func TestExports(t *testing.T) {
	h := New()
	run(h, t0, 60, 1, 60, []float64{60})
	h.FinishCurrentSession()
	run(h, t0.Add(5*time.Minute), 10, 1, 30, []float64{0, 30})
	csv := h.ExportCSV(t0.Add(time.Hour), time.UTC, "zh")
	lines := strings.Split(strings.TrimSuffix(csv, "\n"), "\n")
	if lines[0] != "# Charker 能耗导出：数值由 Charker 在本机对 BLE 遥测做时间积分推算。" || lines[4] != "# generated_at: 2026-03-10T10:00:00Z" {
		t.Fatalf("csv head = %q", lines[:5])
	}
	if lines[5] != "kind,start,end,energy_wh,active_seconds,peak_w,average_w,c1_wh,c2_wh,c3_wh,c4_wh,a1_wh,a2_wh,samples" {
		t.Fatalf("csv header = %q", lines[5])
	}
	if lines[6] != "bucket,2026-03-10T09:00:00Z,2026-03-10T09:05:10Z,1.0833,70,60.00,55.71,1.0000,0.0833,0.0000,0.0000,0.0000,0.0000," {
		t.Fatalf("bucket row = %q", lines[6])
	}
	if len(lines) != 9 || !strings.HasPrefix(lines[8], "session,2026-03-10T09:05:00Z,") || !strings.HasSuffix(lines[8], ",11") {
		t.Fatalf("session rows = %q", lines[7:])
	}
	data, err := h.ExportJSON(t0, time.FixedZone("CST", 8*3600), "en")
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	if doc["schema"] != "charker.energy-history.1" || doc["generatedAt"] != "2026-03-10T17:00:00+0800" ||
		len(doc["sessions"].([]any)) != 2 || len(doc["buckets"].([]any)) != 1 {
		t.Fatalf("json = %s", data)
	}
	if _, ok := doc["archivedSessionsBefore"]; ok {
		t.Fatal("nil watermark must be omitted")
	}
}

func TestDemoHistory(t *testing.T) {
	now := time.Date(2026, 10, 28, 1, 43, 0, 0, time.UTC)
	h := DemoHistory(now, utc, false)
	if h.ActiveSession() != nil {
		t.Fatal("the fixture has no open run")
	}
	// 89 days minus the 8 quiet ones (11, 22 … 88), plus a second run every
	// fourth day that is not quiet (44 and 88 are both).
	if got := len(h.Sessions()); got != 81+20 {
		t.Fatalf("sessions = %d", got)
	}
	all := h.Summary(nil, now)
	if all.EnergyWh <= 0 || all.SessionCount != len(h.Sessions()) || all.PerPortWh[3] != 0 {
		t.Fatalf("summary = %+v", all)
	}
}

func TestDemoHistorySixPorts(t *testing.T) {
	now := time.Date(2026, 10, 28, 1, 43, 0, 0, time.UTC)
	all := DemoHistory(now, utc, true).Summary(nil, now)
	ports := 0.0
	for _, v := range all.PerPortWh {
		ports += v
	}
	if all.PerPortWh[5] <= 0 || !near(ports, all.EnergyWh) && math.Abs(ports-all.EnergyWh) > 1e-6 {
		t.Fatalf("six-port fixture = %+v", all)
	}
}

func TestEstimatedCost(t *testing.T) {
	if _, ok := EstimatedCost(100, 0); ok {
		t.Fatal("no price, no cost")
	}
	if c, ok := EstimatedCost(500, 0.6); !ok || !near(c, 0.3) {
		t.Fatalf("cost = %v", c)
	}
}
