package app

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// The Windows counterpart of Sparkle. Releases are shared with the macOS
// app: a release carries Charker-<version>-Windows-x64.zip and, beside it,
// the zip's Ed25519 signature (.sig, base64) made with the same key that
// signs the macOS updates. The app checks once after launch and then daily;
// an update is downloaded, verified against SUPublicEDKey, put in place of
// the running files (Windows lets a running exe be renamed, not replaced)
// and the new Charker started.

// updatePublicKey is SUPublicEDKey from Resources/Info.plist, stamped by
// build.ps1 into release builds. Empty: no updates (development builds).
var updatePublicKey string

// updateAsset matches the Windows archive of a release.
var updateAsset = regexp.MustCompile(`^Charker-(\d+\.\d+(?:\.\d+)?)-Windows-x64\.zip$`)

// maxUpdateSize bounds a download.
const maxUpdateSize = 200 << 20

// updateRelease is a release that ships a Windows archive.
type updateRelease struct {
	version string
	page    string
	zipURL  string
	sigURL  string
}

// UpdateState is AppState.update: what the page offers.
type UpdateState struct {
	// Available is a newer Windows release than the running one.
	Available bool   `json:"available"`
	Latest    string `json:"latest,omitempty"`
	// Installing is set while an update downloads and goes in place.
	Installing bool `json:"installing"`
	// CanInstall: this build verifies and installs updates itself.
	CanInstall bool `json:"canInstall"`
}

// fetchReleases reads the repository's releases.
func fetchReleases(ctx context.Context, current string) ([]githubRelease, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, releasesAPI, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "Charker/"+current+" (Windows)")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GitHub: %s", resp.Status)
	}
	var releases []githubRelease
	return releases, json.NewDecoder(resp.Body).Decode(&releases)
}

// newestWindowsRelease picks the highest published version whose release
// carries the Windows archive.
func newestWindowsRelease(releases []githubRelease) (updateRelease, bool) {
	var best updateRelease
	found := false
	for _, r := range releases {
		if r.Draft || r.Prerelease {
			continue
		}
		var u updateRelease
		urls := map[string]string{}
		for _, a := range r.Assets {
			urls[a.Name] = a.URL
			if m := updateAsset.FindStringSubmatch(a.Name); m != nil {
				u.version, u.zipURL = m[1], a.URL
			}
		}
		if u.zipURL == "" {
			continue
		}
		u.page = r.HTMLURL
		u.sigURL = urls["Charker-"+u.version+"-Windows-x64.zip.sig"]
		if !found || versionNewer(u.version, best.version) {
			best, found = u, true
		}
	}
	return best, found
}

// checkForUpdate asks GitHub and records the answer in the state.
func (a *App) checkForUpdate(ctx context.Context) (updateRelease, bool, error) {
	releases, err := fetchReleases(ctx, a.version)
	if err != nil {
		return updateRelease{}, false, err
	}
	latest, ok := newestWindowsRelease(releases)
	available := ok && versionNewer(latest.version, a.version)
	a.mu.Lock()
	a.update.Available = available
	a.update.Latest = latest.version
	if available {
		a.updateRelease = latest
	}
	a.mu.Unlock()
	a.publishNow()
	return latest, available, nil
}

// WatchForUpdates checks shortly after launch and then once a day, as
// Sparkle's scheduled check does.
func (a *App) WatchForUpdates(ctx context.Context) {
	if updatePublicKey == "" {
		return
	}
	a.cleanUpAfterUpdate()
	wait := 20 * time.Second
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
		if _, _, err := a.checkForUpdate(ctx); err != nil {
			log.Printf("app: update check: %v", err)
		}
		wait = 24 * time.Hour
	}
}

// installUpdate downloads the newest release, verifies it and starts it in
// place of this one.
func (a *App) installUpdate(ctx context.Context) error {
	if updatePublicKey == "" {
		return errors.New("update: this build does not install updates")
	}
	a.mu.Lock()
	rel := a.updateRelease
	if a.update.Installing {
		a.mu.Unlock()
		return errors.New("update: already installing")
	}
	a.update.Installing = true
	a.mu.Unlock()
	a.publishNow()
	defer func() {
		a.mu.Lock()
		a.update.Installing = false
		a.mu.Unlock()
		a.publishNow()
	}()
	if rel.zipURL == "" || rel.sigURL == "" {
		return errors.New("update: the release has no signed Windows archive")
	}

	archive, err := download(ctx, rel.zipURL, maxUpdateSize)
	if err != nil {
		return err
	}
	sigText, err := download(ctx, rel.sigURL, 4<<10)
	if err != nil {
		return err
	}
	if err := verifyUpdate(archive, sigText); err != nil {
		return err
	}

	exe, err := os.Executable()
	if err != nil {
		return err
	}
	dir := filepath.Dir(exe)
	if err := replaceFromArchive(archive, dir); err != nil {
		return err
	}
	log.Printf("app: updated to %s; restarting", rel.version)

	// The new process waits for this one to let go of the single-instance
	// lock and Home's ports.
	cmd := exec.Command(filepath.Join(dir, "Charker.exe"), "--after-update", strconv.Itoa(os.Getpid()))
	cmd.Dir = dir
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("update: starting the new version: %w", err)
	}
	go a.Quit()
	return nil
}

// WaitForUpdatedProcess waits, at most ten seconds, for the process an
// update replaced (args "--after-update <pid>") to exit, so this one gets
// the single-instance lock and Home's ports.
func WaitForUpdatedProcess(args []string) {
	if len(args) < 2 || args[0] != "--after-update" {
		return
	}
	pid, err := strconv.Atoi(args[1])
	if err != nil {
		return
	}
	waitForExit(pid, 10*time.Second)
}

// verifyUpdate checks the archive's Ed25519 signature: the .sig asset holds
// it base64-encoded, or as sign_update prints it (sparkle:edSignature="…").
func verifyUpdate(archive, sigText []byte) error {
	key, err := base64.StdEncoding.DecodeString(updatePublicKey)
	if err != nil || len(key) != ed25519.PublicKeySize {
		return errors.New("update: bad public key")
	}
	text := strings.TrimSpace(string(sigText))
	if m := regexp.MustCompile(`edSignature="([^"]+)"`).FindStringSubmatch(text); m != nil {
		text = m[1]
	}
	sig, err := base64.StdEncoding.DecodeString(text)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return errors.New("update: bad signature")
	}
	if !ed25519.Verify(ed25519.PublicKey(key), archive, sig) {
		return errors.New("update: the signature does not match the download")
	}
	return nil
}

// replaceFromArchive puts the archive's files (all inside its top folder
// "Charker/", no subfolders) in dir. Each file in the way is renamed to
// <name>.old first, which works for a running exe; the leftovers go at the
// next launch.
func replaceFromArchive(archive []byte, dir string) error {
	zr, err := zip.NewReader(bytes.NewReader(archive), int64(len(archive)))
	if err != nil {
		return fmt.Errorf("update: %w", err)
	}
	staging, err := os.MkdirTemp(dir, ".update-")
	if err != nil {
		return fmt.Errorf("update: %s is not writable: %w", dir, err)
	}
	defer os.RemoveAll(staging)

	var names []string
	for _, f := range zr.File {
		if f.FileInfo().IsDir() {
			continue
		}
		name, ok := strings.CutPrefix(f.Name, "Charker/")
		if !ok || name == "" || strings.ContainsAny(name, `/\:`) || name == "." || name == ".." {
			return fmt.Errorf("update: unexpected file %q in the archive", f.Name)
		}
		if err := extract(f, filepath.Join(staging, name)); err != nil {
			return err
		}
		names = append(names, name)
	}
	if !contains(names, "Charker.exe") {
		return errors.New("update: the archive has no Charker.exe")
	}
	for _, name := range names {
		dst := filepath.Join(dir, name)
		old := dst + ".old"
		_ = os.Remove(old)
		if _, err := os.Stat(dst); err == nil {
			if err := os.Rename(dst, old); err != nil {
				return fmt.Errorf("update: %w", err)
			}
		}
		if err := os.Rename(filepath.Join(staging, name), dst); err != nil {
			// Put the old file back so the app still starts.
			_ = os.Rename(old, dst)
			return fmt.Errorf("update: %w", err)
		}
	}
	return nil
}

func extract(f *zip.File, path string) error {
	r, err := f.Open()
	if err != nil {
		return err
	}
	defer r.Close()
	w, err := os.Create(path)
	if err != nil {
		return err
	}
	if _, err := io.Copy(w, io.LimitReader(r, maxUpdateSize)); err != nil {
		w.Close()
		return err
	}
	return w.Close()
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// cleanUpAfterUpdate removes what the last update left beside the exe.
func (a *App) cleanUpAfterUpdate() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	dir := filepath.Dir(exe)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		name := e.Name()
		if strings.HasSuffix(name, ".old") || strings.HasPrefix(name, ".update-") {
			_ = os.RemoveAll(filepath.Join(dir, name))
		}
	}
}

// download fetches url, at most limit bytes.
func download(ctx context.Context, url string, limit int64) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("update: download: %s", resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, errors.New("update: the download is too large")
	}
	return data, nil
}
