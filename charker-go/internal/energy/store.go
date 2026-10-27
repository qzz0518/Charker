package energy

import (
	"encoding/json"
	"errors"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// The on-disk ledgers, one per product, named as on macOS.
const (
	ArchiveFileName      = "energy-history-v1.json"
	A2345ArchiveFileName = "energy-history-a2345-v1.json"
)

const archiveVersion = 1

// Text is a user-facing message as a Mac L10n key plus arguments, so the
// page renders it in its own language. An argument may itself be a Text.
type Text struct {
	Key  string `json:"key"`
	Args []any  `json:"args"`
}

// Store persists one History (EnergyHistoryStore): versioned JSON, dates in
// epoch milliseconds, no device identifiers.
type Store struct {
	path string
}

// NewStore returns a store for an archive path.
func NewStore(path string) *Store { return &Store{path: path} }

// NewStoreForBaseDir returns a store for ArchiveFileName inside dir.
func NewStoreForBaseDir(dir string) *Store { return NewStore(filepath.Join(dir, ArchiveFileName)) }

// Path is the archive path.
func (s *Store) Path() string { return s.path }

// recoveryPath is "<name>.corrupt.json" next to the archive.
func (s *Store) recoveryPath() string {
	return strings.TrimSuffix(s.path, filepath.Ext(s.path)) + ".corrupt.json"
}

// Load reads the archive and recovers it after launch. A missing file is an
// empty ledger; an unreadable or foreign-version one is copied once to the
// recovery file and replaced by an empty ledger with a warning.
func (s *Store) Load(now time.Time, cal Calendar) (*History, *Text) {
	data, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return New(), nil
	}
	if err == nil {
		var file struct {
			Version int             `json:"version"`
			History json.RawMessage `json:"history"`
		}
		if err = json.Unmarshal(data, &file); err == nil {
			if file.Version != archiveVersion {
				recovery := &Text{Key: "原文件不会在本次加载中被覆盖。"}
				if backup := s.preserveCorrupt(); backup != "" {
					recovery = &Text{Key: "原数据已复制为 %@。", Args: []any{backup}}
				}
				return New(), &Text{Key: "能耗历史来自不受支持的版本，%@", Args: []any{recovery}}
			}
			var h *History
			if h, err = decodeHistory(file.History); err == nil {
				h.RecoverAfterLaunch(now, cal)
				return h, nil
			}
		}
	}
	recovery := &Text{Key: "原文件未被覆盖。"}
	if backup := s.preserveCorrupt(); backup != "" {
		recovery = &Text{Key: "原数据已复制为 %@。", Args: []any{backup}}
	}
	return New(), &Text{Key: "能耗历史无法读取，%@ %@", Args: []any{recovery, err.Error()}}
}

// Save writes the archive atomically with owner-only permissions.
func (s *Store) Save(h *History) error {
	data, err := json.Marshal(struct {
		History archiveHistory `json:"history"`
		Version int            `json:"version"`
	}{encodeHistory(h), archiveVersion})
	if err != nil {
		return err
	}
	return writeFileAtomic(s.path, data, 0o600)
}

// Clear deletes the archive and its recovery copy. The caller replaces its
// in-memory ledger in the same step, or the next Save writes it all back.
func (s *Store) Clear() error {
	for _, p := range []string{s.path, s.recoveryPath()} {
		if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

// ReplaceAfterRemoval saves a ledger with a range deleted and removes the
// recovery copy, which may still hold the deleted data.
func (s *Store) ReplaceAfterRemoval(h *History) error {
	if err := s.Save(h); err != nil {
		return err
	}
	if err := os.Remove(s.recoveryPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// preserveCorrupt copies the archive to the recovery file once and returns
// its base name, or "" when the copy failed.
func (s *Store) preserveCorrupt() string {
	backup := s.recoveryPath()
	if _, err := os.Stat(backup); err == nil {
		return filepath.Base(backup)
	}
	data, err := os.ReadFile(s.path)
	if err != nil {
		return ""
	}
	if err := os.WriteFile(backup, data, 0o600); err != nil {
		return ""
	}
	return filepath.Base(backup)
}

func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	_, werr := f.Write(data)
	cerr := f.Close()
	if werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.Chmod(tmp, perm)
	}
	if werr == nil {
		werr = os.Rename(tmp, path)
	}
	if werr != nil {
		_ = os.Remove(tmp)
	}
	return werr
}

// ---- archive shape ------------------------------------------------------
//
// The Swift EnergyHistory CodingKeys with .millisecondsSince1970 dates. The
// legacy keys (daily, monthly, open) read archives written by the earlier
// Windows ledger, which kept folded buckets in separate arrays.

type archiveHistory struct {
	ActiveSession          *archiveSession     `json:"activeSession,omitempty"`
	ArchivedSessionCount   int                 `json:"archivedSessionCount"`
	ArchivedSessionsBefore *float64            `json:"archivedSessionsBefore,omitempty"`
	Hourly                 []archivePeriod     `json:"hourly"`
	LastMeasurement        *archiveMeasurement `json:"lastMeasurement,omitempty"`
	NextCompactionAt       *float64            `json:"nextCompactionAt,omitempty"`
	Sessions               []archiveSession    `json:"sessions"`

	Daily   []archivePeriod `json:"daily,omitempty"`
	Monthly []archivePeriod `json:"monthly,omitempty"`
	Open    *archiveSession `json:"open,omitempty"`
}

type archiveSession struct {
	ActiveSeconds float64   `json:"activeSeconds"`
	EndedAt       float64   `json:"endedAt"`
	EnergyWh      float64   `json:"energyWh"`
	ID            string    `json:"id"`
	PeakWatts     float64   `json:"peakWatts"`
	PerPortWh     []float64 `json:"perPortWh"`
	SampleCount   int       `json:"sampleCount"`
	StartedAt     float64   `json:"startedAt"`
}

type archivePeriod struct {
	ActiveSeconds float64   `json:"activeSeconds"`
	EndedAt       float64   `json:"endedAt"`
	EnergyWh      float64   `json:"energyWh"`
	PeakWatts     float64   `json:"peakWatts"`
	PerPortWh     []float64 `json:"perPortWh"`
	StartedAt     float64   `json:"startedAt"`
}

type archiveMeasurement struct {
	At           float64   `json:"at"`
	PerPortWatts []float64 `json:"perPortWatts"`
	TotalWatts   float64   `json:"totalWatts"`
}

func toMs(t time.Time) float64 { return float64(t.UnixMicro()) / 1000 }

func fromMs(ms float64) time.Time {
	return time.UnixMicro(int64(math.Round(ms * 1000)))
}

func ptrMs(t *time.Time) *float64 {
	if t == nil {
		return nil
	}
	v := toMs(*t)
	return &v
}

func ptrTime(ms *float64) *time.Time {
	if ms == nil || *ms == 0 {
		return nil
	}
	t := fromMs(*ms)
	return &t
}

func portSlice(p Ports) []float64 { return append([]float64(nil), p[:]...) }

func portsOf(v []float64) Ports {
	var p Ports
	copy(p[:], v)
	return p
}

func encodeSession(s SessionRecord) archiveSession {
	return archiveSession{
		ActiveSeconds: s.ActiveSeconds,
		EndedAt:       toMs(s.EndedAt),
		EnergyWh:      s.EnergyWh,
		ID:            s.ID,
		PeakWatts:     s.PeakWatts,
		PerPortWh:     portSlice(s.PerPortWh),
		SampleCount:   s.SampleCount,
		StartedAt:     toMs(s.StartedAt),
	}
}

func decodeSession(a archiveSession) SessionRecord {
	id := a.ID
	if id == "" {
		id = newID()
	}
	return SessionRecord{
		ID:            id,
		StartedAt:     fromMs(a.StartedAt),
		EndedAt:       fromMs(a.EndedAt),
		EnergyWh:      a.EnergyWh,
		ActiveSeconds: a.ActiveSeconds,
		PeakWatts:     a.PeakWatts,
		PerPortWh:     portsOf(a.PerPortWh),
		SampleCount:   a.SampleCount,
	}
}

func encodePeriod(p PeriodRecord) archivePeriod {
	return archivePeriod{
		ActiveSeconds: p.ActiveSeconds,
		EndedAt:       toMs(p.EndedAt),
		EnergyWh:      p.EnergyWh,
		PeakWatts:     p.PeakWatts,
		PerPortWh:     portSlice(p.PerPortWh),
		StartedAt:     toMs(p.StartedAt),
	}
}

func decodePeriod(a archivePeriod) PeriodRecord {
	return PeriodRecord{
		StartedAt:     fromMs(a.StartedAt),
		EndedAt:       fromMs(a.EndedAt),
		EnergyWh:      a.EnergyWh,
		ActiveSeconds: a.ActiveSeconds,
		PeakWatts:     a.PeakWatts,
		PerPortWh:     portsOf(a.PerPortWh),
	}
}

func encodeHistory(h *History) archiveHistory {
	a := archiveHistory{
		ArchivedSessionCount:   h.archivedSessionCount,
		ArchivedSessionsBefore: ptrMs(h.archivedSessionsBefore),
		NextCompactionAt:       ptrMs(h.nextCompactionAt),
		Hourly:                 make([]archivePeriod, 0, len(h.hourly)),
		Sessions:               make([]archiveSession, 0, len(h.sessions)),
	}
	for _, p := range h.hourly {
		a.Hourly = append(a.Hourly, encodePeriod(p))
	}
	for _, s := range h.sessions {
		a.Sessions = append(a.Sessions, encodeSession(s))
	}
	if h.activeSession != nil {
		s := encodeSession(*h.activeSession)
		a.ActiveSession = &s
	}
	if m := h.lastMeasurement; m != nil {
		a.LastMeasurement = &archiveMeasurement{At: toMs(m.At), PerPortWatts: portSlice(m.PerPortWatts), TotalWatts: m.TotalWatts}
	}
	return a
}

func decodeHistory(raw json.RawMessage) (*History, error) {
	var a archiveHistory
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, err
	}
	h := New()
	for _, list := range [][]archivePeriod{a.Monthly, a.Daily, a.Hourly} {
		for _, p := range list {
			h.hourly = append(h.hourly, decodePeriod(p))
		}
	}
	for _, s := range a.Sessions {
		h.sessions = append(h.sessions, decodeSession(s))
	}
	if a.ActiveSession != nil {
		s := decodeSession(*a.ActiveSession)
		h.activeSession = &s
	} else if a.Open != nil && a.Open.StartedAt > 0 {
		s := decodeSession(*a.Open)
		h.activeSession = &s
	}
	if m := a.LastMeasurement; m != nil {
		mm := NewMeasurement(fromMs(m.At), m.TotalWatts, m.PerPortWatts)
		h.lastMeasurement = &mm
	}
	h.archivedSessionCount = a.ArchivedSessionCount
	h.archivedSessionsBefore = ptrTime(a.ArchivedSessionsBefore)
	h.nextCompactionAt = ptrTime(a.NextCompactionAt)
	// The disk order is only the last writer's order, not a guarantee.
	sortPeriods(h.hourly)
	sortSessions(h.sessions)
	h.rebuildHourIndex()
	return h, nil
}
