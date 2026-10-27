package energy

import "time"

// Calendar is the slice of Foundation's Calendar the ledger uses: hour, day,
// week and month boundaries in one location. The zero value is the local
// time zone with weeks starting on Monday (the zh_CN convention the Mac
// app's Calendar.current follows on a Chinese system).
type Calendar struct {
	// Location is the time zone; nil means time.Local.
	Location *time.Location
	// weekStart starts calendar weeks once set by WithFirstWeekday.
	weekStart    time.Weekday
	hasWeekStart bool
}

// WithFirstWeekday returns a copy of c whose weeks start on day.
func (c Calendar) WithFirstWeekday(day time.Weekday) Calendar {
	c.weekStart = day
	c.hasWeekStart = true
	return c
}

func (c Calendar) loc() *time.Location {
	if c.Location == nil {
		return time.Local
	}
	return c.Location
}

func (c Calendar) firstWeekday() time.Weekday {
	if c.hasWeekStart {
		return c.weekStart
	}
	return time.Monday
}

// HourStart is dateInterval(of: .hour, for:).start: the local hour boundary,
// which is a half hour off UTC in zones like +05:30.
func (c Calendar) HourStart(t time.Time) time.Time {
	t = t.In(c.loc())
	_, offset := t.Zone()
	local := t.Unix() + int64(offset)
	floor := local - mod(local, 3600)
	return time.Unix(floor-int64(offset), 0).In(c.loc())
}

// HourEnd is the end of the hour that starts at HourStart(t).
func (c Calendar) HourEnd(t time.Time) time.Time {
	return c.HourStart(t).Add(time.Hour)
}

// StartOfDay is calendar.startOfDay(for:).
func (c Calendar) StartOfDay(t time.Time) time.Time {
	t = t.In(c.loc())
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, c.loc())
}

// AddDays is calendar.date(byAdding: .day, value: n, to: t).
func (c Calendar) AddDays(t time.Time, n int) time.Time {
	return t.In(c.loc()).AddDate(0, 0, n)
}

// MonthStart is dateInterval(of: .month, for:).start.
func (c Calendar) MonthStart(t time.Time) time.Time {
	t = t.In(c.loc())
	return time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, c.loc())
}

// WeekStart is dateInterval(of: .weekOfYear, for:).start.
func (c Calendar) WeekStart(t time.Time) time.Time {
	day := c.StartOfDay(t)
	back := (int(day.Weekday()) - int(c.firstWeekday()) + 7) % 7
	return c.AddDays(day, -back)
}

// Interval is a half-open [Start, End) calendar range.
type Interval struct {
	Start, End time.Time
}

// DayInterval is dateInterval(of: .day, for:).
func (c Calendar) DayInterval(t time.Time) Interval {
	start := c.StartOfDay(t)
	return Interval{start, c.AddDays(start, 1)}
}

// WeekInterval is dateInterval(of: .weekOfYear, for:).
func (c Calendar) WeekInterval(t time.Time) Interval {
	start := c.WeekStart(t)
	return Interval{start, c.AddDays(start, 7)}
}

// MonthInterval is dateInterval(of: .month, for:).
func (c Calendar) MonthInterval(t time.Time) Interval {
	start := c.MonthStart(t)
	return Interval{start, start.AddDate(0, 1, 0)}
}

func mod(a, b int64) int64 {
	m := a % b
	if m < 0 {
		m += b
	}
	return m
}
