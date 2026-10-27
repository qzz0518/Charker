package app

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/bits"
	"strings"
	"sync"

	"charker/internal/a2345"
	"charker/internal/anker"
	"charker/internal/cloudsession"
	"charker/internal/product"

	"github.com/egoist/mygo"
)

// The first-run setup and the Anker account half of AppModel: the product
// and real/demo choice (InitialSetupView), the sign-in sheet for the A2687
// owner id and the A2345 cloud reader (AnkerSignInView), and the 250W's
// connection and settings-card actions (A2345DevicesView,
// A2345SettingsCards). Sign-in results travel as anker.Text so the page
// translates them with tt(). Nothing here logs an address, a phone number,
// a password, a code or a token.

// ---- first-run setup --------------------------------------------------------------

// CompleteInitialSetup is InitialSetupView's last step: product "A2687" or
// "A2345", mode "real" (useBluetoothConnection / useA2345CloudConnection) or
// "demo" (enterDemoMode). The page selects the section afterwards: 设备与连接
// for a real device, 总览 for the simulator.
func (s *Charker) CompleteInitialSetup(productID, mode string) (any, error) {
	a := s.app
	p := product.ParseProduct(productID)
	a.mu.Lock()
	old := a.prefs
	a.mu.Unlock()
	patch := map[string]any{"initialSetupCompleted": true}
	switch mode {
	case "demo":
		patch["demoProduct"] = string(p)
		patch["demoMode"] = true
	case "real":
		patch["demoMode"] = false
		if p == product.ProductA2345 {
			patch["connectionMode"] = "cloud"
		} else {
			patch["connectionMode"] = "bluetooth"
		}
	default:
		return nil, fmt.Errorf("setup: unknown mode %q", mode)
	}
	if err := a.accountSetPrefs(patch); err != nil {
		return nil, err
	}
	if mode == "real" {
		if p == product.ProductA2345 {
			// Already on the cloud reader: the preferences did not change the
			// product, so start it again explicitly.
			if old.InitialSetupCompleted && !old.DemoMode && old.ConnectionMode == "cloud" {
				if eng := a.Cloud(); eng != nil {
					_ = eng.Retry()
				}
			}
		} else {
			_, _ = s.Browse()
		}
	}
	return nil, nil
}

// RestartInitialSetup returns to the product chooser (restartInitialSetup).
// Both connection pages share this way back.
func (s *Charker) RestartInitialSetup() (any, error) {
	return nil, s.app.accountSetPrefs(map[string]any{"initialSetupCompleted": false, "lastSection": "dashboard"})
}

func (a *App) accountSetPrefs(patch map[string]any) error {
	data, err := json.Marshal(patch)
	if err != nil {
		return err
	}
	return a.SetPrefs(data)
}

// ---- sign-in ------------------------------------------------------------------------

// SignInInfo is what the sign-in sheet needs before the first keystroke.
type SignInInfo struct {
	Common []anker.Region `json:"common"`
	Others []anker.Region `json:"others"`
	// DefaultCountry is AppModel.defaultCountryCode.
	DefaultCountry string `json:"defaultCountry"`
}

// SignInResult is one sign-in step. Error is the Mac's message
// (AnkerLoginError.errorDescription); nil with OK false means cancelled.
type SignInResult struct {
	OK       bool        `json:"ok"`
	Error    *anker.Text `json:"error,omitempty"`
	Nickname string      `json:"nickname,omitempty"`
}

// accountModel is the sheet's in-flight request: one at a time, cancelled
// when the sheet closes so a late answer never saves a token or an id.
type accountModel struct {
	mu     sync.Mutex
	gen    uint64
	cancel context.CancelFunc
	// client sends the SMS code and signs in with it when no cloud engine
	// runs (the Mac sheet keeps one AnkerAccountClient for both).
	client *anker.AccountClient
}

var accountModels sync.Map // *App -> *accountModel

func (a *App) accountModel() *accountModel {
	if m, ok := accountModels.Load(a); ok {
		return m.(*accountModel)
	}
	m, _ := accountModels.LoadOrStore(a, &accountModel{client: anker.NewAccountClient()})
	return m.(*accountModel)
}

// accountBegin starts a request, cancelling an earlier one.
func (a *App) accountBegin(parent context.Context) (context.Context, func()) {
	m := a.accountModel()
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithCancel(parent)
	m.mu.Lock()
	if m.cancel != nil {
		m.cancel()
	}
	m.gen++
	gen := m.gen
	m.cancel = cancel
	m.mu.Unlock()
	return ctx, func() {
		cancel()
		m.mu.Lock()
		if m.gen == gen {
			m.cancel = nil
		}
		m.mu.Unlock()
	}
}

// AnkerSignInInfo lists the countries Anker accepts (AnkerRegion) and the
// best guess at the user's.
func (s *Charker) AnkerSignInInfo() SignInInfo {
	return SignInInfo{
		Common:         anker.CommonRegions,
		Others:         anker.OtherRegions,
		DefaultCountry: anker.DefaultCountryCode(accountSystemRegion()),
	}
}

// accountSystemRegion is the region subtag of the first Windows display
// language ("zh-Hans-CN" → "CN"), or "".
func accountSystemRegion() string {
	if !mygo.App.IsReady() {
		return ""
	}
	for _, tag := range mygo.App.PreferredLanguages() {
		parts := strings.FieldsFunc(tag, func(r rune) bool { return r == '-' || r == '_' })
		for i := len(parts) - 1; i > 0; i-- {
			if len(parts[i]) == 2 {
				return strings.ToUpper(parts[i])
			}
		}
	}
	return ""
}

// CancelAnkerSignIn abandons the request in flight (the sheet's 取消).
func (s *Charker) CancelAnkerSignIn() (any, error) {
	m := s.app.accountModel()
	m.mu.Lock()
	if m.cancel != nil {
		m.cancel()
		m.cancel = nil
	}
	m.gen++
	m.mu.Unlock()
	return nil, nil
}

// SendAnkerPhoneCode is step one of the mainland sign-in.
func (s *Charker) SendAnkerPhoneCode(ctx context.Context, phone string) SignInResult {
	a := s.app
	ctx, done := a.accountBegin(ctx)
	defer done()
	var err error
	if eng := a.Cloud(); eng != nil {
		err = eng.SendPhoneVerificationCode(ctx, phone)
	} else {
		err = a.accountModel().client.SendPhoneVerificationCode(ctx, phone)
	}
	return accountResult(ctx, err, "")
}

// SignInAnker signs in with email and password. purpose "a2345" is the
// cloud reader (token kept, connection mode switched to the cloud); anything
// else fetches the A2687 owner id only.
func (s *Charker) SignInAnker(ctx context.Context, purpose, email, password, country string) SignInResult {
	a := s.app
	ctx, done := a.accountBegin(ctx)
	defer done()
	email = strings.TrimSpace(email)
	if purpose == "a2345" {
		return a.accountFinishCloud(ctx,
			func(eng *cloudsession.Engine) (anker.Account, error) { return eng.SignIn(ctx, email, password, country) },
			func(c *anker.AccountClient) (anker.Authentication, error) {
				return c.Authenticate(ctx, email, password, country)
			})
	}
	account, err := anker.NewAccountClient().Login(ctx, email, password, country)
	return a.accountFinishOwnerID(ctx, account, err)
}

// SignInAnkerPhone signs in with the texted code (country CN).
func (s *Charker) SignInAnkerPhone(ctx context.Context, purpose, phone, code string) SignInResult {
	a := s.app
	ctx, done := a.accountBegin(ctx)
	defer done()
	client := a.accountModel().client
	if purpose == "a2345" {
		return a.accountFinishCloud(ctx,
			func(eng *cloudsession.Engine) (anker.Account, error) { return eng.SignInPhone(ctx, phone, code) },
			func(c *anker.AccountClient) (anker.Authentication, error) {
				return client.AuthenticatePhone(ctx, phone, code)
			})
	}
	account, err := client.LoginPhone(ctx, phone, code)
	return a.accountFinishOwnerID(ctx, account, err)
}

// accountFinishOwnerID keeps only the public account id the A2687 handshake
// needs.
func (a *App) accountFinishOwnerID(ctx context.Context, account anker.Account, err error) SignInResult {
	if err == nil {
		err = ctx.Err()
	}
	if err != nil {
		return accountResult(ctx, err, "")
	}
	if err := a.accountSetPrefs(map[string]any{"ownerUserID": account.UserID}); err != nil {
		return accountResult(ctx, err, "")
	}
	a.broadcast("message", anker.T("已获取账号 ID，正在用它重新连接充电器"))
	return SignInResult{OK: true, Nickname: account.Nickname}
}

// accountFinishCloud is finishSignIn(connectA2345: true). The running cloud
// engine stores the token and restarts itself; without one (the 160W is on
// screen) the token goes to the same store and switching the connection mode
// starts the engine, which loads it.
func (a *App) accountFinishCloud(
	ctx context.Context,
	viaEngine func(*cloudsession.Engine) (anker.Account, error),
	direct func(*anker.AccountClient) (anker.Authentication, error),
) SignInResult {
	var account anker.Account
	var err error
	eng := a.Cloud()
	a.mu.Lock()
	engineIsDemo := a.demo
	a.mu.Unlock()
	if eng != nil && !engineIsDemo {
		account, err = viaEngine(eng)
	} else {
		var auth anker.Authentication
		auth, err = direct(a.accountModel().client)
		if err == nil {
			err = ctx.Err()
		}
		if err == nil {
			err = a.accountCredentialStore().Save(auth)
		}
		account = auth.Account
	}
	if err != nil {
		return accountResult(ctx, err, "")
	}
	// Keeping the public id also means switching back to this account's
	// A2687 later does not need another sign-in.
	if err := a.accountSetPrefs(map[string]any{
		"ownerUserID":    account.UserID,
		"connectionMode": "cloud",
		"demoMode":       false,
	}); err != nil {
		return accountResult(ctx, err, "")
	}
	if eng == nil || engineIsDemo {
		a.broadcast("message", anker.T("账号已验证，正在连接 A2345"))
	}
	return SignInResult{OK: true, Nickname: account.Nickname}
}

// accountCredentialStore is the store the cloud engine reads (cloud.go).
func (a *App) accountCredentialStore() anker.CredentialStore {
	if a.dataDir != "" {
		return anker.NewFileStore(a.dataDir)
	}
	return &anker.MemoryStore{}
}

// accountResult maps an error to the sheet's message; a cancelled request
// reports nothing.
func accountResult(ctx context.Context, err error, nickname string) SignInResult {
	if err == nil {
		return SignInResult{OK: true, Nickname: nickname}
	}
	if ctx.Err() != nil || errors.Is(err, context.Canceled) {
		return SignInResult{}
	}
	t := anker.TextOf(err)
	return SignInResult{Error: &t}
}

// ---- A2345 connection -----------------------------------------------------------

// accountCloud returns the running engine, or a refusal when the 250W is
// not on screen.
func (a *App) accountCloud() (*cloudsession.Engine, error) {
	if eng := a.Cloud(); eng != nil {
		return eng, nil
	}
	return nil, errors.New("a2345: the cloud session is not running")
}

// accountRun runs one engine action. A refusal (a blocker) becomes the
// action message, as the Mac's setters report it.
func (a *App) accountRun(fn func(*cloudsession.Engine) error) (any, error) {
	eng, err := a.accountCloud()
	if err != nil {
		return nil, err
	}
	err = fn(eng)
	var refusal *cloudsession.Refusal
	if errors.As(err, &refusal) {
		a.broadcast("message", refusal.Text())
		return nil, nil
	}
	if err != nil {
		var l anker.Localized
		if errors.As(err, &l) {
			a.broadcast("message", l.Text())
			return nil, nil
		}
	}
	return nil, err
}

// ForgetA2345Account deletes the stored token and stops the cloud reader
// (forgetA2345Account). The engine reports the outcome.
func (s *Charker) ForgetA2345Account() (any, error) {
	return s.app.accountRun((*cloudsession.Engine).ForgetAccount)
}

// RetryA2345 is retryA2345Connection.
func (s *Charker) RetryA2345() (any, error) {
	a := s.app
	a.mu.Lock()
	mode := a.prefs.ConnectionMode
	a.mu.Unlock()
	if mode != "cloud" {
		return nil, a.accountSetPrefs(map[string]any{"initialSetupCompleted": true, "demoMode": false, "connectionMode": "cloud"})
	}
	return a.accountRun((*cloudsession.Engine).Retry)
}

// SelectA2345Device switches to another charger bound to the account.
func (s *Charker) SelectA2345Device(serial string) (any, error) {
	return s.app.accountRun(func(e *cloudsession.Engine) error { return e.SelectDevice(serial) })
}

// ---- A2345 settings cards -------------------------------------------------------

// SetA2345ChargingMode selects a preset: 1 smart allocation, 2 port
// priority, 3 dual laptop, 4 trickle. Stored custom profiles go through
// ApplyA2345ChargingMode (service_a2345.go).
func (s *Charker) SetA2345ChargingMode(code int) (any, error) {
	if code < 1 || code > 4 {
		return nil, fmt.Errorf("a2345: charging mode %d", code)
	}
	return s.app.accountRun(func(e *cloudsession.Engine) error {
		return e.SetChargingMode(a2345.ChargingMode(code))
	})
}

// SetA2345PortPriority sets the preferred C ports (bit0…bit3, at most two).
func (s *Charker) SetA2345PortPriority(bitmap int) (any, error) {
	if bitmap < 0 || bitmap > 0x0F || bits.OnesCount(uint(bitmap)) > 2 {
		return nil, fmt.Errorf("a2345: port priority %#x", bitmap)
	}
	return s.app.accountRun(func(e *cloudsession.Engine) error { return e.SetPortPriority(byte(bitmap)) })
}

// SetA2345ScreenTimeout: 0 always on, 1 30 s, 2 1 min, 3 5 min, 4 30 min.
func (s *Charker) SetA2345ScreenTimeout(code int) (any, error) {
	if code < 0 || code > 4 {
		return nil, fmt.Errorf("a2345: screen timeout %d", code)
	}
	return s.app.accountRun(func(e *cloudsession.Engine) error {
		return e.SetScreenTimeout(a2345.ScreenTimeout(code))
	})
}

// SetA2345Brightness: 20…100 in steps of five.
func (s *Charker) SetA2345Brightness(percent int) (any, error) {
	return s.app.accountRun(func(e *cloudsession.Engine) error { return e.SetBrightness(percent) })
}

// SetA2345KnobDirection: 0 forward, 1 backward.
func (s *Charker) SetA2345KnobDirection(code int) (any, error) {
	if code != 0 && code != 1 {
		return nil, fmt.Errorf("a2345: knob direction %d", code)
	}
	return s.app.accountRun(func(e *cloudsession.Engine) error {
		return e.SetKnobDirection(a2345.KnobDirection(code))
	})
}

// SetA2345ClockEnabled switches the clock screensaver.
func (s *Charker) SetA2345ClockEnabled(on bool) (any, error) {
	return s.app.accountRun(func(e *cloudsession.Engine) error { return e.SetClockEnabled(on) })
}

// SetA2345HourFormat: 0 12-hour, 1 24-hour.
func (s *Charker) SetA2345HourFormat(code int) (any, error) {
	if code != 0 && code != 1 {
		return nil, fmt.Errorf("a2345: hour format %d", code)
	}
	return s.app.accountRun(func(e *cloudsession.Engine) error {
		return e.SetHourFormat(a2345.HourFormat(code))
	})
}

// SetA2345ClockSchedule sets when the clock shows (weekdays bit0 = Monday).
func (s *Charker) SetA2345ClockSchedule(in cloudsession.ClockSchedule) (any, error) {
	if in.StartHour < 0 || in.StartHour > 23 || in.EndHour < 0 || in.EndHour > 23 ||
		in.StartMinute < 0 || in.StartMinute > 59 || in.EndMinute < 0 || in.EndMinute > 59 {
		return nil, errors.New("a2345: clock schedule out of range")
	}
	sched := a2345.ClockSchedule{
		StartHour: byte(in.StartHour), StartMinute: byte(in.StartMinute),
		EndHour: byte(in.EndHour), EndMinute: byte(in.EndMinute),
		Weekdays: byte(in.Weekdays & 0x7F),
	}
	return s.app.accountRun(func(e *cloudsession.Engine) error { return e.SetClockSchedule(sched) })
}

// SetA2345HolidayTheme switches the holiday screensaver.
func (s *Charker) SetA2345HolidayTheme(on bool) (any, error) {
	return s.app.accountRun(func(e *cloudsession.Engine) error { return e.SetHolidayTheme(on) })
}

// SetA2345CustomImageTimeDisplay shows the time over the user's picture.
func (s *Charker) SetA2345CustomImageTimeDisplay(on bool) (any, error) {
	return s.app.accountRun(func(e *cloudsession.Engine) error { return e.SetCustomImageTimeDisplay(on) })
}

// SetA2345UFCS switches UFCS.
func (s *Charker) SetA2345UFCS(on bool) (any, error) {
	return s.app.accountRun(func(e *cloudsession.Engine) error { return e.SetUFCS(on) })
}

// SetA2345CustomModeEnabled is the 实验室 custom charging mode switch.
func (s *Charker) SetA2345CustomModeEnabled(on bool) (any, error) {
	return s.app.accountRun(func(e *cloudsession.Engine) error { return e.SetCustomModeEnabled(on) })
}

// SetA2345MaxCompatibility is the 最大兼容性 switch.
func (s *Charker) SetA2345MaxCompatibility(on bool) (any, error) {
	return s.app.accountRun(func(e *cloudsession.Engine) error { return e.SetMaxCompatibility(on) })
}

// SetA2345DeviceIdentification is the 充电设备识别 switch.
func (s *Charker) SetA2345DeviceIdentification(on bool) (any, error) {
	return s.app.accountRun(func(e *cloudsession.Engine) error { return e.SetDeviceIdentification(on) })
}

// ApplyA2345BuiltInStyle shows built-in clock style 0, 1 or 2.
func (s *Charker) ApplyA2345BuiltInStyle(kind int) (any, error) {
	if kind < 0 || kind > 2 {
		return nil, fmt.Errorf("a2345: built-in style %d", kind)
	}
	return s.app.accountRun(func(e *cloudsession.Engine) error {
		return e.ApplyBuiltInStyle(a2345.ThemeKind(kind))
	})
}

// accountTheme finds a cloud theme or custom picture of the snapshot.
func accountTheme(e *cloudsession.Engine, id uint32, custom bool) (anker.CloudTheme, bool) {
	snap := e.Snapshot()
	list := snap.A2345.Themes
	if custom {
		list = snap.A2345.CustomPictures
	}
	for _, t := range list {
		if t.ID == id {
			return t, true
		}
	}
	return anker.CloudTheme{}, false
}

// ApplyA2345PictureTheme applies a cloud theme or, with custom, one of the
// user's pictures; the charger downloads it itself.
func (s *Charker) ApplyA2345PictureTheme(id uint32, custom bool) (any, error) {
	return s.app.accountRun(func(e *cloudsession.Engine) error {
		theme, ok := accountTheme(e, id, custom)
		if !ok {
			return nil
		}
		return e.ApplyPictureTheme(theme)
	})
}

// UploadA2345Picture uploads a prepared 480×200 JPEG (base64; the page
// crops and compresses it like A2345PictureEncoder).
func (s *Charker) UploadA2345Picture(jpegBase64 string) (any, error) {
	if i := strings.IndexByte(jpegBase64, ','); i >= 0 && strings.HasPrefix(jpegBase64, "data:") {
		jpegBase64 = jpegBase64[i+1:]
	}
	data, err := base64.StdEncoding.DecodeString(jpegBase64)
	if err != nil || len(data) < 4 || data[0] != 0xFF || data[1] != 0xD8 {
		return nil, errors.New("a2345: the picture is not a JPEG")
	}
	return s.app.accountRun(func(e *cloudsession.Engine) error { return e.UploadCustomPicture(data) })
}

// DeleteA2345Picture removes one of the user's pictures.
func (s *Charker) DeleteA2345Picture(id uint32) (any, error) {
	return s.app.accountRun(func(e *cloudsession.Engine) error {
		theme, ok := accountTheme(e, id, true)
		if !ok {
			return nil
		}
		return e.DeleteCustomPicture(theme)
	})
}

// ReloadA2345Pictures fetches the picture list again (its links expire).
func (s *Charker) ReloadA2345Pictures() (any, error) {
	return s.app.accountRun((*cloudsession.Engine).ReloadCustomPictures)
}
