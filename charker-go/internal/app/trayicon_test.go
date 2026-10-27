package app

import (
	"bytes"
	"fmt"
	"image/png"
	"os"
	"path/filepath"
	"testing"
)

func TestTrayDigits(t *testing.T) {
	st := New(Config{}).currentState()
	if _, _, ok := trayDigits(st); ok {
		t.Errorf("idle shows digits")
	}
	st.Session.Phase = PhasePolling
	st.Session.Telemetry = fixtureTelemetry()
	if text, stale, ok := trayDigits(st); !ok || text != "65" || stale {
		t.Errorf("live: %q %v %v", text, stale, ok)
	}
	st.Prefs.ShowIconOnly = true
	if _, _, ok := trayDigits(st); ok {
		t.Errorf("digits off still shows digits")
	}
}

// TestRenderTrayDigits draws the icon wherever a bold system font exists.
// CHARKER_TRAY_PREVIEW=<dir> also writes the PNGs there for a look.
func TestRenderTrayDigits(t *testing.T) {
	f := loadTrayFont()
	if f == nil {
		t.Skip("no bold system font here")
	}
	dir := os.Getenv("CHARKER_TRAY_PREVIEW")
	for _, size := range []int{16, 24, 32} {
		for _, text := range []string{"0", "8", "65", "86", "160"} {
			for _, ink := range []trayInk{{light: true}, {}, {light: true, dim: true}} {
				data, err := renderTrayDigits(f, text, size, ink)
				if err != nil {
					t.Fatalf("%s@%d: %v", text, size, err)
				}
				img, err := png.Decode(bytes.NewReader(data))
				if err != nil || img.Bounds().Dx() != size || img.Bounds().Dy() != size {
					t.Fatalf("%s@%d: bad png %v", text, size, err)
				}
				if dir != "" {
					name := fmt.Sprintf("tray-%d-%s-light%v-dim%v.png", size, text, ink.light, ink.dim)
					_ = os.WriteFile(filepath.Join(dir, name), data, 0o644)
				}
			}
		}
	}
}
