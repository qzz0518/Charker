//go:build windows

package anker

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

// dpapiEntropy binds the blob to this purpose, so another app's DPAPI blob
// for the same user cannot be swapped in.
var dpapiEntropy = []byte("dev.charker.Charker.anker-cloud")

func blob(b []byte) *windows.DataBlob {
	if len(b) == 0 {
		return &windows.DataBlob{}
	}
	return &windows.DataBlob{Size: uint32(len(b)), Data: &b[0]}
}

func takeBlob(out *windows.DataBlob) []byte {
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	src := unsafe.Slice(out.Data, out.Size)
	dst := append([]byte(nil), src...)
	clear(src)
	return dst
}

// protect encrypts for the current Windows user (CryptProtectData).
func protect(plain []byte) ([]byte, error) {
	var out windows.DataBlob
	if err := windows.CryptProtectData(blob(plain), nil, blob(dpapiEntropy), 0, nil,
		windows.CRYPTPROTECT_UI_FORBIDDEN, &out); err != nil {
		return nil, err
	}
	return takeBlob(&out), nil
}

// unprotect decrypts a blob written by protect for the same user.
func unprotect(sealed []byte) ([]byte, error) {
	var out windows.DataBlob
	if err := windows.CryptUnprotectData(blob(sealed), nil, blob(dpapiEntropy), 0, nil,
		windows.CRYPTPROTECT_UI_FORBIDDEN, &out); err != nil {
		return nil, err
	}
	return takeBlob(&out), nil
}
