package energy

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"time"
)

// ExportNotice is the fixed notice block written at the top of both export
// formats (spec-protocol §6.3: four sentences).
var ExportNotice = []string{
	"Charker computes this history locally from telemetry samples; it is an integration, not a meter reading.",
	"The charger does not expose an energy counter and cannot verify these values.",
	"Telemetry gaps longer than 120 seconds are holes: no energy is counted across them.",
	"The file contains only time and power aggregates, with no device identifiers or account data.",
}

// ExportCSV writes the CSV energy export to w. The schema is frozen by
// spec-protocol §6.3: notice lines, generated_at, then a fixed 15-column header
// (`kind,start,end,energy_wh,active_seconds,peak_w,average_w,c1_wh,...,a2_wh,samples`),
// one bucket row per hourly record and one session row per ledger entry
// (active run included).
func (h *History) ExportCSV(w io.Writer, now time.Time) error {
	h.mu.Lock()
	hourly := append([]Bucket(nil), h.hourly...)
	sessions := append([]SessionRecord(nil), h.sessions...)
	open := h.OpenSessionLocked()
	archivedCount := h.archivedSessionCount
	archivedBefore := h.archivedSessionsBeforeMs
	h.mu.Unlock()

	sort.SliceStable(hourly, func(i, j int) bool { return hourly[i].StartedAtMs < hourly[j].StartedAtMs })
	if open != nil {
		sessions = append(sessions, *open)
	}
	sort.SliceStable(sessions, func(i, j int) bool { return sessions[i].StartedAtMs < sessions[j].StartedAtMs })

	loc := h.loc
	iso := func(ms int64) string { return time.UnixMilli(ms).In(loc).Format(time.RFC3339) }

	var sb writer
	for _, line := range ExportNotice {
		sb.printf("# %s\n", line)
	}
	sb.printf("# generated_at: %s\n", now.In(loc).Format(time.RFC3339))
	if archivedCount > 0 {
		sb.printf("# archived_sessions: %d before %s\n", archivedCount, iso(archivedBefore))
	}
	sb.printf("kind,start,end,energy_wh,active_seconds,peak_w,average_w,c1_wh,c2_wh,c3_wh,c4_wh,a1_wh,a2_wh,samples\n")
	for _, b := range hourly {
		sb.printf("bucket,%s,%s,%.4f,%.0f,%.2f,%.2f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,0\n",
			iso(b.StartedAtMs), iso(b.EndedAtMs), b.EnergyWh, b.ActiveSeconds, b.PeakWatts, b.AverageWatts(),
			b.PerPortWh[0], b.PerPortWh[1], b.PerPortWh[2], b.PerPortWh[3], b.PerPortWh[4], b.PerPortWh[5])
	}
	for _, s := range sessions {
		sb.printf("session,%s,%s,%.4f,%.0f,%.2f,%.2f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%d\n",
			iso(s.StartedAtMs), iso(s.EndedAtMs), s.EnergyWh, s.ActiveSeconds, s.PeakWatts, s.AverageWatts(),
			s.PerPortWh[0], s.PerPortWh[1], s.PerPortWh[2], s.PerPortWh[3], s.PerPortWh[4], s.PerPortWh[5], s.SampleCount)
	}
	_, err := io.WriteString(w, sb.String())
	return err
}

// exportBucket is the JSON export shape for one bucket.
type exportBucket struct {
	StartedAtMs   int64      `json:"startedAt"`
	EndedAtMs     int64      `json:"endedAt"`
	EnergyWh      float64    `json:"energyWh"`
	ActiveSeconds float64    `json:"activeSeconds"`
	PeakWatts     float64    `json:"peakWatts"`
	PerPortWh     [6]float64 `json:"perPortWh"`
}

// exportSession is the JSON export shape for one session.
type exportSession struct {
	ID            string     `json:"id"`
	StartedAtMs   int64      `json:"startedAt"`
	EndedAtMs     int64      `json:"endedAt"`
	EnergyWh      float64    `json:"energyWh"`
	ActiveSeconds float64    `json:"activeSeconds"`
	PeakWatts     float64    `json:"peakWatts"`
	PerPortWh     [6]float64 `json:"perPortWh"`
	SampleCount   int        `json:"sampleCount"`
}

// exportDocument is the frozen JSON export schema.
type exportDocument struct {
	Schema                 string          `json:"schema"`
	GeneratedAt            string          `json:"generatedAt"`
	Notice                 []string        `json:"notice"`
	ArchivedSessionCount   int             `json:"archivedSessionCount"`
	ArchivedSessionsBefore *string         `json:"archivedSessionsBefore"`
	Buckets                []exportBucket  `json:"buckets"`
	Sessions               []exportSession `json:"sessions"`
}

// ExportJSON writes the pretty-printed JSON energy export to w (schema
// "charker.energy-history.1"), including the open session.
func (h *History) ExportJSON(w io.Writer, now time.Time) error {
	h.mu.Lock()
	hourly := append([]Bucket(nil), h.hourly...)
	sessions := append([]SessionRecord(nil), h.sessions...)
	open := h.OpenSessionLocked()
	archivedCount := h.archivedSessionCount
	archivedBefore := h.archivedSessionsBeforeMs
	h.mu.Unlock()

	sort.SliceStable(hourly, func(i, j int) bool { return hourly[i].StartedAtMs < hourly[j].StartedAtMs })
	if open != nil {
		sessions = append(sessions, *open)
	}
	sort.SliceStable(sessions, func(i, j int) bool { return sessions[i].StartedAtMs < sessions[j].StartedAtMs })

	doc := exportDocument{
		Schema:               "charker.energy-history.1",
		GeneratedAt:          now.In(h.loc).Format(time.RFC3339),
		Notice:               append([]string(nil), ExportNotice...),
		ArchivedSessionCount: archivedCount,
		Buckets:              make([]exportBucket, 0, len(hourly)),
		Sessions:             make([]exportSession, 0, len(sessions)),
	}
	if archivedCount > 0 && archivedBefore > 0 {
		s := time.UnixMilli(archivedBefore).In(h.loc).Format(time.RFC3339)
		doc.ArchivedSessionsBefore = &s
	}
	for _, b := range hourly {
		doc.Buckets = append(doc.Buckets, exportBucket{
			StartedAtMs:   b.StartedAtMs,
			EndedAtMs:     b.EndedAtMs,
			EnergyWh:      round4(b.EnergyWh),
			ActiveSeconds: round2(b.ActiveSeconds),
			PeakWatts:     round2(b.PeakWatts),
			PerPortWh:     round4Ports(b.PerPortWh),
		})
	}
	for _, s := range sessions {
		doc.Sessions = append(doc.Sessions, exportSession{
			ID:            s.ID,
			StartedAtMs:   s.StartedAtMs,
			EndedAtMs:     s.EndedAtMs,
			EnergyWh:      round4(s.EnergyWh),
			ActiveSeconds: round2(s.ActiveSeconds),
			PeakWatts:     round2(s.PeakWatts),
			PerPortWh:     round4Ports(s.PerPortWh),
			SampleCount:   s.SampleCount,
		})
	}
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	_, err = w.Write(data)
	return err
}

// OpenSessionLocked returns a copy of the active run; the caller must hold
// h.mu. It is used by the export paths.
func (h *History) OpenSessionLocked() *SessionRecord {
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

func round4(v float64) float64 { return float64(int64(v*10000+0.5)) / 10000 }

func round4Ports(per [6]float64) [6]float64 {
	var out [6]float64
	for i := range out {
		out[i] = round4(per[i])
	}
	return out
}

// writer is a tiny append-only buffer with printf.
type writer struct{ b []byte }

func (w *writer) printf(format string, args ...any) {
	w.b = append(w.b, fmt.Sprintf(format, args...)...)
}

func (w *writer) String() string { return string(w.b) }
