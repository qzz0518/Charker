package main

import (
	"io/fs"
	"strings"
	"time"
)

// newFrontend returns the embedded frontend. While the web teammates are still
// writing web/index.html, a diagnostic page is served for the app root instead
// of a 404, so the shell, the bridge and AppState can be verified end-to-end
// before the real UI exists. A complete frontend is used unchanged.
func newFrontend(web fs.FS) fs.FS {
	if _, err := fs.Stat(web, "index.html"); err == nil {
		return web
	}
	return &fallbackFrontend{web: web}
}

// fallbackFrontend serves indexHTML for the app's root routes and delegates
// every other file (assets, vendor, css, js) to the embedded tree.
type fallbackFrontend struct {
	web fs.FS
}

func (f *fallbackFrontend) Open(name string) (fs.File, error) {
	if name == "index.html" {
		src := strings.NewReader(diagnosticHTML)
		return &memFile{reader: src, size: int64(src.Len())}, nil
	}
	return f.web.Open(name)
}

// memFile is a minimal in-memory fs.File for the diagnostic page.
type memFile struct {
	reader *strings.Reader
	size   int64
}

func (f *memFile) Read(p []byte) (int, error) { return f.reader.Read(p) }
func (f *memFile) Close() error               { return nil }
func (f *memFile) Stat() (fs.FileInfo, error) {
	return memFileInfo{size: f.size}, nil
}

type memFileInfo struct{ size int64 }

func (i memFileInfo) Name() string       { return "index.html" }
func (i memFileInfo) Size() int64        { return i.size }
func (i memFileInfo) Mode() fs.FileMode  { return 0o444 }
func (i memFileInfo) ModTime() time.Time { return time.Time{} }
func (i memFileInfo) IsDir() bool        { return false }
func (i memFileInfo) Sys() any           { return nil }

// assert the interfaces at compile time.
var (
	_ fs.FS       = (*fallbackFrontend)(nil)
	_ fs.File     = (*memFile)(nil)
	_ fs.FileInfo = memFileInfo{}
)

// diagnosticHTML is shown until web/index.html exists: it proves the WebView2
// window, window.mygo and Charker.State work, and renders the live AppState.
const diagnosticHTML = `<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="color-scheme" content="dark light">
<title>Charker</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; padding: 24px 28px; background: #0b0d10; color: #f3f5f8;
         font: 13px/1.5 "Segoe UI", system-ui, sans-serif; }
  h1 { font-size: 19px; margin: 0 0 4px; }
  p { margin: 0 0 16px; color: #9aa3b2; }
  #status { display: inline-block; padding: 2px 8px; border-radius: 999px;
            background: #252932; color: #00a7e1; font-size: 11px; }
  pre { margin: 16px 0 0; padding: 16px; border-radius: 10px; background: #14161b;
        border: 1px solid #2a2e37; overflow: auto; max-height: calc(100vh - 140px);
        font: 12px/1.5 Consolas, "Cascadia Mono", monospace; color: #c8d0dc; }
</style>
</head>
<body>
  <h1>Charker <span id="status">loading…</span></h1>
  <p>Diagnostic page — web/index.html is not embedded in this build yet.</p>
  <pre id="state">waiting for window.mygo and Charker.State …</pre>
  <script>
    (function () {
      var status = document.getElementById('status');
      var out = document.getElementById('state');
      function show(kind, text) {
        status.textContent = kind + ': ' + text;
      }
      if (typeof window.mygo === 'undefined') {
        show('error', 'window.mygo is missing');
        return;
      }
      show('ok', 'window.mygo present');
      function render(s) {
        out.textContent = JSON.stringify(s, null, 2);
      }
      try {
        window.mygo.on('state', render);
        window.mygo.call('Charker.State').then(function (s) {
          show('ok', 'Charker.State · phase ' + s.phase);
          render(s);
        }).catch(function (e) {
          show('error', 'Charker.State failed: ' + e);
        });
      } catch (e) {
        show('error', String(e));
      }
    })();
  </script>
</body>
</html>
`
