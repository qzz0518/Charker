//go:build !windows

package anker

// Outside Windows (tests, the macOS dev server) there is no DPAPI; the record
// relies on the file's 0600 permissions.

func protect(plain []byte) ([]byte, error) { return append([]byte(nil), plain...), nil }

func unprotect(sealed []byte) ([]byte, error) { return append([]byte(nil), sealed...), nil }
