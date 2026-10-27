package energy

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

// ArchiveFileName is the on-disk energy history name (spec-protocol §6.3).
const ArchiveFileName = "energy-history-v1.json"

// archiveVersion is the only supported archive version.
const archiveVersion = 1

// Store persists one History to a JSON archive file.
type Store struct {
	path string
}

// NewStore returns a store for the given archive file path.
func NewStore(path string) *Store { return &Store{path: path} }

// NewStoreForBaseDir returns a store for the standard file name inside baseDir.
func NewStoreForBaseDir(baseDir string) *Store {
	return &Store{path: filepath.Join(baseDir, ArchiveFileName)}
}

// Path is the archive file path.
func (s *Store) Path() string { return s.path }

// archiveFile is the persisted wrapper: {"version":1,"history":{...}}.
type archiveFile struct {
	Version int            `json:"version"`
	History archiveHistory `json:"history"`
}

// archiveHistory is the snapshot of a History.
type archiveHistory struct {
	Hourly                 []Bucket        `json:"hourly"`
	Daily                  []Bucket        `json:"daily"`
	Monthly                []Bucket        `json:"monthly"`
	Sessions               []SessionRecord `json:"sessions"`
	Open                   *openArchive    `json:"open,omitempty"`
	ArchivedSessionCount   int             `json:"archivedSessionCount"`
	ArchivedSessionsBefore int64           `json:"archivedSessionsBefore"`
}

type openArchive struct {
	StartedAtMs   int64      `json:"startedAt"`
	EndedAtMs     int64      `json:"endedAt"`
	EnergyWh      float64    `json:"energyWh"`
	ActiveSeconds float64    `json:"activeSeconds"`
	PeakWatts     float64    `json:"peakWatts"`
	PerPortWh     [6]float64 `json:"perPortWh"`
	SampleCount   int        `json:"sampleCount"`
	LastAtMs      int64      `json:"lastAtMs"`
	LastTotal     float64    `json:"lastTotalWatts"`
	LastPerPort   [6]float64 `json:"lastPerPortWatts"`
}

// Load reads the archive. A missing file yields an empty history; a corrupt or
// unsupported-version file is copied once to "<name>.corrupt.json", an empty
// history is returned and a human-readable warning is reported. A run that was
// open when the app exited is recovered (finished) on load.
func (s *Store) Load(opts Options) (*History, string) {
	h := New(opts)
	data, err := os.ReadFile(s.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return h, ""
		}
		return h, "energy history could not be read: " + err.Error()
	}
	var af archiveFile
	if err := json.Unmarshal(data, &af); err != nil {
		s.quarantine()
		return New(opts), "energy history was corrupt and has been backed up; starting empty"
	}
	if af.Version != archiveVersion {
		s.quarantine()
		return New(opts), "energy history has an unsupported version; starting empty"
	}
	h.restore(af.History)
	return h, ""
}

// Save writes the history atomically (temp file + rename, mode 0600).
func (s *Store) Save(h *History) error {
	h.mu.Lock()
	snap := h.archiveLocked()
	h.mu.Unlock()
	data, err := json.MarshalIndent(archiveFile{Version: archiveVersion, History: snap}, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(s.path, append(data, '\n'))
}

// Delete removes the archive and its corrupt backup.
func (s *Store) Delete() error {
	var firstErr error
	for _, p := range []string{s.path, s.path + corruptSuffix} {
		if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

// archiveLocked snapshots the history for persistence. The caller must hold
// h.mu.
func (h *History) archiveLocked() archiveHistory {
	ah := archiveHistory{
		Hourly:                 append([]Bucket(nil), h.hourly...),
		Daily:                  append([]Bucket(nil), h.daily...),
		Monthly:                append([]Bucket(nil), h.monthly...),
		Sessions:               append([]SessionRecord(nil), h.sessions...),
		ArchivedSessionCount:   h.archivedSessionCount,
		ArchivedSessionsBefore: h.archivedSessionsBeforeMs,
	}
	if h.open != nil {
		ah.Open = &openArchive{
			StartedAtMs:   h.open.startedAtMs,
			EndedAtMs:     h.open.endedAtMs,
			EnergyWh:      h.open.energyWh,
			ActiveSeconds: h.open.activeSeconds,
			PeakWatts:     h.open.peakWatts,
			PerPortWh:     h.open.perPortWh,
			SampleCount:   h.open.sampleCount,
		}
		if h.last != nil {
			ah.Open.LastAtMs = h.last.atMs
			ah.Open.LastTotal = h.last.total
			ah.Open.LastPerPort = h.last.perPort
		}
	}
	return ah
}

// restore installs an archive snapshot and finishes any open run (the app was
// not running while the file was closed).
func (h *History) restore(ah archiveHistory) {
	h.hourly = append([]Bucket(nil), ah.Hourly...)
	h.daily = append([]Bucket(nil), ah.Daily...)
	h.monthly = append([]Bucket(nil), ah.Monthly...)
	h.sessions = append([]SessionRecord(nil), ah.Sessions...)
	h.archivedSessionCount = ah.ArchivedSessionCount
	h.archivedSessionsBeforeMs = ah.ArchivedSessionsBefore
	if ah.Open != nil {
		h.open = &openRun{
			startedAtMs:   ah.Open.StartedAtMs,
			endedAtMs:     ah.Open.EndedAtMs,
			energyWh:      ah.Open.EnergyWh,
			activeSeconds: ah.Open.ActiveSeconds,
			peakWatts:     ah.Open.PeakWatts,
			perPortWh:     ah.Open.PerPortWh,
			sampleCount:   ah.Open.SampleCount,
		}
		if ah.Open.LastAtMs > 0 {
			h.last = &measurement{atMs: ah.Open.LastAtMs, total: ah.Open.LastTotal, perPort: ah.Open.LastPerPort}
		}
	}
	h.recoverAfterLaunchLocked()
}

// recoverAfterLaunchLocked finishes the run that was open when the app exited
// and compacts the archive. Called from restore, so the lock is not held by a
// caller — locking is skipped deliberately (construction is single-threaded).
func (h *History) recoverAfterLaunchLocked() {
	if h.open != nil {
		h.closeOpenLocked()
	}
	h.Compact(h.now())
}

const corruptSuffix = ".corrupt.json"

// quarantine keeps one backup of a corrupt/unsupported archive.
func (s *Store) quarantine() {
	dst := s.path + corruptSuffix
	if _, err := os.Stat(dst); err == nil {
		_ = os.Remove(s.path)
		return
	}
	if err := os.Rename(s.path, dst); err != nil {
		if data, rerr := os.ReadFile(s.path); rerr == nil {
			if werr := os.WriteFile(dst, data, 0o600); werr == nil {
				_ = os.Remove(s.path)
			}
		}
	}
}

// writeFileAtomic writes data via a temp file in the destination directory and
// renames it into place.
func writeFileAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}
