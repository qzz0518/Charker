package winble

import (
	"testing"
	"time"
)

func TestConfigDefaults(t *testing.T) {
	got := Config{}.withDefaults()
	if got.ScanWindow != 10*time.Second {
		t.Errorf("ScanWindow = %v, want 10s", got.ScanWindow)
	}
	if got.ConnectTimeout != 12*time.Second {
		t.Errorf("ConnectTimeout = %v, want 12s", got.ConnectTimeout)
	}
	if got.WriteTimeout != 5*time.Second {
		t.Errorf("WriteTimeout = %v, want 5s", got.WriteTimeout)
	}
	if got.EventBuffer != 256 {
		t.Errorf("EventBuffer = %d, want 256", got.EventBuffer)
	}
}

func TestConfigKeepsExplicitValues(t *testing.T) {
	cfg := Config{
		ScanWindow:     time.Second,
		ConnectTimeout: 2 * time.Second,
		WriteTimeout:   3 * time.Second,
		EventBuffer:    8,
	}
	got := cfg.withDefaults()
	if got.ScanWindow != cfg.ScanWindow || got.ConnectTimeout != cfg.ConnectTimeout ||
		got.WriteTimeout != cfg.WriteTimeout || got.EventBuffer != cfg.EventBuffer {
		t.Errorf("withDefaults changed explicit values: %+v, want %+v", got, cfg)
	}
}

func TestConfigNegativeValuesGetDefaults(t *testing.T) {
	cfg := Config{ScanWindow: -1, ConnectTimeout: -1, WriteTimeout: -1, EventBuffer: -5}
	got := cfg.withDefaults()
	want := Config{}.withDefaults()
	if got.ScanWindow != want.ScanWindow || got.ConnectTimeout != want.ConnectTimeout ||
		got.WriteTimeout != want.WriteTimeout || got.EventBuffer != want.EventBuffer {
		t.Errorf("negative values did not fall back to defaults: %+v", got)
	}
}
