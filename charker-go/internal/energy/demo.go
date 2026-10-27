package energy

import (
	"math"
	"time"
)

// DemoHistory is AppModel.makeDemoEnergyHistory: a deterministic,
// explicitly labelled fixture covering every range in demo mode. sixPorts
// selects the A2345 shape (C1 C2 C3 C4 A1 A2) over the A2687's three ports.
// It lives in memory only and is never saved.
func DemoHistory(now time.Time, cal Calendar, sixPorts bool) *History {
	h := New()
	today := cal.StartOfDay(now)
	for dayOffset := -89; dayOffset < 0; dayOffset++ {
		d := abs(dayOffset)
		// Real logs have quiet days; a regular gap shows how the chart
		// treats absence instead of painting an implausible wall.
		if d%11 == 0 {
			continue
		}
		day := cal.AddDays(today, dayOffset)
		runCount := 1
		if d%4 == 0 {
			runCount = 2
		}
		for run := 0; run < runCount; run++ {
			minuteOfDay := (8+d%6+run*7)*60 + run*13
			start := day.Add(time.Duration(minuteOfDay) * time.Minute)
			observedMinutes := 5 + abs(dayOffset+run)%6
			base := 38.0 + float64((d*13+run*19)%64)
			for minute := 0; minute <= observedMinutes; minute++ {
				at := start.Add(time.Duration(minute) * time.Minute)
				wave := float64((minute*7+d)%9) - 4
				total := math.Max(8, base+wave)
				c1Share := 0.46 + float64(d%4)*0.05
				c2Share := 0.30
				if run != 0 {
					c2Share = 0.18
				}
				c1 := total * c1Share
				c2 := total * c2Share
				perPort := []float64{c1, c2, math.Max(0, total-c1-c2)}
				if sixPorts {
					// The extra ports take a small, stable share and all six
					// are normalised back to the same total wattage.
					c4 := total * 0.08
					a1 := total * 0.05
					if run != 0 {
						a1 = total * 0.03
					}
					a2 := total * 0.02
					if d%3 == 0 {
						a2 = total * 0.04
					}
					perPort = append(perPort, c4, a1, a2)
					sum := 0.0
					for _, v := range perPort {
						sum += v
					}
					for i := range perPort {
						perPort[i] *= total / sum
					}
				}
				h.Record(NewMeasurement(at, total, perPort), cal)
			}
			h.FinishCurrentSession()
		}
	}
	return h
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
