package app

import (
	"archive/zip"
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
)

func testArchive(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, body := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		w.Write([]byte(body))
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestVerifyUpdate(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	old := updatePublicKey
	updatePublicKey = base64.StdEncoding.EncodeToString(pub)
	defer func() { updatePublicKey = old }()

	archive := []byte("archive")
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(priv, archive))
	if err := verifyUpdate(archive, []byte(sig+"\n")); err != nil {
		t.Errorf("plain signature: %v", err)
	}
	if err := verifyUpdate(archive, []byte(`sparkle:edSignature="`+sig+`" length="7"`)); err != nil {
		t.Errorf("sign_update output: %v", err)
	}
	if err := verifyUpdate([]byte("tampered"), []byte(sig)); err == nil {
		t.Error("a tampered archive passed")
	}
}

func TestReplaceFromArchive(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "Charker.exe"), []byte("old"), 0o755)
	archive := testArchive(t, map[string]string{
		"Charker/Charker.exe":        "new",
		"Charker/charker-matter.exe": "helper",
	})
	if err := replaceFromArchive(archive, dir); err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]string{"Charker.exe": "new", "Charker.exe.old": "old", "charker-matter.exe": "helper"} {
		if got, _ := os.ReadFile(filepath.Join(dir, name)); string(got) != want {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}

	for _, bad := range []map[string]string{
		{"Charker/../evil.exe": "x", "Charker/Charker.exe": "x"},
		{"Charker/sub/a.dll": "x", "Charker/Charker.exe": "x"},
		{"Charker/charker-matter.exe": "x"},
	} {
		if err := replaceFromArchive(testArchive(t, bad), t.TempDir()); err == nil {
			t.Errorf("accepted %v", bad)
		}
	}
}

func TestNewestWindowsRelease(t *testing.T) {
	rel := func(tag string, assets ...string) githubRelease {
		r := githubRelease{TagName: tag, HTMLURL: "https://github.com/qzz0518/Charker/releases/tag/" + tag}
		for _, a := range assets {
			r.Assets = append(r.Assets, struct {
				Name string `json:"name"`
				URL  string `json:"browser_download_url"`
			}{a, "https://example.invalid/" + a})
		}
		return r
	}
	got, ok := newestWindowsRelease([]githubRelease{
		rel("v0.5.8", "Charker-0.5.8.dmg"),
		rel("v0.5.7", "Charker-0.5.7.dmg", "Charker-0.5.7-Windows-x64.zip", "Charker-0.5.7-Windows-x64.zip.sig"),
		rel("v0.5.6", "Charker-0.5.6-Windows-x64.zip"),
	})
	if !ok || got.version != "0.5.7" || got.sigURL == "" {
		t.Errorf("got %+v", got)
	}
}
