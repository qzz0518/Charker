package anker

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
)

// CredentialStore keeps the one signed-in Authentication (the Keychain item
// of the macOS app). Passwords and MQTT client certificates never pass
// through it.
type CredentialStore interface {
	// Load returns nil, nil when nothing is stored.
	Load() (*Authentication, error)
	Save(Authentication) error
	Delete() error
}

// StoreError is a credential store failure (AnkerCredentialStoreError).
type StoreError struct {
	// Malformed: the record exists but cannot be read.
	Malformed bool
	Err       error
}

func (e *StoreError) Error() string { return e.Text().String() }
func (e *StoreError) Unwrap() error { return e.Err }

// Text mirrors the Keychain messages with the platform store in their place.
func (e *StoreError) Text() Text {
	if e.Malformed {
		return T("钥匙串中的 Anker 登录记录无法读取。")
	}
	return T("钥匙串操作失败（%d）。", -1)
}

// CredentialFileName is the record's file name inside the data directory.
const CredentialFileName = "anker-cloud.bin"

// FileStore keeps the record in one file under a caller-provided data
// directory. On Windows the file is DPAPI-encrypted for the current user
// (CryptProtectData); elsewhere (tests, the macOS dev server) it is the plain
// JSON with 0600 permissions.
type FileStore struct {
	path string
	mu   sync.Mutex
}

// NewFileStore stores the record as dataDir/anker-cloud.bin.
func NewFileStore(dataDir string) *FileStore {
	return &FileStore{path: filepath.Join(dataDir, CredentialFileName)}
}

// Path is the record's file path.
func (s *FileStore) Path() string { return s.path }

// Load reads and decrypts the record.
func (s *FileStore) Load() (*Authentication, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sealed, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, &StoreError{Err: err}
	}
	plain, err := unprotect(sealed)
	if err != nil {
		return nil, &StoreError{Malformed: true, Err: err}
	}
	defer clear(plain)
	var auth Authentication
	if err := json.Unmarshal(plain, &auth); err != nil {
		return nil, &StoreError{Malformed: true}
	}
	return &auth, nil
}

// Save encrypts and atomically replaces the record.
func (s *FileStore) Save(auth Authentication) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	plain, err := json.Marshal(auth)
	if err != nil {
		return &StoreError{Malformed: true}
	}
	defer clear(plain)
	sealed, err := protect(plain)
	if err != nil {
		return &StoreError{Err: err}
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return &StoreError{Err: err}
	}
	tmp, err := os.CreateTemp(filepath.Dir(s.path), ".anker-cloud-*")
	if err != nil {
		return &StoreError{Err: err}
	}
	name := tmp.Name()
	_ = tmp.Chmod(0o600)
	if _, err := tmp.Write(sealed); err != nil {
		tmp.Close()
		os.Remove(name)
		return &StoreError{Err: err}
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return &StoreError{Err: err}
	}
	if err := os.Rename(name, s.path); err != nil {
		os.Remove(name)
		return &StoreError{Err: err}
	}
	return nil
}

// Delete removes the record; a missing record is not an error.
func (s *FileStore) Delete() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := os.Remove(s.path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return &StoreError{Err: err}
	}
	return nil
}

// MemoryStore keeps the record in memory only (tests, demo).
type MemoryStore struct {
	mu   sync.Mutex
	auth *Authentication
}

// Load returns a copy of the stored record.
func (m *MemoryStore) Load() (*Authentication, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.auth == nil {
		return nil, nil
	}
	a := *m.auth
	return &a, nil
}

// Save replaces the record.
func (m *MemoryStore) Save(auth Authentication) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.auth = &auth
	return nil
}

// Delete forgets the record.
func (m *MemoryStore) Delete() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.auth = nil
	return nil
}
