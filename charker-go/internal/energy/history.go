// Package energy integrates charger power telemetry into energy history: Wh
// integration with gap rules, hourly/day/month buckets, a session ledger,
// retention folding, cheap app aggregates and CSV/JSON export.
//
// The A2687 exposes no energy counter, so everything here is a local
// integration of observed power samples (spec-protocol §6.3). Timestamps are
// epoch milliseconds in the archive; all bucket keys are calendar hours/days/
// months in the history's location.
package energy

import (
	"fmt"
	"math"
	"sync"
	"time"
)

// Per-port arrays are always six entries (C1…C4, A1, A2).
const PortCount = 6

// Integration / retention constants (spec-protocol §6.3).
const (
	// MaximumGapSeconds: a longer gap closes the session and carries no energy.
	MaximumGapSeconds = 120.0
	maximumGapMs      = int64(MaximumGapSeconds * 1000)

	hourlyRetentionDays  = 90
	dailyRetentionDays   = 730
	sessionRetentionDays = 90
	maxSessions          = 4000
	clockRunawayDays     = 730
)

// Bucket is one aggregated energy bucket at some resolution.
type Bucket struct {
	StartedAtMs   int64      `json:"startedAt"`
	EndedAtMs     int64      `json:"endedAt"`
	EnergyWh      float64    `json:"energyWh"`
	ActiveSeconds float64    `json:"activeSeconds"`
	PeakWatts     float64    `json:"peakWatts"`
	PerPortWh     [6]float64 `json:"perPortWh"`
}

// AverageWatts is the bucket's mean power while active.
func (b Bucket) AverageWatts() float64 {
	if b.ActiveSeconds <= 0 {
		return 0
	}
	return b.EnergyWh * 3600 / b.ActiveSeconds
}

// SessionRecord is one charging run in the ledger.
type SessionRecord struct {
	ID            string     `json:"id"`
	StartedAtMs   int64      `json:"startedAt"`
	EndedAtMs     int64      `json:"endedAt"`
	EnergyWh      float64    `json:"energyWh"`
	ActiveSeconds float64    `json:"activeSeconds"`
	PeakWatts     float64    `json:"peakWatts"`
	PerPortWh     [6]float64 `json:"perPortWh"`
	SampleCount   int        `json:"sampleCount"`
}

// AverageWatts is the run's mean power while active.
func (s SessionRecord) AverageWatts() float64 {
	if s.ActiveSeconds <= 0 {
		return 0
	}
	return s.EnergyWh * 3600 / s.ActiveSeconds
}

// Summary aggregates a time range from the buckets.
type Summary struct {
	EnergyWh      float64    `json:"energyWh"`
	ActiveSeconds float64    `json:"activeSeconds"`
	PeakWatts     float64    `json:"peakWatts"`
	PerPortWh     [6]float64 `json:"perPortWh"`
	SessionCount  int        `json:"sessionCount"`
}

// AppEnergy is the cheap cached aggregate the dashboard AppState.energy uses.
type AppEnergy struct {
	Day   EnergyCard `json:"day"`
	Week  EnergyCard `json:"week"`
	Month EnergyCard `json:"month"`
}

// EnergyCard is one range's total energy and cost.
type EnergyCard struct {
	Wh       float64 `json:"wh"`
	Cost     float64 `json:"cost"`
	Currency string  `json:"currency"`
}

// Report is the detailed range report returned by Charker.energyReport.
type Report struct {
	Range    string          `json:"range"`
	Buckets  []ReportBucket  `json:"buckets"`
	TotalWh  float64         `json:"totalWh"`
	Cost     float64         `json:"cost"`
	Currency string          `json:"currency"`
	Sessions []ReportSession `json:"sessions"`
}

// ReportBucket is one chart point.
type ReportBucket struct {
	T  int64   `json:"t"`
	Wh float64 `json:"wh"`
}

// ReportSession is one ledger row.
type ReportSession struct {
	StartMs int64   `json:"startMs"`
	EndMs   int64   `json:"endMs"`
	Wh      float64 `json:"wh"`
	PeakW   float64 `json:"peakW"`
}

// RecordResult describes what one Record call did.
type RecordResult struct {
	Opened     bool
	Integrated bool
	GapClosed  bool
	EnergyWh   float64
	Revision   uint64
}

// CompactResult reports what one retention pass folded.
type CompactResult struct {
	FoldedHourly   int
	FoldedDaily    int
	FoldedSessions int
	Skipped        bool
}

// Options configures a History.
type Options struct {
	// Clock is the wall-clock source (nil = time.Now).
	Clock func() time.Time
	// Location is the calendar used for day/month bucketing (nil = time.Local).
	Location *time.Location
	// PricePerKWh is the electricity price; <= 0 disables cost.
	PricePerKWh float64
	// Currency is the 3-letter currency code.
	Currency string
}

// History is the energy ledger. All methods are safe for concurrent use.
type History struct {
	mu       sync.Mutex
	now      func() time.Time
	loc      *time.Location
	hourly   []Bucket
	daily    []Bucket
	monthly  []Bucket
	sessions []SessionRecord

	open *openRun
	last *measurement

	price    float64
	currency string

	revision                 uint64
	archivedSessionCount     int
	archivedSessionsBeforeMs int64
	skippedCompaction        bool

	sessionSeq int
}

type openRun struct {
	startedAtMs   int64
	endedAtMs     int64
	energyWh      float64
	activeSeconds float64
	peakWatts     float64
	perPortWh     [6]float64
	sampleCount   int
}

type measurement struct {
	atMs    int64
	total   float64
	perPort [6]float64
}

// New creates an empty history.
func New(opts Options) *History {
	now := opts.Clock
	if now == nil {
		now = time.Now
	}
	loc := opts.Location
	if loc == nil {
		loc = time.Local
	}
	currency := opts.Currency
	if currency == "" {
		currency = "CNY"
	}
	return &History{
		now:      now,
		loc:      loc,
		price:    opts.PricePerKWh,
		currency: currency,
	}
}

// SetPrice updates the cost model.
func (h *History) SetPrice(pricePerKWh float64, currency string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if math.IsNaN(pricePerKWh) || math.IsInf(pricePerKWh, 0) || pricePerKWh < 0 {
		pricePerKWh = 0
	}
	if currency == "" {
		currency = "CNY"
	}
	if h.price == pricePerKWh && h.currency == currency {
		return
	}
	h.price = pricePerKWh
	h.currency = currency
	h.revision++
}

// Price returns the cost model.
func (h *History) Price() (float64, string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.price, h.currency
}

// Revision is a process-wide change counter (not persisted).
func (h *History) Revision() uint64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.revision
}

// EstimatedCost is the package-level cost helper: Wh / 1000 * price, valid only
// for a positive finite price and non-negative finite Wh.
func EstimatedCost(wattHours, pricePerKWh float64) (float64, bool) {
	if math.IsNaN(wattHours) || math.IsInf(wattHours, 0) || wattHours < 0 {
		return 0, false
	}
	if math.IsNaN(pricePerKWh) || math.IsInf(pricePerKWh, 0) || pricePerKWh <= 0 {
		return 0, false
	}
	return wattHours / 1000 * pricePerKWh, true
}

// Cost is the method form of EstimatedCost with the history's price.
func (h *History) Cost(wattHours float64) (float64, bool) {
	h.mu.Lock()
	price := h.price
	h.mu.Unlock()
	return EstimatedCost(wattHours, price)
}

// clampWatts normalises a power value: non-finite/negative → 0.
func clampWatts(v float64) float64 {
	if math.IsNaN(v) || math.IsInf(v, 0) || v < 0 {
		return 0
	}
	return v
}

// normalizePorts clamps and normalises a per-port array to six entries.
func normalizePorts(per [6]float64) [6]float64 {
	var out [6]float64
	for i := range out {
		out[i] = clampWatts(per[i])
	}
	return out
}

// Record feeds one power measurement into the ledger.
func (h *History) Record(at time.Time, totalWatts float64, perPortWatts [6]float64) RecordResult {
	h.mu.Lock()
	defer h.mu.Unlock()
	atMs := at.UnixMilli()
	if atMs <= 0 {
		atMs = h.now().UnixMilli()
	}
	cur := measurement{atMs: atMs, total: clampWatts(totalWatts), perPort: normalizePorts(perPortWatts)}
	res := RecordResult{Revision: h.revision}
	if h.last == nil {
		h.startOpenLocked(atMs, cur)
		h.last = &cur
		h.revision++
		res.Opened = true
		res.Revision = h.revision
		return res
	}
	elapsed := atMs - h.last.atMs
	if elapsed <= 0 {
		return res // duplicate/older timestamp is a no-op
	}
	if elapsed >= maximumGapMs {
		h.closeOpenLocked()
		h.startOpenLocked(atMs, cur)
		h.last = &cur
		h.revision++
		res.Opened = true
		res.GapClosed = true
		res.Revision = h.revision
		return res
	}
	prev := *h.last
	dt := float64(elapsed) / 1000
	energy := dt * (prev.total + cur.total) / 2 / 3600
	h.open.energyWh += energy
	h.open.activeSeconds += dt
	if cur.total > h.open.peakWatts {
		h.open.peakWatts = cur.total
	}
	for i := 0; i < PortCount; i++ {
		h.open.perPortWh[i] += dt * (prev.perPort[i] + cur.perPort[i]) / 2 / 3600
	}
	h.open.endedAtMs = atMs
	h.open.sampleCount++
	h.attributeIntervalLocked(prev, cur)
	h.last = &cur
	h.revision++
	res.Integrated = true
	res.EnergyWh = energy
	res.Revision = h.revision
	return res
}

func (h *History) startOpenLocked(atMs int64, m measurement) {
	h.open = &openRun{
		startedAtMs: atMs,
		endedAtMs:   atMs,
		peakWatts:   m.total,
		sampleCount: 1,
	}
}

// closeOpenLocked archives the current run into the session ledger.
func (h *History) closeOpenLocked() {
	if h.open == nil {
		return
	}
	run := h.open
	h.sessionSeq++
	rec := SessionRecord{
		ID:            fmt.Sprintf("sess-%d-%d", run.startedAtMs, h.sessionSeq),
		StartedAtMs:   run.startedAtMs,
		EndedAtMs:     run.endedAtMs,
		EnergyWh:      run.energyWh,
		ActiveSeconds: run.activeSeconds,
		PeakWatts:     run.peakWatts,
		PerPortWh:     run.perPortWh,
		SampleCount:   run.sampleCount,
	}
	h.sessions = append(h.sessions, rec)
	h.open = nil
	h.last = nil
}

// FinishCurrentSession closes the current run; the next Record starts a new
// session (spec §6.3).
func (h *History) FinishCurrentSession() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.open == nil {
		return
	}
	h.closeOpenLocked()
	h.revision++
}

// attributeIntervalLocked splits one interval at hour boundaries and adds the
// segments to the hourly, daily and monthly buckets.
func (h *History) attributeIntervalLocked(prev, cur measurement) {
	start, end := prev.atMs, cur.atMs
	if end <= start {
		return
	}
	totalSpan := float64(end - start)
	for pos := start; pos < end; {
		hourStartMs := startOfHour(pos, h.loc).UnixMilli()
		hourEndMs := startOfHour(pos, h.loc).Add(time.Hour).UnixMilli()
		segEnd := end
		if segEnd > hourEndMs {
			segEnd = hourEndMs
		}
		if segEnd <= pos {
			break
		}
		frac0 := float64(pos-start) / totalSpan
		frac1 := float64(segEnd-start) / totalSpan
		w0 := prev.total + (cur.total-prev.total)*frac0
		w1 := prev.total + (cur.total-prev.total)*frac1
		var p0, p1 [6]float64
		for i := 0; i < PortCount; i++ {
			p0[i] = prev.perPort[i] + (cur.perPort[i]-prev.perPort[i])*frac0
			p1[i] = prev.perPort[i] + (cur.perPort[i]-prev.perPort[i])*frac1
		}
		seconds := float64(segEnd-pos) / 1000
		energy := seconds * (w0 + w1) / 2 / 3600
		var perWh [6]float64
		for i := 0; i < PortCount; i++ {
			perWh[i] = seconds * (p0[i] + p1[i]) / 2 / 3600
		}
		peak := math.Max(w0, w1)
		addOrMergeBucket(&h.hourly, hourStartMs, segEnd, energy, seconds, peak, perWh)
		addOrMergeBucket(&h.daily, h.startOfDayMs(pos), pos, energy, seconds, peak, perWh)
		addOrMergeBucket(&h.monthly, h.startOfMonthMs(pos), pos, energy, seconds, peak, perWh)
		pos = segEnd
	}
}

func addOrMergeBucket(list *[]Bucket, startMs, endMs int64, energy, active, peak float64, per [6]float64) {
	buckets := *list
	// Buckets are appended in time order; look at the tail first.
	if n := len(buckets); n > 0 && buckets[n-1].StartedAtMs == startMs {
		b := &buckets[n-1]
		b.EnergyWh += energy
		b.ActiveSeconds += active
		if peak > b.PeakWatts {
			b.PeakWatts = peak
		}
		if endMs > b.EndedAtMs {
			b.EndedAtMs = endMs
		}
		for i := 0; i < PortCount; i++ {
			b.PerPortWh[i] += per[i]
		}
		return
	}
	idx := len(buckets)
	for idx > 0 && buckets[idx-1].StartedAtMs > startMs {
		idx--
	}
	if idx > 0 && buckets[idx-1].StartedAtMs == startMs {
		b := &buckets[idx-1]
		b.EnergyWh += energy
		b.ActiveSeconds += active
		if peak > b.PeakWatts {
			b.PeakWatts = peak
		}
		if endMs > b.EndedAtMs {
			b.EndedAtMs = endMs
		}
		for i := 0; i < PortCount; i++ {
			b.PerPortWh[i] += per[i]
		}
		return
	}
	buckets = append(buckets, Bucket{})
	copy(buckets[idx+1:], buckets[idx:])
	buckets[idx] = Bucket{
		StartedAtMs:   startMs,
		EndedAtMs:     endMs,
		EnergyWh:      energy,
		ActiveSeconds: active,
		PeakWatts:     peak,
		PerPortWh:     per,
	}
	*list = buckets
}

// Compact applies the retention policy:
//
//	hourly detail 90 days, day detail 730 days, sessions 90 days / 4000 max.
//
// Folding is lossy in resolution only: coarser buckets already carry the same
// energy (hourly/daily/monthly are accumulated independently), so totals are
// preserved. A runaway wall clock (archive more than 730 days in the future)
// skips compaction and deletes nothing.
func (h *History) Compact(now time.Time) CompactResult {
	h.mu.Lock()
	defer h.mu.Unlock()
	var res CompactResult
	latest := h.latestRecordMsLocked()
	if latest == 0 {
		return res
	}
	if now.UnixMilli()-latest > int64(clockRunawayDays)*24*3600*1000 {
		h.skippedCompaction = true
		res.Skipped = true
		return res
	}
	h.skippedCompaction = false
	hourCut := now.AddDate(0, 0, -hourlyRetentionDays).UnixMilli()
	if n := len(h.hourly); n > 0 {
		keep := 0
		for keep < n && h.hourly[keep].StartedAtMs < hourCut {
			keep++
		}
		if keep > 0 {
			res.FoldedHourly = keep
			h.hourly = append([]Bucket(nil), h.hourly[keep:]...)
		}
	}
	dayCut := now.AddDate(0, 0, -dailyRetentionDays).UnixMilli()
	if n := len(h.daily); n > 0 {
		keep := 0
		for keep < n && h.daily[keep].StartedAtMs < dayCut {
			keep++
		}
		if keep > 0 {
			res.FoldedDaily = keep
			h.daily = append([]Bucket(nil), h.daily[keep:]...)
		}
	}
	sessionCut := now.AddDate(0, 0, -sessionRetentionDays).UnixMilli()
	if n := len(h.sessions); n > 0 {
		keep := 0
		for keep < n && h.sessions[keep].EndedAtMs < sessionCut {
			if h.sessions[keep].EndedAtMs > h.archivedSessionsBeforeMs {
				h.archivedSessionsBeforeMs = h.sessions[keep].EndedAtMs
			}
			h.archivedSessionCount++
			keep++
		}
		if extra := len(h.sessions) - keep - maxSessions; extra > 0 {
			if h.sessions[keep+extra-1].EndedAtMs > h.archivedSessionsBeforeMs {
				h.archivedSessionsBeforeMs = h.sessions[keep+extra-1].EndedAtMs
			}
			h.archivedSessionCount += extra
			keep += extra
		}
		if keep > 0 {
			res.FoldedSessions = keep
			h.sessions = append([]SessionRecord(nil), h.sessions[keep:]...)
		}
	}
	if res.FoldedHourly+res.FoldedDaily+res.FoldedSessions > 0 {
		h.revision++
	}
	return res
}

func (h *History) latestRecordMsLocked() int64 {
	var latest int64
	for _, list := range [][]Bucket{h.hourly, h.daily, h.monthly} {
		if n := len(list); n > 0 && list[n-1].EndedAtMs > latest {
			latest = list[n-1].EndedAtMs
		}
	}
	if n := len(h.sessions); n > 0 && h.sessions[n-1].EndedAtMs > latest {
		latest = h.sessions[n-1].EndedAtMs
	}
	if h.last != nil && h.last.atMs > latest {
		latest = h.last.atMs
	}
	return latest
}

// SkippedCompaction reports whether the last Compact run was skipped because
// of a runaway clock.
func (h *History) SkippedCompaction() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.skippedCompaction
}

// --- calendar helpers ---

func (h *History) startOfDayMs(ms int64) int64 {
	return startOfDay(ms, h.loc).UnixMilli()
}

func (h *History) startOfMonthMs(ms int64) int64 {
	return startOfMonth(ms, h.loc).UnixMilli()
}

func startOfHour(ms int64, loc *time.Location) time.Time {
	t := time.UnixMilli(ms).In(loc)
	return time.Date(t.Year(), t.Month(), t.Day(), t.Hour(), 0, 0, 0, loc)
}

func startOfDay(ms int64, loc *time.Location) time.Time {
	t := time.UnixMilli(ms).In(loc)
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, loc)
}

func startOfMonth(ms int64, loc *time.Location) time.Time {
	t := time.UnixMilli(ms).In(loc)
	return time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, loc)
}

// --- aggregates ---

// Summary aggregates [fromMs, toMs). It uses hourly detail for short ranges and
// daily detail for longer ones, plus monthly detail older than the daily
// retention window.
func (h *History) Summary(fromMs, toMs int64) Summary {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.summaryLocked(fromMs, toMs)
}

func (h *History) summaryLocked(fromMs, toMs int64) Summary {
	var sum Summary
	if toMs <= fromMs {
		return sum
	}
	useHourly := toMs-fromMs <= int64(48*time.Hour/time.Millisecond)
	add := func(b Bucket) {
		sum.EnergyWh += b.EnergyWh
		sum.ActiveSeconds += b.ActiveSeconds
		if b.PeakWatts > sum.PeakWatts {
			sum.PeakWatts = b.PeakWatts
		}
		for i := 0; i < PortCount; i++ {
			sum.PerPortWh[i] += b.PerPortWh[i]
		}
	}
	buckets := h.daily
	if useHourly {
		buckets = h.hourly
	}
	for _, b := range buckets {
		if b.StartedAtMs >= fromMs && b.StartedAtMs < toMs {
			add(b)
		}
	}
	// Monthly buckets cover anything older than the daily retention window.
	for _, b := range h.monthly {
		if b.StartedAtMs >= fromMs && b.StartedAtMs < toMs {
			// Skip months that also have daily detail to avoid double counting.
			if h.hasDailyInMonth(b.StartedAtMs) {
				continue
			}
			add(b)
		}
	}
	for _, s := range h.sessions {
		if s.EndedAtMs >= fromMs && s.StartedAtMs < toMs {
			sum.SessionCount++
		}
	}
	if h.open != nil && h.open.endedAtMs >= fromMs && h.open.startedAtMs < toMs {
		sum.SessionCount++
	}
	if fromMs < h.archivedSessionsBeforeMs {
		sum.SessionCount += h.archivedSessionCount
	}
	return sum
}

func (h *History) hasDailyInMonth(monthStartMs int64) bool {
	monthEnd := time.UnixMilli(monthStartMs).In(h.loc)
	endMs := time.Date(monthEnd.Year(), monthEnd.Month()+1, 1, 0, 0, 0, 0, h.loc).UnixMilli()
	for _, b := range h.daily {
		if b.StartedAtMs >= monthStartMs && b.StartedAtMs < endMs {
			return true
		}
	}
	return false
}

// AppEnergy returns the cheap day/week/month aggregates for AppState.energy.
func (h *History) AppEnergy(now time.Time) AppEnergy {
	h.mu.Lock()
	defer h.mu.Unlock()
	dayStart := startOfDay(now.UnixMilli(), h.loc)
	weekStart := dayStart.AddDate(0, 0, -6)
	monthStart := dayStart.AddDate(0, 0, -29)
	energyCard := func(from time.Time) EnergyCard {
		sum := h.summaryLocked(from.UnixMilli(), now.UnixMilli()+1)
		card := EnergyCard{Wh: round2(sum.EnergyWh), Currency: h.currency}
		if cost, ok := EstimatedCost(sum.EnergyWh, h.price); ok {
			card.Cost = round2(cost)
		}
		return card
	}
	return AppEnergy{
		Day:   energyCard(dayStart),
		Week:  energyCard(weekStart),
		Month: energyCard(monthStart),
	}
}

// Report builds the detailed range report for "day", "week" or "month".
func (h *History) Report(rangeName string, now time.Time) (Report, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	dayStart := startOfDay(now.UnixMilli(), h.loc)
	var from time.Time
	buckets := h.daily
	switch rangeName {
	case "day":
		from = dayStart
		buckets = h.hourly
	case "week":
		from = dayStart.AddDate(0, 0, -6)
	case "month":
		from = dayStart.AddDate(0, 0, -29)
	default:
		return Report{}, fmt.Errorf("energy: unknown range %q", rangeName)
	}
	toMs := now.UnixMilli() + 1
	out := Report{Range: rangeName, Currency: h.currency, Buckets: []ReportBucket{}, Sessions: []ReportSession{}}
	var total float64
	for _, b := range buckets {
		if b.StartedAtMs < from.UnixMilli() || b.StartedAtMs >= toMs {
			continue
		}
		out.Buckets = append(out.Buckets, ReportBucket{T: b.StartedAtMs, Wh: round2(b.EnergyWh)})
		total += b.EnergyWh
	}
	out.TotalWh = round2(total)
	if cost, ok := EstimatedCost(total, h.price); ok {
		out.Cost = round2(cost)
	}
	sessionRows := make([]ReportSession, 0, len(h.sessions)+1)
	for _, s := range h.sessions {
		if s.EndedAtMs < from.UnixMilli() || s.StartedAtMs >= toMs {
			continue
		}
		sessionRows = append(sessionRows, ReportSession{StartMs: s.StartedAtMs, EndMs: s.EndedAtMs, Wh: round2(s.EnergyWh), PeakW: round2(s.PeakWatts)})
	}
	if h.open != nil && h.open.endedAtMs >= from.UnixMilli() && h.open.startedAtMs < toMs {
		sessionRows = append(sessionRows, ReportSession{StartMs: h.open.startedAtMs, EndMs: h.open.endedAtMs, Wh: round2(h.open.energyWh), PeakW: round2(h.open.peakWatts)})
	}
	out.Sessions = sessionRows
	return out, nil
}

// Clear drops all history.
func (h *History) Clear() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.hourly = nil
	h.daily = nil
	h.monthly = nil
	h.sessions = nil
	h.open = nil
	h.last = nil
	h.archivedSessionCount = 0
	h.archivedSessionsBeforeMs = 0
	h.revision++
}

// DeleteRange removes energy and sessions whose start lies in [fromMs, toMs).
func (h *History) DeleteRange(fromMs, toMs int64) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if toMs <= fromMs {
		return false
	}
	changed := false
	filter := func(list []Bucket) []Bucket {
		out := make([]Bucket, 0, len(list))
		for _, b := range list {
			if b.StartedAtMs >= fromMs && b.StartedAtMs < toMs {
				changed = true
				continue
			}
			out = append(out, b)
		}
		return out
	}
	h.hourly = filter(h.hourly)
	h.daily = filter(h.daily)
	h.monthly = filter(h.monthly)
	sessions := make([]SessionRecord, 0, len(h.sessions))
	for _, s := range h.sessions {
		if s.StartedAtMs >= fromMs && s.StartedAtMs < toMs {
			changed = true
			continue
		}
		sessions = append(sessions, s)
	}
	h.sessions = sessions
	if changed {
		h.revision++
	}
	return changed
}

// Sessions returns a copy of the closed session ledger.
func (h *History) Sessions() []SessionRecord {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]SessionRecord(nil), h.sessions...)
}

// OpenSession returns the active run as a record, or nil.
func (h *History) OpenSession() *SessionRecord {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.open == nil {
		return nil
	}
	rec := SessionRecord{
		ID:            "open",
		StartedAtMs:   h.open.startedAtMs,
		EndedAtMs:     h.open.endedAtMs,
		EnergyWh:      h.open.energyWh,
		ActiveSeconds: h.open.activeSeconds,
		PeakWatts:     h.open.peakWatts,
		PerPortWh:     h.open.perPortWh,
		SampleCount:   h.open.sampleCount,
	}
	return &rec
}

func round2(v float64) float64 { return math.Round(v*100) / 100 }
