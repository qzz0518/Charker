package anker

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode"

	"charker/internal/a2687"
)

// CloudErrorKind discriminates CloudError (AnkerCloudError).
type CloudErrorKind int

const (
	CloudErrExpiredAuthentication CloudErrorKind = iota + 1
	CloudErrInvalidEndpoint
	CloudErrInvalidRequestBody
	CloudErrNetwork
	CloudErrHTTPStatus
	CloudErrServer
	CloudErrMalformedResponse
	CloudErrMissingMQTTCredentials
	CloudErrInvalidMQTTTopicComponent
)

// CloudError is an authenticated cloud request failure.
type CloudError struct {
	Kind    CloudErrorKind
	Code    int
	Message string
	Detail  string
}

func (e *CloudError) Error() string { return e.Text().String() }

// Is matches on the kind, so errors.Is(err, ErrExpiredAuthentication) works.
func (e *CloudError) Is(target error) bool {
	t, ok := target.(*CloudError)
	return ok && t.Kind == e.Kind && (t.Code == 0 || t.Code == e.Code)
}

// Text is AnkerCloudError.errorDescription.
func (e *CloudError) Text() Text {
	switch e.Kind {
	case CloudErrExpiredAuthentication:
		return T("Anker 登录已过期，请重新登录。")
	case CloudErrInvalidEndpoint:
		return T("云端接口地址无效。")
	case CloudErrInvalidRequestBody:
		return T("无法编码云端请求。")
	case CloudErrNetwork:
		return T("网络错误：%@", e.Detail)
	case CloudErrHTTPStatus:
		return T("服务器返回 HTTP %d", e.Code)
	case CloudErrServer:
		if e.Message == "" {
			return T("请求失败（代码 %d）", e.Code)
		}
		return T("%@（代码 %d）", e.Message, e.Code)
	case CloudErrMalformedResponse:
		return T("服务器返回了无法解析的内容")
	case CloudErrMissingMQTTCredentials:
		return T("服务器没有返回完整的 MQTT 临时凭据。")
	case CloudErrInvalidMQTTTopicComponent:
		return T("设备身份包含无法用于 MQTT 主题的字符。")
	}
	return T("服务器返回了无法解析的内容")
}

// ErrExpiredAuthentication matches (errors.Is) every expired/revoked-token
// failure: the app deletes the stored record and asks to sign in again.
var ErrExpiredAuthentication error = &CloudError{Kind: CloudErrExpiredAuthentication}

func cloudErr(kind CloudErrorKind) error { return &CloudError{Kind: kind} }

// BoundDevice is one charger bound to the account (get_relate_and_bind_devices).
type BoundDevice struct {
	DeviceSerial    string `json:"device_sn"`
	ProductCode     string `json:"product_code"`
	DeviceName      string `json:"device_name,omitempty"`
	AliasName       string `json:"alias_name,omitempty"`
	WiFiOnline      *bool  `json:"wifi_online,omitempty"`
	SoftwareVersion string `json:"device_sw_version,omitempty"`
	OwnerUserID     string `json:"owner_user_id,omitempty"`
}

// DisplayName is the alias, else the device name, else the product code.
func (d BoundDevice) DisplayName() string {
	if d.AliasName != "" {
		return d.AliasName
	}
	if d.DeviceName != "" {
		return d.DeviceName
	}
	return d.ProductCode
}

func (d *BoundDevice) UnmarshalJSON(data []byte) error {
	var raw struct {
		DeviceSerial    *string `json:"device_sn"`
		ProductCode     *string `json:"product_code"`
		DeviceName      *string `json:"device_name"`
		AliasName       *string `json:"alias_name"`
		WiFiOnline      flex    `json:"wifi_online"`
		SoftwareVersion *string `json:"device_sw_version"`
		OwnerUserID     *string `json:"owner_user_id"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	if raw.DeviceSerial == nil || raw.ProductCode == nil {
		return errors.New("anker: bound device without serial or product code")
	}
	*d = BoundDevice{DeviceSerial: *raw.DeviceSerial, ProductCode: *raw.ProductCode}
	if raw.DeviceName != nil {
		d.DeviceName = *raw.DeviceName
	}
	if raw.AliasName != nil {
		d.AliasName = *raw.AliasName
	}
	if b, ok := raw.WiFiOnline.boolean(); ok {
		d.WiFiOnline = &b
	}
	if raw.SoftwareVersion != nil {
		d.SoftwareVersion = *raw.SoftwareVersion
	}
	if raw.OwnerUserID != nil {
		d.OwnerUserID = *raw.OwnerUserID
	}
	return nil
}

// MQTTCredentials is the short-lived client material Anker returns for an AWS
// IoT MQTT session: an ordinary PEM certificate and RSA private key, decoded
// to DER here and kept in memory only. String() redacts them.
type MQTTCredentials struct {
	UserID         string
	AppName        string
	ThingName      string
	CertificateID  string
	Endpoint       string
	CertificateDER []byte
	PrivateKeyDER  []byte
	// PrivateKeyPEMType is "RSA PRIVATE KEY" (PKCS#1) or "PRIVATE KEY" (PKCS#8).
	PrivateKeyPEMType string
}

// String never prints the key material or the full identifiers.
func (c MQTTCredentials) String() string {
	return fmt.Sprintf("MQTTCredentials{app: %s, thing: %s, endpoint: %s, certificate: %d B, key: <redacted>}",
		c.AppName, a2687.RedactIdentifier(c.ThingName), c.Endpoint, len(c.CertificateDER))
}

// GoString keeps %#v from dumping the key.
func (c MQTTCredentials) GoString() string { return c.String() }

// ClientID is the MQTT client identifier: thing name plus a five-digit suffix.
func (c MQTTCredentials) ClientID(randomSuffix uint32) string {
	return fmt.Sprintf("%s_%05d", c.ThingName, randomSuffix%100_000)
}

// SubscriptionTopic is the device's telemetry wildcard topic.
func (c MQTTCredentials) SubscriptionTopic(device BoundDevice) (string, error) {
	if !validTopicComponents(c.AppName, device.ProductCode, device.DeviceSerial) {
		return "", cloudErr(CloudErrInvalidMQTTTopicComponent)
	}
	return "dt/" + c.AppName + "/" + device.ProductCode + "/" + device.DeviceSerial + "/#", nil
}

// CommandTopic is the only MQTT write topic Charker constructs. Its payloads
// can only be built from allowlisted a2345.Command values.
func (c MQTTCredentials) CommandTopic(device BoundDevice) (string, error) {
	if !validTopicComponents(c.AppName, device.ProductCode, device.DeviceSerial) {
		return "", cloudErr(CloudErrInvalidMQTTTopicComponent)
	}
	return "cmd/" + c.AppName + "/" + device.ProductCode + "/" + device.DeviceSerial + "/req", nil
}

func validTopicComponents(values ...string) bool {
	for _, v := range values {
		if v == "" {
			return false
		}
		for i := 0; i < len(v); i++ {
			b := v[i]
			if !(b >= '0' && b <= '9' || b >= 'A' && b <= 'Z' || b >= 'a' && b <= 'z' || b == '-' || b == '_') {
				return false
			}
		}
	}
	return true
}

// TLSCertificate turns the certificate and key into a TLS client identity.
// tls.X509KeyPair also checks that the key belongs to the certificate.
func (c MQTTCredentials) TLSCertificate() (tls.Certificate, error) {
	keyType := c.PrivateKeyPEMType
	if keyType == "" {
		keyType = "RSA PRIVATE KEY"
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: c.CertificateDER})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: keyType, Bytes: c.PrivateKeyDER})
	defer clear(keyPEM)
	return tls.X509KeyPair(certPEM, keyPEM)
}

// Cloud API paths.
const (
	BindDevicesPath = "power_service/v1/app/get_relate_and_bind_devices"
	MQTTInfoPath    = "app/devicemanage/get_user_mqtt_info"
)

// CloudClient makes authenticated requests on the server that issued the
// token. Every request is refused locally once the token is expired.
type CloudClient struct {
	auth Authentication
	http *http.Client
	now  func() time.Time
}

// NewCloudClient builds a client. httpClient nil uses a no-redirect,
// no-cookie, 30 s client; now nil uses time.Now.
func NewCloudClient(auth Authentication, httpClient *http.Client, now func() time.Time) *CloudClient {
	if httpClient == nil {
		httpClient = newHTTPClient()
	}
	if now == nil {
		now = time.Now
	}
	return &CloudClient{auth: auth, http: httpClient, now: now}
}

// IsMainlandAccount reports whether the account lives on the mainland server,
// which is also where mainland-firmware chargers are bound.
func (c *CloudClient) IsMainlandAccount() bool { return c.auth.IsMainland() }

// AccountUserID is the account's own user id.
func (c *CloudClient) AccountUserID() string { return c.auth.Account.UserID }

// BoundDevices lists the account's chargers, filtered case-insensitively by
// productCode unless it is empty.
func (c *CloudClient) BoundDevices(ctx context.Context, productCode string) ([]BoundDevice, error) {
	var payload struct {
		Data []BoundDevice `json:"data"`
	}
	if err := c.post(ctx, BindDevicesPath, struct{}{}, nil, false, &payload); err != nil {
		return nil, err
	}
	if payload.Data == nil {
		payload.Data = []BoundDevice{}
	}
	if productCode == "" {
		return payload.Data, nil
	}
	out := []BoundDevice{}
	for _, d := range payload.Data {
		if strings.EqualFold(d.ProductCode, productCode) {
			out = append(out, d)
		}
	}
	return out, nil
}

// MQTTCredentials fetches the temporary MQTT identity. Malformed PEM fails
// closed without retaining any of the server's text.
func (c *CloudClient) MQTTCredentials(ctx context.Context) (MQTTCredentials, error) {
	var p struct {
		UserID        string `json:"user_id"`
		AppName       string `json:"app_name"`
		ThingName     string `json:"thing_name"`
		CertificateID string `json:"certificate_id"`
		Endpoint      string `json:"endpoint_addr"`
		Certificate   string `json:"certificate_pem"`
		PrivateKey    string `json:"private_key"`
	}
	if err := c.post(ctx, MQTTInfoPath, struct{}{}, nil, false, &p); err != nil {
		return MQTTCredentials{}, err
	}
	defer func() { p.PrivateKey = "" }()
	if p.UserID == "" || p.AppName == "" || p.ThingName == "" || p.CertificateID == "" || !isValidMQTTHost(p.Endpoint) {
		return MQTTCredentials{}, cloudErr(CloudErrMissingMQTTCredentials)
	}
	cert, _, ok := decodePEM(p.Certificate, "CERTIFICATE")
	if !ok {
		return MQTTCredentials{}, cloudErr(CloudErrMissingMQTTCredentials)
	}
	key, keyType, ok := decodePEM(p.PrivateKey, "RSA PRIVATE KEY", "PRIVATE KEY")
	if !ok {
		return MQTTCredentials{}, cloudErr(CloudErrMissingMQTTCredentials)
	}
	return MQTTCredentials{
		UserID:            p.UserID,
		AppName:           p.AppName,
		ThingName:         p.ThingName,
		CertificateID:     p.CertificateID,
		Endpoint:          p.Endpoint,
		CertificateDER:    cert,
		PrivateKeyDER:     key,
		PrivateKeyPEMType: keyType,
	}, nil
}

// decodePEM accepts ordinary PEM line wrapping while rejecting extra text,
// missing boundaries and empty bodies.
func decodePEM(value string, labels ...string) ([]byte, string, bool) {
	for _, label := range labels {
		header := "-----BEGIN " + label + "-----"
		footer := "-----END " + label + "-----"
		h := strings.Index(value, header)
		f := strings.Index(value, footer)
		if h < 0 || f < 0 || h+len(header) > f {
			continue
		}
		if strings.TrimSpace(value[:h]) != "" || strings.TrimSpace(value[f+len(footer):]) != "" {
			continue
		}
		body := strings.Map(func(r rune) rune {
			if unicode.IsSpace(r) {
				return -1
			}
			return r
		}, value[h+len(header):f])
		decoded, err := base64.StdEncoding.DecodeString(body)
		if err != nil || len(decoded) == 0 {
			continue
		}
		return decoded, label, true
	}
	return nil, "", false
}

func isValidMQTTHost(value string) bool {
	if value == "" || strings.ContainsAny(value, "/:#?") {
		return false
	}
	for i := 0; i < len(value); i++ {
		b := value[i]
		if !(b >= '0' && b <= '9' || b >= 'A' && b <= 'Z' || b >= 'a' && b <= 'z' || b == '-' || b == '.') {
			return false
		}
	}
	return true
}

func md5Hex(value string) string {
	sum := md5.Sum([]byte(value))
	return hex.EncodeToString(sum[:])
}

func (c *CloudClient) endpointURL(path string) (string, error) {
	if path == "" || strings.HasPrefix(path, "/") || strings.Contains(path, "..") ||
		strings.Contains(path, "://") || strings.ContainsAny(path, "?#") {
		return "", cloudErr(CloudErrInvalidEndpoint)
	}
	base, err := url.Parse(c.auth.ServerBase())
	if err != nil {
		return "", cloudErr(CloudErrInvalidEndpoint)
	}
	u := *base
	u.Path = "/" + path
	if u.Scheme != base.Scheme || u.Host != base.Host {
		return "", cloudErr(CloudErrInvalidEndpoint)
	}
	return u.String(), nil
}

// post sends one authenticated JSON request and decodes `data` into out. With
// allowsMissingData a null or absent `data` is success (write endpoints).
func (c *CloudClient) post(ctx context.Context, path string, body any, headers map[string]string, allowsMissingData bool, out any) error {
	now := c.now()
	if !c.auth.Valid(now) {
		return ErrExpiredAuthentication
	}
	endpoint, err := c.endpointURL(path)
	if err != nil {
		return err
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return cloudErr(CloudErrInvalidRequestBody)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return cloudErr(CloudErrInvalidEndpoint)
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("model-type", "DESKTOP")
	req.Header.Set("app-name", "anker_power")
	req.Header.Set("os-type", "android")
	req.Header.Set("country", c.auth.RegionCode)
	req.Header.Set("timezone", GMTString(now))
	if c.auth.IsMainland() {
		for k, v := range chinaHeaders(now) {
			req.Header.Set(k, v)
		}
	}
	req.Header.Set("x-auth-token", c.auth.AuthToken)
	req.Header.Set("gtoken", md5Hex(c.auth.Account.UserID))
	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return ctxErr
		}
		return &CloudError{Kind: CloudErrNetwork, Detail: networkDetail(err)}
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return ctxErr
		}
		return &CloudError{Kind: CloudErrNetwork, Detail: networkDetail(err)}
	}
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return ErrExpiredAuthentication
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return &CloudError{Kind: CloudErrHTTPStatus, Code: resp.StatusCode}
	}

	var envelope struct {
		Code    *int            `json:"code"`
		Message *string         `json:"msg"`
		Data    json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil || envelope.Code == nil {
		return cloudErr(CloudErrMalformedResponse)
	}
	// Anker has returned both ordinary HTTP auth statuses and an API-level
	// 26084 for revoked/expired sessions. Normalize these so the app can
	// delete the unusable record and present a real sign-in path instead of
	// retrying the same rejected token.
	switch *envelope.Code {
	case 401, 403, 26_084:
		return ErrExpiredAuthentication
	case 0:
	default:
		msg := ""
		if envelope.Message != nil {
			msg = *envelope.Message
		}
		return &CloudError{Kind: CloudErrServer, Code: *envelope.Code, Message: msg}
	}
	if len(envelope.Data) == 0 || string(envelope.Data) == "null" {
		if allowsMissingData {
			return nil
		}
		return cloudErr(CloudErrMalformedResponse)
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(envelope.Data, out); err != nil {
		return cloudErr(CloudErrMalformedResponse)
	}
	return nil
}

// putSignedUpload uploads raw bytes to a pre-signed storage URL. It carries
// none of the Anker headers: the URL is not on the API host and its signature
// covers only the content type.
func (c *CloudClient) putSignedUpload(ctx context.Context, data []byte, rawURL, contentType string) error {
	u, err := url.Parse(rawURL)
	if err != nil || u.Scheme != "https" || u.Host == "" {
		return cloudErr(CloudErrInvalidEndpoint)
	}
	ctx, cancel := context.WithTimeout(ctx, 120*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, u.String(), bytes.NewReader(data))
	if err != nil {
		return cloudErr(CloudErrInvalidEndpoint)
	}
	req.Header.Set("content-type", contentType)
	req.Header.Set("content-length", strconv.Itoa(len(data)))
	req.ContentLength = int64(len(data))
	client := *c.http
	client.Timeout = 0
	resp, err := client.Do(req)
	if err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return ctxErr
		}
		return &CloudError{Kind: CloudErrNetwork, Detail: networkDetail(err)}
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return &CloudError{Kind: CloudErrHTTPStatus, Code: resp.StatusCode}
	}
	return nil
}
