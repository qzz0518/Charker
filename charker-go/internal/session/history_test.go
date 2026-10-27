package session_test

import (
	"context"
	"sync"
	"testing"
	"time"

	"charker/internal/energy"
	"charker/internal/product"
	"charker/internal/session"
	"charker/internal/transport/mock"
)

func TestDecimateHistory(t *testing.T) {
	// Short input is returned untouched.
	short := []product.Sample{{T: 1, W: 1}, {T: 2, W: 2}}
	if got := product.Decimate(short, 180); len(got) != 2 {
		t.Fatalf("short decimation = %v", got)
	}
	// Long input: bounded, ordered, last sample exact, spike/trough preserved.
	const n = 2000
	samples := make([]product.Sample, 0, n)
	for i := 0; i < n; i++ {
		w := 10 + float64(i%7)
		if i == 700 {
			w = 158 // peak
		}
		if i == 1400 {
			w = 3 // trough
		}
		samples = append(samples, product.Sample{T: int64(i) * 1000, W: w})
	}
	out := product.Decimate(samples, 180)
	if len(out) > 180 || len(out) < 2 {
		t.Fatalf("decimated to %d points, want 2..180", len(out))
	}
	var havePeak, haveTrough bool
	for i, s := range out {
		if i > 0 && s.T < out[i-1].T {
			t.Fatalf("decimated samples out of order at %d: %d < %d", i, s.T, out[i-1].T)
		}
		if s.W == 158 {
			havePeak = true
		}
		if s.W == 3 {
			haveTrough = true
		}
	}
	if !havePeak || !haveTrough {
		t.Fatalf("peak/trough lost: peak=%v trough=%v", havePeak, haveTrough)
	}
	last := out[len(out)-1]
	if last.T != samples[len(samples)-1].T || last.W != samples[len(samples)-1].W {
		t.Fatalf("last sample = %+v, want exact %+v", last, samples[len(samples)-1])
	}
	// Zero time span collapses to the last sample (needs more samples than the
	// budget to enter the bucketing branch).
	flat := []product.Sample{{T: 5, W: 1}, {T: 5, W: 2}, {T: 5, W: 3}}
	if got := product.Decimate(flat, 2); len(got) != 1 || got[0].W != 3 {
		t.Fatalf("zero-span decimation = %v", got)
	}
}

func TestSessionFeedsEnergyHistory(t *testing.T) {
	tr := mock.NewWithOptions(mock.Options{
		ReportInterval: 5 * time.Millisecond,
		ConnectDelay:   time.Millisecond,
		ScanDelay:      time.Millisecond,
	})
	opts := session.DefaultOptions()
	opts.PollInterval = 0
	opts.StageTimeout = 250 * time.Millisecond
	opts.OpeningBurstSpacing = 0
	hist := energy.New()
	cal := energy.Calendar{Location: time.UTC}
	var mu sync.Mutex
	opts.OnSample = func(at time.Time, totalWatts float64, perPortWatts [6]float64) {
		mu.Lock()
		defer mu.Unlock()
		hist.Record(energy.NewMeasurement(at, totalWatts, perPortWatts[:]), cal)
	}
	m := session.NewManager(tr, opts)
	t.Cleanup(m.Stop)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := m.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	// ~0.02 Wh at 42 W takes ~1.7 s of live samples.
	deadline := time.Now().Add(6 * time.Second)
	var open *energy.SessionRecord
	var day energy.Summary
	for time.Now().Before(deadline) {
		mu.Lock()
		open = hist.ActiveSession()
		day = hist.Summary(nil, time.Now().Add(time.Second))
		mu.Unlock()
		if open != nil && open.SampleCount >= 3 && day.EnergyWh >= 0.02 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if day.EnergyWh < 0.02 {
		t.Fatalf("integrated energy = %v Wh, want >= 0.02", day.EnergyWh)
	}
	if open == nil || open.SampleCount < 3 {
		t.Fatalf("open session = %+v", open)
	}
	// A2687 has three ports; the C2 sample carries the energy.
	if c2 := open.PerPortWh[1]; c2 <= 0 {
		t.Fatalf("C2 energy = %v, want > 0 (per-port = %v)", c2, open.PerPortWh)
	}
}
