package cloudsession

import (
	"sort"
	"time"

	"charker/internal/a2345"
	"charker/internal/anker"
	"charker/internal/product"
	"charker/internal/session"
)

// Snapshot is the immutable A2345 state published to the app
// (A2345ConnectionSnapshot plus the AppModel state the A2345 pages read). It
// contains no token, MQTT topic, client certificate or private key.
//
// The electrical part has the A2687 engine's shape so product-neutral pages
// read the same fields: Phase in session.Phase vocabulary, Reading,
// Telemetry{receivedAtMs, ports[{port, statusCode, voltage, current, power,
// control}]}, History [{t, total, perPort[6]}], IsStale. Everything only the
// A2345 has lives under A2345.
type Snapshot struct {
	// Phase is the session-neutral phase (idle, connecting, polling,
	// reconnecting, failed); Stage the exact A2345 phase.
	Phase   session.Phase `json:"phase"`
	Stage   Phase         `json:"stage"`
	Attempt int           `json:"attempt,omitempty"`
	// Failure is the reason of a failed phase.
	Failure *anker.Text `json:"failure,omitempty"`
	// StatusLabel/StatusDetail are AppModel.activeStatusLabel/Detail.
	StatusLabel  anker.Text `json:"statusLabel"`
	StatusDetail anker.Text `json:"statusDetail"`

	Device  *Device  `json:"device,omitempty"`
	Devices []Device `json:"devices"`

	Reading   *product.Reading        `json:"reading,omitempty"`
	Telemetry *Telemetry              `json:"telemetry,omitempty"`
	History   []session.HistorySample `json:"history"`
	IsStale   bool                    `json:"isStale"`
	IsDemo    bool                    `json:"isDemo"`
	Warning   *anker.Text             `json:"warning,omitempty"`
	// Live is hasFreshTelemetry: monitoring, a reading, not stale.
	Live          bool  `json:"live"`
	LastUpdatedMs int64 `json:"lastUpdatedMs,omitempty"`

	// SignedIn is hasStoredA2345Authentication; Nickname the account's.
	SignedIn bool   `json:"signedIn"`
	Nickname string `json:"nickname,omitempty"`
	// SigningIn is isSigningIn: a sign-in request is in flight.
	SigningIn bool `json:"signingIn"`
	// CanRetry is canRetryA2345 minus the app-level checks (product, running).
	CanRetry bool `json:"canRetry"`

	A2345 Extras `json:"a2345"`
}

// Device is public, non-secret metadata of a bound charger (A2345DeviceSummary).
type Device struct {
	Serial      string `json:"serial"`
	Name        string `json:"name"`
	Firmware    string `json:"firmware,omitempty"`
	WiFiOnline  *bool  `json:"wifiOnline,omitempty"`
	Product     string `json:"product"`
	ProductName string `json:"productName"`
}

// Telemetry is the page-facing copy of the last reading, ports C1 C2 C3 C4
// A1 A2.
type Telemetry struct {
	ReceivedAtMs int64           `json:"receivedAtMs"`
	Ports        []PortTelemetry `json:"ports"`
}

// PortTelemetry is one port. StatusCode is normalised to 0/1 (only those are
// established on the wire). Cable, FastCharge and DeviceBrand are the
// mainland-firmware codes (PortCable 0 3 A, 1 5 A, 2 EPR, 3 Huawei, 4 Xiaomi;
// PortFastCharge 1 Huawei SCP, 2 Xiaomi HyperCharge; PortDeviceBrand 1
// Huawei/Honor, 2 Xiaomi), set only while the port is active; Cable only on
// USB-C. They deliberately do not reuse the A2687's cableCode.
type PortTelemetry struct {
	Port        string               `json:"port"`
	Group       string               `json:"group"`
	StatusCode  int                  `json:"statusCode"`
	Voltage     float64              `json:"voltage"`
	Current     float64              `json:"current"`
	Power       float64              `json:"power"`
	Cable       *int                 `json:"cable,omitempty"`
	FastCharge  *int                 `json:"fastCharge,omitempty"`
	DeviceBrand *int                 `json:"deviceBrand,omitempty"`
	Control     *session.PortControl `json:"control,omitempty"`
	// Device is only ever set by the simulator; the live A8 words are not a
	// confirmed USB identity yet.
	Device *session.USBDevice `json:"device,omitempty"`
}

// Extras is everything only the A2345 carries.
type Extras struct {
	// Settings is nil until this subscription has read a full 0x0A00;
	// controls stay disabled before.
	Settings *SettingsView `json:"settings,omitempty"`
	// Account-side data; nil until loaded.
	CloudSettings  *anker.CloudSettings      `json:"cloudSettings,omitempty"`
	ChargingModes  []anker.CloudChargingMode `json:"chargingModes"`
	Themes         []anker.CloudTheme        `json:"themes"`
	CustomPictures []anker.CloudTheme        `json:"customPictures"`
	// CloudWork lists the account operations in flight: labExclusive,
	// customModeSwitch, chargingModes, pictures.
	CloudWork []string `json:"cloudWork"`
	// PendingWrites are the writes waiting for their 0x0ANN.
	PendingWrites []PendingWrite `json:"pendingWrites"`
	// ThemeDownload is the picture theme the charger is fetching.
	ThemeDownload *uint32 `json:"themeDownload,omitempty"`
	Mainland      bool    `json:"mainland"`

	// Why writes are refused right now; nil when allowed.
	ControlBlocker     *anker.Text `json:"controlBlocker,omitempty"`
	PortControlBlocker *anker.Text `json:"portControlBlocker,omitempty"`
	SwitchBlocker      *anker.Text `json:"switchBlocker,omitempty"`

	NextChargingModeNumber *int              `json:"nextChargingModeNumber,omitempty"`
	SupportsCustomMode     bool              `json:"supportsCustomMode"`
	SupportsPictureThemes  bool              `json:"supportsPictureThemes"`
	CanToggleClock         bool              `json:"canToggleClock"`
	CanUploadPicture       bool              `json:"canUploadPicture"`
	CurrentPictureTheme    *anker.CloudTheme `json:"currentPictureTheme,omitempty"`
	WritesEnabled          bool              `json:"writesEnabled"`
}

// PendingWrite is one write waiting for its acknowledgement.
type PendingWrite struct {
	MessageType int    `json:"messageType"`
	Group       string `json:"group,omitempty"`
	Slot        *int   `json:"slot,omitempty"`
}

// SettingsView is a2345.DeviceSettings for the page: raw codes, nil when the
// charger has not reported a field (or the firmware lacks the capability).
type SettingsView struct {
	FirmwareVersion        *string        `json:"firmwareVersion,omitempty"`
	ErrorCode              *int           `json:"errorCode,omitempty"`
	HasFault               bool           `json:"hasFault"`
	IsOverTemperature      bool           `json:"isOverTemperature"`
	Groups                 []GroupView    `json:"groups"`
	Clock                  *ClockView     `json:"clock,omitempty"`
	ScreenTimeout          *int           `json:"screenTimeout,omitempty"`
	ChargingMode           *int           `json:"chargingMode,omitempty"`
	IsCustomChargingMode   bool           `json:"isCustomChargingMode"`
	IsUpdatingFirmware     *bool          `json:"isUpdatingFirmware,omitempty"`
	Brightness             *int           `json:"brightness,omitempty"`
	KnobDirection          *int           `json:"knobDirection,omitempty"`
	HourFormat             *int           `json:"hourFormat,omitempty"`
	ProtocolVersion        *int           `json:"protocolVersion,omitempty"`
	Capabilities           *int           `json:"capabilities,omitempty"`
	CustomProfile          *ProfileView   `json:"customProfile,omitempty"`
	ClockSchedule          *ClockSchedule `json:"clockSchedule,omitempty"`
	PortProtocols          []int          `json:"portProtocols,omitempty"`
	MaxCompatibility       *bool          `json:"maxCompatibility,omitempty"`
	UFCS                   *bool          `json:"ufcs,omitempty"`
	DeviceIdentification   *bool          `json:"deviceIdentification,omitempty"`
	CustomImageTimeDisplay *bool          `json:"customImageTimeDisplay,omitempty"`
	PriorityBitmap         int            `json:"priorityBitmap"`
	ConnectedDeviceUSB     []IdentityView `json:"connectedDeviceUSB"`
	ConnectedDeviceBrand   []IdentityView `json:"connectedDeviceBrand"`
}

// GroupView is one control group (C1…C4, the shared USB-A pair).
type GroupView struct {
	Group     string        `json:"group"`
	Index     int           `json:"index"`
	Ports     []string      `json:"ports"`
	IsOn      bool          `json:"isOn"`
	PowerOn   ScheduleView  `json:"powerOn"`
	PowerOff  ScheduleView  `json:"powerOff"`
	HasFault  bool          `json:"hasFault"`
	Priority  int           `json:"priority"`
	Countdown CountdownView `json:"countdown"`
}

// CountdownView: Remaining runs down between reports (computed at publish
// time from ReportedAtMs, like A2345ConnectionSnapshot.countdownRemaining).
type CountdownView struct {
	Enabled      bool  `json:"enabled"`
	Total        int   `json:"total"`
	Remaining    *int  `json:"remaining,omitempty"`
	ReportedAtMs int64 `json:"reportedAtMs,omitempty"`
}

// ScheduleView is one daily on/off slot.
type ScheduleView struct {
	RawSwitch  int  `json:"rawSwitch"`
	Enabled    bool `json:"enabled"`
	Unset      bool `json:"unset"`
	Hour       int  `json:"hour"`
	Minute     int  `json:"minute"`
	Weekdays   int  `json:"weekdays"`
	RepeatDays int  `json:"repeatDays"`
}

// ClockView is the clock screensaver state.
type ClockView struct {
	IsOn             bool    `json:"isOn"`
	HolidayEnabled   bool    `json:"holidayEnabled"`
	ThemeCode        int     `json:"themeCode"`
	ThemeID          *uint32 `json:"themeId,omitempty"`
	ThemeURL         *string `json:"themeUrl,omitempty"`
	IsShowingHoliday *bool   `json:"isShowingHoliday,omitempty"`
}

// ProfileView is the active custom profile (watts C1 C2 C3 C4 USB-A).
type ProfileView struct {
	Number   int   `json:"number"`
	AutoExit bool  `json:"autoExit"`
	Watts    []int `json:"watts"`
}

// ClockSchedule is when the clock screensaver shows (weekdays bit0 = Monday).
type ClockSchedule struct {
	StartHour   int `json:"startHour"`
	StartMinute int `json:"startMinute"`
	EndHour     int `json:"endHour"`
	EndMinute   int `json:"endMinute"`
	Weekdays    int `json:"weekdays"`
}

// IdentityView is one BD/BE slot.
type IdentityView struct {
	Group  string `json:"group"`
	First  int    `json:"first"`
	Second int    `json:"second"`
	Empty  bool   `json:"empty"`
}

// portValue is one port of the engine's last reading.
type portValue struct {
	port              a2345.Port
	status            int
	voltage, current  float64
	power             float64
	cable, fast, kind *int
	vendor, productID uint16
	hasIdentity       bool
}

type reading struct {
	ports      []portValue
	receivedAt time.Time
}

// readingFrom is ChargerReading(a2345:): status normalised, the
// mainland-firmware tail only while active, the cable only on USB-C.
func readingFrom(ports map[a2345.Port]a2345.PortReading, at time.Time) *reading {
	r := &reading{receivedAt: at}
	for _, p := range a2345.Ports {
		v, ok := ports[p]
		if !ok {
			continue
		}
		pv := portValue{port: p, voltage: v.Voltage(), current: v.Current(), power: v.Power()}
		if v.IsActive() {
			pv.status = 1
			if p.IsUSBC() && v.Cable != nil && *v.Cable <= 4 {
				pv.cable = intPtr(int(*v.Cable))
			}
			if v.FastCharge != nil && (*v.FastCharge == 1 || *v.FastCharge == 2) {
				pv.fast = intPtr(int(*v.FastCharge))
			}
			if v.DeviceBrand != nil && (*v.DeviceBrand == 1 || *v.DeviceBrand == 2) {
				pv.kind = intPtr(int(*v.DeviceBrand))
			}
		}
		r.ports = append(r.ports, pv)
	}
	return r
}

// orderedPortPower is the per-port power C1…A2, an off port counted as 0.
func (r *reading) orderedPortPower() [6]float64 {
	var out [6]float64
	for _, p := range r.ports {
		if p.status != 0 {
			out[p.port] = p.power
		}
	}
	return out
}

func (r *reading) totalPower() float64 {
	total := 0.0
	for _, p := range r.ports {
		if p.status != 0 {
			total += p.power
		}
	}
	return total
}

func intPtr(v int) *int { return &v }

func bytePtrToInt(p *byte) *int {
	if p == nil {
		return nil
	}
	return intPtr(int(*p))
}

// countdownRemaining runs a reported countdown down to now.
func countdownRemaining(settings *a2345.DeviceSettings, reported map[a2345.PortGroup]time.Time, g a2345.PortGroup, now time.Time) (uint32, bool) {
	if settings == nil {
		return 0, false
	}
	c, ok := settings.PortControls[g]
	if !ok || !c.CountdownEnabled {
		return 0, false
	}
	elapsed := 0.0
	if at, ok := reported[g]; ok {
		elapsed = max(0, now.Sub(at).Seconds())
	}
	remaining := float64(c.CountdownRemaining) - elapsed
	if remaining <= 0 {
		return 0, true
	}
	whole := uint32(remaining)
	if float64(whole) < remaining {
		whole++
	}
	return whole, true
}

func scheduleView(s a2345.PortSchedule) ScheduleView {
	return ScheduleView{
		RawSwitch: int(s.RawSwitch), Enabled: s.IsEnabled(), Unset: s.IsUnset(),
		Hour: int(s.Hour), Minute: int(s.Minute), Weekdays: int(s.Weekdays), RepeatDays: int(s.RepeatDays()),
	}
}

func identityViews(slots []a2345.IdentitySlot) []IdentityView {
	out := make([]IdentityView, 0, len(slots))
	for _, s := range slots {
		out = append(out, IdentityView{Group: s.Group.Label(), First: int(s.First), Second: int(s.Second), Empty: s.IsEmpty()})
	}
	return out
}

func settingsView(s *a2345.DeviceSettings, reported map[a2345.PortGroup]time.Time, now time.Time) *SettingsView {
	if s == nil {
		return nil
	}
	v := &SettingsView{
		FirmwareVersion:        s.FirmwareVersion,
		HasFault:               s.HasFault(),
		IsOverTemperature:      s.IsOverTemperature(),
		ScreenTimeout:          bytePtrToInt(s.ScreenTimeoutCode),
		ChargingMode:           bytePtrToInt(s.ChargingModeCode),
		IsCustomChargingMode:   s.IsCustomChargingMode(),
		IsUpdatingFirmware:     s.IsUpdatingFirmware,
		Brightness:             bytePtrToInt(s.Brightness),
		KnobDirection:          bytePtrToInt(s.KnobDirectionCode),
		HourFormat:             bytePtrToInt(s.HourFormatCode),
		ProtocolVersion:        bytePtrToInt(s.ProtocolVersion),
		MaxCompatibility:       s.MaxCompatibility,
		UFCS:                   s.UFCS,
		DeviceIdentification:   s.DeviceIdentification,
		CustomImageTimeDisplay: s.CustomImageTimeDisplay,
		PriorityBitmap:         int(s.PriorityBitmap()),
		ConnectedDeviceUSB:     identityViews(s.ConnectedDeviceUSB),
		ConnectedDeviceBrand:   identityViews(s.ConnectedDeviceBrand),
		Groups:                 []GroupView{},
	}
	if s.ErrorCode != nil {
		v.ErrorCode = intPtr(int(*s.ErrorCode))
	}
	if s.Capabilities != nil {
		v.Capabilities = intPtr(int(*s.Capabilities))
	}
	for _, g := range a2345.PortGroups {
		c, ok := s.PortControls[g]
		if !ok {
			continue
		}
		gv := GroupView{
			Group: g.Label(), Index: int(g), IsOn: c.IsOn,
			PowerOn: scheduleView(c.PowerOn), PowerOff: scheduleView(c.PowerOff),
			HasFault: s.HasGroupFault(g), Priority: int(c.Priority),
			Countdown: CountdownView{Enabled: c.CountdownEnabled, Total: int(c.CountdownTotal)},
		}
		for _, p := range g.Ports() {
			gv.Ports = append(gv.Ports, p.Label())
		}
		if r, ok := countdownRemaining(s, reported, g, now); ok {
			gv.Countdown.Remaining = intPtr(int(r))
		}
		if at, ok := reported[g]; ok {
			gv.Countdown.ReportedAtMs = at.UnixMilli()
		}
		v.Groups = append(v.Groups, gv)
	}
	if c := s.Clock; c != nil {
		v.Clock = &ClockView{
			IsOn: c.IsOn, HolidayEnabled: c.HolidayEnabled, ThemeCode: int(c.ThemeCode),
			ThemeID: c.ThemeID, ThemeURL: c.ThemeURL, IsShowingHoliday: c.IsShowingHoliday,
		}
	}
	if p := s.CustomProfile; p != nil {
		pv := &ProfileView{Number: int(p.Number), AutoExit: p.AutoExit, Watts: []int{}}
		for _, w := range p.Watts {
			pv.Watts = append(pv.Watts, int(w))
		}
		v.CustomProfile = pv
	}
	if c := s.ClockSchedule; c != nil {
		v.ClockSchedule = &ClockSchedule{int(c.StartHour), int(c.StartMinute), int(c.EndHour), int(c.EndMinute), int(c.Weekdays)}
	}
	if p := s.PortProtocols; p != nil {
		for _, f := range p.Ports {
			v.PortProtocols = append(v.PortProtocols, int(f))
		}
	}
	return v
}

// telemetryView builds the page copy of r with the group controls.
func telemetryView(r *reading, s *a2345.DeviceSettings, reported map[a2345.PortGroup]time.Time, now time.Time) *Telemetry {
	t := &Telemetry{ReceivedAtMs: r.receivedAt.UnixMilli(), Ports: make([]PortTelemetry, 0, len(r.ports))}
	for _, p := range r.ports {
		g := a2345.GroupOf(p.port)
		pt := PortTelemetry{
			Port: p.port.Label(), Group: g.Label(), StatusCode: p.status,
			Voltage: p.voltage, Current: p.current, Power: p.power,
			Cable: p.cable, FastCharge: p.fast, DeviceBrand: p.kind,
		}
		if s != nil {
			if c, ok := s.PortControls[g]; ok {
				pc := &session.PortControl{
					SwitchStatus:   boolInt(c.IsOn),
					CountdownTotal: int(c.CountdownTotal),
				}
				if c.CountdownEnabled {
					pc.CountdownTaskStatus = 1
				}
				if r, ok := countdownRemaining(s, reported, g, now); ok {
					pc.CountdownRemaining = int(r)
					pc.Running = r > 0
				}
				pt.Control = pc
			}
		}
		if p.hasIdentity {
			pt.Device = &session.USBDevice{VendorID: int(p.vendor), ProductID: int(p.productID)}
		}
		t.Ports = append(t.Ports, pt)
	}
	return t
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// productReading is the transport-neutral reading (six ports, product order).
func productReading(r *reading, s *a2345.DeviceSettings) *product.Reading {
	pr := &product.Reading{Product: product.ProductA2345, ReceivedAt: r.receivedAt}
	byPort := map[a2345.Port]portValue{}
	for _, p := range r.ports {
		byPort[p.port] = p
	}
	for _, port := range a2345.Ports {
		p := byPort[port]
		enabled := p.status != 0
		if s != nil {
			if c, ok := s.PortControls[a2345.GroupOf(port)]; ok {
				enabled = c.IsOn
			}
		}
		pr.Ports = append(pr.Ports, product.PortReading{
			Enabled: enabled, Status: p.status,
			Watts: p.power, Volts: p.voltage, Amps: p.current,
			VID: p.vendor, PID: p.productID,
		})
	}
	pr.TotalWattsOf()
	return pr
}

func pendingViews(keys []a2345.WriteKey) []PendingWrite {
	out := make([]PendingWrite, 0, len(keys))
	for _, k := range keys {
		pw := PendingWrite{MessageType: int(k.MessageType)}
		if k.HasGroup {
			pw.Group = k.Group.Label()
		}
		if k.HasSlot {
			pw.Slot = intPtr(int(k.Slot))
		}
		out = append(out, pw)
	}
	return out
}

func sortedWork(work map[string]bool) []string {
	out := make([]string, 0, len(work))
	for w := range work {
		out = append(out, w)
	}
	sort.Strings(out)
	return out
}
