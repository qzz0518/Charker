package cloudsession

import (
	"context"
	"fmt"
	"slices"
	"time"

	"charker/internal/a2345"
	"charker/internal/anker"
)

// Account-side operations that can be in flight (A2345CloudWork); the UI
// disables the matching control meanwhile.
const (
	// WorkLabExclusive: maximum compatibility and device identification
	// exclude each other, so they share one slot.
	WorkLabExclusive     = "labExclusive"
	WorkCustomModeSwitch = "customModeSwitch"
	WorkChargingModes    = "chargingModes"
	WorkPictures         = "pictures"
)

func textPtr(t anker.Text) *anker.Text { return &t }

// controlBlocker is a2345ControlBlocker: why settings cannot be written now.
// Writes go out over the same MQTT session as the reads, so they need a live
// subscription and one full snapshot to start from.
func (e *Engine) controlBlocker() *anker.Text {
	st := &e.st
	if st.isDemo {
		return nil
	}
	if st.phase != PhaseMonitoring || st.sub == nil {
		return textPtr(anker.T("需要先连上充电器"))
	}
	if st.settings == nil {
		return textPtr(anker.T("正在读取充电器设置"))
	}
	if st.isStale {
		return textPtr(anker.T("数据已陈旧"))
	}
	if st.settings.IsUpdatingFirmware != nil && *st.settings.IsUpdatingFirmware {
		return textPtr(anker.T("充电器正在升级固件"))
	}
	return nil
}

// switchBlocker: something is being written; switching devices would strand it.
func (e *Engine) switchBlocker() *anker.Text {
	if len(e.st.pending) == 0 && len(e.st.cloudWork) == 0 {
		return nil
	}
	return textPtr(anker.T("正在写入设备设置，完成后再切换"))
}

// portControlBlocker: port switches, countdowns and schedules cut power, so
// they share the A2687 write opt-in. The simulator never needs it.
func (e *Engine) portControlBlocker() *anker.Text {
	if b := e.controlBlocker(); b != nil {
		return b
	}
	if !e.st.isDemo && !e.st.writesEnabled {
		return textPtr(anker.T("在「高级」里打开「允许端口开关」后才能操作"))
	}
	return nil
}

func (e *Engine) guarded(blocker func() *anker.Text, fn func() error) error {
	return e.exec(func() error {
		if b := blocker(); b != nil {
			return &Refusal{Message: *b}
		}
		return fn()
	})
}

func groupLabel(g a2345.PortGroup) *anker.Text { return textPtr(anker.Text{Key: g.Label()}) }

// SetPortOutput switches a port group.
func (e *Engine) SetPortOutput(g a2345.PortGroup, on bool) error {
	return e.guarded(e.portControlBlocker, func() error {
		return e.send(a2345.SetPortOutput(g, on), groupLabel(g), true, nil)
	})
}

// SetPortCountdown arms a group's countdown for seconds, or cancels it with
// seconds <= 0 (the cancel echoes the reported total, as the official app).
func (e *Engine) SetPortCountdown(g a2345.PortGroup, seconds int) error {
	return e.guarded(e.portControlBlocker, func() error {
		if seconds > 0 {
			return e.send(a2345.SetPortCountdown(g, true, uint32(seconds)), groupLabel(g), true, nil)
		}
		var previous uint32
		if e.st.settings != nil {
			previous = e.st.settings.PortControls[g].CountdownTotal
		}
		return e.send(a2345.SetPortCountdown(g, false, previous), groupLabel(g), true, nil)
	})
}

// SetPortSchedule writes one of a group's two daily slots.
func (e *Engine) SetPortSchedule(g a2345.PortGroup, slot a2345.ScheduleSlot, s a2345.PortSchedule) error {
	return e.guarded(e.portControlBlocker, func() error {
		return e.send(a2345.SetPortSchedule(g, slot, s), groupLabel(g), true, nil)
	})
}

// SetChargingMode selects a preset mode (a no-op when already active).
func (e *Engine) SetChargingMode(m a2345.ChargingMode) error {
	return e.guarded(e.controlBlocker, func() error {
		if e.st.settings != nil {
			if current, ok := e.st.settings.ChargingMode(); ok && current == m {
				return nil
			}
		}
		return e.send(a2345.SetChargingMode(m), textPtr(anker.T("充电模式")), true, nil)
	})
}

// SetPortPriority sets the preferred C ports (bit0…bit3, at most two).
func (e *Engine) SetPortPriority(bitmap byte) error {
	return e.guarded(e.controlBlocker, func() error {
		return e.send(a2345.SetPortPriority(bitmap), textPtr(anker.T("优先端口")), true, nil)
	})
}

// SetScreenTimeout sets the display timeout.
func (e *Engine) SetScreenTimeout(t a2345.ScreenTimeout) error {
	return e.guarded(e.controlBlocker, func() error {
		return e.send(a2345.SetScreenTimeout(t), textPtr(anker.T("熄屏时间")), true, nil)
	})
}

// SetBrightness rounds to the 5 % steps the charger takes, 20…100.
func (e *Engine) SetBrightness(percent int) error {
	return e.guarded(e.controlBlocker, func() error {
		value := min(100, max(20, (percent+2)/5*5))
		return e.send(a2345.SetBrightness(byte(value)), textPtr(anker.T("屏幕亮度")), true, nil)
	})
}

// SetKnobDirection sets the knob direction.
func (e *Engine) SetKnobDirection(d a2345.KnobDirection) error {
	return e.guarded(e.controlBlocker, func() error {
		return e.send(a2345.SetKnobDirection(d), textPtr(anker.T("旋钮方向")), true, nil)
	})
}

// SetHourFormat sets 12/24-hour time.
func (e *Engine) SetHourFormat(f a2345.HourFormat) error {
	return e.guarded(e.controlBlocker, func() error {
		return e.send(a2345.SetHourFormat(f), textPtr(anker.T("时间格式")), true, nil)
	})
}

// SetClockSchedule sets when the clock screensaver shows.
func (e *Engine) SetClockSchedule(s a2345.ClockSchedule) error {
	return e.guarded(e.controlBlocker, func() error {
		return e.send(a2345.SetClockSchedule(s), textPtr(anker.T("显示时段")), true, nil)
	})
}

// SetHolidayTheme switches the holiday screensaver.
func (e *Engine) SetHolidayTheme(on bool) error {
	return e.guarded(e.controlBlocker, func() error {
		return e.send(a2345.SetHolidayTheme(on), textPtr(anker.T("节日屏保")), true, nil)
	})
}

// SetCustomImageTimeDisplay shows or hides the time over a custom picture.
func (e *Engine) SetCustomImageTimeDisplay(on bool) error {
	return e.guarded(e.controlBlocker, func() error {
		return e.send(a2345.SetCustomImageTimeDisplay(on), textPtr(anker.T("显示时间")), true, nil)
	})
}

// SetUFCS switches UFCS (mainland firmware without protocol management).
func (e *Engine) SetUFCS(on bool) error {
	return e.guarded(e.controlBlocker, func() error {
		return e.send(a2345.SetUFCS(on), textPtr(anker.Text{Key: "UFCS"}), true, nil)
	})
}

// ackWaits is how long to wait before each (re)send, as the official app
// paces it. Mode and priority writes make the charger re-allocate power every
// time, so priority goes out once and a custom profile waits three seconds.
func (e *Engine) ackWaits(c a2345.Command, retries bool) []time.Duration {
	unit := e.opts.AckUnit
	scale := func(seconds ...float64) []time.Duration {
		out := make([]time.Duration, len(seconds))
		for i, s := range seconds {
			out[i] = time.Duration(s * float64(unit))
		}
		return out
	}
	switch c.Kind() {
	case a2345.CmdSetPortPriority:
		return scale(4)
	case a2345.CmdSetCustomChargingMode:
		if retries {
			return scale(3, 4)
		}
		return scale(6)
	}
	if retries {
		return scale(1.5, 3)
	}
	return scale(4)
}

func (e *Engine) writeMessage(text anker.Text, label *anker.Text) {
	if label != nil {
		e.message(anker.T("%@：%@", *label, text))
	} else {
		e.message(text)
	}
}

// send is sendA2345: validate, apply optimistically, publish, wait for the
// acknowledgement and resend once when nothing comes back, then read the
// full state again either way. Runs on the loop.
func (e *Engine) send(c a2345.Command, label *anker.Text, retries bool, onResult func(bool)) error {
	st := &e.st
	result := func(ok bool) {
		if onResult != nil {
			onResult(ok)
		}
	}
	if _, err := c.Encode(e.now()); err != nil {
		e.diag("WRITE", "A2345 %s rejected locally: %v", c, err)
		msg := anker.T("充电器不接受这个值。")
		e.writeMessage(msg, label)
		result(false)
		return &Refusal{Message: msg}
	}
	if !st.isDemo {
		if b := e.controlBlocker(); b != nil {
			e.writeMessage(*b, label)
			result(false)
			return &Refusal{Message: *b}
		}
	}
	if st.settings != nil {
		next := st.settings.Applying(c)
		st.settings = &next
		if c.Kind() == a2345.CmdSetPortCountdown {
			if g, ok := c.Group(); ok {
				st.reported[g] = e.now()
			}
		}
	}
	if st.isDemo {
		result(true)
		return nil
	}
	sub := st.sub
	if sub == nil {
		result(false)
		return nil
	}

	key := a2345.NewWriteKey(c)
	if cancel, ok := st.writeCancel[key]; ok {
		cancel()
	}
	if done, ok := st.writeCompletions[key]; ok {
		delete(st.writeCompletions, key)
		done(false)
	}
	if onResult != nil {
		st.writeCompletions[key] = onResult
	}
	if !slices.Contains(st.pending, key) {
		st.pending = append(st.pending, key)
	}
	st.writeLabels[key] = label
	e.diag("WRITE", "A2345 %s sent", c)

	waits := e.ackWaits(c, retries)
	ctx, cancel := context.WithCancel(context.Background())
	st.writeCancel[key] = cancel
	gen := st.generation
	go func() {
		for _, wait := range waits {
			_ = sub.Send(c)
			select {
			case <-ctx.Done():
				return
			case <-time.After(wait):
			}
		}
		e.post(func() {
			if ctx.Err() != nil || e.st.generation != gen {
				return
			}
			delete(e.st.writeCancel, key)
			label := e.st.writeLabels[key]
			delete(e.st.writeLabels, key)
			e.removePending(key)
			if done, ok := e.st.writeCompletions[key]; ok {
				delete(e.st.writeCompletions, key)
				done(false)
			}
			e.diag("WRITE", "A2345 %s not acknowledged", c)
			e.writeMessage(anker.T("充电器没有回应，这次操作有没有生效不清楚。"), label)
			e.requestReadback(c.MessageType() == 0x0205)
		})
	}()
	return nil
}

func (e *Engine) removePending(key a2345.WriteKey) {
	e.st.pending = slices.DeleteFunc(e.st.pending, func(k a2345.WriteKey) bool { return k == key })
}

// resolveWrite matches an acknowledgement to the oldest pending write.
func (e *Engine) resolveWrite(ack a2345.WriteAcknowledgement) {
	st := &e.st
	i := slices.IndexFunc(st.pending, func(k a2345.WriteKey) bool { return k.Matches(ack) })
	if i < 0 {
		return
	}
	key := st.pending[i]
	if cancel, ok := st.writeCancel[key]; ok {
		cancel()
		delete(st.writeCancel, key)
	}
	e.removePending(key)
	label := st.writeLabels[key]
	delete(st.writeLabels, key)
	if done, ok := st.writeCompletions[key]; ok {
		delete(st.writeCompletions, key)
		done(!ack.IsRejected())
	}
	typeLabel := fmt.Sprintf("0x%04X", key.MessageType)
	if ack.IsRejected() {
		status := 0
		if ack.Status != nil {
			status = int(*ack.Status)
		}
		e.diag("WRITE", "A2345 %s rejected, status 0x%02X", typeLabel, status)
		e.writeMessage(anker.T("充电器拒绝了这次操作。"), label)
	} else {
		e.diag("WRITE", "A2345 %s acknowledged", typeLabel)
	}
	// Settings without a change message (12/24 h, clock hours, the lab
	// switches) only show up in the next snapshot.
	e.requestReadback(key.MessageType == 0x0205 || key.MessageType == 0x0222)
}

// requestReadback reads the full state again shortly after a write settles.
// Bursts of writes share one read.
func (e *Engine) requestReadback(includeTheme bool) {
	e.arm(&e.st.readback, e.opts.ReadbackDelay, func() {
		sub := e.st.sub
		if sub == nil {
			return
		}
		_ = sub.Send(a2345.RequestStatusSnapshot())
		if includeTheme {
			_ = sub.Send(a2345.ThemeStatus())
		}
	})
}

func (e *Engine) cancelWrites() {
	st := &e.st
	for _, cancel := range st.writeCancel {
		cancel()
	}
	st.writeCancel = map[a2345.WriteKey]context.CancelFunc{}
	st.writeLabels = map[a2345.WriteKey]*anker.Text{}
	completions := st.writeCompletions
	st.writeCompletions = map[a2345.WriteKey]func(bool){}
	for _, done := range completions {
		done(false)
	}
	st.pending = nil
	st.readback.cancel()
}

// --- account-side settings ---

// loadCloudExtras fetches the account-side data, retrying a few times for
// whatever failed. Values already loaded (or just written) are never
// overwritten.
func (e *Engine) loadCloudExtras() {
	st := &e.st
	if st.extrasRunning || st.client == nil || st.cloudDevice == nil {
		return
	}
	st.extrasRunning = true
	client, serial, gen, language := st.client, st.cloudDevice.DeviceSerial, st.generation, e.opts.ThemeLanguage
	ctx := context.Background()
	go func() {
		for attempt := range 3 {
			if attempt > 0 {
				time.Sleep(e.opts.ExtrasRetryDelay)
			}
			var needSettings, needModes, needThemes, needPictures bool
			if !e.on(gen, func() {
				needSettings = e.st.cloudSettings == nil
				needModes = !e.st.modesLoaded
				needThemes = !e.st.themesLoaded
				needPictures = !e.st.picturesLoaded
			}) {
				return
			}
			if !needSettings && !needModes && !needThemes && !needPictures {
				break
			}
			type result struct {
				settings *anker.CloudSettings
				modes    []anker.CloudChargingMode
				themes   []anker.CloudTheme
				pictures []anker.CloudTheme
				ok       [4]bool
			}
			var r result
			done := make(chan struct{}, 4)
			run := func(need bool, fn func()) {
				if !need {
					done <- struct{}{}
					return
				}
				go func() { fn(); done <- struct{}{} }()
			}
			run(needSettings, func() {
				if v, err := client.A2345CloudSettings(ctx, serial); err == nil {
					r.settings, r.ok[0] = &v, true
				}
			})
			run(needModes, func() {
				if v, err := client.A2345ChargingModes(ctx, serial); err == nil {
					r.modes, r.ok[1] = v, true
				}
			})
			run(needThemes, func() {
				if v, err := client.A2345ClockThemes(ctx, language); err == nil {
					r.themes, r.ok[2] = v, true
				}
			})
			run(needPictures, func() {
				if v, err := client.A2345CustomScreensavers(ctx, serial); err == nil {
					r.pictures, r.ok[3] = v, true
				}
			})
			for range 4 {
				<-done
			}
			if !e.on(gen, func() {
				st := &e.st
				if st.cloudSettings == nil && r.ok[0] {
					st.cloudSettings = r.settings
				}
				if !st.modesLoaded && r.ok[1] {
					st.modes, st.modesLoaded = r.modes, true
				}
				if !st.themesLoaded && r.ok[2] {
					st.themes, st.themesLoaded = r.themes, true
				}
				if !st.picturesLoaded && r.ok[3] {
					st.pictures, st.picturesLoaded = r.pictures, true
				}
				count := func(ok bool, n int) int {
					if ok {
						return n
					}
					return -1
				}
				e.diag("CLOUD", "A2345 extras attempt %d: settings=%v modes=%d themes=%d pictures=%d",
					attempt+1, r.ok[0], count(r.ok[1], len(r.modes)), count(r.ok[2], len(r.themes)), count(r.ok[3], len(r.pictures)))
			}) {
				return
			}
		}
		e.on(gen, func() { e.st.extrasRunning = false })
	}()
}

// runCloudWork runs one account write; then() follows on success. The
// simulator runs then() at once.
func (e *Engine) runCloudWork(work string, op func(context.Context, Cloud, string) error, then func()) {
	st := &e.st
	if st.isDemo {
		if then != nil {
			then()
		}
		return
	}
	if st.client == nil || st.cloudDevice == nil {
		e.message(anker.T("需要先连上充电器"))
		return
	}
	if st.cloudWork[work] {
		return
	}
	st.cloudWork[work] = true
	client, serial, gen := st.client, st.cloudDevice.DeviceSerial, st.generation
	go func() {
		err := op(context.Background(), client, serial)
		e.on(gen, func() {
			delete(e.st.cloudWork, work)
			if err == nil {
				if then != nil {
					then()
				}
				return
			}
			e.diag("CLOUD", "A2345 %s failed: %v", work, err)
			e.message(anker.T("没有保存到 Anker 账号：%@", anker.TextOf(err)))
			if work == WorkLabExclusive {
				e.reloadCloudSettings()
			}
		})
	}()
}

func (e *Engine) reloadCloudSettings() {
	st := &e.st
	if st.client == nil || st.cloudDevice == nil {
		return
	}
	client, serial, gen := st.client, st.cloudDevice.DeviceSerial, st.generation
	go func() {
		v, err := client.A2345CloudSettings(context.Background(), serial)
		if err == nil {
			e.on(gen, func() { e.st.cloudSettings = &v })
		}
	}()
}

func boolPtr(b bool) *bool { return &b }

func (e *Engine) setCloudSetting(apply func(*anker.CloudSettings)) {
	if e.st.cloudSettings == nil {
		return
	}
	next := *e.st.cloudSettings
	apply(&next)
	e.st.cloudSettings = &next
}

// SetMaxCompatibility: maximum compatibility and device identification
// exclude each other, as in the official app. Each step is stored in the
// account first and then sent to the charger; turning one on first turns the
// other off.
func (e *Engine) SetMaxCompatibility(on bool) error {
	return e.guarded(e.controlBlocker, func() error {
		if e.st.cloudWork[WorkLabExclusive] {
			return nil
		}
		other := e.labValue(func(s anker.CloudSettings) *bool { return s.DeviceIdentification },
			func(s *a2345.DeviceSettings) *bool { return s.DeviceIdentification })
		apply := func() {
			e.runCloudWork(WorkLabExclusive, func(ctx context.Context, c Cloud, serial string) error {
				return c.SetA2345MaxCompatibility(ctx, on, serial)
			}, func() {
				e.setCloudSetting(func(s *anker.CloudSettings) { s.MaxCompatibility = boolPtr(on) })
				_ = e.send(a2345.SetMaxCompatibility(on), textPtr(anker.T("最大兼容性")), true, nil)
			})
		}
		if !on || !other {
			apply()
			return nil
		}
		e.runCloudWork(WorkLabExclusive, func(ctx context.Context, c Cloud, serial string) error {
			return c.SetA2345DeviceIdentification(ctx, false, serial)
		}, func() {
			e.setCloudSetting(func(s *anker.CloudSettings) { s.DeviceIdentification = boolPtr(false) })
			_ = e.send(a2345.SetDeviceIdentification(false), textPtr(anker.T("充电设备识别")), true, nil)
			apply()
		})
		return nil
	})
}

// SetDeviceIdentification is SetMaxCompatibility's mirror.
func (e *Engine) SetDeviceIdentification(on bool) error {
	return e.guarded(e.controlBlocker, func() error {
		if e.st.cloudWork[WorkLabExclusive] {
			return nil
		}
		other := e.labValue(func(s anker.CloudSettings) *bool { return s.MaxCompatibility },
			func(s *a2345.DeviceSettings) *bool { return s.MaxCompatibility })
		apply := func() {
			e.runCloudWork(WorkLabExclusive, func(ctx context.Context, c Cloud, serial string) error {
				return c.SetA2345DeviceIdentification(ctx, on, serial)
			}, func() {
				e.setCloudSetting(func(s *anker.CloudSettings) { s.DeviceIdentification = boolPtr(on) })
				_ = e.send(a2345.SetDeviceIdentification(on), textPtr(anker.T("充电设备识别")), true, nil)
			})
		}
		if !on || !other {
			apply()
			return nil
		}
		e.runCloudWork(WorkLabExclusive, func(ctx context.Context, c Cloud, serial string) error {
			return c.SetA2345MaxCompatibility(ctx, false, serial)
		}, func() {
			e.setCloudSetting(func(s *anker.CloudSettings) { s.MaxCompatibility = boolPtr(false) })
			_ = e.send(a2345.SetMaxCompatibility(false), textPtr(anker.T("最大兼容性")), true, nil)
			apply()
		})
		return nil
	})
}

// labValue reads a lab switch: the account value first, then the charger's.
func (e *Engine) labValue(cloud func(anker.CloudSettings) *bool, device func(*a2345.DeviceSettings) *bool) bool {
	if e.st.cloudSettings != nil {
		if v := cloud(*e.st.cloudSettings); v != nil {
			return *v
		}
	}
	if e.st.settings != nil {
		if v := device(e.st.settings); v != nil {
			return *v
		}
	}
	return false
}

// SetCustomModeEnabled is the 实验室 switch that makes custom mode available.
// Turning it off also takes the charger out of custom mode.
func (e *Engine) SetCustomModeEnabled(on bool) error {
	return e.guarded(e.controlBlocker, func() error {
		e.runCloudWork(WorkCustomModeSwitch, func(ctx context.Context, c Cloud, serial string) error {
			return c.SetA2345CustomModeEnabled(ctx, on, serial)
		}, func() {
			e.setCloudSetting(func(s *anker.CloudSettings) { s.CustomModeEnabled = boolPtr(on) })
			if on {
				return
			}
			if b := e.controlBlocker(); b != nil {
				e.message(*b)
			} else if e.st.settings != nil && e.st.settings.IsCustomChargingMode() {
				_ = e.send(a2345.ExitCustomChargingMode(), textPtr(anker.T("自定义模式")), true, nil)
			}
		})
		return nil
	})
}

// protocolsFor: the protocol bitmap travels with a custom profile only where
// the firmware has per-port protocols and no separate protocol manager.
func (e *Engine) protocolsFor(mode anker.CloudChargingMode) *a2345.PortProtocols {
	s := e.st.settings
	if s == nil || !s.Supports(a2345.CapPortProtocols) || s.Supports(a2345.CapProtocolManagement) || !mode.HasChargeProtocol {
		return nil
	}
	p := mode.Protocols(e.isMainland())
	return &p
}

func (e *Engine) applyChargingMode(mode anker.CloudChargingMode) error {
	return e.send(a2345.SetCustomChargingMode(mode.Profile(), e.protocolsFor(mode)), textPtr(anker.T("自定义模式")), true, nil)
}

// ApplyChargingMode makes a stored profile the active custom mode. Every port
// drops out for a few seconds while the charger renegotiates.
func (e *Engine) ApplyChargingMode(mode anker.CloudChargingMode) error {
	return e.guarded(e.controlBlocker, func() error { return e.applyChargingMode(mode) })
}

func (e *Engine) isActiveMode(mode anker.CloudChargingMode) bool {
	s := e.st.settings
	return s != nil && s.IsCustomChargingMode() && s.CustomProfile != nil && int(s.CustomProfile.Number) == mode.Number
}

// SaveChargingMode stores a profile in the account; when it is the one in
// use, the charger gets the new limits too.
func (e *Engine) SaveChargingMode(mode anker.CloudChargingMode, isNew bool) error {
	return e.guarded(e.controlBlocker, func() error {
		saved := mode
		saved.TotalPower = 0
		for _, s := range mode.PowerSettings {
			saved.TotalPower += s.Power
		}
		active := e.isActiveMode(mode)
		if e.st.isDemo {
			modes := append([]anker.CloudChargingMode{}, e.st.modes...)
			if isNew {
				next := 0
				for _, m := range modes {
					next = max(next, m.ID)
				}
				saved.ID = next + 1
				modes = append(modes, saved)
			} else if i := slices.IndexFunc(modes, func(m anker.CloudChargingMode) bool { return m.ID == saved.ID }); i >= 0 {
				modes[i] = saved
			}
			slices.SortStableFunc(modes, func(a, b anker.CloudChargingMode) int { return a.Number - b.Number })
			e.st.modes, e.st.modesLoaded = modes, true
			if active {
				_ = e.applyChargingMode(saved)
			}
			return nil
		}
		e.runCloudWork(WorkChargingModes, func(ctx context.Context, c Cloud, serial string) error {
			if isNew {
				return c.AddA2345ChargingMode(ctx, saved, serial)
			}
			return c.UpdateA2345ChargingMode(ctx, saved)
		}, func() {
			if active {
				if b := e.controlBlocker(); b != nil {
					e.message(*b)
				} else {
					_ = e.applyChargingMode(saved)
				}
			}
			e.reloadChargingModes()
		})
		return nil
	})
}

// DeleteChargingMode: deleting the profile in use first takes the charger
// out of custom mode and only removes it once the charger has agreed.
func (e *Engine) DeleteChargingMode(mode anker.CloudChargingMode) error {
	return e.guarded(e.controlBlocker, func() error {
		active := e.isActiveMode(mode)
		if e.st.isDemo {
			if active {
				_ = e.send(a2345.ExitCustomChargingMode(), nil, true, nil)
			}
			e.st.modes = slices.DeleteFunc(append([]anker.CloudChargingMode{}, e.st.modes...),
				func(m anker.CloudChargingMode) bool { return m.ID == mode.ID })
			return nil
		}
		deleteFromAccount := func() {
			e.runCloudWork(WorkChargingModes, func(ctx context.Context, c Cloud, _ string) error {
				return c.DeleteA2345ChargingMode(ctx, mode.ID)
			}, e.reloadChargingModes)
		}
		if !active {
			deleteFromAccount()
			return nil
		}
		return e.send(a2345.ExitCustomChargingMode(), textPtr(anker.T("自定义模式")), false, func(accepted bool) {
			if accepted {
				deleteFromAccount()
			}
		})
	})
}

// nextChargingModeNumber is the lowest profile number 1…4 not yet taken.
func (e *Engine) nextChargingModeNumber() *int {
	for n := 1; n <= 4; n++ {
		if !slices.ContainsFunc(e.st.modes, func(m anker.CloudChargingMode) bool { return m.Number == n }) {
			return intPtr(n)
		}
	}
	return nil
}

func (e *Engine) reloadChargingModes() {
	st := &e.st
	if st.client == nil || st.cloudDevice == nil {
		return
	}
	client, serial, gen := st.client, st.cloudDevice.DeviceSerial, st.generation
	go func() {
		modes, err := client.A2345ChargingModes(context.Background(), serial)
		if err == nil {
			e.on(gen, func() { e.st.modes, e.st.modesLoaded = modes, true })
		}
	}()
}

// --- clock screensaver ---

// currentPictureTheme is the cloud theme the charger shows, if a picture.
func (e *Engine) currentPictureTheme() *anker.CloudTheme {
	s := e.st.settings
	if s == nil || s.Clock == nil || s.Clock.ThemeID == nil {
		return nil
	}
	id := *s.Clock.ThemeID
	var list []anker.CloudTheme
	switch a2345.ThemeKind(s.Clock.ThemeCode) {
	case a2345.ThemePicture:
		list = e.st.themes
	case a2345.ThemeCustom:
		list = e.st.pictures
	default:
		return nil
	}
	for _, t := range list {
		if t.ID == id {
			t := t
			return &t
		}
	}
	return nil
}

// currentThemeRequest is the 0x0205 that re-sends the current theme with the
// switch changed; false when the theme is a picture whose details have not
// loaded.
func (e *Engine) currentThemeRequest(clockOn bool) (a2345.ClockThemeRequest, bool) {
	code := byte(0)
	if s := e.st.settings; s != nil && s.Clock != nil {
		code = s.Clock.ThemeCode
	}
	if kind, ok := a2345.ValidThemeKind(code); ok && kind.IsBuiltIn() {
		return a2345.NewClockThemeRequest(clockOn, kind, nil, 0, a2345.BuiltInStyleURL(kind)), true
	}
	theme := e.currentPictureTheme()
	if theme == nil {
		return a2345.ClockThemeRequest{}, false
	}
	id := theme.ID
	if theme.Kind == a2345.ThemeCustom {
		// The official switch path sends a custom picture's link in A6,
		// which only has room for 254 bytes.
		if len(theme.ImageURL) <= 254 {
			return a2345.NewClockThemeRequest(clockOn, a2345.ThemeCustom, &id, theme.CRC32, theme.ImageURL), true
		}
		r := a2345.NewClockThemeRequest(clockOn, a2345.ThemeCustom, &id, theme.CRC32, "")
		r.CustomURL = theme.ImageURL
		return r, true
	}
	r := a2345.NewClockThemeRequest(clockOn, a2345.ThemePicture, &id, theme.CRC32, theme.ImageURL)
	if theme.TextColor != nil {
		r.TextColor = *theme.TextColor
	}
	return r, true
}

// SetClockEnabled switches the clock screensaver by re-sending its theme.
func (e *Engine) SetClockEnabled(on bool) error {
	return e.guarded(e.controlBlocker, func() error {
		if !on {
			e.st.themeTimer.cancel()
			e.st.themeDownload = nil
		}
		r, ok := e.currentThemeRequest(on)
		if !ok {
			msg := anker.T("主题信息还没读到，稍后再试。")
			e.message(msg)
			return &Refusal{Message: msg}
		}
		return e.send(a2345.SetClockTheme(r), textPtr(anker.T("时钟屏保")), true, nil)
	})
}

// supportsPictureThemes: firmware reporting protocol version 1 or the
// clock-schedule capability, as the official app checks.
func (e *Engine) supportsPictureThemes() bool {
	s := e.st.settings
	return s != nil && ((s.ProtocolVersion != nil && *s.ProtocolVersion == 1) || s.Supports(a2345.CapClockSchedule))
}

func (e *Engine) clockIsOn() bool {
	s := e.st.settings
	return s != nil && s.Clock != nil && s.Clock.IsOn
}

// ApplyBuiltInStyle shows one of the three built-in clock styles.
func (e *Engine) ApplyBuiltInStyle(kind a2345.ThemeKind) error {
	return e.guarded(e.controlBlocker, func() error {
		if !kind.IsBuiltIn() || !e.clockIsOn() {
			return nil
		}
		err := e.send(a2345.SetClockTheme(a2345.NewClockThemeRequest(true, kind, nil, 0, a2345.BuiltInStyleURL(kind))),
			textPtr(anker.T("时钟屏保")), true, nil)
		e.st.themeTimer.cancel()
		e.st.themeDownload = nil
		return err
	})
}

// ApplyPictureTheme: cloud and custom pictures are fetched by the charger
// itself over Wi-Fi; it reports the outcome with 0x0311. A custom picture's
// link expires within minutes, so a fresh one is fetched first.
func (e *Engine) ApplyPictureTheme(theme anker.CloudTheme) error {
	return e.guarded(e.controlBlocker, func() error {
		st := &e.st
		if st.themeDownload != nil || !e.clockIsOn() {
			return nil
		}
		if theme.Kind == a2345.ThemePicture && !e.supportsPictureThemes() {
			return nil
		}
		if theme.Kind != a2345.ThemeCustom || st.isDemo || st.client == nil || st.cloudDevice == nil {
			e.sendPictureTheme(theme)
			return nil
		}
		id := theme.ID
		st.themeDownload = &id
		client, serial, gen := st.client, st.cloudDevice.DeviceSerial, st.generation
		go func() {
			fresh, err := client.A2345CustomScreensavers(context.Background(), serial)
			e.on(gen, func() {
				st := &e.st
				if st.themeDownload == nil || *st.themeDownload != id {
					return
				}
				if err == nil {
					st.pictures, st.picturesLoaded = fresh, true
				}
				if !e.clockIsOn() {
					st.themeDownload = nil
					return
				}
				i := -1
				if err == nil {
					i = slices.IndexFunc(fresh, func(t anker.CloudTheme) bool { return t.ID == id })
				}
				if e.controlBlocker() != nil || i < 0 {
					e.finishThemeDownload(false)
					return
				}
				e.sendPictureTheme(fresh[i])
			})
		}()
		return nil
	})
}

func (e *Engine) sendPictureTheme(theme anker.CloudTheme) {
	st := &e.st
	cmd := a2345.SetClockTheme(theme.Request(true))
	label := textPtr(anker.T("时钟屏保"))
	if st.isDemo {
		st.themeDownload = nil
		_ = e.send(cmd, label, true, nil)
		return
	}
	id := theme.ID
	st.themeDownload = &id
	e.arm(&st.themeTimer, e.opts.ThemeDownloadTimeout, func() {
		if e.st.themeDownload != nil && *e.st.themeDownload == id {
			e.finishThemeDownload(false)
		}
	})
	// A refusal or no answer has already been reported by send; only stop
	// waiting for the download.
	_ = e.send(cmd, label, true, func(accepted bool) {
		if accepted || e.st.themeDownload == nil || *e.st.themeDownload != id {
			return
		}
		e.st.themeTimer.cancel()
		e.st.themeDownload = nil
	})
}

func (e *Engine) canUploadPicture() bool {
	st := &e.st
	if st.isDemo || e.controlBlocker() != nil || st.settings == nil || !st.settings.Supports(a2345.CapCustomImageTimeDisplay) {
		return false
	}
	count := anker.A2345CustomPictureLimit
	if st.picturesLoaded {
		count = len(st.pictures)
	}
	return count < anker.A2345CustomPictureLimit
}

// UploadCustomPicture uploads a prepared 480×200 JPEG to the account; it then
// appears under 我的图片 and can be applied like any theme.
func (e *Engine) UploadCustomPicture(jpeg []byte) error {
	data := append([]byte(nil), jpeg...)
	return e.exec(func() error {
		if !e.canUploadPicture() {
			return nil
		}
		e.runCloudWork(WorkPictures, func(ctx context.Context, c Cloud, serial string) error {
			return c.UploadA2345CustomPicture(ctx, data, serial)
		}, e.reloadCustomPictures)
		return nil
	})
}

// DeleteCustomPicture removes one of the user's own pictures.
func (e *Engine) DeleteCustomPicture(theme anker.CloudTheme) error {
	return e.guarded(e.controlBlocker, func() error {
		if theme.Kind != a2345.ThemeCustom {
			return nil
		}
		e.runCloudWork(WorkPictures, func(ctx context.Context, c Cloud, _ string) error {
			return c.DeleteA2345CustomPicture(ctx, theme.ID)
		}, e.reloadCustomPictures)
		return nil
	})
}

// ReloadCustomPictures fetches the picture list again: the links are signed
// for a few minutes only.
func (e *Engine) ReloadCustomPictures() error {
	return e.exec(func() error {
		e.reloadCustomPictures()
		return nil
	})
}

func (e *Engine) reloadCustomPictures() {
	st := &e.st
	if st.isDemo || st.client == nil || st.cloudDevice == nil {
		return
	}
	client, serial, gen := st.client, st.cloudDevice.DeviceSerial, st.generation
	go func() {
		pictures, err := client.A2345CustomScreensavers(context.Background(), serial)
		if err == nil {
			e.on(gen, func() { e.st.pictures, e.st.picturesLoaded = pictures, true })
		}
	}()
}

func (e *Engine) finishThemeDownload(succeeded bool) {
	e.st.themeTimer.cancel()
	e.st.themeDownload = nil
	if !succeeded {
		e.message(anker.T("充电器没有换上这张主题，可能是网络不好。"))
		e.requestReadback(true)
	}
}
