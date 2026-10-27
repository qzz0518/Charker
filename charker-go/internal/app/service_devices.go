package app

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"charker/internal/a2687"
	"charker/internal/prefs"
	"charker/internal/session"
)

// The devices page's half of AppModel: display-setting writes with their
// reconnect read-back, charging-mode switches, the saved-charger list, the
// picker flows, the model screen library and the cover push to the
// charger's own panel. Strings the page shows travel as the Mac's Chinese
// source keys and are translated there with t().

// SessionDevices is what the devices page needs from the session engine on
// top of the shared Session calls.
type SessionDevices interface {
	SetChargingMode(code byte) (bool, error)
	SetCustomChargingMode(autoExit bool, watts [3]int) (bool, error)
	Browse() error
	BrowseForNewCharger() error
	CancelBrowseForNewCharger() error
	Forget(id string) error
	PushCover(ctx context.Context, jpeg []byte, image a2687.CoverImageReference, acknowledgedIrreversible bool, onProgress func(session.CoverProgress)) (session.CoverOutcome, error)
	SelectCover(image a2687.CoverImageReference) (uint16, bool, error)
	ReadCoverPictureID() (uint16, bool, error)
}

// ---- SessionHost forwarding -------------------------------------------------------

func (h *SessionHost) SetChargingMode(code byte) (bool, error) {
	m, err := h.manager()
	if err != nil {
		return false, err
	}
	return m.SetChargingMode(code)
}

func (h *SessionHost) SetCustomChargingMode(autoExit bool, watts [3]int) (bool, error) {
	m, err := h.manager()
	if err != nil {
		return false, err
	}
	return m.SetCustomChargingMode(autoExit, watts)
}

func (h *SessionHost) Browse() error {
	return h.withManager(func(m *session.Manager) error { return m.Browse() })
}

func (h *SessionHost) BrowseForNewCharger() error {
	return h.withManager(func(m *session.Manager) error { return m.BrowseForNewCharger() })
}

func (h *SessionHost) CancelBrowseForNewCharger() error {
	return h.withManager(func(m *session.Manager) error { return m.CancelBrowseForNewCharger() })
}

func (h *SessionHost) Forget(id string) error {
	h.mu.Lock()
	kept := h.opts.Remembered[:0:0]
	for _, r := range h.opts.Remembered {
		if r != id {
			kept = append(kept, r)
		}
	}
	h.opts.Remembered = kept
	h.mu.Unlock()
	return h.withManager(func(m *session.Manager) error { return m.Forget(id) })
}

func (h *SessionHost) PushCover(ctx context.Context, jpeg []byte, image a2687.CoverImageReference, ack bool, onProgress func(session.CoverProgress)) (session.CoverOutcome, error) {
	m, err := h.manager()
	if err != nil {
		return session.CoverOutcome{}, err
	}
	return m.PushCover(ctx, jpeg, image, ack, onProgress)
}

func (h *SessionHost) SelectCover(image a2687.CoverImageReference) (uint16, bool, error) {
	m, err := h.manager()
	if err != nil {
		return 0, false, err
	}
	return m.SelectCover(image)
}

func (h *SessionHost) ReadCoverPictureID() (uint16, bool, error) {
	m, err := h.manager()
	if err != nil {
		return 0, false, err
	}
	return m.ReadCoverPictureID()
}

// ---- page state -------------------------------------------------------------------

// DevicesState is AppState.devices.
type DevicesState struct {
	// PeripheralID is the charger in use or being waited for.
	PeripheralID string `json:"peripheralId,omitempty"`
	Browsing     bool   `json:"browsing"`
	// SettingChange is AppModel.chargerSettingChange.
	SettingChange *SettingChangeView `json:"settingChange"`
	// ModeChange is AppModel.chargingModeChange.
	ModeChange  *ModeChangeView `json:"modeChange"`
	CoverPush   CoverPushView   `json:"coverPush"`
	ModelScreen ModelScreenView `json:"modelScreen"`
}

// SettingChangeView: outcome is sending, reconnecting, confirmed, accepted,
// unconfirmed or failed (reason is a Chinese source key).
type SettingChangeView struct {
	Key     string `json:"key"`
	Value   string `json:"value"`
	Outcome string `json:"outcome"`
	Reason  string `json:"reason,omitempty"`
}

// ModeChangeView: outcome is sending, confirmed, unconfirmed or failed.
type ModeChangeView struct {
	Mode    int    `json:"mode"`
	Outcome string `json:"outcome"`
	Reason  string `json:"reason,omitempty"`
}

// CoverPushView is AppModel.coverPush. Phase: idle, running, done, failed,
// reselected.
type CoverPushView struct {
	Phase    string                 `json:"phase"`
	Slot     *int                   `json:"slot"`
	Stopping bool                   `json:"stopping"`
	Progress *session.CoverProgress `json:"progress,omitempty"`
	// Verification is witnessed or inconclusive on a finished push.
	Verification string            `json:"verification,omitempty"`
	Failure      *CoverFailureView `json:"failure,omitempty"`
}

// CoverFailureView is CoverPushFailure. Remedy: nothingWritten, interrupted,
// lostSlices, selectionDidNotTake. Detail is a Chinese source key.
type CoverFailureView struct {
	Remedy              string `json:"remedy"`
	Detail              string `json:"detail,omitempty"`
	SuggestsCloudID     bool   `json:"suggestsCloudId"`
	PixelsMayHaveLanded bool   `json:"pixelsMayHaveLanded"`
}

// ModelScreenView is the custom screen library. Images are fetched with
// ModelScreenArtworks when Revision changes.
type ModelScreenView struct {
	Revision    int           `json:"revision"`
	Artworks    []ArtworkView `json:"artworks"`
	SyncedSlots []int         `json:"syncedSlots"`
	Error       string        `json:"error,omitempty"`
}

// ArtworkView is one saved custom screen.
type ArtworkView struct {
	ID         int             `json:"id"`
	Crop       json.RawMessage `json:"crop"`
	Vignette   json.RawMessage `json:"vignette"`
	HasSource  bool            `json:"hasSource"`
	CoverBytes int             `json:"coverBytes"`
}

// ---- the model ----------------------------------------------------------------------

type settingChange struct {
	id        int64
	key       string
	value     string
	outcome   string
	reason    string
	clearedAt time.Time
}

type modeChange struct {
	id      int64
	mode    int
	outcome string
	reason  string
}

type coverPush struct {
	phase        string
	slot         *int
	stopping     bool
	progress     *session.CoverProgress
	verification string
	failure      *CoverFailureView
	lastPublish  time.Time
}

type devicesModel struct {
	mu        sync.Mutex
	nextID    int64
	setting   *settingChange
	mode      *modeChange
	cover     coverPush
	cancel    context.CancelFunc
	lastRef   *a2687.CoverImageReference
	library   []ArtworkView
	revision  int
	loaded    bool
	synced    map[int]bool
	libError  string
	demoKnown bool
	demo      bool
}

var devicesModels sync.Map // *App -> *devicesModel

func (a *App) devices() *devicesModel {
	if dm, ok := devicesModels.Load(a); ok {
		return dm.(*devicesModel)
	}
	dm, _ := devicesModels.LoadOrStore(a, &devicesModel{cover: coverPush{phase: "idle"}, synced: map[int]bool{}})
	return dm.(*devicesModel)
}

// devicesStateLocked fills AppState.devices. a.mu is held.
func (a *App) devicesStateLocked(snap Snapshot) DevicesState {
	dm := a.devices()
	if !dm.loaded {
		a.loadModelScreenLocked(dm)
	}
	dm.mu.Lock()
	defer dm.mu.Unlock()
	// Toggling demo mode rebuilds the session: notes about the previous link
	// describe a charger this session is not talking to (AppModel.buildSession).
	if dm.demoKnown && dm.demo != a.demo {
		dm.setting = nil
		dm.mode = nil
		if dm.cancel != nil {
			dm.cancel()
		}
		if dm.cover.phase != "running" {
			dm.cover = coverPush{phase: "idle"}
		}
	}
	dm.demoKnown, dm.demo = true, a.demo
	// A write left unconfirmed is promoted once a later live snapshot shows
	// the value (resolveChargerSettingChange keeps watching .unconfirmed).
	if c := dm.setting; c != nil && c.outcome == "unconfirmed" && snap.Phase == PhasePolling && snap.Telemetry != nil {
		if match, defined := readbackMatches(c.key, c.value, snap.Telemetry.Settings); defined && match {
			c.outcome = "confirmed"
			id := c.id
			time.AfterFunc(8*time.Second, func() {
				dm.mu.Lock()
				if dm.setting != nil && dm.setting.id == id {
					dm.setting = nil
				}
				dm.mu.Unlock()
				a.publishNow()
			})
		}
	}
	// The 「这次连接里还看不到变化」 note comes down once the row can answer.
	if dm.mode != nil && dm.mode.outcome == "unconfirmed" && snap.Telemetry != nil &&
		snap.Telemetry.Settings != nil && snap.Telemetry.Settings.ChargingMode != nil &&
		*snap.Telemetry.Settings.ChargingMode == dm.mode.mode {
		dm.mode = nil
	}
	st := DevicesState{
		PeripheralID: snap.PeripheralID,
		Browsing:     snap.Browsing,
		CoverPush: CoverPushView{
			Phase:        dm.cover.phase,
			Slot:         dm.cover.slot,
			Stopping:     dm.cover.stopping,
			Progress:     dm.cover.progress,
			Verification: dm.cover.verification,
			Failure:      dm.cover.failure,
		},
		ModelScreen: ModelScreenView{
			Revision:    dm.revision,
			Artworks:    append([]ArtworkView{}, dm.library...),
			SyncedSlots: []int{},
			Error:       dm.libError,
		},
	}
	for slot := range dm.synced {
		st.ModelScreen.SyncedSlots = append(st.ModelScreen.SyncedSlots, slot)
	}
	sort.Ints(st.ModelScreen.SyncedSlots)
	if c := dm.setting; c != nil {
		st.SettingChange = &SettingChangeView{Key: c.key, Value: c.value, Outcome: c.outcome, Reason: c.reason}
	}
	if c := dm.mode; c != nil {
		st.ModeChange = &ModeChangeView{Mode: c.mode, Outcome: c.outcome, Reason: c.reason}
	}
	return st
}

// ---- blockers (AppModel) -------------------------------------------------------------

const firmwareVerified = "0.0.5.2"

// chargerSettingBlocker is AppModel.chargerSettingBlocker.
func (a *App) chargerSettingBlocker(snap Snapshot) string {
	if a.sess == nil || snap.Phase != PhasePolling {
		return "需要先连上充电器"
	}
	version := ""
	if snap.Device != nil {
		version = strings.ToLower(strings.TrimSpace(snap.Device.Firmware))
	}
	version = strings.TrimPrefix(version, "v")
	if version != firmwareVerified {
		return "这些写入目前只在固件 v0.0.5.2 上验证过"
	}
	return ""
}

func (dm *devicesModel) isChangingSettingLocked() bool {
	return dm.setting != nil && (dm.setting.outcome == "sending" || dm.setting.outcome == "reconnecting")
}

// switchBlockerLocked is AppModel.chargerSwitchBlocker.
func (dm *devicesModel) switchBlockerLocked() string {
	if dm.cover.phase == "running" {
		return "正在推送屏保，完成后再切换"
	}
	if dm.isChangingSettingLocked() {
		return "正在写入设备设置，完成后再切换"
	}
	if dm.mode != nil && dm.mode.outcome == "sending" {
		return "正在切换充电模式，完成后再切换"
	}
	return ""
}

// describeError is AppModel.describe: one sentence the user can act on.
func describeError(err error) string {
	switch {
	case errors.Is(err, session.ErrNotReady), errors.Is(err, session.ErrNotRunning), errors.Is(err, errNoSession):
		return "连接还没就绪，命令没有发出去。"
	case errors.Is(err, session.ErrWritesDisabled):
		return "写入开关还没打开，命令没有发出去。"
	case errors.Is(err, session.ErrTimeout), errors.Is(err, session.ErrLinkLost):
		return "充电器没有回应，这次操作有没有生效不清楚。"
	case errors.Is(err, session.ErrDeviceRejected):
		return "充电器拒绝了这次操作。"
	}
	return "操作没有完成。"
}

// devicesError is a refusal the page shows as an action message.
type devicesError struct{ key string }

func (e devicesError) Error() string { return e.key }

// ---- display settings ----------------------------------------------------------------

// ChangeChargerSetting is AppModel.setChargerSetting: send the write, require
// its ACK, reconnect, and compare the new handshake snapshot. Keys and values
// are the session's (language 0-3, screenTimeout 0-4, brightness 25-100,
// orientation 0-3, gyroscope true/false, fixedAllocation 0/1).
func (s *Charker) ChangeChargerSetting(key, value string) (any, error) {
	a := s.app
	if a.sess == nil {
		return nil, errNoSession
	}
	snap := a.sess.Snapshot()
	if b := a.chargerSettingBlocker(snap); b != "" {
		return nil, devicesError{b}
	}
	dm := a.devices()
	dm.mu.Lock()
	if dm.isChangingSettingLocked() || (dm.mode != nil && dm.mode.outcome == "sending") {
		dm.mu.Unlock()
		return nil, nil
	}
	dm.nextID++
	change := &settingChange{id: dm.nextID, key: key, value: value, outcome: "sending"}
	dm.setting = change
	dm.mu.Unlock()
	a.publishNow()
	go a.runSettingChange(change.id, key, value)
	return nil, nil
}

func (a *App) runSettingChange(id int64, key, value string) {
	dm := a.devices()
	current := func() bool {
		dm.mu.Lock()
		defer dm.mu.Unlock()
		return dm.setting != nil && dm.setting.id == id
	}
	err := a.sess.SetSetting(key, value)
	if !current() {
		return
	}
	if err != nil {
		log.Printf("devices: display setting %s=%s failed: %v", key, value, err)
		reason := describeError(err)
		if key == "brightness" && errors.Is(err, session.ErrInvalidArgument) {
			reason = "屏幕亮度只能设为 25% 到 100%。"
		}
		a.noteSetting(id, "failed", reason, 10*time.Second)
		return
	}
	a.noteSetting(id, "reconnecting", "", 0)
	started := time.Now()
	if err := a.sess.Reconnect(); err != nil {
		log.Printf("devices: reconnect for read-back: %v", err)
	}
	// Resolve only against a fresh live session: a link whose handshake
	// finished after the write, and a report received on that link.
	deadline := started.Add(30 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
		if !current() {
			return
		}
		snap := a.sess.Snapshot()
		if snap.Phase != PhasePolling || snap.LinkReadyAtMs < started.UnixMilli() ||
			snap.Telemetry == nil || snap.Telemetry.ReceivedAtMs < snap.LinkReadyAtMs {
			continue
		}
		match, defined := readbackMatches(key, value, snap.Telemetry.Settings)
		switch {
		case !defined:
			a.noteSetting(id, "accepted", "", 8*time.Second)
			return
		case match:
			a.noteSetting(id, "confirmed", "", 8*time.Second)
			return
		case snap.Telemetry.Settings != nil:
			a.noteSetting(id, "unconfirmed", "", 0)
			return
		}
	}
	if !current() {
		return
	}
	if _, defined := readbackMatches(key, value, nil); !defined {
		// Language has no read-back field; its ACK is still a firm fact.
		a.noteSetting(id, "accepted", "", 8*time.Second)
		return
	}
	a.noteSetting(id, "unconfirmed", "", 0)
}

// readbackMatches is ChargerSetting.readbackMatches; defined is false for
// the settings with no read-back field (language, fixed allocation).
func readbackMatches(key, value string, s *session.ChargerSettings) (match, defined bool) {
	intIs := func(p *int) bool {
		return p != nil && fmt.Sprint(*p) == value
	}
	switch key {
	case "language", "fixedAllocation":
		return false, false
	case "screenTimeout":
		return s != nil && intIs(s.ScreenTimeout), true
	case "brightness":
		return s != nil && intIs(s.ScreenBrightness), true
	case "orientation":
		return s != nil && intIs(s.ScreenOrientation), true
	case "gyroscope":
		return s != nil && s.GyroscopeEnabled != nil && fmt.Sprint(*s.GyroscopeEnabled) == value, true
	}
	return false, false
}

func (a *App) noteSetting(id int64, outcome, reason string, clearAfter time.Duration) {
	dm := a.devices()
	dm.mu.Lock()
	if dm.setting == nil || dm.setting.id != id {
		dm.mu.Unlock()
		return
	}
	dm.setting.outcome = outcome
	dm.setting.reason = reason
	dm.mu.Unlock()
	a.publishNow()
	if clearAfter > 0 {
		time.AfterFunc(clearAfter, func() {
			dm.mu.Lock()
			if dm.setting != nil && dm.setting.id == id {
				dm.setting = nil
			}
			dm.mu.Unlock()
			a.publishNow()
		})
	}
}

// ---- charging mode ---------------------------------------------------------------------

// ChangeChargingMode is AppModel.setChargingMode (0 AI, 1 standard).
func (s *Charker) ChangeChargingMode(code int) (any, error) {
	if code != 0 && code != 1 {
		return nil, fmt.Errorf("charging mode %d needs its own editor", code)
	}
	return s.app.changeMode(code, func(x Session) (bool, error) { return x.SetChargingMode(byte(code)) })
}

// ChangeCustomChargingMode is AppModel.setCustomChargingMode.
func (s *Charker) ChangeCustomChargingMode(autoExit bool, c1, c2, c3 int) (any, error) {
	watts := [3]int{c1, c2, c3}
	total := 0
	for _, w := range watts {
		if w != 0 && (w < 15 || w > 140) {
			return nil, nil // CustomChargingPower.isValid: nothing is sent
		}
		total += w
	}
	if total > 160 {
		return nil, nil
	}
	return s.app.changeMode(2, func(x Session) (bool, error) { return x.SetCustomChargingMode(autoExit, watts) })
}

func (a *App) changeMode(code int, write func(Session) (bool, error)) (any, error) {
	if a.sess == nil {
		return nil, errNoSession
	}
	if a.sess.Snapshot().Phase != PhasePolling {
		return nil, devicesError{"需要先连上充电器"}
	}
	dm := a.devices()
	dm.mu.Lock()
	if (dm.mode != nil && dm.mode.outcome == "sending") || dm.isChangingSettingLocked() {
		dm.mu.Unlock()
		return nil, nil
	}
	dm.nextID++
	id := dm.nextID
	dm.mode = &modeChange{id: id, mode: code, outcome: "sending"}
	dm.mu.Unlock()
	a.publishNow()
	go func() {
		confirmed, err := write(a.sess)
		switch {
		case err != nil:
			log.Printf("devices: charging mode 0x%02X failed: %v", code, err)
			a.noteMode(id, "failed", describeError(err), 10*time.Second)
		case confirmed:
			a.noteMode(id, "confirmed", "", 6*time.Second)
		default:
			// Not a failure: the settings field may not move until the next
			// link. Left standing until the row answers for itself.
			a.noteMode(id, "unconfirmed", "", 0)
		}
	}()
	return nil, nil
}

func (a *App) noteMode(id int64, outcome, reason string, clearAfter time.Duration) {
	dm := a.devices()
	dm.mu.Lock()
	if dm.mode == nil || dm.mode.id != id {
		dm.mu.Unlock()
		return
	}
	dm.mode.outcome = outcome
	dm.mode.reason = reason
	dm.mu.Unlock()
	a.publishNow()
	if clearAfter > 0 {
		time.AfterFunc(clearAfter, func() {
			dm.mu.Lock()
			if dm.mode != nil && dm.mode.id == id {
				dm.mode = nil
			}
			dm.mu.Unlock()
			a.publishNow()
		})
	}
}

// ---- saved chargers and the picker ------------------------------------------------------

func (a *App) saveChargers(list []prefs.SavedCharger) {
	a.mu.Lock()
	a.saved = list
	store := a.store
	a.mu.Unlock()
	if store != nil {
		if err := store.SaveSavedChargers(list); err != nil {
			log.Printf("app: saving chargers: %v", err)
		}
	}
}

// RenameCharger is AppModel.renameCharger; an empty name clears it.
func (s *Charker) RenameCharger(id, nickname string) (any, error) {
	a := s.app
	a.mu.Lock()
	list := prefs.SetNickname(a.saved, id, nickname)
	a.mu.Unlock()
	a.saveChargers(list)
	a.publishNow()
	return nil, nil
}

// ForgetCharger is AppModel.forgetCharger: the session lets it go and
// carries on with the others. Energy history and settings stay.
func (s *Charker) ForgetCharger(id string) (any, error) {
	a := s.app
	if a.sess == nil {
		return nil, errNoSession
	}
	dm := a.devices()
	dm.mu.Lock()
	blocker := dm.switchBlockerLocked()
	dm.mu.Unlock()
	if blocker != "" && id == a.sess.Snapshot().PeripheralID {
		return nil, devicesError{blocker}
	}
	a.mu.Lock()
	list := prefs.RemoveSaved(a.saved, id)
	if a.prefs.LastDeviceID == id {
		a.prefs.LastDeviceID = ""
	}
	a.mu.Unlock()
	a.saveChargers(list)
	a.savePrefs()
	if err := a.sess.SetRemembered(prefs.ReconnectOrder(list)); err != nil {
		log.Printf("app: remembered chargers: %v", err)
	}
	if err := a.sess.Forget(id); err != nil {
		log.Printf("app: forget charger: %v", err)
	}
	a.publishNow()
	return nil, nil
}

// ConnectCharger is AppModel.connect(to:): a pick from the nearby list or a
// switch between saved chargers.
func (s *Charker) ConnectCharger(id string) (any, error) {
	a := s.app
	if a.sess == nil {
		return nil, errNoSession
	}
	snap := a.sess.Snapshot()
	if id == snap.PeripheralID && (snap.Phase == PhasePolling || snap.Phase == PhaseHandshake) {
		return nil, nil // re-picking the live charger must not drop its link
	}
	dm := a.devices()
	dm.mu.Lock()
	blocker := dm.switchBlockerLocked()
	dm.mu.Unlock()
	if blocker != "" && id != snap.PeripheralID {
		return nil, devicesError{blocker}
	}
	return s.Connect(id)
}

// Browse lists nearby chargers without connecting (AppModel.browse).
func (s *Charker) Browse() (any, error) { return nil, s.app.withSession(Session.Browse) }

// BeginAddingCharger lets go of the current charger and scans.
func (s *Charker) BeginAddingCharger() (any, error) {
	return nil, s.app.withSession(Session.BrowseForNewCharger)
}

// CancelAddingCharger goes back to the charger it let go of, then the saved ones.
func (s *Charker) CancelAddingCharger() (any, error) {
	return nil, s.app.withSession(Session.CancelBrowseForNewCharger)
}

// ---- model screen library --------------------------------------------------------------

const maximumCustomScreens = 3

func (a *App) modelScreenDir() (string, error) {
	if a.store == nil || a.store.Dir() == "" {
		return "", devicesError{"无法访问 Charker 的本地图片目录"}
	}
	return filepath.Join(a.store.Dir(), "ModelScreen"), nil
}

func slotDir(base string, slot int) string {
	return filepath.Join(base, fmt.Sprintf("slot-%d", slot+1))
}

// loadModelScreenLocked reads the library index (not the pixels). a.mu held.
func (a *App) loadModelScreenLocked(dm *devicesModel) {
	dm.mu.Lock()
	defer dm.mu.Unlock()
	dm.loaded = true
	base, err := a.modelScreenDir()
	if err != nil {
		return
	}
	dm.library = scanLibrary(base)
	dm.synced = map[int]bool{}
	if data, err := os.ReadFile(filepath.Join(base, "synced.json")); err == nil {
		var slots []int
		if json.Unmarshal(data, &slots) == nil {
			for _, s := range slots {
				if s >= 0 && s < maximumCustomScreens {
					dm.synced[s] = true
				}
			}
		}
	}
}

func scanLibrary(base string) []ArtworkView {
	out := []ArtworkView{}
	for slot := 0; slot < maximumCustomScreens; slot++ {
		dir := slotDir(base, slot)
		if _, err := os.Stat(filepath.Join(dir, "custom.png")); err != nil {
			continue
		}
		item := ArtworkView{ID: slot, Crop: json.RawMessage(`{"centerX":0.5,"centerY":0.5,"zoom":1}`), Vignette: json.RawMessage(`{"red":0,"green":0,"blue":0,"strength":0,"innerRadius":0.45}`)}
		if data, err := os.ReadFile(filepath.Join(dir, "crop.json")); err == nil && json.Valid(data) {
			item.Crop = data
		}
		if data, err := os.ReadFile(filepath.Join(dir, "vignette.json")); err == nil && json.Valid(data) {
			item.Vignette = data
		}
		if _, err := os.Stat(filepath.Join(dir, "source.png")); err == nil {
			item.HasSource = true
		}
		if info, err := os.Stat(filepath.Join(dir, "cover.jpg")); err == nil {
			item.CoverBytes = int(info.Size())
		}
		out = append(out, item)
	}
	return out
}

func (dm *devicesModel) persistSyncedLocked(base string) {
	slots := []int{}
	for s := range dm.synced {
		slots = append(slots, s)
	}
	sort.Ints(slots)
	data, _ := json.Marshal(slots)
	_ = os.MkdirAll(base, 0o755)
	if err := os.WriteFile(filepath.Join(base, "synced.json"), data, 0o644); err != nil {
		log.Printf("devices: saving synced slots: %v", err)
	}
}

// ArtworkImages are one custom screen's pictures as data URLs.
type ArtworkImages struct {
	ID      int    `json:"id"`
	Source  string `json:"source,omitempty"`
	Texture string `json:"texture,omitempty"`
	Cover   string `json:"cover,omitempty"`
}

// ModelScreenArtworks returns the saved pictures; the page refetches them
// when state.devices.modelScreen.revision changes.
func (s *Charker) ModelScreenArtworks() ([]ArtworkImages, error) {
	base, err := s.app.modelScreenDir()
	if err != nil {
		return []ArtworkImages{}, nil
	}
	dataURL := func(path, mime string) string {
		data, err := os.ReadFile(path)
		if err != nil {
			return ""
		}
		return "data:" + mime + ";base64," + base64.StdEncoding.EncodeToString(data)
	}
	out := []ArtworkImages{}
	for _, item := range scanLibrary(base) {
		dir := slotDir(base, item.ID)
		out = append(out, ArtworkImages{
			ID:      item.ID,
			Source:  dataURL(filepath.Join(dir, "source.png"), "image/png"),
			Texture: dataURL(filepath.Join(dir, "custom.png"), "image/png"),
			Cover:   dataURL(filepath.Join(dir, "cover.jpg"), "image/jpeg"),
		})
	}
	return out, nil
}

// ArtworkInput is one custom screen rendered by the page: the source picture
// (PNG, at most 2048 px), the 960x400 model texture and the 240x240 JPEG
// the charger's panel receives, all from the same crop and vignette.
type ArtworkInput struct {
	// Slot replaces that slot; -1 takes the first free one.
	Slot     int             `json:"slot"`
	Source   string          `json:"source"`
	Texture  string          `json:"texture"`
	Cover    string          `json:"cover"`
	Crop     json.RawMessage `json:"crop"`
	Vignette json.RawMessage `json:"vignette"`
}

func decodeDataURL(s string) ([]byte, error) {
	if i := strings.Index(s, ","); i >= 0 && strings.HasPrefix(s, "data:") {
		s = s[i+1:]
	}
	return base64.StdEncoding.DecodeString(s)
}

// SaveModelScreenArtwork is AppModel.saveModelScreenArtwork. The pushed copy
// in the charger is not touched: a re-crop needs another push.
func (s *Charker) SaveModelScreenArtwork(in ArtworkInput) (any, error) {
	a := s.app
	base, err := a.modelScreenDir()
	if err != nil {
		return nil, err
	}
	dm := a.devices()
	dm.mu.Lock()
	slot := in.Slot
	if slot < 0 {
		occupied := map[int]bool{}
		for _, item := range dm.library {
			occupied[item.ID] = true
		}
		slot = -1
		for i := 0; i < maximumCustomScreens; i++ {
			if !occupied[i] {
				slot = i
				break
			}
		}
		if slot < 0 {
			dm.libError = "最多只能添加 3 个自定义屏保"
			dm.mu.Unlock()
			a.publishNow()
			return nil, devicesError{"最多只能添加 3 个自定义屏保"}
		}
	} else if slot >= maximumCustomScreens {
		dm.mu.Unlock()
		return nil, devicesError{"自定义屏保位置无效"}
	}
	dm.mu.Unlock()

	fail := func(err error) (any, error) {
		log.Printf("devices: saving model screen: %v", err)
		dm.mu.Lock()
		dm.libError = "无法生成模型屏幕图片"
		dm.mu.Unlock()
		a.publishNow()
		return nil, devicesError{"无法生成模型屏幕图片"}
	}
	source, err := decodeDataURL(in.Source)
	if err != nil || len(source) == 0 {
		return fail(fmt.Errorf("source: %v", err))
	}
	texture, err := decodeDataURL(in.Texture)
	if err != nil || len(texture) == 0 {
		return fail(fmt.Errorf("texture: %v", err))
	}
	cover, err := decodeDataURL(in.Cover)
	if err != nil || len(cover) == 0 {
		return fail(fmt.Errorf("cover: %v", err))
	}
	dir := slotDir(base, slot)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fail(err)
	}
	files := map[string][]byte{
		"source.png": source, "custom.png": texture, "cover.jpg": cover,
		"crop.json": in.Crop, "vignette.json": in.Vignette,
	}
	for name, data := range files {
		if err := writeAtomic(filepath.Join(dir, name), data); err != nil {
			return fail(err)
		}
	}
	dm.mu.Lock()
	dm.library = scanLibrary(base)
	dm.revision++
	dm.libError = ""
	dm.mu.Unlock()
	if err := a.SetPrefs(json.RawMessage(fmt.Sprintf(`{"modelScreenStyle":"custom","modelScreenCustomSlot":%d}`, slot))); err != nil {
		return nil, err
	}
	a.toast("info", a.tr(textScreenApplied))
	return slot, nil
}

func writeAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// RemoveModelScreenArtwork is AppModel.removeModelScreenArtwork. It frees
// nothing inside the charger; it only forgets the claim for the slot.
func (s *Charker) RemoveModelScreenArtwork(id int) (any, error) {
	a := s.app
	base, err := a.modelScreenDir()
	if err != nil {
		return nil, err
	}
	if id < 0 || id >= maximumCustomScreens {
		return nil, devicesError{"自定义屏保位置无效"}
	}
	dm := a.devices()
	dm.mu.Lock()
	removedIndex := -1
	for i, item := range dm.library {
		if item.ID == id {
			removedIndex = i
		}
	}
	dm.mu.Unlock()
	if err := os.RemoveAll(slotDir(base, id)); err != nil {
		return nil, devicesError{"操作没有完成。"}
	}
	dm.mu.Lock()
	dm.library = scanLibrary(base)
	remaining := append([]ArtworkView(nil), dm.library...)
	if dm.synced[id] {
		delete(dm.synced, id)
		dm.persistSyncedLocked(base)
	}
	dm.revision++
	dm.libError = ""
	dm.mu.Unlock()

	p := a.Prefs()
	patch := ""
	if p.ModelScreenStyle == "custom" && p.ModelScreenCustomSlot == id {
		if removedIndex >= 0 && len(remaining) > 0 {
			i := removedIndex
			if i > len(remaining)-1 {
				i = len(remaining) - 1
			}
			patch = fmt.Sprintf(`{"modelScreenCustomSlot":%d}`, remaining[i].ID)
		} else {
			patch = `{"modelScreenStyle":"ankerPrime"}`
		}
	}
	if patch != "" {
		if err := a.SetPrefs(json.RawMessage(patch)); err != nil {
			return nil, err
		}
	} else {
		a.publishNow()
	}
	if len(remaining) == 0 {
		a.toast("info", a.tr(textScreenDefault))
	} else {
		a.toast("info", a.tr(textScreenRemoved))
	}
	return nil, nil
}

// ---- the cover push ------------------------------------------------------------------------

// coverPushBlocker is AppModel.coverPushBlocker. Demo mode is a hard no: the
// simulator answers nothing in the 0x021F-0x0221 range.
func (a *App) coverPushBlocker() string {
	a.mu.Lock()
	demo := a.demo
	a.mu.Unlock()
	if demo {
		return "演示模式里没有真实充电器可以写入"
	}
	if a.sess == nil || a.sess.Snapshot().Phase != PhasePolling {
		return "需要先连上充电器"
	}
	return ""
}

// PushCover is AppModel.pushCoverToDevice. acknowledged is the tick on 「我知
// 道推上去的图删不掉」; without it nothing is sent.
func (s *Charker) PushCover(slot int, acknowledged bool) (any, error) {
	a := s.app
	if !acknowledged {
		return nil, nil
	}
	if b := a.coverPushBlocker(); b != "" {
		return nil, devicesError{b}
	}
	dm := a.devices()
	dm.mu.Lock()
	if dm.cover.phase == "running" {
		dm.mu.Unlock()
		return nil, nil
	}
	dm.mu.Unlock()
	base, err := a.modelScreenDir()
	if err != nil {
		return nil, err
	}
	dir := slotDir(base, slot)
	slotCopy := slot
	if _, err := os.Stat(filepath.Join(dir, "source.png")); err != nil {
		a.failCover(&CoverFailureView{Remedy: "nothingWritten", Detail: "这个屏保只剩下模型贴图，没有原图，重新导入一次就能推。"}, &slotCopy)
		return nil, nil
	}
	jpeg, err := os.ReadFile(filepath.Join(dir, "cover.jpg"))
	if err != nil || len(jpeg) == 0 {
		a.failCover(&CoverFailureView{Remedy: "nothingWritten", Detail: "这张图没能转成充电器要的画面。"}, &slotCopy)
		return nil, nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	dm.mu.Lock()
	dm.cover = coverPush{
		phase:    "running",
		slot:     &slotCopy,
		progress: &session.CoverProgress{Stage: session.CoverStageSelecting, ChunkCount: a2687.CoverChunkCount(len(jpeg))},
	}
	dm.cancel = cancel
	dm.mu.Unlock()
	a.publishNow()
	a.toast("info", a.tr(textCoverPushing))

	go func() {
		defer cancel()
		displayed, known, _ := a.sess.ReadCoverPictureID()
		ref := a2687.NewCoverImageReferenceForJPEG(mintCoverPictureID(jpeg, displayed, known), jpeg)
		dm.mu.Lock()
		dm.lastRef = &ref
		dm.mu.Unlock()
		outcome, err := a.sess.PushCover(ctx, jpeg, ref, true, func(p session.CoverProgress) {
			a.noteCoverProgress(p, slotCopy)
		})
		if err != nil {
			a.failCover(classifyCoverFailure(err), &slotCopy)
			return
		}
		log.Printf("devices: cover %s", outcome.Evidence())
		dm.mu.Lock()
		verification := "witnessed"
		if !outcome.Witnessed() {
			verification = "inconclusive"
		}
		dm.cover = coverPush{phase: "done", slot: &slotCopy, verification: verification}
		dm.cancel = nil
		a.noteResidentLocked(dm, slotCopy)
		dm.mu.Unlock()
		a.publishNow()
		if verification == "witnessed" {
			a.toast("info", a.tr(textCoverWitnessed))
		} else {
			a.toast("info", a.tr(textCoverInconclusive))
		}
	}()
	return nil, nil
}

// mintCoverPictureID is AppModel.mintCoverPictureID: stable for the same
// pixels, and never the id the panel already shows.
func mintCoverPictureID(jpeg []byte, displayed uint16, known bool) uint32 {
	low := uint16(a2687.CRC32(jpeg))
	if known && low == displayed {
		low++
	}
	return 0x0001_0000 | uint32(low)
}

func (a *App) noteCoverProgress(p session.CoverProgress, slot int) {
	dm := a.devices()
	dm.mu.Lock()
	if dm.cover.phase != "running" || dm.cover.slot == nil || *dm.cover.slot != slot {
		dm.mu.Unlock()
		return
	}
	cur := dm.cover.progress
	if cur != nil && p.ChunksSent < cur.ChunksSent {
		dm.mu.Unlock()
		return
	}
	final := p.ChunkCount > 0 && p.ChunksSent == p.ChunkCount
	if cur != nil && p.Stage == cur.Stage && !final && time.Since(dm.cover.lastPublish) < 120*time.Millisecond {
		dm.mu.Unlock()
		return
	}
	dm.cover.lastPublish = time.Now()
	pc := p
	dm.cover.progress = &pc
	dm.mu.Unlock()
	a.publishNow()
}

func (a *App) noteResidentLocked(dm *devicesModel, slot int) {
	if dm.synced[slot] {
		return
	}
	dm.synced[slot] = true
	if base, err := a.modelScreenDir(); err == nil {
		dm.persistSyncedLocked(base)
	}
}

func (a *App) failCover(f *CoverFailureView, slot *int) {
	dm := a.devices()
	dm.mu.Lock()
	dm.cover = coverPush{phase: "failed", slot: slot, failure: f}
	dm.cancel = nil
	if f.PixelsMayHaveLanded && slot != nil {
		a.noteResidentLocked(dm, *slot)
	}
	dm.mu.Unlock()
	a.publishNow()
	a.toast("warn", a.tr(remedyNotice(f.Remedy)))
}

// classifyCoverFailure groups a failure by what the user can do about it.
func classifyCoverFailure(err error) *CoverFailureView {
	var ce *session.CoverTransferError
	if !errors.As(err, &ce) {
		log.Printf("devices: cover failed before the first frame: %v", err)
		return &CoverFailureView{Remedy: "nothingWritten", Detail: describeError(err)}
	}
	log.Printf("devices: cover failed: %s", ce.Diagnostic())
	f := &CoverFailureView{PixelsMayHaveLanded: ce.PixelsMayHaveLanded()}
	switch ce.Kind {
	case session.CoverEmptyImage, session.CoverTooManyChunks, session.CoverAlreadyRunning,
		session.CoverIrreversibilityNotAcknowledged, session.CoverHashMismatch,
		session.CoverSelectUnanswered, session.CoverStartUnanswered:
		f.Remedy = "nothingWritten"
	case session.CoverSelectRejected, session.CoverStartRejected:
		f.Remedy = "nothingWritten"
		f.SuggestsCloudID = true
	case session.CoverCancelled, session.CoverBudgetExhausted:
		if ce.Sent == 0 {
			f.Remedy = "nothingWritten"
			f.PixelsMayHaveLanded = false
		} else {
			f.Remedy = "interrupted"
		}
	case session.CoverChunkSendFailed, session.CoverAcknowledgementTimedOut, session.CoverChunkRejected:
		f.Remedy = "interrupted"
	case session.CoverProgressMismatch:
		f.Remedy = "lostSlices"
	case session.CoverNotShownAfterTransfer:
		f.Remedy = "selectionDidNotTake"
	}
	f.Detail = coverFailureDetail(ce)
	return f
}

// coverFailureDetail is AppModel.coverFailureDetail: a cause the user can
// act on, or nothing.
func coverFailureDetail(ce *session.CoverTransferError) string {
	switch ce.Kind {
	case session.CoverEmptyImage, session.CoverTooManyChunks:
		return "这张图推不过去，换一张试试。"
	case session.CoverAlreadyRunning:
		return "上一次推送还没结束。"
	case session.CoverSelectUnanswered, session.CoverStartUnanswered:
		return "充电器没有回应。"
	case session.CoverSelectRejected, session.CoverStartRejected:
		return "充电器拒绝了这张图。"
	case session.CoverChunkSendFailed, session.CoverAcknowledgementTimedOut, session.CoverBudgetExhausted:
		return "传到一半中断了。"
	case session.CoverChunkRejected:
		return "充电器中途报错，停下了。"
	case session.CoverNotShownAfterTransfer:
		return "先去看一眼充电器的屏幕：如果它已经换了，就不用再管。"
	}
	return ""
}

// CancelCoverPush stops at the next slice boundary. It cannot unsend anything.
func (s *Charker) CancelCoverPush() (any, error) {
	dm := s.app.devices()
	dm.mu.Lock()
	if dm.cover.phase != "running" || dm.cover.stopping {
		dm.mu.Unlock()
		return nil, nil
	}
	dm.cover.stopping = true
	cancel := dm.cancel
	dm.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	s.app.publishNow()
	return nil, nil
}

// DismissCoverPushResult closes a finished push's card.
func (s *Charker) DismissCoverPushResult() (any, error) {
	dm := s.app.devices()
	dm.mu.Lock()
	if dm.cover.phase != "running" {
		dm.cover = coverPush{phase: "idle"}
	}
	dm.mu.Unlock()
	s.app.publishNow()
	return nil, nil
}

// RetryCoverSelection re-sends 0x021F after a push whose pixels all landed
// and whose screen did not change. No pixels move, so it needs no gate.
func (s *Charker) RetryCoverSelection() (any, error) {
	a := s.app
	dm := a.devices()
	dm.mu.Lock()
	if dm.cover.phase != "failed" || dm.cover.failure == nil || dm.cover.failure.Remedy != "selectionDidNotTake" || dm.lastRef == nil {
		dm.mu.Unlock()
		return nil, nil
	}
	dm.mu.Unlock()
	if b := a.coverPushBlocker(); b != "" {
		return nil, devicesError{b}
	}
	dm.mu.Lock()
	ref := *dm.lastRef
	slot := dm.cover.slot
	dm.cover = coverPush{phase: "running", slot: slot, progress: &session.CoverProgress{Stage: session.CoverStageSelecting}}
	dm.mu.Unlock()
	a.publishNow()
	go func() {
		reported, known, err := a.sess.SelectCover(ref)
		if err != nil {
			detail := describeError(err)
			cloud := false
			var ce *session.CoverTransferError
			if errors.As(err, &ce) {
				detail = coverFailureDetail(ce)
				cloud = ce.Kind == session.CoverSelectRejected
			}
			a.failCover(&CoverFailureView{Remedy: "selectionDidNotTake", Detail: detail, SuggestsCloudID: cloud, PixelsMayHaveLanded: true}, slot)
			return
		}
		if !known || reported != ref.ReportedID() {
			detail := "又试了一次，充电器的屏幕还是没换过来。"
			if !known {
				detail = "没能确认屏幕换了没有。去看一眼充电器：如果已经换了，就不用再管。"
			}
			dm.mu.Lock()
			dm.cover = coverPush{phase: "failed", slot: slot, failure: &CoverFailureView{
				Remedy: "selectionDidNotTake", Detail: detail, SuggestsCloudID: known, PixelsMayHaveLanded: true,
			}}
			dm.mu.Unlock()
			a.publishNow()
			return
		}
		dm.mu.Lock()
		dm.cover = coverPush{phase: "reselected", slot: slot}
		dm.mu.Unlock()
		a.publishNow()
		a.toast("info", a.tr(textCoverReselected))
	}()
	return nil, nil
}

// ---- Go-side copy (toasts) ------------------------------------------------------------------

var (
	textScreenApplied     = translated{"已应用自定义模型屏保", "Custom Model Screen Applied"}
	textScreenDefault     = translated{"已恢复 Anker Prime 默认屏保", "Restored the Default Anker Prime Screen"}
	textScreenRemoved     = translated{"已移除自定义模型屏保", "Custom Model Screen Removed"}
	textCoverPushing      = translated{"正在把屏保推到充电器…", "Pushing the screen to the charger…"}
	textCoverWitnessed    = translated{"充电器的屏幕已经换成这张图", "The charger's display now shows this picture"}
	textCoverInconclusive = translated{"图已经发完，但没能证明充电器的屏幕真换了", "The picture went out in full, but nothing proves the charger's display actually changed"}
	textCoverReselected   = translated{"充电器已经切到这张封面", "The charger switched to this cover"}
)

func remedyNotice(remedy string) translated {
	switch remedy {
	case "interrupted":
		return translated{"屏保没推完，已经写进去的部分留在充电器里", "The push did not finish; what was written stays inside the charger"}
	case "lostSlices":
		return translated{"屏保没有传完整，充电器不会显示它", "The screen did not arrive complete, so the charger will not show it"}
	case "selectionDidNotTake":
		return translated{"图已经传进充电器，没看到屏幕换过来", "The picture is inside the charger; its display has not been seen to change"}
	}
	return translated{"屏保没能推上去，充电器里什么都没写进去", "The screen could not be pushed; nothing was written to the charger"}
}
