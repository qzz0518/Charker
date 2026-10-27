package energy

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// Export, as in the Swift extension: CSV and JSON share one notice and one
// selection. Neither holds a serial number, MAC or account: the ledger has
// no such fields.

// exportNotice answers the four "can I trust this number" questions: who
// computed it, whether the charger keeps a ledger, how gaps are treated,
// and what identifying data the file holds.
var exportNotice = map[string][]string{
	"zh": {
		"Charker 能耗导出：数值由 Charker 在本机对 BLE 遥测做时间积分推算。",
		"充电器不提供能量账本，这些是观测推算值，不是设备读数。",
		"Charker 未运行或未连接的时间是空洞，不计入，也不补值。",
		"文件只含时间与功率/能量聚合值，不含序列号、MAC 或账号信息。",
	},
	"en": {
		"Charker energy export: values are integrated over time from BLE telemetry on this PC.",
		"The charger keeps no energy ledger; these are values derived from observation, not device readings.",
		"Time when Charker was not running or not connected is a gap: neither counted nor filled in.",
		"The file holds only timestamps and power/energy aggregates — no serial number, MAC address, or account information.",
	},
}

var foldedNotice = map[string]string{
	"zh": "%s 之前的 %d 段连接旅程已折叠为汇总，能量与时长仍计入小时/日/月桶，但不再单独成行。",
	"en": "Connection journeys before %s — %d of them — have been folded into summaries; their energy and duration still count toward the hourly, daily, and monthly buckets, but they no longer appear as individual rows.",
}

func lang(locale string) string {
	if locale == "en" {
		return "en"
	}
	return "zh"
}

// ISOText is the local-time ISO 8601 form the Mac writes
// (Date.ISO8601FormatStyle(timeZone: .current)): local on purpose, so a
// file's times match what the user saw on screen.
func ISOText(t time.Time, loc *time.Location) string {
	if loc == nil {
		loc = time.Local
	}
	return t.In(loc).Format("2006-01-02T15:04:05Z0700")
}

func number(v float64, digits int) string { return fmt.Sprintf("%.*f", digits, v) }

// ExportCSV is one flat table: a kind column tells hourly buckets from
// sessions; every field is a number or an ISO time, nothing to escape.
// The caller prepends the UTF-8 BOM Excel needs.
func (h *History) ExportCSV(generatedAt time.Time, loc *time.Location, locale string) string {
	l := lang(locale)
	var lines []string
	for _, n := range exportNotice[l] {
		lines = append(lines, "# "+n)
	}
	lines = append(lines, "# generated_at: "+ISOText(generatedAt, loc))
	if h.archivedSessionCount > 0 && h.archivedSessionsBefore != nil {
		lines = append(lines, "# "+fmt.Sprintf(foldedNotice[l], ISOText(*h.archivedSessionsBefore, loc), h.archivedSessionCount))
	}
	lines = append(lines, strings.Join([]string{
		"kind", "start", "end", "energy_wh", "active_seconds", "peak_w", "average_w",
		"c1_wh", "c2_wh", "c3_wh", "c4_wh", "a1_wh", "a2_wh", "samples",
	}, ","))
	row := func(kind string, start, end time.Time, wh, seconds, peak, avg float64, ports Ports, samples string) string {
		cols := []string{kind, ISOText(start, loc), ISOText(end, loc), number(wh, 4), number(seconds, 0), number(peak, 2), number(avg, 2)}
		for _, v := range ports {
			cols = append(cols, number(v, 4))
		}
		return strings.Join(append(cols, samples), ",")
	}
	for _, p := range h.hourly {
		lines = append(lines, row("bucket", p.StartedAt, p.EndedAt, p.EnergyWh, p.ActiveSeconds, p.PeakWatts, p.AverageWatts(), p.PerPortWh, ""))
	}
	for _, s := range h.exportableSessions() {
		lines = append(lines, row("session", s.StartedAt, s.EndedAt, s.EnergyWh, s.ActiveSeconds, s.PeakWatts, s.AverageWatts(), s.PerPortWh, fmt.Sprint(s.SampleCount)))
	}
	return strings.Join(lines, "\n") + "\n"
}

// ExportJSON is the "charker.energy-history.1" document: pretty-printed,
// sorted keys, ISO dates.
func (h *History) ExportJSON(generatedAt time.Time, loc *time.Location, locale string) ([]byte, error) {
	iso := func(t time.Time) string { return ISOText(t, loc) }
	type bucket struct {
		ActiveSeconds float64   `json:"activeSeconds"`
		EndedAt       string    `json:"endedAt"`
		EnergyWh      float64   `json:"energyWh"`
		PeakWatts     float64   `json:"peakWatts"`
		PerPortWh     []float64 `json:"perPortWh"`
		StartedAt     string    `json:"startedAt"`
	}
	type session struct {
		ActiveSeconds float64   `json:"activeSeconds"`
		EndedAt       string    `json:"endedAt"`
		EnergyWh      float64   `json:"energyWh"`
		ID            string    `json:"id"`
		PeakWatts     float64   `json:"peakWatts"`
		PerPortWh     []float64 `json:"perPortWh"`
		SampleCount   int       `json:"sampleCount"`
		StartedAt     string    `json:"startedAt"`
	}
	doc := struct {
		ArchivedSessionCount   int       `json:"archivedSessionCount"`
		ArchivedSessionsBefore *string   `json:"archivedSessionsBefore,omitempty"`
		Buckets                []bucket  `json:"buckets"`
		GeneratedAt            string    `json:"generatedAt"`
		Notice                 []string  `json:"notice"`
		Schema                 string    `json:"schema"`
		Sessions               []session `json:"sessions"`
	}{
		ArchivedSessionCount: h.archivedSessionCount,
		Buckets:              []bucket{},
		GeneratedAt:          iso(generatedAt),
		Notice:               exportNotice[lang(locale)],
		Schema:               "charker.energy-history.1",
		Sessions:             []session{},
	}
	if h.archivedSessionsBefore != nil {
		s := iso(*h.archivedSessionsBefore)
		doc.ArchivedSessionsBefore = &s
	}
	for _, p := range h.hourly {
		doc.Buckets = append(doc.Buckets, bucket{p.ActiveSeconds, iso(p.EndedAt), p.EnergyWh, p.PeakWatts, portSlice(p.PerPortWh), iso(p.StartedAt)})
	}
	for _, s := range h.exportableSessions() {
		doc.Sessions = append(doc.Sessions, session{s.ActiveSeconds, iso(s.EndedAt), s.EnergyWh, s.ID, s.PeakWatts, portSlice(s.PerPortWh), s.SampleCount, iso(s.StartedAt)})
	}
	var b strings.Builder
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(doc); err != nil {
		return nil, err
	}
	return []byte(strings.TrimSuffix(b.String(), "\n")), nil
}

// exportableSessions includes the open run: "export right after charging"
// must not lose the most useful row.
func (h *History) exportableSessions() []SessionRecord {
	out := append([]SessionRecord(nil), h.sessions...)
	if h.activeSession != nil {
		out = append(out, *h.activeSession)
		sortSessions(out)
	}
	return out
}
