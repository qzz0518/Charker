package cloudsession

import (
	"math"

	"charker/internal/session"
)

// decimatedHistory is PowerSample.decimated: min/max per bucket of a rounded
// width, the last sample always kept. It is a copy of the unexported helper
// in internal/session so both engines publish the same chart series.
func decimatedHistory(samples []session.HistorySample, budget int) []session.HistorySample {
	if len(samples) <= budget || len(samples) == 0 {
		return append([]session.HistorySample(nil), samples...)
	}
	first, last := samples[0], samples[len(samples)-1]
	span := float64(last.T-first.T) / 1000
	if span <= 0 {
		return append([]session.HistorySample(nil), samples...)
	}
	buckets := max(2, budget/2)
	width := roundedInterval(span / float64(buckets))
	out := make([]session.HistorySample, 0, buckets*2+1)
	var low, high *session.HistorySample
	bucket := int64(math.MinInt64)
	flush := func() {
		if low == nil || high == nil {
			return
		}
		switch {
		case low.T == high.T:
			out = append(out, *low)
		case low.T < high.T:
			out = append(out, *low, *high)
		default:
			out = append(out, *high, *low)
		}
	}
	for i := range samples {
		s := &samples[i]
		index := int64(math.Floor(float64(s.T) / 1000 / width))
		if index != bucket {
			flush()
			low, high = nil, nil
			bucket = index
		}
		if low == nil || s.Total < low.Total {
			low = s
		}
		if high == nil || s.Total > high.Total {
			high = s
		}
	}
	flush()
	if out[len(out)-1].T != last.T {
		out = append(out, last)
	}
	return out
}

func roundedInterval(minimum float64) float64 {
	if minimum <= 0 {
		return 1
	}
	for _, step := range []float64{1, 2, 5, 10, 15, 20, 30, 60, 120, 300, 600, 900, 1800, 3600} {
		if step >= minimum {
			return step
		}
	}
	step := 3600.0
	for step < minimum {
		step *= 2
	}
	return step
}
