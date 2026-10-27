package anker

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"charker/internal/a2687"
)

// Anker's API servers. No other host is ever contacted with a credential.
const (
	EUServer  = "https://ankerpower-api-eu.anker.com"
	ComServer = "https://ankerpower-api.anker.com"
	CNServer  = "https://aiot-api-cn.anker.com.cn"
)

// serverPublicKeyHex is Anker's fixed login public key, an uncompressed P-256
// point. The password is encrypted to it so it is never on the wire in the
// clear, even inside TLS.
const serverPublicKeyHex = "04c5c00c4f8d1197cc7c3167c52bf7acb054d722f0ef08dcd7e0883236e0d72a" +
	"3868d9750cb47fa4619248f3d83f0f662671dadc6e2d31c2f41db0161651c7c076"

// comCountries are served by the `.com` endpoint. This is the Anker charging
// app's own table (3.23.0, SpUtilImpl.getLocalHostByRegion), and
// /passport/estimate_domain agrees with it. anker-solix-api's longer list
// belongs to the Solix product line: HK, TW, SG, KR and the rest are
// EU-served here, and logging them in to `.com` succeeds but lists no devices.
var comCountries = map[string]bool{
	"AR": true, "AU": true, "BR": true, "CA": true, "MX": true, "NZ": true, "US": true,
}

// ServerBase picks the server for a country code. The code is also sent as
// the `ab` field of the login body.
func ServerBase(country string) string {
	c := strings.ToUpper(country)
	if c == "CN" {
		return CNServer
	}
	if comCountries[c] {
		return ComServer
	}
	return EUServer
}

// IsEUServed reports whether the country signs in on the EU server.
func IsEUServed(country string) bool { return ServerBase(country) == EUServer }

// overseasServer maps the `domain` of a login response onto the fixed
// overseas allowlist. Anker sends it with or without a scheme; anything else
// is ignored so a response can never point the password or token at another
// host.
func overseasServer(domain string) string {
	d := strings.ToLower(strings.TrimSpace(domain))
	if d == "" {
		return ""
	}
	if !strings.HasPrefix(d, "https://") {
		d = "https://" + d
	}
	d = strings.TrimRight(d, "/")
	if d == EUServer || d == ComServer {
		return d
	}
	return ""
}

// homeServer is the overseas server a login response says the account
// belongs to: an explicit `domain` if Anker sent one, otherwise the server of
// the account's own `ab_code`. A CN code is ignored — the mainland service
// signs in by phone, so an email login is never replayed there. Like the
// official app, a code outside the country table leaves the route alone
// rather than falling through to EU.
func homeServer(data map[string]any) string {
	if data == nil {
		return ""
	}
	if s, ok := data["domain"].(string); ok {
		if named := overseasServer(s); named != "" {
			return named
		}
	}
	code, ok := data["ab_code"].(string)
	if !ok {
		return ""
	}
	if _, known := RegionNamed(code); !known {
		return ""
	}
	mapped := ServerBase(code)
	if mapped == CNServer {
		return ""
	}
	return mapped
}

// Account is the public account identity used by the A2687 BLE handshake and
// the cloud UI. Authentication material lives separately in Authentication so
// code that only needs the id cannot accidentally retain a token.
type Account struct {
	UserID   string `json:"userID"`
	Nickname string `json:"nickname,omitempty"`
}

// Authentication is what Anker's HTTP and MQTT bootstrap APIs need.
//
// AuthToken is a credential: keep it in memory or in a CredentialStore, never
// in preferences, diagnostics or command-line arguments. String() redacts it.
// The account password is deliberately absent and cannot be recovered.
type Authentication struct {
	Account        Account
	AuthToken      string
	TokenExpiresAt time.Time
	RegionCode     string
	chinaService   bool
	// server is the overseas server that actually issued the token, when
	// Anker's login response named one. Empty for CN and old records.
	server string
}

// NewAuthentication builds an authentication record. server is validated
// against the overseas allowlist and dropped for CN.
func NewAuthentication(account Account, token string, expiresAt time.Time, region, server string) Authentication {
	a := Authentication{
		Account:        account,
		AuthToken:      token,
		TokenExpiresAt: expiresAt,
		RegionCode:     strings.ToUpper(region),
	}
	a.chinaService = a.RegionCode == "CN"
	if !a.chinaService {
		a.server = overseasServer(server)
	}
	return a
}

// ServerBase is the API origin this token belongs to.
func (a Authentication) ServerBase() string {
	if a.server != "" {
		return a.server
	}
	// Records saved without a server follow the current table. For the
	// countries that moved from `.com` to EU that is the point: `.com` never
	// listed their devices, and if EU refuses the old token the cloud client
	// reports it as expired and the app asks to sign in again.
	if a.RegionCode == "CN" && !a.chinaService {
		return EUServer
	}
	return ServerBase(a.RegionCode)
}

// IsMainland reports whether the token lives on the mainland server.
func (a Authentication) IsMainland() bool { return a.ServerBase() == CNServer }

// Valid reports whether the token is present and more than a minute from
// expiry at `at`.
func (a Authentication) Valid(at time.Time) bool {
	return a.AuthToken != "" && a.TokenExpiresAt.Sub(at) > time.Minute
}

// String never prints the token.
func (a Authentication) String() string {
	return fmt.Sprintf("Authentication{user: %s, region: %s, server: %s, token: <redacted>, expires: %s}",
		a2687.RedactIdentifier(a.Account.UserID), a.RegionCode, a.ServerBase(), a.TokenExpiresAt.UTC().Format(time.RFC3339))
}

// GoString keeps %#v from dumping the token too.
func (a Authentication) GoString() string { return a.String() }

type authenticationRecord struct {
	Account        Account   `json:"account"`
	AuthToken      string    `json:"authToken"`
	TokenExpiresAt time.Time `json:"tokenExpiresAt"`
	RegionCode     string    `json:"regionCode"`
	ChinaService   *bool     `json:"chinaService,omitempty"`
	Server         string    `json:"server,omitempty"`
}

// MarshalJSON is the credential-store record (the Swift Codable keys).
func (a Authentication) MarshalJSON() ([]byte, error) {
	cs := a.chinaService
	return json.Marshal(authenticationRecord{
		Account:        a.Account,
		AuthToken:      a.AuthToken,
		TokenExpiresAt: a.TokenExpiresAt,
		RegionCode:     a.RegionCode,
		ChinaService:   &cs,
		Server:         a.server,
	})
}

// UnmarshalJSON re-validates the stored server on every load: a stored record
// must not be able to name a host outside the fixed allowlist. A record
// without `chinaService` predates the SMS login: earlier builds allowed CN
// email accounts on the EU host, so it must not be forwarded to CN.
func (a *Authentication) UnmarshalJSON(data []byte) error {
	var r authenticationRecord
	if err := json.Unmarshal(data, &r); err != nil {
		return err
	}
	*a = Authentication{
		Account:        r.Account,
		AuthToken:      r.AuthToken,
		TokenExpiresAt: r.TokenExpiresAt,
		RegionCode:     strings.ToUpper(r.RegionCode),
	}
	if r.ChinaService != nil {
		a.chinaService = *r.ChinaService
	}
	if !a.chinaService {
		a.server = overseasServer(r.Server)
	}
	return nil
}

// LoginErrorKind discriminates LoginError (AnkerLoginError).
type LoginErrorKind int

const (
	LoginErrInvalidEmail LoginErrorKind = iota + 1
	LoginErrInvalidPhoneNumber
	LoginErrInvalidVerificationCode
	LoginErrPhoneLoginRequired
	LoginErrEmptyPassword
	LoginErrNetwork
	LoginErrServer
	LoginErrMalformedResponse
	LoginErrMissingUserID
	LoginErrMissingAuthToken
	LoginErrMissingTokenExpiration
)

// LoginError is a sign-in failure. It never carries the password, the code
// or the token; for SMS requests the server's message is replaced by local
// copy because it can echo account input.
type LoginError struct {
	Kind LoginErrorKind
	// Code is the server or HTTP status code for LoginErrServer.
	Code int
	// HTTPStatus marks a Server error that came from the HTTP status line.
	HTTPStatus bool
	// Message is the server's own message for LoginErrServer, or a local
	// Text for the SMS endpoints; Detail is the network failure.
	Message Text
	Detail  string
}

func (e *LoginError) Error() string { return e.Text().String() }

// Is lets errors.Is match on the kind (and code, for server errors).
func (e *LoginError) Is(target error) bool {
	t, ok := target.(*LoginError)
	if !ok {
		return false
	}
	if t.Kind != e.Kind {
		return false
	}
	return t.Kind != LoginErrServer || t.Code == 0 || t.Code == e.Code
}

// Text is AnkerLoginError.errorDescription.
func (e *LoginError) Text() Text {
	switch e.Kind {
	case LoginErrInvalidPhoneNumber:
		return T("请输入 11 位中国大陆手机号")
	case LoginErrInvalidVerificationCode:
		return T("请输入 6 位短信验证码")
	case LoginErrPhoneLoginRequired:
		return T("中国大陆账号请使用手机号和验证码登录")
	case LoginErrInvalidEmail:
		return T("邮箱格式不对")
	case LoginErrEmptyPassword:
		return T("请输入密码")
	case LoginErrNetwork:
		return T("网络错误：%@", e.Detail)
	case LoginErrServer:
		if e.HTTPStatus {
			return T("服务器返回 HTTP %d", e.Code)
		}
		// The server's own message is the most useful thing here; wrong
		// password and wrong region look nothing alike.
		if e.Message.IsZero() {
			return T("登录失败（代码 %d）", e.Code)
		}
		return T("%@（代码 %d）", e.Message, e.Code)
	case LoginErrMalformedResponse:
		return T("服务器返回了无法解析的内容")
	case LoginErrMissingUserID:
		return T("登录成功，但没有返回账号 ID")
	case LoginErrMissingAuthToken:
		return T("登录成功，但没有返回云端访问令牌")
	case LoginErrMissingTokenExpiration:
		return T("登录成功，但没有返回访问令牌有效期")
	}
	return T("服务器返回了无法解析的内容")
}

func loginErr(kind LoginErrorKind) error { return &LoginError{Kind: kind} }

// newHTTPClient is the ephemeral client the Swift code builds: no cookie jar,
// no redirects (an origin chosen from the fixed allowlist must not forward an
// encrypted password or an auth token to another host), 30 s per request.
func newHTTPClient() *http.Client {
	return &http.Client{
		Timeout: 30 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

// AccountClient signs in to Anker. The password exists for the duration of
// one request and is never logged or persisted.
type AccountClient struct {
	// HTTP is the client used for every request; nil uses a no-redirect,
	// no-cookie, 30 s client. Tests inject a RoundTripper here.
	HTTP *http.Client
	// Now is the clock; nil means time.Now.
	Now func() time.Time
	// Rand feeds the ECDH key generation; nil means crypto/rand.
	Rand io.Reader
}

// NewAccountClient returns a client with the production defaults.
func NewAccountClient() *AccountClient { return &AccountClient{} }

func (c *AccountClient) httpClient() *http.Client {
	if c != nil && c.HTTP != nil {
		return c.HTTP
	}
	return newHTTPClient()
}

func (c *AccountClient) now() time.Time {
	if c != nil && c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

func (c *AccountClient) random() io.Reader {
	if c != nil && c.Rand != nil {
		return c.Rand
	}
	return rand.Reader
}

type loginPayload struct {
	account   Account
	token     string
	expiresAt time.Time
	hasExpiry bool
	region    string
	server    string
}

// Login returns only the account identity (the A2687 BLE handshake needs the
// owner id, not a token).
func (c *AccountClient) Login(ctx context.Context, email, password, country string) (Account, error) {
	p, err := c.emailLogin(ctx, email, password, country)
	if err != nil {
		return Account{}, err
	}
	return p.account, nil
}

// Authenticate performs the same login but keeps the auth token and expiry
// the A2345 cloud bootstrap needs. It fails closed without either.
func (c *AccountClient) Authenticate(ctx context.Context, email, password, country string) (Authentication, error) {
	p, err := c.emailLogin(ctx, email, password, country)
	if err != nil {
		return Authentication{}, err
	}
	return p.authentication()
}

func (p loginPayload) authentication() (Authentication, error) {
	if p.token == "" {
		return Authentication{}, loginErr(LoginErrMissingAuthToken)
	}
	if !p.hasExpiry {
		return Authentication{}, loginErr(LoginErrMissingTokenExpiration)
	}
	return NewAuthentication(p.account, p.token, p.expiresAt, p.region, p.server), nil
}

func (c *AccountClient) emailLogin(ctx context.Context, email, password, country string) (loginPayload, error) {
	email = strings.TrimSpace(email)
	country = strings.ToUpper(strings.TrimSpace(country))
	if country == "CN" {
		return loginPayload{}, loginErr(LoginErrPhoneLoginRequired)
	}
	if !strings.Contains(email, "@") || len([]rune(email)) < 5 {
		return loginPayload{}, loginErr(LoginErrInvalidEmail)
	}
	if password == "" {
		return loginPayload{}, loginErr(LoginErrEmptyPassword)
	}

	private, err := ecdh.P256().GenerateKey(c.random())
	if err != nil {
		return loginPayload{}, loginErr(LoginErrMalformedResponse)
	}
	shared, err := SharedKey(private)
	if err != nil {
		return loginPayload{}, err
	}
	encrypted, err := EncryptPassword(password, shared)
	if err != nil {
		return loginPayload{}, err
	}

	now := c.now()
	_, offset := now.Zone()
	body := map[string]any{
		"ab":                 country,
		"client_secret_info": map[string]string{"public_key": hex.EncodeToString(private.PublicKey().Bytes())},
		"enc":                0,
		"email":              email,
		"password":           encrypted,
		"time_zone":          offset * 1000,
		"transaction":        strconv.FormatInt(now.UnixMilli(), 10),
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return loginPayload{}, loginErr(LoginErrMalformedResponse)
	}

	login := func(server string) (map[string]any, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, server+"/passport/login", bytes.NewReader(payload))
		if err != nil {
			return nil, loginErr(LoginErrMalformedResponse)
		}
		req.Header.Set("content-type", "application/json")
		req.Header.Set("model-type", "DESKTOP")
		req.Header.Set("app-name", "anker_power")
		req.Header.Set("os-type", "android")
		req.Header.Set("country", country)
		req.Header.Set("timezone", GMTString(now))
		return c.execute(req, false)
	}

	server := ServerBase(country)
	root, err := login(server)
	if err != nil {
		return loginPayload{}, err
	}
	// Both overseas servers accept the same account, but the devices live on
	// only one of them, and the account's real region decides which — not
	// the country picked here. The official app re-routes on the `ab_code`
	// of the login response for the same reason. Follow it once; the second
	// response is final so two servers can never bounce a login forever.
	data, _ := root["data"].(map[string]any)
	if home := homeServer(data); home != "" && home != server {
		server = home
		if root, err = login(server); err != nil {
			return loginPayload{}, err
		}
	}
	return parseLoginPayload(root, country, server)
}

func (c *AccountClient) execute(req *http.Request, redactServerMessage bool) (map[string]any, error) {
	if err := req.Context().Err(); err != nil {
		return nil, err
	}
	resp, err := c.httpClient().Do(req)
	if err != nil {
		if ctxErr := req.Context().Err(); ctxErr != nil {
			return nil, ctxErr
		}
		return nil, &LoginError{Kind: LoginErrNetwork, Detail: networkDetail(err)}
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		if ctxErr := req.Context().Err(); ctxErr != nil {
			return nil, ctxErr
		}
		return nil, &LoginError{Kind: LoginErrNetwork, Detail: networkDetail(err)}
	}
	if err := req.Context().Err(); err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, &LoginError{Kind: LoginErrServer, Code: resp.StatusCode, HTTPStatus: true}
	}
	root, ok := decodeObject(data)
	if !ok {
		return nil, loginErr(LoginErrMalformedResponse)
	}
	code := -1
	if n, ok := intValue(root["code"]); ok {
		code = n
	}
	if code != 0 {
		var msg Text
		if redactServerMessage {
			msg = phoneErrorMessage(code)
		} else if s, ok := root["msg"].(string); ok {
			msg = Text{Key: s}
		}
		return nil, &LoginError{Kind: LoginErrServer, Code: code, Message: msg}
	}
	return root, nil
}

// networkDetail strips the request URL from a transport error.
func networkDetail(err error) string {
	var urlErr *url.Error
	if errors.As(err, &urlErr) && urlErr.Err != nil {
		return urlErr.Err.Error()
	}
	return err.Error()
}

// decodeObject decodes a JSON object keeping numbers exact.
func decodeObject(data []byte) (map[string]any, bool) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var root map[string]any
	if err := dec.Decode(&root); err != nil || root == nil {
		return nil, false
	}
	return root, true
}

func intValue(v any) (int, bool) {
	switch n := v.(type) {
	case json.Number:
		i, err := n.Int64()
		if err != nil {
			return 0, false
		}
		return int(i), true
	case float64:
		if n != math.Trunc(n) {
			return 0, false
		}
		return int(n), true
	}
	return 0, false
}

func parseLoginPayload(root map[string]any, country, server string) (loginPayload, error) {
	data, ok := root["data"].(map[string]any)
	if !ok {
		return loginPayload{}, loginErr(LoginErrMalformedResponse)
	}
	userID, _ := data["user_id"].(string)
	if userID == "" {
		return loginPayload{}, loginErr(LoginErrMissingUserID)
	}
	p := loginPayload{
		account: Account{UserID: userID},
		region:  country,
		server:  server,
	}
	p.account.Nickname, _ = data["nick_name"].(string)
	p.token, _ = data["auth_token"].(string)
	p.expiresAt, p.hasExpiry = tokenExpiration(data["token_expires_at"])
	return p, nil
}

// tokenExpiration accepts a number or a numeric string, in seconds or (above
// 1e11) milliseconds.
func tokenExpiration(raw any) (time.Time, bool) {
	var seconds float64
	switch v := raw.(type) {
	case json.Number:
		f, err := v.Float64()
		if err != nil {
			return time.Time{}, false
		}
		seconds = f
	case float64:
		seconds = v
	case string:
		f, err := strconv.ParseFloat(v, 64)
		if err != nil {
			return time.Time{}, false
		}
		seconds = f
	default:
		return time.Time{}, false
	}
	if math.IsNaN(seconds) || math.IsInf(seconds, 0) || seconds <= 0 {
		return time.Time{}, false
	}
	if seconds > 100_000_000_000 {
		seconds /= 1000
	}
	whole, frac := math.Modf(seconds)
	return time.Unix(int64(whole), int64(frac*1e9)), true
}

// --- Mainland China SMS login ---

// IsValidPhoneNumber accepts an 11-digit ASCII number starting with 1.
func IsValidPhoneNumber(value string) bool {
	if len(value) != 11 || value[0] != '1' {
		return false
	}
	return allASCIIDigits(value)
}

// IsValidVerificationCode accepts six ASCII digits (a leading zero included).
func IsValidVerificationCode(value string) bool {
	return len(value) == 6 && allASCIIDigits(value)
}

func allASCIIDigits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// SendPhoneVerificationCode asks Anker to text a login code. One
// user-initiated send, no automatic retry, no account creation.
func (c *AccountClient) SendPhoneVerificationCode(ctx context.Context, phoneNumber string) error {
	phone := strings.TrimSpace(phoneNumber)
	if !IsValidPhoneNumber(phone) {
		return loginErr(LoginErrInvalidPhoneNumber)
	}
	_, err := c.phoneRequest(ctx, "phone_verification_code", map[string]any{"phone_number": phone, "kind": "login"})
	return err
}

// LoginPhone signs in with the SMS code and returns the account identity.
func (c *AccountClient) LoginPhone(ctx context.Context, phoneNumber, verificationCode string) (Account, error) {
	p, err := c.phoneLogin(ctx, phoneNumber, verificationCode)
	if err != nil {
		return Account{}, err
	}
	return p.account, nil
}

// AuthenticatePhone signs in with the SMS code and keeps the token for the
// cloud connection (region CN, mainland server).
func (c *AccountClient) AuthenticatePhone(ctx context.Context, phoneNumber, verificationCode string) (Authentication, error) {
	p, err := c.phoneLogin(ctx, phoneNumber, verificationCode)
	if err != nil {
		return Authentication{}, err
	}
	p.server = ""
	return p.authentication()
}

func (c *AccountClient) phoneLogin(ctx context.Context, phoneNumber, verificationCode string) (loginPayload, error) {
	phone := strings.TrimSpace(phoneNumber)
	code := strings.TrimSpace(verificationCode)
	if !IsValidPhoneNumber(phone) {
		return loginPayload{}, loginErr(LoginErrInvalidPhoneNumber)
	}
	if !IsValidVerificationCode(code) {
		return loginPayload{}, loginErr(LoginErrInvalidVerificationCode)
	}
	key, err := ecdh.P256().GenerateKey(c.random())
	if err != nil {
		return loginPayload{}, loginErr(LoginErrMalformedResponse)
	}
	root, err := c.phoneRequest(ctx, "phone_verification_login", map[string]any{
		"phone_number":       phone,
		"verify_code":        code,
		"client_secret_info": map[string]string{"public_key": hex.EncodeToString(key.PublicKey().Bytes())},
	})
	if err != nil {
		return loginPayload{}, err
	}
	return parseLoginPayload(root, "CN", "")
}

func (c *AccountClient) phoneRequest(ctx context.Context, endpoint string, body map[string]any) (map[string]any, error) {
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, loginErr(LoginErrMalformedResponse)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, CNServer+"/passport/"+endpoint, bytes.NewReader(payload))
	if err != nil {
		return nil, loginErr(LoginErrMalformedResponse)
	}
	for k, v := range chinaHeaders(c.now()) {
		req.Header.Set(k, v)
	}
	return c.execute(req, true)
}

// chinaHeaders are shared with the authenticated CN cloud path, matching the
// tested probe.
func chinaHeaders(now time.Time) map[string]string {
	return map[string]string{
		"Content-Type": "application/json",
		"Model-Type":   "PHONE",
		"App-Name":     "anker_power",
		"App-Version":  "3.23.0",
		"Os-Type":      "android",
		"Country":      "CN",
		"Language":     "zh-Hans",
		"X-App-Key":    "CN",
		"Timezone":     GMTString(now),
		"X-Auth-TS":    strconv.FormatInt(now.Unix(), 10),
	}
}

// phoneErrorMessage replaces the backend's SMS messages, which can echo
// account input, with local copy.
func phoneErrorMessage(code int) Text {
	switch code {
	case 26124:
		return T("该手机号尚未注册，请先在安克 App 注册并绑定设备")
	case 26008, 26125:
		return T("验证码发送失败，请稍后重试")
	}
	return Text{}
}

// --- crypto ---

// SharedKey is the 32-byte ECDH secret between private and Anker's fixed
// login key (the x coordinate, as CryptoKit returns it).
func SharedKey(private *ecdh.PrivateKey) ([]byte, error) {
	raw, err := hex.DecodeString(serverPublicKeyHex)
	if err != nil {
		return nil, loginErr(LoginErrMalformedResponse)
	}
	server, err := ecdh.P256().NewPublicKey(raw)
	if err != nil {
		return nil, loginErr(LoginErrMalformedResponse)
	}
	secret, err := private.ECDH(server)
	if err != nil {
		return nil, loginErr(LoginErrMalformedResponse)
	}
	return secret, nil
}

// EncryptPassword is AES-256-CBC with the 32-byte shared secret as the key and
// its first 16 bytes as the IV, PKCS7 padded, base64 encoded — the shape
// Anker's login expects.
func EncryptPassword(text string, key []byte) (string, error) {
	if len(key) != 32 {
		return "", loginErr(LoginErrMalformedResponse)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", loginErr(LoginErrMalformedResponse)
	}
	plain := []byte(text)
	pad := aes.BlockSize - len(plain)%aes.BlockSize
	plain = append(plain, bytes.Repeat([]byte{byte(pad)}, pad)...)
	out := make([]byte, len(plain))
	cipher.NewCBCEncrypter(block, key[:aes.BlockSize]).CryptBlocks(out, plain)
	return base64.StdEncoding.EncodeToString(out), nil
}

// GMTString formats the local UTC offset at date as "GMT+08:00".
func GMTString(date time.Time) string {
	_, offset := date.Zone()
	sign := "+"
	if offset < 0 {
		sign = "-"
		offset = -offset
	}
	return fmt.Sprintf("GMT%s%02d:%02d", sign, offset/3600, (offset%3600)/60)
}
