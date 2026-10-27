package anker

import (
	"os"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

func TestFileStoreRoundTripsAndDeletes(t *testing.T) {
	dir := t.TempDir()
	store := NewFileStore(dir)
	if a, err := store.Load(); a != nil || err != nil {
		t.Fatalf("empty store: %v %v", a, err)
	}
	auth := NewAuthentication(Account{UserID: strings.Repeat("a", 40), Nickname: "n"}, "secret-token", farFuture(), "US", EUServer)
	if err := store.Save(auth); err != nil {
		t.Fatal(err)
	}
	loaded, err := store.Load()
	if err != nil || loaded == nil || !reflect.DeepEqual(*loaded, auth) || loaded.ServerBase() != EUServer {
		t.Fatalf("loaded %v %v", loaded, err)
	}
	if runtime.GOOS != "windows" {
		info, _ := os.Stat(store.Path())
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("mode %v", info.Mode())
		}
	}
	if err := store.Delete(); err != nil {
		t.Fatal(err)
	}
	if err := store.Delete(); err != nil {
		t.Fatal("second delete", err)
	}
	if a, _ := store.Load(); a != nil {
		t.Fatal("record survived Delete")
	}
}

func TestFileStoreReportsAMalformedRecord(t *testing.T) {
	store := NewFileStore(t.TempDir())
	if err := os.WriteFile(store.Path(), []byte("garbage"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := store.Load()
	se, ok := err.(*StoreError)
	if !ok || !se.Malformed || TextOf(err).Key != "钥匙串中的 Anker 登录记录无法读取。" {
		t.Fatalf("err = %v", err)
	}
}

func TestMemoryStore(t *testing.T) {
	var m MemoryStore
	auth := NewAuthentication(Account{UserID: "u"}, "t", farFuture(), "JP", "")
	_ = m.Save(auth)
	if a, _ := m.Load(); a == nil || a.AuthToken != "t" {
		t.Fatal("load")
	}
	_ = m.Delete()
	if a, _ := m.Load(); a != nil {
		t.Fatal("delete")
	}
}
