//go:build charkerdev

package main

// Dev builds redirect the app's data and temp directories into the workspace
// and add the test hooks the agent bridge needs:
//
//	CHARKER_MOCK=1        start on the simulated charger
//	CHARKER_AUTOQUIT=12s  quit 12 s after the app is ready
//	CHARKER_SHOT=path.png capture the desktop ~3.5 s after the page loads
//	CHARKER_STAY=1        keep running after the screenshot
//
// The agent shell launches the app at low integrity, where %LOCALAPPDATA% is
// not writable, which WebView2 needs for its user data; hence the redirects.
// Release builds don't include this file.

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const devRoot = `C:\Users\atm52\Documents\deepseek-harness\default-workspace\charker-go`

func init() {
	for _, dir := range []string{".localappdata", ".appdata", ".temp"} {
		_ = os.MkdirAll(filepath.Join(devRoot, dir), 0o755)
	}
	os.Setenv("LOCALAPPDATA", filepath.Join(devRoot, ".localappdata"))
	os.Setenv("APPDATA", filepath.Join(devRoot, ".appdata"))
	os.Setenv("TEMP", filepath.Join(devRoot, ".temp"))
	os.Setenv("TMP", filepath.Join(devRoot, ".temp"))
}

// logFile appends to charker-go/dev.log. It appends rather than truncating so
// a second instance launched for the single-instance test does not wipe the
// first one's log.
func logFile() *os.File {
	f, err := os.OpenFile(filepath.Join(devRoot, "dev.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil
	}
	return f
}

// devAutoQuit parses CHARKER_AUTOQUIT ("12s", "1m", or plain seconds).
func devAutoQuit() time.Duration {
	v := strings.TrimSpace(os.Getenv("CHARKER_AUTOQUIT"))
	if v == "" {
		return 0
	}
	if d, err := time.ParseDuration(v); err == nil {
		return d
	}
	if n, err := strconv.Atoi(v); err == nil {
		return time.Duration(n) * time.Second
	}
	return 0
}

// devForceMock starts the app on the simulated charger.
func devForceMock() bool {
	v := strings.ToLower(strings.TrimSpace(os.Getenv("CHARKER_MOCK")))
	return v == "1" || v == "true" || v == "yes"
}

// devScreenshot captures the desktop (the app window included) with
// PowerShell's CopyFromScreen, since win.CapturePage deadlocks on WebView2.
func devScreenshot(path string) bool {
	if path == "" {
		return false
	}
	if dir := filepath.Dir(path); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return false
		}
	}
	script := fmt.Sprintf(
		`Add-Type -AssemblyName System.Windows.Forms,System.Drawing; `+
			`$b=[System.Windows.Forms.SystemInformation]::VirtualScreen; `+
			`$bmp=New-Object System.Drawing.Bitmap $b.Width,$b.Height; `+
			`$g=[System.Drawing.Graphics]::FromImage($bmp); `+
			`$g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size); `+
			`$bmp.Save('%s',[System.Drawing.Imaging.ImageFormat]::Png); `+
			`$g.Dispose(); $bmp.Dispose()`, strings.ReplaceAll(path, `'`, `''`))
	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script)
	if out, err := cmd.CombinedOutput(); err != nil {
		fmt.Printf("screenshot: %v: %s\n", err, out)
		return false
	}
	return true
}

// devPreloadScript is injected before the page's own scripts: it reports the
// bridge and AppState facts through the "CharkerDiag" service into dev.log.
func devPreloadScript() string {
	return `(function () {
  var sent = {};
  var counts = {};
  function report(kind, text) {
    try {
      if (sent[kind]) { return; }
      sent[kind] = true;
      window.mygo.call("CharkerDiag.Report", kind, String(text)).catch(function () {});
    } catch (e) {}
  }
  function reportMany(kind, text) {
    try {
      counts[kind] = (counts[kind] || 0) + 1;
      if (counts[kind] > 12) { return; }
      window.mygo.call("CharkerDiag.Report", kind, String(text)).catch(function () {});
    } catch (e) {}
  }
  function formatArgs(args) {
    try {
      return Array.prototype.map.call(args, function (a) {
        if (a && a.stack) { return a.stack; }
        if (typeof a === "object") { try { return JSON.stringify(a); } catch (e) { return String(a); } }
        return String(a);
      }).join(" ");
    } catch (e) { return "?"; }
  }
  var originalWarn = console.warn, originalError = console.error;
  console.warn = function () {
    reportMany("console-warn", formatArgs(arguments));
    return originalWarn.apply(console, arguments);
  };
  console.error = function () {
    reportMany("console-error", formatArgs(arguments));
    return originalError.apply(console, arguments);
  };
  window.addEventListener("error", function (e) {
    report("js-error", (e.message || "") + " @" + (e.filename || "") + ":" + (e.lineno || 0));
  });
  window.addEventListener("unhandledrejection", function (e) {
    report("promise", String(e.reason));
  });
  window.addEventListener("DOMContentLoaded", function () {
    setTimeout(function () {
      var body = (document.body && document.body.innerText) || "";
      report("dom", JSON.stringify({
        title: document.title,
        bridge: typeof window.mygo !== "undefined",
        platform: (typeof window.mygo !== "undefined") ? window.mygo.platform : "",
        bodyLen: body.length,
        head: body.slice(0, 160),
        innerWidth: window.innerWidth,
        innerHeight: window.innerHeight,
        devicePixelRatio: window.devicePixelRatio
      }));
    }, 700);
    setTimeout(function () {
      try {
        var gpu = { webgl: null, webgl2: null, errors: [], userAgent: navigator.userAgent };
        function ctxInfo(kind) {
          try {
            var c = document.createElement("canvas");
            c.width = 16; c.height = 16;
            c.addEventListener("webglcontextcreationerror", function (e) {
              gpu.errors.push(kind + ": " + (e.statusMessage || "unknown"));
            });
            var gl = c.getContext(kind);
            if (!gl) { return null; }
            var ext = gl.getExtension("WEBGL_debug_renderer_info");
            return {
              vendor: ext ? gl.getParameter(ext.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR),
              renderer: ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER),
              version: gl.getParameter(gl.VERSION)
            };
          } catch (e) {
            gpu.errors.push(kind + " threw: " + String(e));
            return null;
          }
        }
        gpu.webgl = ctxInfo("webgl");
        gpu.webgl2 = ctxInfo("webgl2");
        report("gpu", JSON.stringify(gpu));
      } catch (e) {
        report("gpu-error", String(e));
      }
    }, 900);
    setTimeout(function () {
      try {
        var stage = document.querySelector('.ck-stage') || document.querySelector('[class*="ck-stage"]');
        var canvases = document.querySelectorAll('canvas');
        var resources = performance.getEntriesByType('resource').filter(function (r) {
          return /\.(glb|wasm)$/.test(r.name);
        }).map(function (r) {
          return { name: r.name.split('/').slice(-2).join('/'), ms: Math.round(r.duration), transfer: r.transferSize, ok: r.responseStatus || 0 };
        });
        report("stage", JSON.stringify({
          text: stage ? (stage.innerText || "").slice(0, 160) : null,
          canvases: canvases.length,
          canvasSizes: Array.prototype.map.call(canvases, function (c) { return c.width + "x" + c.height; }),
          resources: resources
        }));
      } catch (e) {
        report("stage-error", String(e));
      }
    }, 2200);
    setTimeout(function () {
      try {
        window.mygo.call("Charker.State").then(function (s) {
          report("state", JSON.stringify({
            len: JSON.stringify(s).length,
            phase: s.phase,
            scanning: s.scanning,
            device: s.device && s.device.id,
            devices: (s.devices || []).length,
            ports: (s.ports || []).length,
            history: (s.history || []).length,
            menuBar: (s.menuBar && s.menuBar.items || []).length,
            locale: s.app && s.app.locale,
            theme: s.app && s.app.theme,
            settings: s.settings,
            totals: s.totals,
            energy: s.energy,
            lastUpdatedMs: s.lastUpdatedMs
          }));
          report("state-json", JSON.stringify(s));
        }).catch(function (e) { report("state-error", String(e)); });
        window.mygo.call("Charker.EnergyReport", "day").then(function (r) {
          report("energy", JSON.stringify({
            range: r.range,
            buckets: (r.buckets || []).length,
            sessions: (r.sessions || []).length,
            totalWh: r.totalWh,
            currency: r.currency
          }));
        }).catch(function (e) { report("energy-error", String(e)); });
      } catch (e) {
        report("state-throw", String(e));
      }
    }, 1500);
  });
})();`
}
