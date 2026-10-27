package anker

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"math"
	"sort"
	"strconv"
	"strings"

	"charker/internal/a2345"
)

// CloudSettings are the A2345 settings the official app keeps on Anker's
// servers. The app pushes the stored compatibility and identification values
// back to the charger whenever it opens, so they are written here as well as
// to the charger. Nil means "not reported".
type CloudSettings struct {
	// CustomModeEnabled is the 实验室 switch that makes custom charging mode
	// available.
	CustomModeEnabled    *bool `json:"customModeEnabled,omitempty"`
	MaxCompatibility     *bool `json:"maxCompatibility,omitempty"`
	DeviceIdentification *bool `json:"deviceIdentification,omitempty"`
}

// ChargingModePortSetting is one port of a stored custom profile.
type ChargingModePortSetting struct {
	// Name is "C1" … "C4" or "A".
	Name     string `json:"name"`
	Power    int    `json:"power"`
	MaxPower int    `json:"maxPower"`
	SCP      bool   `json:"scp"`
	UFCS     bool   `json:"ufcs"`
	PD12V    bool   `json:"pd12V"`
	PPS11V   bool   `json:"pps11V"`
	PPS16V   bool   `json:"pps16V"`
	PPS21V   bool   `json:"pps21V"`
	Huawei   bool   `json:"huawei"`
	Xiaomi   bool   `json:"xiaomi"`
}

type portSettingWire struct {
	Name     string `json:"name"`
	Power    int    `json:"power"`
	MaxPower int    `json:"max_power"`
	SCP      int    `json:"scp"`
	UFCS     int    `json:"ufcs"`
	PD12V    int    `json:"pd12v"`
	PPS11V   int    `json:"pps11v"`
	PPS16V   int    `json:"pps16v"`
	PPS21V   int    `json:"pps20v"`
	Huawei   int    `json:"huawei"`
	Xiaomi   int    `json:"xiaomi"`
}

func bit(b bool) int {
	if b {
		return 1
	}
	return 0
}

func (s ChargingModePortSetting) wire() portSettingWire {
	return portSettingWire{
		Name: s.Name, Power: s.Power, MaxPower: s.MaxPower,
		SCP: bit(s.SCP), UFCS: bit(s.UFCS), PD12V: bit(s.PD12V), PPS11V: bit(s.PPS11V),
		PPS16V: bit(s.PPS16V), PPS21V: bit(s.PPS21V), Huawei: bit(s.Huawei), Xiaomi: bit(s.Xiaomi),
	}
}

func (s *ChargingModePortSetting) decode(data []byte) error {
	var raw struct {
		Name     flex `json:"name"`
		Power    flex `json:"power"`
		MaxPower flex `json:"max_power"`
		SCP      flex `json:"scp"`
		UFCS     flex `json:"ufcs"`
		PD12V    flex `json:"pd12v"`
		PPS11V   flex `json:"pps11v"`
		PPS16V   flex `json:"pps16v"`
		PPS21V   flex `json:"pps20v"`
		Huawei   flex `json:"huawei"`
		Xiaomi   flex `json:"xiaomi"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*s = ChargingModePortSetting{}
	s.Name, _ = raw.Name.str()
	s.Power, _ = raw.Power.integer()
	s.MaxPower, _ = raw.MaxPower.integer()
	s.SCP, _ = raw.SCP.boolean()
	s.UFCS, _ = raw.UFCS.boolean()
	s.PD12V, _ = raw.PD12V.boolean()
	s.PPS11V, _ = raw.PPS11V.boolean()
	s.PPS16V, _ = raw.PPS16V.boolean()
	s.PPS21V, _ = raw.PPS21V.boolean()
	s.Huawei, _ = raw.Huawei.boolean()
	s.Xiaomi, _ = raw.Xiaomi.boolean()
	return nil
}

// CloudChargingMode is one stored custom charging profile
// (charging/get_charging_mode_list).
type CloudChargingMode struct {
	ID                int                       `json:"id"`
	Number            int                       `json:"number"`
	Name              string                    `json:"name"`
	TotalPower        int                       `json:"totalPower"`
	MaxTotalPower     int                       `json:"maxTotalPower"`
	AutoExit          bool                      `json:"autoExit"`
	HasChargeProtocol bool                      `json:"hasChargeProtocol"`
	PowerSettings     []ChargingModePortSetting `json:"powerSettings"`
}

// ChargingModePortNames are the profile's port names in group order.
var ChargingModePortNames = []string{"C1", "C2", "C3", "C4", "A"}

// NewCloudChargingMode builds a profile the way the Swift initialiser does:
// total from the ports, the 250 W limit, protocols enabled.
func NewCloudChargingMode(number int, name string, autoExit bool, settings []ChargingModePortSetting) CloudChargingMode {
	total := 0
	for _, s := range settings {
		total += s.Power
	}
	return CloudChargingMode{
		Number: number, Name: name, TotalPower: total,
		MaxTotalPower: a2345.CustomTotalLimit, AutoExit: autoExit,
		HasChargeProtocol: true, PowerSettings: settings,
	}
}

// ChargingModeTemplate is a new profile with the official editor's defaults
// for each power band: PD 12V off, the PPS ranges the port's limit can use.
func ChargingModeTemplate(number int, name string, mainland bool) CloudChargingMode {
	watts := []int{100, 65, 45, 25, 15}
	settings := make([]ChargingModePortSetting, 0, len(a2345.PortGroups))
	for i, group := range a2345.PortGroups {
		power := watts[i]
		mid, high := power >= 21, power >= 45
		settings = append(settings, ChargingModePortSetting{
			Name: ChargingModePortNames[i], Power: power,
			MaxPower: int(a2345.MaximumWatts(group, mainland)),
			SCP:      mid, UFCS: true, PD12V: false,
			PPS11V: mid, PPS16V: high, PPS21V: high,
			Huawei: mid, Xiaomi: false,
		})
	}
	return NewCloudChargingMode(number, name, false, settings)
}

// Setting returns the port setting of a group, by name first, then by index.
func (m CloudChargingMode) Setting(group a2345.PortGroup) (ChargingModePortSetting, bool) {
	if int(group) < 0 || int(group) >= len(ChargingModePortNames) {
		return ChargingModePortSetting{}, false
	}
	name := ChargingModePortNames[group]
	for _, s := range m.PowerSettings {
		if strings.EqualFold(s.Name, name) {
			return s, true
		}
	}
	if int(group) < len(m.PowerSettings) {
		return m.PowerSettings[group], true
	}
	return ChargingModePortSetting{}, false
}

func clampByte(v int) byte {
	return byte(min(255, max(0, v)))
}

// Profile is the 0x0206 profile this stored mode applies.
func (m CloudChargingMode) Profile() a2345.CustomChargingProfile {
	watts := make([]byte, 0, len(a2345.PortGroups))
	for _, g := range a2345.PortGroups {
		s, _ := m.Setting(g)
		watts = append(watts, clampByte(s.Power))
	}
	return a2345.CustomChargingProfile{Number: clampByte(m.Number), AutoExit: m.AutoExit, Watts: watts}
}

// Protocols is the per-port protocol bitmap 0x0206 carries. Mainland firmware
// puts Huawei where overseas firmware puts SCP and adds Xiaomi on bit 6.
func (m CloudChargingMode) Protocols(mainland bool) a2345.PortProtocols {
	ports := make([]a2345.ProtocolFlags, 0, len(a2345.USBCGroups))
	for _, g := range a2345.USBCGroups {
		s, ok := m.Setting(g)
		var flags a2345.ProtocolFlags
		if ok {
			if (mainland && s.Huawei) || (!mainland && s.SCP) {
				flags |= a2345.ProtoSCP
			}
			if s.UFCS {
				flags |= a2345.ProtoUFCS
			}
			if s.PD12V {
				flags |= a2345.ProtoPD12V
			}
			if s.PPS11V {
				flags |= a2345.ProtoPPS11V
			}
			if s.PPS16V {
				flags |= a2345.ProtoPPS16V
			}
			if s.PPS21V {
				flags |= a2345.ProtoPPS21V
			}
			if mainland && s.Xiaomi {
				flags |= a2345.ProtoXiaomi
			}
		}
		ports = append(ports, flags)
	}
	return a2345.PortProtocols{Ports: ports}
}

func (m *CloudChargingMode) decode(data []byte) error {
	var raw struct {
		ID                flex              `json:"id"`
		Number            flex              `json:"number"`
		Name              flex              `json:"name"`
		TotalPower        flex              `json:"total_power"`
		MaxTotalPower     flex              `json:"max_total_power"`
		AutoExit          flex              `json:"auto_exit"`
		HasChargeProtocol flex              `json:"has_charge_protocol"`
		PowerSettings     []json.RawMessage `json:"power_settings"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*m = CloudChargingMode{}
	m.ID, _ = raw.ID.integer()
	m.Number, _ = raw.Number.integer()
	m.Name, _ = raw.Name.str()
	m.TotalPower, _ = raw.TotalPower.integer()
	var ok bool
	if m.MaxTotalPower, ok = raw.MaxTotalPower.integer(); !ok {
		m.MaxTotalPower = a2345.CustomTotalLimit
	}
	m.AutoExit, _ = raw.AutoExit.boolean()
	m.HasChargeProtocol, _ = raw.HasChargeProtocol.boolean()
	m.PowerSettings = []ChargingModePortSetting{}
	for _, item := range raw.PowerSettings {
		var s ChargingModePortSetting
		if err := s.decode(item); err != nil {
			// The Swift `try?` drops the whole list on one bad entry.
			m.PowerSettings = []ChargingModePortSetting{}
			break
		}
		m.PowerSettings = append(m.PowerSettings, s)
	}
	return nil
}

// body is the request body of add_charging_mode (with serial and number) or
// update_charging_mode (with id).
func (m CloudChargingMode) body(deviceSerial string, includesNumber bool) map[string]any {
	total := 0
	ports := make([]portSettingWire, 0, len(m.PowerSettings))
	for _, s := range m.PowerSettings {
		total += s.Power
		ports = append(ports, s.wire())
	}
	b := map[string]any{
		"name":                m.Name,
		"total_power":         total,
		"max_total_power":     m.MaxTotalPower,
		"auto_exit":           bit(m.AutoExit),
		"has_charge_protocol": bit(m.HasChargeProtocol),
		"power_settings":      ports,
	}
	if deviceSerial != "" {
		b["device_sn"] = deviceSerial
	} else {
		b["id"] = m.ID
	}
	if includesNumber {
		b["number"] = m.Number
	}
	return b
}

// CloudTheme is a clock picture theme from style/get_clock_screensavers (kind
// picture) or one of the user's own pictures from
// style/get_manual_clock_screensavers (kind custom).
type CloudTheme struct {
	ID        uint32          `json:"id"`
	Title     string          `json:"title"`
	Category  string          `json:"category"`
	ImageURL  string          `json:"imageURL"`
	ShortURL  string          `json:"shortURL,omitempty"`
	CRC32     uint32          `json:"crc32"`
	TextColor *uint32         `json:"textColor,omitempty"`
	Kind      a2345.ThemeKind `json:"kind"`
}

// Request is the 0x0205 that applies this theme with the clock on or off.
func (t CloudTheme) Request(clockOn bool) a2345.ClockThemeRequest {
	id := t.ID
	if t.Kind == a2345.ThemeCustom {
		r := a2345.NewClockThemeRequest(clockOn, a2345.ThemeCustom, &id, t.CRC32, "")
		r.CustomURL = t.ImageURL
		return r
	}
	return a2345.NewClockThemeRequest(clockOn, a2345.ThemePicture, &id, t.CRC32, t.ImageURL)
}

type themeItem struct {
	id       *uint32
	title    string
	imageURL string
	shortURL string
	crc32    *uint32
	color    *uint32
}

func (it *themeItem) decode(data []byte) error {
	var raw struct {
		ID        flex `json:"id"`
		Title     flex `json:"title"`
		Name      flex `json:"name"`
		ImageURL  flex `json:"image_url"`
		ImgURL    flex `json:"img_url"`
		ShortURL  flex `json:"short_url"`
		CRC32     flex `json:"file_crc32"`
		HashCode  flex `json:"hash_code"`
		TextColor flex `json:"text_color"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*it = themeItem{}
	if n, ok := raw.ID.integer(); ok && n >= 0 && n <= math.MaxUint32 {
		v := uint32(n)
		it.id = &v
	}
	if s, ok := raw.Title.str(); ok {
		it.title = s
	} else {
		it.title, _ = raw.Name.str()
	}
	if s, ok := raw.ImageURL.str(); ok {
		it.imageURL = s
	} else {
		it.imageURL, _ = raw.ImgURL.str()
	}
	it.shortURL, _ = raw.ShortURL.str()
	// `file_crc32` is always hex; `hash_code` is read like Dart's
	// int.tryParse: hex with a 0x prefix, decimal without.
	if v, ok := raw.CRC32.hexUInt32(); ok {
		it.crc32 = &v
	} else if v, ok := raw.HashCode.prefixedUInt32(); ok {
		it.crc32 = &v
	}
	if v, ok := raw.TextColor.hexUInt32(); ok {
		it.color = &v
	}
	return nil
}

func decodeThemeItems(list []json.RawMessage) []themeItem {
	out := make([]themeItem, 0, len(list))
	for _, raw := range list {
		var it themeItem
		if err := it.decode(raw); err != nil {
			return nil
		}
		out = append(out, it)
	}
	return out
}

// listOf decodes `{key: [...]}` or a bare array, the two shapes Anker uses.
func listOf(data []byte, key string) []json.RawMessage {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) > 0 && trimmed[0] == '[' {
		var list []json.RawMessage
		_ = json.Unmarshal(trimmed, &list)
		return list
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &obj); err != nil {
		return nil
	}
	var list []json.RawMessage
	_ = json.Unmarshal(obj[key], &list)
	return list
}

// A2345 mini_power API paths.
const (
	A2345DeviceSettingPath = "mini_power/v1/app/setting/get_device_setting"
	a2345IdentityGetPath   = "mini_power/v1/app/setting/get_charging_device_identity_status_default_true"
	a2345IdentitySetPath   = "mini_power/v1/app/setting/set_charging_device_identity_status_default_true"
)

// A2345CustomPictureLimit is how many of the user's own pictures the official
// app keeps.
const A2345CustomPictureLimit = 8

// ThemeLanguage is the `Language` header for the theme list: theme and
// category names come back in it, and without it the overseas servers answer
// in English, even to a Chinese interface.
func ThemeLanguage(chinese bool) string {
	if chinese {
		return "zh-Hans"
	}
	return "en"
}

type serialBody struct {
	DeviceSerial string `json:"device_sn"`
}

// A2345CloudSettings reads the laboratory switches. The identification value
// in get_device_setting belongs to the A2687; the A2345 keeps its switch
// behind the `_default_true` endpoint, which always wins (nil if it fails).
func (c *CloudClient) A2345CloudSettings(ctx context.Context, serial string) (CloudSettings, error) {
	var raw map[string]json.RawMessage
	if err := c.post(ctx, A2345DeviceSettingPath, serialBody{serial}, nil, false, &raw); err != nil {
		return CloudSettings{}, err
	}
	read := func(obj map[string]json.RawMessage) CloudSettings {
		var s CloudSettings
		if b, ok := flex(obj["charging_mode_status"]).boolean(); ok {
			s.CustomModeEnabled = &b
		}
		if b, ok := flex(obj["compatibility_status"]).boolean(); ok {
			s.MaxCompatibility = &b
		}
		if b, ok := flex(obj["charging_device_identity_status"]).boolean(); ok {
			s.DeviceIdentification = &b
		}
		return s
	}
	settings := read(raw)
	var nested map[string]json.RawMessage
	if err := json.Unmarshal(raw["device_setting"], &nested); err == nil && nested != nil {
		settings = read(nested)
	}
	settings.DeviceIdentification = nil
	if v, err := c.A2345DeviceIdentification(ctx, serial); err == nil {
		settings.DeviceIdentification = v
	}
	return settings, nil
}

// A2345DeviceIdentification reads the A2345's device-identification switch.
func (c *CloudClient) A2345DeviceIdentification(ctx context.Context, serial string) (*bool, error) {
	var raw map[string]json.RawMessage
	if err := c.post(ctx, a2345IdentityGetPath, serialBody{serial}, nil, false, &raw); err != nil {
		return nil, err
	}
	if b, ok := flex(raw["charging_device_identity_status_default_true"]).boolean(); ok {
		return &b, nil
	}
	if b, ok := flex(raw["status"]).boolean(); ok {
		return &b, nil
	}
	return nil, nil
}

func (c *CloudClient) setSwitch(ctx context.Context, path, serial, key string, on bool) error {
	return c.post(ctx, path, map[string]any{"device_sn": serial, key: bit(on)}, nil, true, nil)
}

// SetA2345CustomModeEnabled writes the 实验室 custom-mode switch.
func (c *CloudClient) SetA2345CustomModeEnabled(ctx context.Context, on bool, serial string) error {
	return c.setSwitch(ctx, "mini_power/v1/app/setting/set_charging_mode_status", serial, "charging_mode_status", on)
}

// SetA2345MaxCompatibility writes the cloud value of 0x0214 (1 = on).
func (c *CloudClient) SetA2345MaxCompatibility(ctx context.Context, on bool, serial string) error {
	return c.setSwitch(ctx, "mini_power/v1/app/setting/set_compatibility_status", serial, "compatibility_status", on)
}

// SetA2345DeviceIdentification writes the cloud value of 0x0223.
func (c *CloudClient) SetA2345DeviceIdentification(ctx context.Context, on bool, serial string) error {
	return c.setSwitch(ctx, a2345IdentitySetPath, serial, "charging_device_identity_status_default_true", on)
}

// A2345ChargingModes lists the stored custom profiles, by number.
func (c *CloudClient) A2345ChargingModes(ctx context.Context, serial string) ([]CloudChargingMode, error) {
	var raw json.RawMessage
	if err := c.post(ctx, "mini_power/v1/app/charging/get_charging_mode_list", serialBody{serial}, nil, false, &raw); err != nil {
		return nil, err
	}
	modes := []CloudChargingMode{}
	for _, item := range listOf(raw, "charging_mode_list") {
		var m CloudChargingMode
		if err := m.decode(item); err != nil {
			modes = []CloudChargingMode{}
			break
		}
		modes = append(modes, m)
	}
	sort.SliceStable(modes, func(i, j int) bool { return modes[i].Number < modes[j].Number })
	return modes, nil
}

// AddA2345ChargingMode stores a new profile.
func (c *CloudClient) AddA2345ChargingMode(ctx context.Context, mode CloudChargingMode, serial string) error {
	return c.post(ctx, "mini_power/v1/app/charging/add_charging_mode", mode.body(serial, true), nil, true, nil)
}

// UpdateA2345ChargingMode rewrites a stored profile, by id.
func (c *CloudClient) UpdateA2345ChargingMode(ctx context.Context, mode CloudChargingMode) error {
	return c.post(ctx, "mini_power/v1/app/charging/update_charging_mode", mode.body("", false), nil, true, nil)
}

// DeleteA2345ChargingMode removes a stored profile.
func (c *CloudClient) DeleteA2345ChargingMode(ctx context.Context, id int) error {
	return c.post(ctx, "mini_power/v1/app/charging/delete_charging_mode", map[string]any{"id": id}, nil, true, nil)
}

// A2345ClockThemes lists the cloud picture themes; language is the
// ThemeLanguage of the UI.
func (c *CloudClient) A2345ClockThemes(ctx context.Context, language string) ([]CloudTheme, error) {
	var raw json.RawMessage
	err := c.post(ctx, "mini_power/v1/app/style/get_clock_screensavers",
		map[string]any{"product_code": "A2345"}, map[string]string{"Language": language}, false, &raw)
	if err != nil {
		return nil, err
	}
	themes := []CloudTheme{}
	for _, catRaw := range listOf(raw, "category") {
		var cat struct {
			Name flex              `json:"category_name"`
			List []json.RawMessage `json:"list"`
		}
		if err := json.Unmarshal(catRaw, &cat); err != nil {
			return []CloudTheme{}, nil
		}
		name, _ := cat.Name.str()
		for _, it := range decodeThemeItems(cat.List) {
			if it.id == nil || it.imageURL == "" {
				continue
			}
			t := CloudTheme{
				ID: *it.id, Title: it.title, Category: name, ImageURL: it.imageURL,
				ShortURL: it.shortURL, TextColor: it.color, Kind: a2345.ThemePicture,
			}
			if it.crc32 != nil {
				t.CRC32 = *it.crc32
			}
			themes = append(themes, t)
		}
	}
	return themes, nil
}

// A2345CustomScreensavers lists the user's own pictures. Their links are
// signed for a few minutes only; fetch again right before use.
func (c *CloudClient) A2345CustomScreensavers(ctx context.Context, serial string) ([]CloudTheme, error) {
	var raw json.RawMessage
	if err := c.post(ctx, "mini_power/v1/app/style/get_manual_clock_screensavers", map[string]any{"sn": serial}, nil, false, &raw); err != nil {
		return nil, err
	}
	themes := []CloudTheme{}
	for _, it := range decodeThemeItems(listOf(raw, "list")) {
		if it.id == nil || it.imageURL == "" {
			continue
		}
		t := CloudTheme{ID: *it.id, Title: it.title, ImageURL: it.imageURL, ShortURL: it.shortURL, Kind: a2345.ThemeCustom}
		if it.crc32 != nil {
			t.CRC32 = *it.crc32
		}
		themes = append(themes, t)
	}
	return themes, nil
}

// UploadA2345CustomPicture uploads one prepared 480×200 JPEG and registers it
// as a custom clock picture, the way the official app does: a signed upload
// slot from cloudstor, a plain PUT, then add_manual_clock_screensavers with
// the slot's short path and the file's CRC-32.
func (c *CloudClient) UploadA2345CustomPicture(ctx context.Context, jpeg []byte, serial string) error {
	var ticket struct {
		UploadToken string `json:"uptoken"`
		KeyPrefix   string `json:"key_prefix"`
	}
	err := c.post(ctx, "app/cloudstor/get_app_up_token_general", map[string]any{
		"file_name":    "cropped_image.jpg",
		"content_type": "binary/octet-stream",
		"file_size":    len(jpeg),
		"disable_ssl":  false,
		"type":         106,
	}, map[string]string{"user_id": c.AccountUserID()}, false, &ticket)
	if err != nil {
		return err
	}
	if ticket.UploadToken == "" || ticket.KeyPrefix == "" {
		return cloudErr(CloudErrMalformedResponse)
	}
	if err := c.putSignedUpload(ctx, jpeg, ticket.UploadToken, "binary/octet-stream"); err != nil {
		return err
	}
	return c.post(ctx, "mini_power/v1/app/style/add_manual_clock_screensavers", map[string]any{
		"sn":        serial,
		"img_url":   ticket.KeyPrefix,
		"hash_code": fmt.Sprintf("0x%08x", CRC32(jpeg)),
	}, nil, true, nil)
}

// DeleteA2345CustomPicture removes one of the user's pictures.
func (c *CloudClient) DeleteA2345CustomPicture(ctx context.Context, id uint32) error {
	return c.post(ctx, "mini_power/v1/app/style/delete_manual_clock_screensavers", map[string]any{"id": int(id)}, nil, true, nil)
}

// CRC32 is zlib's CRC-32, which the charger uses to recognise a picture it
// has already downloaded.
func CRC32(data []byte) uint32 { return crc32.ChecksumIEEE(data) }

// flex is a JSON value Anker returns as an int, a string or occasionally a
// bool for the same field.
type flex json.RawMessage

func (f *flex) UnmarshalJSON(b []byte) error {
	*f = append((*f)[:0], b...)
	return nil
}

func (f flex) value() (any, bool) {
	if len(f) == 0 {
		return nil, false
	}
	dec := json.NewDecoder(bytes.NewReader(f))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, false
	}
	return v, v != nil
}

func (f flex) str() (string, bool) {
	v, ok := f.value()
	if !ok {
		return "", false
	}
	s, ok := v.(string)
	return s, ok
}

// integer is KeyedDecodingContainer.flexibleInt: an int, a decimal string, a
// bool (1/0) or an integral double.
func (f flex) integer() (int, bool) {
	v, ok := f.value()
	if !ok {
		return 0, false
	}
	switch x := v.(type) {
	case json.Number:
		if i, err := x.Int64(); err == nil {
			return int(i), true
		}
		if fl, err := x.Float64(); err == nil && fl == math.Trunc(fl) && math.Abs(fl) < 1<<53 {
			return int(fl), true
		}
	case string:
		if i, err := strconv.Atoi(x); err == nil {
			return i, true
		}
	case bool:
		return bit(x), true
	}
	return 0, false
}

func (f flex) boolean() (bool, bool) {
	i, ok := f.integer()
	return i == 1, ok
}

// hexUInt32 reads "0x1a2b3c4d", "1a2b3c4d" or a plain number.
func (f flex) hexUInt32() (uint32, bool) {
	v, ok := f.value()
	if !ok {
		return 0, false
	}
	switch x := v.(type) {
	case json.Number:
		if i, err := x.Int64(); err == nil {
			return uint32(i), true
		}
	case string:
		text := strings.TrimSpace(x)
		if strings.HasPrefix(strings.ToLower(text), "0x") {
			text = text[2:]
		}
		if u, err := strconv.ParseUint(text, 16, 32); err == nil {
			return uint32(u), true
		}
	}
	return 0, false
}

// prefixedUInt32 reads like Dart's int.tryParse: hex with 0x, decimal without.
func (f flex) prefixedUInt32() (uint32, bool) {
	v, ok := f.value()
	if !ok {
		return 0, false
	}
	switch x := v.(type) {
	case json.Number:
		if i, err := x.Int64(); err == nil {
			return uint32(i), true
		}
	case string:
		text := strings.TrimSpace(x)
		if strings.HasPrefix(strings.ToLower(text), "0x") {
			if u, err := strconv.ParseUint(text[2:], 16, 32); err == nil {
				return uint32(u), true
			}
			return 0, false
		}
		if u, err := strconv.ParseUint(text, 10, 32); err == nil {
			return uint32(u), true
		}
	}
	return 0, false
}
