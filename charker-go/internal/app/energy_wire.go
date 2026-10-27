package app

import (
	"fmt"
	"log"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"charker/internal/energy"
	"charker/internal/product"
)

// energySaveDelay is AppModel.scheduleEnergySave: at most one save per 15 s
// while samples arrive, so a crash mid-charge loses at most that much.
const energySaveDelay = 15 * time.Second

// energyScopes are DashboardEnergyScope's cases, the keys of
// AppState.energy.scopes.
var energyScopes = []string{"session", "day", "week", "month"}

// EnergyService is AppModel's energy half: the persisted ledger of the real
// charger, the in-memory demo fixture shown in demo mode, and the actions
// on them. Like AppModel.displayedEnergyHistory it shows the demo ledger
// while demo mode is on and never writes, exports or clears it.
//
// Lock order: App.mu before EnergyService.mu, never the reverse. Summary is
// called with App.mu held; nothing here calls back into App while holding
// e.mu.
type EnergyService struct {
	mu  sync.Mutex
	cal energy.Calendar
	// books are the persisted ledgers, one per product, as on macOS
	// (energy-history-v1.json and energy-history-a2345-v1.json).
	books map[product.ChargerProduct]*energyBook
	// active is the product on screen (AppModel.usesA2345); demoProduct is
	// Preferences.demoProduct. Both are seams the product switch drives.
	active      product.ChargerProduct
	demoProduct product.ChargerProduct
	demoBook    *energy.History
	demo        bool
	price       float64
	currency    string
	saveTimer   *time.Timer
	app         *App
}

// energyBook is one product's persisted ledger and its warning
// (energyHistoryWarning / a2345EnergyHistoryWarning).
type energyBook struct {
	store   *energy.Store
	hist    *energy.History
	warning *energy.Text
}

// NewEnergyService loads the ledger under baseDir (the user-data directory)
// and, when the app starts in demo mode, builds the demo fixture. It returns
// nil when baseDir is empty.
func NewEnergyService(baseDir string, pricePerKWh float64, currency string, demo bool) *EnergyService {
	if baseDir == "" {
		return nil
	}
	cal := energy.Calendar{}
	e := &EnergyService{
		cal:         cal,
		books:       map[product.ChargerProduct]*energyBook{},
		active:      product.ProductA2687,
		demoProduct: product.ProductA2687,
		demo:        demo,
		price:       pricePerKWh,
		currency:    currency,
	}
	for p, name := range map[product.ChargerProduct]string{
		product.ProductA2687: energy.ArchiveFileName,
		product.ProductA2345: energy.A2345ArchiveFileName,
	} {
		store := energy.NewStore(filepath.Join(baseDir, name))
		hist, warning := store.Load(time.Now(), cal)
		if warning != nil {
			log.Printf("app: energy history %s: %s %v", p, warning.Key, warning.Args)
		}
		e.books[p] = &energyBook{store: store, hist: hist, warning: warning}
	}
	if demo {
		e.demoBook = e.makeDemo()
	}
	return e
}

func (e *EnergyService) makeDemo() *energy.History {
	return energy.DemoHistory(time.Now(), e.cal, e.demoProduct == product.ProductA2345)
}

// SetProducts selects the product on screen and the demo product (the
// AppModel.usesA2345 / Preferences.demoProduct seam). A change rebuilds the
// observation like AppModel.buildSession: every open run is finished.
func (e *EnergyService) SetProducts(active, demoProduct product.ChargerProduct) {
	if e == nil {
		return
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if active == e.active && demoProduct == e.demoProduct {
		return
	}
	e.finishAllLocked()
	e.active, e.demoProduct = active, demoProduct
	if e.demo {
		e.demoBook = e.makeDemo()
	}
}

// book returns a product's ledger (the A2687's for an unknown product).
func (e *EnergyService) book(p product.ChargerProduct) *energyBook {
	if b := e.books[p]; b != nil {
		return b
	}
	return e.books[product.ProductA2687]
}

// Attach lets the service follow the app's demo mode. Call it right after
// app.New.
func (e *EnergyService) Attach(a *App) {
	if e == nil {
		return
	}
	e.mu.Lock()
	e.app = a
	e.mu.Unlock()
	a.syncEnergyProducts()
}

// Warning is "": the energy page shows the load warning itself, as on the
// Mac, rather than as an app-wide notice.
func (e *EnergyService) Warning() string { return "" }

// RecordAt feeds one A2687 BLE sample (the session's OnSample hook).
func (e *EnergyService) RecordAt(atUnixMs int64, totalWatts float64, perPortWatts [6]float64, mock bool) {
	e.Record(product.ProductA2687, atUnixMs, totalWatts, perPortWatts, mock)
}

// Record feeds one telemetry sample of a product into the ledger of its
// source: simulator samples into the demo fixture, charger samples into the
// product's persisted ledger (AppModel.recordEnergy). perPortWatts uses the
// six ChargerPortID slots C1 C2 C3 C4 A1 A2.
func (e *EnergyService) Record(p product.ChargerProduct, atUnixMs int64, totalWatts float64, perPortWatts [6]float64, mock bool) {
	if e == nil {
		return
	}
	m := energy.NewMeasurement(time.UnixMilli(atUnixMs), totalWatts, perPortWatts[:])
	e.mu.Lock()
	defer e.mu.Unlock()
	if mock {
		if e.demoBook == nil {
			e.demoBook = e.makeDemo()
		}
		e.demoBook.Record(m, e.cal)
		return
	}
	e.book(p).hist.Record(m, e.cal)
	e.scheduleSaveLocked()
}

// SetPrice updates the electricity price used for the cost estimates.
func (e *EnergyService) SetPrice(pricePerKWh float64, currency string) {
	if e == nil {
		return
	}
	e.mu.Lock()
	e.price, e.currency = pricePerKWh, currency
	e.mu.Unlock()
}

// syncDemoLocked follows a demo-mode switch the way AppModel.buildSession
// does: every open run is finished (and the real ledger saved), and entering
// demo mode rebuilds the fixture. e.mu must be held.
func (e *EnergyService) syncDemoLocked(demo bool) {
	if demo == e.demo {
		return
	}
	e.finishAllLocked()
	if demo {
		e.demoBook = e.makeDemo()
	}
	e.demo = demo
}

// finishAllLocked is AppModel.finishEnergyObservation: every ledger's open
// run is closed and the persisted ones are saved.
func (e *EnergyService) finishAllLocked() {
	e.stopSaveTimerLocked()
	if e.demoBook != nil {
		e.demoBook.FinishCurrentSession()
	}
	for _, b := range e.books {
		b.hist.FinishCurrentSession()
	}
	e.saveLocked()
}

// Break is finishA2345EnergyObservation: the open runs end here (device
// switch, failure, sign-out) so a later sample starts a new one.
func (e *EnergyService) Break() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.finishAllLocked()
}

// syncDemo reads the app's demo flag (taking App.mu) and follows it.
func (e *EnergyService) syncDemo() {
	e.mu.Lock()
	a := e.app
	e.mu.Unlock()
	if a == nil {
		return
	}
	a.mu.Lock()
	demo := a.demo
	a.mu.Unlock()
	e.mu.Lock()
	e.syncDemoLocked(demo)
	e.mu.Unlock()
}

// displayedLocked is AppModel.displayedEnergyHistory. e.mu must be held.
func (e *EnergyService) displayedLocked() *energy.History {
	if e.demo {
		if e.demoBook == nil {
			e.demoBook = e.makeDemo()
		}
		return e.demoBook
	}
	return e.book(e.active).hist
}

// productLocked is the product whose ledger is displayed.
func (e *EnergyService) productLocked() product.ChargerProduct {
	if e.demo {
		return e.demoProduct
	}
	return e.active
}

// portSlots maps a product's ports to their ChargerPortID raw values.
func portSlots(p product.ChargerProduct) []int {
	slots := map[product.PortID]int{"C1": 0, "C2": 1, "C3": 2, "C4": 3, "A1": 4, "A2": 5}
	out := []int{}
	for _, id := range p.PortIDs() {
		out = append(out, slots[id])
	}
	return out
}

func portLabels(p product.ChargerProduct) []string {
	out := []string{}
	for _, id := range p.PortIDs() {
		out = append(out, string(id))
	}
	return out
}

func ratedWatts(p product.ChargerProduct) float64 {
	if p == product.ProductA2345 {
		return 250
	}
	return 160
}

// Summary returns AppState.energy. The caller holds App.mu (buildStateLocked),
// so the app's demo flag is read directly.
func (e *EnergyService) Summary() EnergySummary {
	if e == nil {
		return EnergySummary{Product: string(product.ProductA2687), Ports: portLabels(product.ProductA2687), Scopes: emptyScopes("")}
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.app != nil {
		e.syncDemoLocked(e.app.demo)
	}
	h := e.displayedLocked()
	p := e.productLocked()
	now := time.Now()
	end := now.Add(time.Second)
	out := EnergySummary{
		HasActiveSession: h.ActiveSession() != nil,
		Ephemeral:        e.demo,
		Revision:         h.Revision(),
		Product:          string(p),
		Ports:            portLabels(p),
		Scopes:           map[string]EnergyScopeSummary{},
	}
	for _, scope := range energyScopes {
		var s energy.Summary
		if scope == "session" {
			s = h.CurrentSessionSummary()
		} else {
			s = h.Summary(e.rangeStart(scope, now), end)
		}
		perPort := []float64{}
		for _, slot := range portSlots(p) {
			perPort = append(perPort, s.PerPortWh[slot])
		}
		out.Scopes[scope] = EnergyScopeSummary{
			Wh:       s.EnergyWh,
			Cost:     e.costLocked(s.EnergyWh),
			Currency: e.currency,
			PerPort:  perPort,
		}
	}
	return out
}

func emptyScopes(currency string) map[string]EnergyScopeSummary {
	out := map[string]EnergyScopeSummary{}
	for _, scope := range energyScopes {
		out[scope] = EnergyScopeSummary{Currency: currency, PerPort: make([]float64, product.ProductA2687.PortCount())}
	}
	return out
}

func (e *EnergyService) costLocked(wh float64) *float64 {
	if c, ok := energy.EstimatedCost(wh, e.price); ok {
		return &c
	}
	return nil
}

// rangeStart is HistoryRange.start: nil for "all" (and "session", which
// the caller resolves from the open run).
func (e *EnergyService) rangeStart(r string, now time.Time) *time.Time {
	var t time.Time
	switch r {
	case "day":
		t = e.cal.StartOfDay(now)
	case "week":
		t = e.cal.WeekStart(now)
	case "month":
		t = e.cal.MonthStart(now)
	default:
		return nil
	}
	return &t
}

// clearInterval is HistoryClearScope.interval.
func (e *EnergyService) clearInterval(scope string, now time.Time) (energy.Interval, bool) {
	switch scope {
	case "day":
		return e.cal.DayInterval(now), true
	case "week":
		return e.cal.WeekInterval(now), true
	case "month":
		return e.cal.MonthInterval(now), true
	}
	return energy.Interval{}, false
}

// Report builds EnergyHistoryView's digest for one range.
func (e *EnergyService) Report(rangeArg string) EnergyReport {
	if e == nil {
		return EnergyReport{Range: rangeArg, Periods: []EnergyRecord{}, Sessions: []EnergyRecord{}, Clearable: map[string]bool{}}
	}
	e.syncDemo()
	e.mu.Lock()
	defer e.mu.Unlock()
	h := e.displayedLocked()
	p := e.productLocked()
	now := time.Now()
	end := now.Add(time.Second)
	week := e.cal.WeekInterval(now)
	rep := EnergyReport{
		Range:                rangeArg,
		Product:              string(p),
		Ports:                portLabels(p),
		RatedWatts:           ratedWatts(p),
		NowMs:                now.UnixMilli(),
		WeekStartMs:          week.Start.UnixMilli(),
		WeekEndMs:            week.End.UnixMilli(),
		Periods:              []EnergyRecord{},
		Sessions:             []EnergyRecord{},
		ArchivedSessionCount: h.ArchivedSessionCount(),
		Ephemeral:            e.demo,
		Clearable:            map[string]bool{},
		Revision:             h.Revision(),
	}
	active := h.ActiveSession()
	if active != nil {
		rep.ActiveSessionID = active.ID
		ms := active.StartedAt.UnixMilli()
		rep.ActiveSessionStartMs = &ms
	}

	var summary energy.Summary
	if rangeArg == "session" {
		summary = h.CurrentSessionSummary()
		if p := h.CurrentSessionPeriod(); p != nil {
			rep.Periods = append(rep.Periods, periodRecord(*p))
		}
		if active != nil {
			rep.Sessions = append(rep.Sessions, sessionRecord(*active))
			rep.RangeStartMs = rep.ActiveSessionStartMs
		}
	} else {
		start := e.rangeStart(rangeArg, now)
		if start != nil {
			ms := start.UnixMilli()
			rep.RangeStartMs = &ms
		}
		sessions := h.SessionRecords(start, end)
		summary = h.SummaryWithSessions(start, end, sessions)
		for _, s := range sessions {
			rep.Sessions = append(rep.Sessions, sessionRecord(s))
		}
		for _, p := range h.Periods(start, end, granularity(rangeArg), e.cal) {
			rep.Periods = append(rep.Periods, periodRecord(p))
		}
	}
	rep.Summary = EnergyRangeSummary{
		EnergyWh:      summary.EnergyWh,
		ActiveSeconds: summary.ActiveSeconds,
		PeakWatts:     summary.PeakWatts,
		AverageWatts:  summary.AverageWatts(),
		PerPortWh:     summary.PerPortWh[:],
		SessionCount:  summary.SessionCount,
	}

	if !e.demo {
		rep.Warning = e.book(e.active).warning
		if sc := h.SkippedCompaction(); sc != nil {
			rep.SkippedCompaction = &energy.Text{
				Key:  "系统时间（%@）远超存档里最新一条记录（%@），已跳过本次历史裁剪，未删除任何数据。请检查电脑的日期与时间。",
				Args: []any{energy.ISOText(sc.AttemptedAt, nil), energy.ISOText(sc.LatestRecordAt, nil)},
			}
		}
	}
	rep.CanClear = e.canClearLocked()
	for _, scope := range []string{"day", "week", "month"} {
		iv, _ := e.clearInterval(scope, now)
		rep.Clearable[scope] = !e.demo && h.HasRecords(iv.Start, iv.End)
	}
	rep.Exportable = !e.demo && !h.IsEmpty()
	return rep
}

func granularity(r string) energy.Granularity {
	switch r {
	case "week", "month":
		return energy.Day
	case "all":
		return energy.Month
	}
	return energy.Hour
}

func periodRecord(p energy.PeriodRecord) EnergyRecord {
	return EnergyRecord{
		StartedAt:     p.StartedAt.UnixMilli(),
		EndedAt:       p.EndedAt.UnixMilli(),
		EnergyWh:      p.EnergyWh,
		ActiveSeconds: p.ActiveSeconds,
		PeakWatts:     p.PeakWatts,
		AverageWatts:  p.AverageWatts(),
		PerPortWh:     p.PerPortWh[:],
	}
}

func sessionRecord(s energy.SessionRecord) EnergyRecord {
	return EnergyRecord{
		ID:            s.ID,
		StartedAt:     s.StartedAt.UnixMilli(),
		EndedAt:       s.EndedAt.UnixMilli(),
		EnergyWh:      s.EnergyWh,
		ActiveSeconds: s.ActiveSeconds,
		PeakWatts:     s.PeakWatts,
		AverageWatts:  s.AverageWatts(),
		PerPortWh:     s.PerPortWh[:],
		SampleCount:   s.SampleCount,
	}
}

// canClearLocked is AppModel.canClearEnergyHistory: a recovery warning also
// counts, since the clear action is how the user removes the leftover files.
func (e *EnergyService) canClearLocked() bool {
	if e.demo {
		return false
	}
	b := e.book(e.active)
	h := b.hist
	return !h.IsEmpty() || h.ArchivedSessionCount() > 0 || h.SkippedCompaction() != nil || b.warning != nil
}

// EndSession is AppModel.endCurrentEnergySession: it ends only the local
// segment; the next distinct sample starts a fresh one. It reports whether
// a segment was open.
func (e *EnergyService) EndSession() bool {
	if e == nil {
		return false
	}
	e.syncDemo()
	e.mu.Lock()
	defer e.mu.Unlock()
	h := e.displayedLocked()
	if h.ActiveSession() == nil {
		return false
	}
	e.stopSaveTimerLocked()
	h.FinishCurrentSession()
	if !e.demo {
		e.saveLocked()
	}
	return true
}

// ClearAll is AppModel.clearEnergyHistory(): the archive and its recovery
// copy are deleted first, then the memory, so a failed delete never leaves
// a page that looks empty over files that come back next launch.
func (e *EnergyService) ClearAll() (bool, error) {
	if e == nil {
		return false, nil
	}
	e.syncDemo()
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.demo || !e.canClearLocked() {
		return false, nil
	}
	e.stopSaveTimerLocked()
	b := e.book(e.active)
	if err := b.store.Clear(); err != nil {
		_ = b.store.Save(b.hist)
		b.warning = &energy.Text{Key: "能耗历史清空失败：%@", Args: []any{err.Error()}}
		return false, err
	}
	b.hist = energy.New()
	b.warning = nil
	return true, nil
}

// ClearRange is AppModel.clearEnergyHistory(from:to:) for a calendar scope
// (day, week, month). It reports whether anything was removed.
func (e *EnergyService) ClearRange(scope string) (bool, error) {
	if e == nil {
		return false, nil
	}
	e.syncDemo()
	e.mu.Lock()
	defer e.mu.Unlock()
	iv, ok := e.clearInterval(scope, time.Now())
	if !ok {
		return false, fmt.Errorf("unknown energy scope %q", scope)
	}
	if e.demo {
		return false, nil
	}
	e.stopSaveTimerLocked()
	b := e.book(e.active)
	cleared := b.hist.Clone()
	if !cleared.RemoveRecords(iv.Start, iv.End) {
		return false, nil
	}
	if err := b.store.ReplaceAfterRemoval(cleared); err != nil {
		_ = b.store.Save(b.hist)
		b.warning = &energy.Text{Key: "能耗历史清空失败：%@", Args: []any{err.Error()}}
		return false, err
	}
	b.hist = cleared
	b.warning = nil
	return true, nil
}

// Export renders the displayed ledger as "csv" (UTF-8 with BOM, which Excel
// needs for the Chinese notice) or "json". The whole ledger is exported,
// as on the Mac; rangeArg is ignored.
func (e *EnergyService) Export(rangeArg, format string) ([]byte, error) {
	return e.exportBytes(format, "zh")
}

func (e *EnergyService) exportBytes(format, locale string) ([]byte, error) {
	if e == nil {
		return nil, fmt.Errorf("energy history is not available")
	}
	e.syncDemo()
	e.mu.Lock()
	// Taken at the press of the button: telemetry keeps arriving while the
	// save dialog is open.
	snapshot := e.displayedLocked().Clone()
	demo := e.demo
	e.mu.Unlock()
	if demo {
		return nil, fmt.Errorf("demo data is not exported")
	}
	now := time.Now()
	switch strings.ToLower(format) {
	case "csv":
		return append([]byte{0xEF, 0xBB, 0xBF}, snapshot.ExportCSV(now, nil, locale)...), nil
	case "json":
		return snapshot.ExportJSON(now, nil, locale)
	}
	return nil, fmt.Errorf("unknown export format %q", format)
}

// Finish closes the open run and writes the archive; called on exit.
func (e *EnergyService) Finish() error {
	if e == nil {
		return nil
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	e.stopSaveTimerLocked()
	var first error
	for _, b := range e.books {
		b.hist.FinishCurrentSession()
		if err := b.store.Save(b.hist); err != nil && first == nil {
			first = err
		}
	}
	return first
}

func (e *EnergyService) scheduleSaveLocked() {
	if e.saveTimer != nil {
		return
	}
	e.saveTimer = time.AfterFunc(energySaveDelay, func() {
		e.mu.Lock()
		defer e.mu.Unlock()
		e.saveTimer = nil
		e.saveLocked()
	})
}

func (e *EnergyService) stopSaveTimerLocked() {
	if e.saveTimer != nil {
		e.saveTimer.Stop()
		e.saveTimer = nil
	}
}

// saveLocked is AppModel.saveEnergyHistory: every product's ledger is
// written; a failure becomes that ledger's warning, a success clears it.
func (e *EnergyService) saveLocked() {
	for p, b := range e.books {
		if err := b.store.Save(b.hist); err != nil {
			log.Printf("app: saving %s energy history: %v", p, err)
			b.warning = &energy.Text{Key: "能耗历史保存失败：%@", Args: []any{err.Error()}}
			continue
		}
		b.warning = nil
	}
}
