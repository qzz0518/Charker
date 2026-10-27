// Package energy is the local, observation-only energy ledger: a port of
// CharkerCore/EnergyHistory.swift. The A2687 exposes no lifetime energy
// counter, so everything here is integrated from pairs of trustworthy power
// samples; gaps are never guessed as consumed energy.
//
// History is a plain value-like type with no lock of its own, like the Swift
// struct: the owner (internal/app's EnergyService) serializes access.
package energy

import (
	"crypto/rand"
	"fmt"
	"math"
	"sort"
	"sync/atomic"
	"time"
)

// PortSlotCount is the stable storage width shared by measurements,
// sessions, buckets, summaries and exports (C1 C2 C3 C4 A1 A2). The A2687
// fills the first three.
const PortSlotCount = 6

// Ports is one value per port slot.
type Ports [PortSlotCount]float64

// MaximumIntegrableGap is the longest step, in seconds, integrated as
// energy; a longer one closes the session.
const MaximumIntegrableGap = 120.0

// Retention, as in the Swift ledger: hourly buckets for 90 days, then daily
// buckets for two years, then monthly buckets for good. Session detail is
// kept as long as hourly detail, and never more than 4000 rows.
const (
	hourlyDetailDays   = 90
	dailyDetailDays    = 730
	sessionDetailDays  = hourlyDetailDays
	sessionDetailLimit = 4000
	// implausibleClockLead: how far now may lead the newest record before
	// the clock, not time, is suspect.
	implausibleClockLead = time.Duration(dailyDetailDays) * 24 * time.Hour
	// implausibleCompactionLead: how far the compaction watermark may lead
	// now before it is treated as computed from a runaway clock.
	implausibleCompactionLead = 2 * 24 * time.Hour
)

// Measurement is one point from the live telemetry stream.
type Measurement struct {
	At           time.Time
	TotalWatts   float64
	PerPortWatts Ports
}

// NewMeasurement cleans the readings: non-finite or negative watts are 0.
func NewMeasurement(at time.Time, totalWatts float64, perPortWatts []float64) Measurement {
	m := Measurement{At: at, TotalWatts: clean(totalWatts)}
	for i := 0; i < PortSlotCount && i < len(perPortWatts); i++ {
		m.PerPortWatts[i] = clean(perPortWatts[i])
	}
	return m
}

func clean(v float64) float64 {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return 0
	}
	return math.Max(0, v)
}

// SessionRecord is a continuous stretch of observed telemetry, one trip in
// an EV mileage log. ActiveSeconds is observed time, not wall time across
// gaps.
type SessionRecord struct {
	ID            string
	StartedAt     time.Time
	EndedAt       time.Time
	EnergyWh      float64
	ActiveSeconds float64
	PeakWatts     float64
	PerPortWh     Ports
	SampleCount   int
}

// AverageWatts is the mean power while observed.
func (s SessionRecord) AverageWatts() float64 { return averageWatts(s.EnergyWh, s.ActiveSeconds) }

// PeriodRecord is one storage bucket: an hour, or a day or month once
// retention folded it. Charts aggregate these into days or months.
type PeriodRecord struct {
	StartedAt     time.Time
	EndedAt       time.Time
	EnergyWh      float64
	ActiveSeconds float64
	PeakWatts     float64
	PerPortWh     Ports
}

// AverageWatts is the mean power while observed.
func (p PeriodRecord) AverageWatts() float64 { return averageWatts(p.EnergyWh, p.ActiveSeconds) }

// Summary is the aggregate of a range.
type Summary struct {
	EnergyWh      float64
	ActiveSeconds float64
	PeakWatts     float64
	PerPortWh     Ports
	SessionCount  int
}

// AverageWatts is the mean power while observed.
func (s Summary) AverageWatts() float64 { return averageWatts(s.EnergyWh, s.ActiveSeconds) }

func averageWatts(wh, seconds float64) float64 {
	if seconds > 0 {
		return wh * 3600 / seconds
	}
	return 0
}

// Granularity is the bucket size of a chart series.
type Granularity int

const (
	Hour Granularity = iota
	Day
	Month
)

// SkippedCompaction is a retention pass refused because the clock looked
// wrong. Not archived: it describes this run's clock.
type SkippedCompaction struct {
	AttemptedAt    time.Time
	LatestRecordAt time.Time
}

// History is the ledger.
type History struct {
	sessions      []SessionRecord
	hourly        []PeriodRecord
	activeSession *SessionRecord
	// archivedSessionCount continues counting sessions folded out of the
	// detail list, so "全部" never shrinks after retention.
	archivedSessionCount int
	// archivedSessionsBefore: every folded session ended before this.
	archivedSessionsBefore *time.Time
	skippedCompaction      *SkippedCompaction
	lastMeasurement        *Measurement
	// nextCompactionAt: the earliest moment another retention pass is worth
	// doing; the cut-offs move by days.
	nextCompactionAt *time.Time
	// hourIndex maps an hourly bucket's start (unix ms) to its index.
	hourIndex map[int64]int
	revision  uint64
}

var lastRevision atomic.Uint64

// New returns an empty ledger.
func New() *History {
	return &History{hourIndex: map[int64]int{}, revision: lastRevision.Add(1)}
}

// Revision changes whenever the ledger does; drawn from one process-wide
// counter so two different ledgers never share a number.
func (h *History) Revision() uint64 { return h.revision }

func (h *History) markChanged() { h.revision = lastRevision.Add(1) }

// Clone returns an independent copy (the Swift value semantics, for exports
// taken at the moment the user asked).
func (h *History) Clone() *History {
	c := *h
	c.sessions = append([]SessionRecord(nil), h.sessions...)
	c.hourly = append([]PeriodRecord(nil), h.hourly...)
	if h.activeSession != nil {
		a := *h.activeSession
		c.activeSession = &a
	}
	if h.lastMeasurement != nil {
		m := *h.lastMeasurement
		c.lastMeasurement = &m
	}
	if h.skippedCompaction != nil {
		s := *h.skippedCompaction
		c.skippedCompaction = &s
	}
	c.hourIndex = map[int64]int{}
	c.rebuildHourIndex()
	return &c
}

// Sessions returns the finished sessions, oldest first.
func (h *History) Sessions() []SessionRecord { return append([]SessionRecord(nil), h.sessions...) }

// Hourly returns the storage buckets, oldest first.
func (h *History) Hourly() []PeriodRecord { return append([]PeriodRecord(nil), h.hourly...) }

// ActiveSession returns the open session, or nil.
func (h *History) ActiveSession() *SessionRecord {
	if h.activeSession == nil {
		return nil
	}
	a := *h.activeSession
	return &a
}

// ArchivedSessionCount is the number of sessions folded into the totals.
func (h *History) ArchivedSessionCount() int { return h.archivedSessionCount }

// ArchivedSessionsBefore is the folding watermark, or nil.
func (h *History) ArchivedSessionsBefore() *time.Time { return h.archivedSessionsBefore }

// SkippedCompaction reports a retention pass refused for a suspect clock.
func (h *History) SkippedCompaction() *SkippedCompaction { return h.skippedCompaction }

// IsEmpty reports whether nothing at all is recorded.
func (h *History) IsEmpty() bool {
	return len(h.hourly) == 0 && len(h.sessions) == 0 && h.activeSession == nil
}

// RecoverAfterLaunch treats an app launch as a new observation run: a
// session left open by a killed process is kept as finished, and the archive
// is compacted before the first telemetry arrives.
func (h *History) RecoverAfterLaunch(now time.Time, cal Calendar) {
	watermark := h.latestObservation()
	h.FinishCurrentSession()
	h.compact(now, cal, watermark)
}

// RemoveRecords deletes one calendar range. Hourly buckets intersecting it
// go; a session crossing the boundary goes whole, so the list never shows a
// run containing deleted time. It reports whether anything was removed.
func (h *History) RemoveRecords(start, end time.Time) bool {
	if !start.Before(end) {
		return false
	}
	hourlyCount := len(h.hourly)
	sessionCount := len(h.sessions)
	removedActive := h.activeSession != nil &&
		h.activeSession.StartedAt.Before(end) && !h.activeSession.EndedAt.Before(start)
	removedLast := h.lastMeasurement != nil &&
		!h.lastMeasurement.At.Before(start) && h.lastMeasurement.At.Before(end)

	keptHourly := h.hourly[:0:0]
	for _, p := range h.hourly {
		if p.StartedAt.Before(end) && p.EndedAt.After(start) {
			continue
		}
		keptHourly = append(keptHourly, p)
	}
	h.hourly = keptHourly
	keptSessions := h.sessions[:0:0]
	for _, s := range h.sessions {
		if s.StartedAt.Before(end) && !s.EndedAt.Before(start) {
			continue
		}
		keptSessions = append(keptSessions, s)
	}
	h.sessions = keptSessions
	if removedActive {
		h.activeSession = nil
	}
	if removedActive || removedLast {
		h.lastMeasurement = nil
	}
	changed := len(h.hourly) != hourlyCount || len(h.sessions) != sessionCount || removedActive || removedLast
	if changed {
		h.rebuildHourIndex()
		h.markChanged()
	}
	return changed
}

// HasRecords reports whether RemoveRecords(start, end) would remove
// anything shown in the lists (the clear menu's enabled state).
func (h *History) HasRecords(start, end time.Time) bool {
	for _, p := range h.hourly {
		if p.StartedAt.Before(end) && p.EndedAt.After(start) {
			return true
		}
	}
	for _, s := range h.sessions {
		if s.StartedAt.Before(end) && !s.EndedAt.Before(start) {
			return true
		}
	}
	a := h.activeSession
	return a != nil && a.StartedAt.Before(end) && !a.EndedAt.Before(start)
}

// Record integrates one measurement.
func (h *History) Record(m Measurement, cal Calendar) {
	if h.lastMeasurement == nil {
		h.beginSession(m)
		h.markChanged()
		return
	}
	previous := *h.lastMeasurement
	elapsed := m.At.Sub(previous.At).Seconds()
	if elapsed <= 0 {
		return
	}
	// Every path from here on writes to the ledger.
	defer h.markChanged()
	if elapsed >= MaximumIntegrableGap {
		h.FinishCurrentSession()
		h.beginSession(m)
		return
	}
	if h.activeSession == nil {
		h.beginSession(previous)
	}
	h.integrateSession(previous, m, elapsed)
	// The clock check must use the watermark from before this sample: the
	// next line writes a bucket at m.At, which a runaway clock would make
	// its own alibi.
	watermark := h.latestObservation()
	h.integrateHourly(previous, m, cal)
	h.lastMeasurement = &m
	h.compactIfNeeded(m.At, cal, watermark)
}

// FinishCurrentSession closes the open session; the next sample starts a
// new one.
func (h *History) FinishCurrentSession() {
	if h.activeSession != nil {
		h.sessions = append(h.sessions, *h.activeSession)
	}
	h.activeSession = nil
	h.lastMeasurement = nil
	h.markChanged()
}

// CurrentSessionSummary is the open run only ("本次").
func (h *History) CurrentSessionSummary() Summary {
	a := h.activeSession
	if a == nil {
		return Summary{}
	}
	return Summary{
		EnergyWh:      a.EnergyWh,
		ActiveSeconds: a.ActiveSeconds,
		PeakWatts:     a.PeakWatts,
		PerPortWh:     a.PerPortWh,
		SessionCount:  1,
	}
}

// CurrentSessionPeriod is the open run as one chart record, or nil.
func (h *History) CurrentSessionPeriod() *PeriodRecord {
	a := h.activeSession
	if a == nil {
		return nil
	}
	return &PeriodRecord{
		StartedAt:     a.StartedAt,
		EndedAt:       a.EndedAt,
		EnergyWh:      a.EnergyWh,
		ActiveSeconds: a.ActiveSeconds,
		PeakWatts:     a.PeakWatts,
		PerPortWh:     a.PerPortWh,
	}
}

// Summary aggregates [start, end); a nil start means since the beginning.
func (h *History) Summary(start *time.Time, end time.Time) Summary {
	return h.SummaryWithSessions(start, end, h.SessionRecords(start, end))
}

// SummaryWithSessions is Summary for callers already holding
// SessionRecords(start, end).
func (h *History) SummaryWithSessions(start *time.Time, end time.Time, records []SessionRecord) Summary {
	var s Summary
	for _, p := range h.hourly {
		if !periodInRange(p, start, end) {
			continue
		}
		s.EnergyWh += p.EnergyWh
		s.ActiveSeconds += p.ActiveSeconds
		s.PeakWatts = math.Max(s.PeakWatts, p.PeakWatts)
		for i := range s.PerPortWh {
			s.PerPortWh[i] += p.PerPortWh[i]
		}
	}
	s.SessionCount = len(records) + h.archivedSessions(start)
	return s
}

func periodInRange(p PeriodRecord, start *time.Time, end time.Time) bool {
	return p.StartedAt.Before(end) && (start == nil || p.EndedAt.After(*start))
}

func sessionInRange(r SessionRecord, start *time.Time, end time.Time) bool {
	return r.StartedAt.Before(end) && (start == nil || !r.EndedAt.Before(*start))
}

// archivedSessions counts folded sessions only when the range reaches back
// past the folding watermark: they have no timestamps of their own.
func (h *History) archivedSessions(start *time.Time) int {
	if h.archivedSessionCount <= 0 {
		return 0
	}
	if start == nil {
		return h.archivedSessionCount
	}
	if h.archivedSessionsBefore == nil {
		return 0
	}
	if start.Before(*h.archivedSessionsBefore) {
		return h.archivedSessionCount
	}
	return 0
}

// SessionRecords lists the sessions touching [start, end), newest first,
// the open one included.
func (h *History) SessionRecords(start *time.Time, end time.Time) []SessionRecord {
	records := []SessionRecord{}
	for _, r := range h.sessions {
		if sessionInRange(r, start, end) {
			records = append(records, r)
		}
	}
	if a := h.activeSession; a != nil && sessionInRange(*a, start, end) {
		records = append(records, *a)
	}
	sort.SliceStable(records, func(i, j int) bool { return records[i].StartedAt.After(records[j].StartedAt) })
	return records
}

// Periods returns the buckets touching [start, end) grouped by granularity,
// oldest first.
func (h *History) Periods(start *time.Time, end time.Time, g Granularity, cal Calendar) []PeriodRecord {
	source := []PeriodRecord{}
	for _, p := range h.hourly {
		if periodInRange(p, start, end) {
			source = append(source, p)
		}
	}
	return aggregate(source, g, cal)
}

// aggregate serves both the charts and retention folding, so "folding keeps
// the totals" holds by construction: sums of sums, maxima of maxima.
func aggregate(source []PeriodRecord, g Granularity, cal Calendar) []PeriodRecord {
	grouped := map[int64]*PeriodRecord{}
	for _, p := range source {
		var key time.Time
		switch g {
		case Hour:
			key = cal.HourStart(p.StartedAt)
		case Day:
			key = cal.StartOfDay(p.StartedAt)
		default:
			key = cal.MonthStart(p.StartedAt)
		}
		agg := grouped[key.UnixNano()]
		if agg == nil {
			agg = &PeriodRecord{StartedAt: key, EndedAt: p.EndedAt}
			grouped[key.UnixNano()] = agg
		}
		if p.EndedAt.After(agg.EndedAt) {
			agg.EndedAt = p.EndedAt
		}
		agg.EnergyWh += p.EnergyWh
		agg.ActiveSeconds += p.ActiveSeconds
		agg.PeakWatts = math.Max(agg.PeakWatts, p.PeakWatts)
		for i := range agg.PerPortWh {
			agg.PerPortWh[i] += p.PerPortWh[i]
		}
	}
	out := make([]PeriodRecord, 0, len(grouped))
	for _, p := range grouped {
		out = append(out, *p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].StartedAt.Before(out[j].StartedAt) })
	return out
}

func (h *History) beginSession(m Measurement) {
	h.activeSession = &SessionRecord{
		ID:          newID(),
		StartedAt:   m.At,
		EndedAt:     m.At,
		PeakWatts:   m.TotalWatts,
		SampleCount: 1,
	}
	h.lastMeasurement = &m
}

func (h *History) integrateSession(previous, current Measurement, seconds float64) {
	a := h.activeSession
	if a == nil {
		return
	}
	a.EndedAt = current.At
	a.ActiveSeconds += seconds
	a.EnergyWh += wattHours(previous.TotalWatts, current.TotalWatts, seconds)
	a.PeakWatts = math.Max(a.PeakWatts, math.Max(previous.TotalWatts, current.TotalWatts))
	a.SampleCount++
	for i := range a.PerPortWh {
		a.PerPortWh[i] += wattHours(previous.PerPortWatts[i], current.PerPortWatts[i], seconds)
	}
}

// integrateHourly splits the step at hour boundaries, interpolating the
// watts at each cut.
func (h *History) integrateHourly(previous, current Measurement, cal Calendar) {
	total := current.At.Sub(previous.At).Seconds()
	segmentStart := previous.At
	for segmentStart.Before(current.At) {
		periodStart := cal.HourStart(segmentStart)
		segmentEnd := cal.HourEnd(segmentStart)
		if current.At.Before(segmentEnd) {
			segmentEnd = current.At
		}
		if !segmentEnd.After(segmentStart) {
			break
		}
		startFraction := segmentStart.Sub(previous.At).Seconds() / total
		endFraction := segmentEnd.Sub(previous.At).Seconds() / total
		var startPorts, endPorts Ports
		for i := range startPorts {
			startPorts[i] = interpolate(previous.PerPortWatts[i], current.PerPortWatts[i], startFraction)
			endPorts[i] = interpolate(previous.PerPortWatts[i], current.PerPortWatts[i], endFraction)
		}
		h.accumulateHour(
			periodStart,
			segmentEnd,
			segmentEnd.Sub(segmentStart).Seconds(),
			interpolate(previous.TotalWatts, current.TotalWatts, startFraction),
			interpolate(previous.TotalWatts, current.TotalWatts, endFraction),
			startPorts,
			endPorts,
		)
		segmentStart = segmentEnd
	}
}

func (h *History) accumulateHour(start, end time.Time, seconds, startTotal, endTotal float64, startPorts, endPorts Ports) {
	if h.hourIndex == nil {
		h.rebuildHourIndex()
	}
	key := start.UnixMilli()
	index, ok := h.hourIndex[key]
	if !ok {
		h.hourly = append(h.hourly, PeriodRecord{StartedAt: start, EndedAt: end})
		h.hourIndex[key] = len(h.hourly) - 1
		// A clock stepped back lands a new bucket before older ones; keep the
		// array ordered, which retention and export rely on.
		if n := len(h.hourly); n > 1 && h.hourly[n-2].StartedAt.After(start) {
			sortPeriods(h.hourly)
			h.rebuildHourIndex()
		}
		index = h.hourIndex[key]
	}
	p := &h.hourly[index]
	if end.After(p.EndedAt) {
		p.EndedAt = end
	}
	p.ActiveSeconds += seconds
	p.EnergyWh += wattHours(startTotal, endTotal, seconds)
	p.PeakWatts = math.Max(p.PeakWatts, math.Max(startTotal, endTotal))
	for i := range p.PerPortWh {
		p.PerPortWh[i] += wattHours(startPorts[i], endPorts[i], seconds)
	}
}

func (h *History) rebuildHourIndex() {
	h.hourIndex = make(map[int64]int, len(h.hourly))
	for i, p := range h.hourly {
		h.hourIndex[p.StartedAt.UnixMilli()] = i
	}
}

func sortPeriods(p []PeriodRecord) {
	sort.SliceStable(p, func(i, j int) bool { return p[i].StartedAt.Before(p[j].StartedAt) })
}

func sortSessions(s []SessionRecord) {
	sort.SliceStable(s, func(i, j int) bool { return s[i].StartedAt.Before(s[j].StartedAt) })
}

// ---- Retention -----------------------------------------------------------
//
// Folding may lower resolution but never lose totals: after it, "全部" has
// exactly the same energy, time and session count as before.

// compactIfNeeded runs on every sample, so its early exit is one comparison;
// the session cap is the only line that can be crossed within a day.
func (h *History) compactIfNeeded(now time.Time, cal Calendar, latestRecord *time.Time) {
	// A watermark scheduled by a runaway clock would lock the early exit
	// shut for decades once the clock is fixed; drop it and reschedule.
	if h.nextCompactionAt != nil && h.nextCompactionAt.Sub(now) > implausibleCompactionLead {
		h.nextCompactionAt = nil
	}
	if h.nextCompactionAt != nil && now.Before(*h.nextCompactionAt) && len(h.sessions) <= sessionDetailLimit {
		return
	}
	h.compact(now, cal, latestRecord)
}

// compact skips the pass when now is implausibly far ahead of the newest
// record: folding is irreversible, a wrong clock is usually corrected
// seconds later.
func (h *History) compact(now time.Time, cal Calendar, latestRecord *time.Time) {
	reference := latestRecord
	if h.skippedCompaction != nil {
		r := h.skippedCompaction.LatestRecordAt
		reference = &r
	}
	if reference != nil && now.Sub(*reference) > implausibleClockLead {
		h.skippedCompaction = &SkippedCompaction{AttemptedAt: now, LatestRecordAt: *reference}
		return
	}
	h.skippedCompaction = nil
	h.compactHourly(now, cal)
	h.compactSessions(now, cal)
	// With nothing to fold, scheduling would rest on now alone; let the
	// first sample bring a reference instead.
	if h.latestObservation() == nil {
		h.nextCompactionAt = nil
		return
	}
	next := cal.AddDays(cal.StartOfDay(now), 1)
	h.nextCompactionAt = &next
}

// latestObservation is the newest archived record: only hourly and sessions,
// never the open run, whose time comes from the suspect clock itself.
func (h *History) latestObservation() *time.Time {
	var bucket, session *time.Time
	if n := len(h.hourly); n > 0 {
		t := h.hourly[n-1].EndedAt
		bucket = &t
	}
	if n := len(h.sessions); n > 0 {
		t := h.sessions[n-1].EndedAt
		session = &t
	}
	switch {
	case bucket == nil:
		return session
	case session == nil:
		return bucket
	case session.After(*bucket):
		return session
	default:
		return bucket
	}
}

// compactHourly folds hours older than 90 days into days and days older
// than two years into months, all within the one hourly array.
func (h *History) compactHourly(now time.Time, cal Calendar) {
	today := cal.StartOfDay(now)
	hourCutoff := cal.AddDays(today, -hourlyDetailDays)
	dayCutoff := cal.AddDays(today, -dailyDetailDays)
	var kept, toDays, toMonths []PeriodRecord
	for _, p := range h.hourly {
		switch {
		case p.StartedAt.Before(dayCutoff):
			toMonths = append(toMonths, p)
		case p.StartedAt.Before(hourCutoff):
			toDays = append(toDays, p)
		default:
			kept = append(kept, p)
		}
	}
	if len(toDays) == 0 && len(toMonths) == 0 {
		return
	}
	next := aggregate(toMonths, Month, cal)
	next = append(next, aggregate(toDays, Day, cal)...)
	h.hourly = append(next, kept...)
	h.rebuildHourIndex()
}

// compactSessions drops session detail older than 90 days (and beyond the
// row cap); the count continues in archivedSessionCount.
func (h *History) compactSessions(now time.Time, cal Calendar) {
	cutoff := cal.AddDays(cal.StartOfDay(now), -sessionDetailDays)
	drop := 0
	for drop < len(h.sessions) && h.sessions[drop].StartedAt.Before(cutoff) {
		drop++
	}
	folded := drop
	if kept := len(h.sessions) - drop; kept > sessionDetailLimit {
		folded += kept - sessionDetailLimit
	}
	if folded <= 0 {
		return
	}
	var watermark *time.Time
	for _, s := range h.sessions[:folded] {
		if watermark == nil || s.EndedAt.After(*watermark) {
			t := s.EndedAt
			watermark = &t
		}
	}
	h.sessions = append([]SessionRecord(nil), h.sessions[folded:]...)
	h.archivedSessionCount += folded
	if watermark != nil && (h.archivedSessionsBefore == nil || watermark.After(*h.archivedSessionsBefore)) {
		h.archivedSessionsBefore = watermark
	}
}

func interpolate(start, end, fraction float64) float64 {
	return start + (end-start)*math.Max(0, math.Min(1, fraction))
}

func wattHours(start, end, seconds float64) float64 {
	return seconds * (start + end) / 2 / 3600
}

// newID is an uppercase UUID v4, as Foundation's UUID().uuidString prints.
func newID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%X-%X-%X-%X-%X", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// EstimatedCost converts observed watt-hours into the configured retail
// cost (Preferences.estimatedEnergyCost); ok is false while no rate is set
// or the inputs cannot give a finite estimate.
func EstimatedCost(wattHours, pricePerKWh float64) (float64, bool) {
	if !(pricePerKWh > 0) || math.IsInf(pricePerKWh, 0) || !(wattHours >= 0) || math.IsInf(wattHours, 0) {
		return 0, false
	}
	amount := wattHours / 1000 * pricePerKWh
	if math.IsNaN(amount) || math.IsInf(amount, 0) {
		return 0, false
	}
	return amount, true
}
