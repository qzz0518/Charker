//go:build charkerdev

package main

// Dev builds run as "Charker Dev" (plus CHARKER_INSTANCE) so their preferences, energy ledger and
// single-instance lock never touch an installed Charker. They log to dev.log
// beside the exe, honour CHARKER_MOCK=1 (start on the simulated charger) and
// CHARKER_ROUTE=<page> (open on that page), and report page errors and state
// facts into the log through the "CharkerDiag" service.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// appName keeps dev data apart from an installed Charker; CHARKER_INSTANCE
// runs several dev copies side by side, each with its own data and lock.
var appName = func() string {
	if v := strings.TrimSpace(os.Getenv("CHARKER_INSTANCE")); v != "" {
		return "Charker Dev " + v
	}
	return "Charker Dev"
}()

func logFile() *os.File {
	dir := "."
	if exe, err := os.Executable(); err == nil {
		dir = filepath.Dir(exe)
	}
	f, err := os.OpenFile(filepath.Join(dir, "dev.log"), os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return nil
	}
	return f
}

func devForceMock() bool {
	v := strings.ToLower(strings.TrimSpace(os.Getenv("CHARKER_MOCK")))
	return v == "1" || v == "true" || v == "yes"
}

func devRouteScript() string {
	route := strings.TrimSpace(os.Getenv("CHARKER_ROUTE"))
	if route == "" {
		return ""
	}
	q, _ := json.Marshal("#/" + route)
	return "location.hash = " + string(q) + ";\n"
}

// devPreloadScript is injected before the page's own scripts: it reports the
// bridge and AppState facts through the "CharkerDiag" service into dev.log.
func devPreloadScript() string {
	return devRouteScript() + `(function () {
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
      var page = document.querySelector(".page");
      var active = document.activeElement;
      report("layout", JSON.stringify({
        scrollTop: page ? page.scrollTop : null,
        scrollHeight: page ? page.scrollHeight : null,
        clientHeight: page ? page.clientHeight : null,
        active: active ? active.tagName + "." + active.className : ""
      }));
    }, 4000);
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
  });
})();`
}
