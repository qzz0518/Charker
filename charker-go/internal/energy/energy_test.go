package energy

import (
	"bytes"
	"encoding/csv"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var (
	t0      = time.Date(2026, 10, 27, 10, 59, 30, 0, time.UTC)
	utcMeta = Options{Location: time.UTC, Clock: func() time.Time { return t0 }}
)

func newUTC(opts Options) *History {
	if opts.Location == nil {
		opts.Location = time.UTC
	}
	if opts.Clock == nil {
		opts.Clock = func() time.Time { return t0 }
	}
	return New(opts)
}

// recordRun feeds two samples `seconds` apart at total watts with a constant
// per-port split.
func recordRun(h *History, start time.Time, seconds float64, total float64, per [6]float64) {
	h.Record(start, total, per)
	h.Record(start.Add(time.Duration(seconds*float64(time.Second))), total, per)
}

func TestIntegrationMath(t *testing.T) {
	h := newUTC(utcMeta)
	per := [6]float64{40, 20}
	recordRun(h, t0, 60, 60, per)
	sum := h.Summary(t0.Add(-time.Hour).UnixMilli(), t0.Add(time.Hour).UnixMilli())
	if math.Abs(sum.EnergyWh-1.0) > 1e-9 {
		t.Fatalf("energy = %v, want 1 Wh", sum.EnergyWh)
	}
	if math.Abs(sum.ActiveSeconds-60) > 1e-9 {
		t.Fatalf("active = %v, want 60 s", sum.ActiveSeconds)
	}
	if math.Abs(sum.PeakWatts-60) > 1e-9 {
		t.Fatalf("peak = %v, want 60", sum.PeakWatts)
	}
	avg := sum.EnergyWh * 3600 / sum.ActiveSeconds
	if math.Abs(avg-60) > 1e-9 {
		t.Fatalf("average = %v, want 60", avg)
	}
	if math.Abs(sum.PerPortWh[0]-2.0/3.0) > 1e-9 || math.Abs(sum.PerPortWh[1]-1.0/3.0) > 1e-9 {
		t.Fatalf("per-port = %v", sum.PerPortWh)
	}
	if sum.SessionCount != 1 {
		t.Fatalf("sessions = %d, want 1", sum.SessionCount)
	}
}

func TestGapClosesSessionWithoutEnergy(t *testing.T) {
	h := newUTC(utcMeta)
	if r := h.Record(t0, 60, [6]float64{}); !r.Opened {
		t.Fatal("first sample should open a session")
	}
	if r := h.Record(t0.Add(60*time.Second), 60, [6]float64{}); !r.Integrated {
		t.Fatal("second sample should integrate")
	}
	// 120 s gap: closes and starts a new run, no energy across the gap.
	if r := h.Record(t0.Add(180*time.Second), 30, [6]float64{}); !r.GapClosed || !r.Opened {
		t.Fatalf("gap sample result = %+v", r)
	}
	h.Record(t0.Add(240*time.Second), 30, [6]float64{})
	sum := h.Summary(t0.Add(-time.Hour).UnixMilli(), t0.Add(time.Hour).UnixMilli())
	if math.Abs(sum.EnergyWh-1.5) > 1e-9 {
		t.Fatalf("energy = %v, want 1.5 Wh", sum.EnergyWh)
	}
	if math.Abs(sum.ActiveSeconds-120) > 1e-9 {
		t.Fatalf("active = %v, want 120 s", sum.ActiveSeconds)
	}
	if sum.SessionCount != 2 {
		t.Fatalf("sessions = %d, want 2", sum.SessionCount)
	}
}

func TestManualSessionCut(t *testing.T) {
	h := newUTC(utcMeta)
	recordRun(h, t0, 60, 60, [6]float64{})
	h.FinishCurrentSession()
	recordRun(h, t0.Add(200*time.Second), 30, 60, [6]float64{})
	sum := h.Summary(t0.Add(-time.Hour).UnixMilli(), t0.Add(time.Hour).UnixMilli())
	if math.Abs(sum.EnergyWh-1.5) > 1e-9 {
		t.Fatalf("energy = %v, want 1.5 Wh", sum.EnergyWh)
	}
	if sum.SessionCount != 2 {
		t.Fatalf("sessions = %d, want 2", sum.SessionCount)
	}
}

func TestHourSplit(t *testing.T) {
	h := newUTC(utcMeta)
	start := time.Date(2026, 10, 27, 10, 59, 30, 0, time.UTC)
	h.Record(start, 60, [6]float64{})
	h.Record(start.Add(60*time.Second), 60, [6]float64{})
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.hourly) != 2 {
		t.Fatalf("hourly buckets = %d, want 2", len(h.hourly))
	}
	for _, b := range h.hourly {
		if math.Abs(b.EnergyWh-0.5) > 1e-9 {
			t.Fatalf("bucket %d energy = %v, want 0.5", b.StartedAtMs, b.EnergyWh)
		}
		if math.Abs(b.ActiveSeconds-30) > 1e-9 {
			t.Fatalf("bucket %d active = %v, want 30", b.StartedAtMs, b.ActiveSeconds)
		}
	}
}

func TestDayBuckets(t *testing.T) {
	h := newUTC(utcMeta)
	day1 := time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)
	day2 := day1.AddDate(0, 0, 1)
	recordRun(h, day1, 60, 60, [6]float64{})
	recordRun(h, day2, 60, 60, [6]float64{})
	sum := h.Summary(day1.Add(-time.Hour).UnixMilli(), day2.Add(time.Hour).UnixMilli())
	if math.Abs(sum.EnergyWh-2.0) > 1e-9 {
		t.Fatalf("energy = %v, want 2 Wh", sum.EnergyWh)
	}
	h.mu.Lock()
	days := len(h.daily)
	h.mu.Unlock()
	if days != 2 {
		t.Fatalf("daily buckets = %d, want 2", days)
	}
}

func TestRetentionPreservesTotals(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	h := newUTC(Options{Location: time.UTC, Clock: func() time.Time { return now }})
	days := []int{-1000, -800, -100, -1}
	for _, d := range days {
		start := now.AddDate(0, 0, d)
		recordRun(h, start, 60, 60, [6]float64{})
	}
	before := totalBucketEnergy(h)
	compact := h.Compact(now)
	if compact.Skipped {
		t.Fatal("unexpected skipped compaction")
	}
	if compact.FoldedHourly == 0 || compact.FoldedDaily == 0 {
		t.Fatalf("compact result = %+v", compact)
	}
	after := totalBucketEnergy(h)
	if math.Abs(before-after) > 1e-9 {
		t.Fatalf("totals changed by compaction: before %v after %v", before, after)
	}
	if again := h.Compact(now); again.FoldedHourly+again.FoldedDaily+again.FoldedSessions != 0 {
		t.Fatalf("compaction not idempotent: %+v", again)
	}
	// Older-than-daily-window detail still sums through monthly buckets.
	sum := h.Summary(now.AddDate(-3, 0, 0).UnixMilli(), now.UnixMilli())
	if math.Abs(sum.EnergyWh-before) > 1e-9 {
		t.Fatalf("summary after compaction = %v, want %v", sum.EnergyWh, before)
	}
}

func totalBucketEnergy(h *History) float64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	var total float64
	for _, list := range [][]Bucket{h.hourly, h.daily, h.monthly} {
		// Count each resolution once: prefer finest available.
		if len(list) == 0 {
			continue
		}
		var sum float64
		for _, b := range list {
			sum += b.EnergyWh
		}
		// The finest list that still holds the oldest data wins; here just
		// return hourly+daily+monthly disjointly by construction: totals per
		// resolution are equal, so return the largest (monthly is complete).
		if sum > total {
			total = sum
		}
	}
	return total
}

func TestClockRunawaySkipsCompaction(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	h := newUTC(Options{Location: time.UTC, Clock: func() time.Time { return now }})
	recordRun(h, now.AddDate(-1, 0, 0), 60, 60, [6]float64{})
	h.FinishCurrentSession()
	future := now.AddDate(10, 0, 0)
	res := h.Compact(future)
	if !res.Skipped || !h.SkippedCompaction() {
		t.Fatalf("clock runaway should skip compaction: %+v", res)
	}
	if len(h.Sessions()) == 0 {
		t.Fatal("clock runaway must delete nothing")
	}
	if res2 := h.Compact(now); res2.Skipped {
		t.Fatal("compaction should resume once the clock is corrected")
	}
}

func TestStoreRoundTripAndCorruption(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ArchiveFileName)
	store := NewStore(path)
	h := newUTC(Options{Location: time.UTC, Clock: func() time.Time { return t0 }})
	recordRun(h, t0, 60, 60, [6]float64{40, 20})
	h.FinishCurrentSession()
	recordRun(h, t0.Add(200*time.Second), 60, 30, [6]float64{})
	if err := store.Save(h); err != nil {
		t.Fatalf("save: %v", err)
	}
	loaded, warning := NewStore(path).Load(Options{Location: time.UTC, Clock: func() time.Time { return t0 }})
	if warning != "" {
		t.Fatalf("unexpected warning: %q", warning)
	}
	sum := loaded.Summary(t0.Add(-time.Hour).UnixMilli(), t0.Add(3600*1000).UnixMilli())
	orig := h.Summary(t0.Add(-time.Hour).UnixMilli(), t0.Add(3600*1000).UnixMilli())
	if math.Abs(sum.EnergyWh-orig.EnergyWh) > 1e-9 {
		t.Fatalf("round-trip energy = %v, want %v", sum.EnergyWh, orig.EnergyWh)
	}
	if math.Abs(sum.ActiveSeconds-orig.ActiveSeconds) > 1e-9 {
		t.Fatalf("round-trip active = %v, want %v", sum.ActiveSeconds, orig.ActiveSeconds)
	}

	// Corrupt archive: backup + empty history + warning.
	if err := os.WriteFile(path, []byte("{nope"), 0o600); err != nil {
		t.Fatal(err)
	}
	empty, warning := NewStore(path).Load(Options{Location: time.UTC})
	if warning == "" {
		t.Fatal("expected a corrupt-file warning")
	}
	if got := empty.Summary(0, t0.Add(time.Hour).UnixMilli()); got.EnergyWh != 0 {
		t.Fatalf("corrupt load energy = %v, want 0", got.EnergyWh)
	}
	if _, err := os.Stat(path + corruptSuffix); err != nil {
		t.Fatalf("corrupt backup missing: %v", err)
	}
	if err := store.Delete(); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if _, err := os.Stat(path + corruptSuffix); !os.IsNotExist(err) {
		t.Fatalf("corrupt backup not deleted: %v", err)
	}
}

func TestOpenSessionRecoveredOnLoad(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ArchiveFileName)
	h := newUTC(Options{Location: time.UTC, Clock: func() time.Time { return t0 }})
	recordRun(h, t0, 60, 60, [6]float64{})
	open := h.OpenSession()
	if open == nil || open.SampleCount != 2 {
		t.Fatalf("open session = %+v", open)
	}
	if err := NewStore(path).Save(h); err != nil {
		t.Fatal(err)
	}
	loaded, _ := NewStore(path).Load(Options{Location: time.UTC, Clock: func() time.Time { return t0 }})
	if got := loaded.OpenSession(); got != nil {
		t.Fatalf("open session should be finished on load: %+v", got)
	}
	if got := len(loaded.Sessions()); got != 1 {
		t.Fatalf("sessions after recovery = %d, want 1", got)
	}
}

func TestExports(t *testing.T) {
	h := newUTC(Options{Location: time.UTC, Clock: func() time.Time { return t0 }, PricePerKWh: 0.42, Currency: "USD"})
	recordRun(h, t0, 60, 60, [6]float64{40, 20})
	h.FinishCurrentSession()
	recordRun(h, t0.Add(200*time.Second), 30, 30, [6]float64{10, 10})

	var csvBuf bytes.Buffer
	if err := h.ExportCSV(&csvBuf, t0.Add(time.Hour)); err != nil {
		t.Fatalf("ExportCSV: %v", err)
	}
	text := csvBuf.String()
	if !strings.HasSuffix(text, "\n") {
		t.Fatal("CSV must end with a newline")
	}
	notice := 0
	for _, line := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		if strings.HasPrefix(line, "# ") {
			notice++
		}
	}
	if notice != 5 { // four notice sentences + generated_at
		t.Fatalf("notice lines = %d, want 5\n%s", notice, text)
	}
	firstData := ""
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(line, "kind,") {
			firstData = line
			break
		}
	}
	if firstData != "kind,start,end,energy_wh,active_seconds,peak_w,average_w,c1_wh,c2_wh,c3_wh,c4_wh,a1_wh,a2_wh,samples" {
		t.Fatalf("CSV header = %q", firstData)
	}
	dataSection := text[strings.Index(text, "kind,"):]
	rows, err := csv.NewReader(strings.NewReader(dataSection)).ReadAll()
	if err != nil {
		t.Fatalf("parse CSV: %v", err)
	}
	var buckets, sessions int
	for _, row := range rows {
		if len(row) == 0 {
			continue
		}
		switch row[0] {
		case "bucket":
			buckets++
		case "session":
			sessions++
		}
	}
	if buckets != 2 || sessions != 2 {
		t.Fatalf("CSV rows buckets=%d sessions=%d, want 2/2\n%s", buckets, sessions, text)
	}

	var jsonBuf bytes.Buffer
	if err := h.ExportJSON(&jsonBuf, t0.Add(time.Hour)); err != nil {
		t.Fatalf("ExportJSON: %v", err)
	}
	var doc map[string]any
	if err := json.Unmarshal(jsonBuf.Bytes(), &doc); err != nil {
		t.Fatalf("parse JSON: %v", err)
	}
	if doc["schema"] != "charker.energy-history.1" {
		t.Fatalf("schema = %v", doc["schema"])
	}
	if notice, ok := doc["notice"].([]any); !ok || len(notice) != 4 {
		t.Fatalf("notice = %v", doc["notice"])
	}
	if got := len(doc["sessions"].([]any)); got != 2 {
		t.Fatalf("export sessions = %d, want 2", got)
	}
	if got := len(doc["buckets"].([]any)); got != 2 {
		t.Fatalf("export buckets = %d, want 2", got)
	}
}

func TestAppEnergyAndReport(t *testing.T) {
	now := t0.Add(2 * time.Hour)
	h := newUTC(Options{Location: time.UTC, Clock: func() time.Time { return now }, PricePerKWh: 0.5, Currency: "EUR"})
	recordRun(h, t0, 60, 1000, [6]float64{})
	app := h.AppEnergy(now)
	if app.Day.Wh <= 0 || app.Day.Currency != "EUR" {
		t.Fatalf("app energy = %+v", app)
	}
	if app.Day.Cost <= 0 {
		t.Fatalf("cost = %v, want > 0", app.Day.Cost)
	}
	if app.Week.Wh < app.Day.Wh || app.Month.Wh < app.Week.Wh {
		t.Fatalf("range nesting wrong: %+v", app)
	}
	report, err := h.Report("day", now)
	if err != nil {
		t.Fatalf("Report(day): %v", err)
	}
	if report.Range != "day" || len(report.Buckets) == 0 || report.TotalWh <= 0 {
		t.Fatalf("day report = %+v", report)
	}
	if len(report.Sessions) != 1 {
		t.Fatalf("report sessions = %+v", report.Sessions)
	}
	if _, err := h.Report("year", now); err == nil {
		t.Fatal("unknown range should error")
	}
}

func TestCost(t *testing.T) {
	if cost, ok := EstimatedCost(2500, 0.42); !ok || math.Abs(cost-1.05) > 1e-9 {
		t.Fatalf("cost = %v ok=%v, want 1.05", cost, ok)
	}
	if _, ok := EstimatedCost(math.Inf(1), 0.42); ok {
		t.Fatal("infinite Wh must be invalid")
	}
	if _, ok := EstimatedCost(10, math.Inf(1)); ok {
		t.Fatal("infinite price must be invalid")
	}
	if _, ok := EstimatedCost(10, 0); ok {
		t.Fatal("zero price means no cost")
	}
	h := newUTC(utcMeta)
	h.SetPrice(0.3, "CNY")
	if cost, ok := h.Cost(1000); !ok || math.Abs(cost-0.3) > 1e-9 {
		t.Fatalf("history cost = %v", cost)
	}
}

func TestRevisionAndDeleteRange(t *testing.T) {
	h := newUTC(utcMeta)
	recordRun(h, t0, 60, 60, [6]float64{})
	rev1 := h.Revision()
	// Duplicate timestamp is a no-op.
	h.Record(t0.Add(60*time.Second), 60, [6]float64{})
	if h.Revision() != rev1 {
		t.Fatal("duplicate timestamp must not bump the revision")
	}
	recordRun(h, t0.Add(400*time.Second), 60, 60, [6]float64{})
	if h.Revision() == rev1 {
		t.Fatal("integration should bump the revision")
	}
	before := h.Summary(t0.Add(-time.Hour).UnixMilli(), t0.Add(time.Hour).UnixMilli())
	if !h.DeleteRange(t0.Add(-time.Second).UnixMilli(), t0.Add(100*time.Second).UnixMilli()) {
		t.Fatal("DeleteRange should report a change")
	}
	after := h.Summary(t0.Add(-time.Hour).UnixMilli(), t0.Add(time.Hour).UnixMilli())
	if after.EnergyWh >= before.EnergyWh {
		t.Fatalf("DeleteRange did not remove energy: %v -> %v", before.EnergyWh, after.EnergyWh)
	}
}
