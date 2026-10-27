package anker

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"charker/internal/a2345"
)

func TestLegacyCNEmailRecordStaysOnEUWhileNewSMSRecordStaysOnCN(t *testing.T) {
	auth := NewAuthentication(Account{UserID: "test"}, "test", farFuture(), "CN", "")
	encoded, _ := json.Marshal(auth)
	var restored Authentication
	if err := json.Unmarshal(encoded, &restored); err != nil || restored.ServerBase() != CNServer {
		t.Fatalf("CN record -> %s (%v)", restored.ServerBase(), err)
	}
	var legacy map[string]any
	_ = json.Unmarshal(encoded, &legacy)
	delete(legacy, "chinaService")
	data, _ := json.Marshal(legacy)
	if err := json.Unmarshal(data, &restored); err != nil || restored.ServerBase() != EUServer {
		t.Fatalf("legacy CN record -> %s", restored.ServerBase())
	}
}

func TestAlreadyCancelledSMSRequestDoesNotSend(t *testing.T) {
	client, stub := stubClient(func(*http.Request, []byte) (int, []byte) { return jsonResponse(t, map[string]any{"code": 0}) })
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err := (&AccountClient{HTTP: client}).SendPhoneVerificationCode(ctx, "13800138000")
	if !errors.Is(err, context.Canceled) || stub.calls != 0 {
		t.Fatalf("err=%v calls=%d", err, stub.calls)
	}
}

func TestSMSRejectsHTTPFailureEvenWithSuccessEnvelope(t *testing.T) {
	client, _ := stubClient(func(*http.Request, []byte) (int, []byte) { return 403, []byte(`{"code":0,"data":{}}`) })
	err := (&AccountClient{HTTP: client}).SendPhoneVerificationCode(context.Background(), "13800138000")
	var le *LoginError
	if !errors.As(err, &le) || le.Kind != LoginErrServer || le.Code != 403 {
		t.Fatalf("err = %v", err)
	}
}

func TestLoginFollowsTheDomainAnkerNamesOnceAndKeepsItForCloudRequests(t *testing.T) {
	client, stub := stubClient(func(r *http.Request, _ []byte) (int, []byte) {
		return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{
			"user_id":          strings.Repeat("e", 40),
			"auth_token":       "token-from-" + r.URL.Host,
			"token_expires_at": 2_000_000_000,
			// The account lives on EU although the picked country says `.com`.
			"domain": "ankerpower-api-eu.anker.com",
		}})
	})
	auth, err := (&AccountClient{HTTP: client}).Authenticate(context.Background(), "a@example.com", "test", "US")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(stub.hosts, []string{"ankerpower-api.anker.com", "ankerpower-api-eu.anker.com"}) {
		t.Fatalf("hosts = %v", stub.hosts)
	}
	if auth.AuthToken != "token-from-ankerpower-api-eu.anker.com" || auth.ServerBase() != EUServer || auth.RegionCode != "US" {
		t.Fatalf("auth = %v", auth)
	}
	data, _ := json.Marshal(auth)
	var restored Authentication
	_ = json.Unmarshal(data, &restored)
	if restored.ServerBase() != EUServer {
		t.Fatalf("restored server = %s", restored.ServerBase())
	}
}

func TestLoginFollowsTheAccountsOwnCountryNotThePickedOne(t *testing.T) {
	// Anker sends `domain` empty in practice; `ab_code` is what the official
	// app re-routes on. Picked US, account registered in Japan.
	respond := func(code string) func(*http.Request, []byte) (int, []byte) {
		return func(*http.Request, []byte) (int, []byte) {
			data := map[string]any{
				"user_id": strings.Repeat("e", 40), "auth_token": "test-token",
				"token_expires_at": 2_000_000_000, "ab_code": code,
			}
			if code == "JP" {
				data["domain"] = ""
			}
			return jsonResponse(t, map[string]any{"code": 0, "data": data})
		}
	}
	client, stub := stubClient(respond("JP"))
	auth, err := (&AccountClient{HTTP: client}).Authenticate(context.Background(), "a@example.com", "test", "US")
	if err != nil || auth.ServerBase() != EUServer ||
		!reflect.DeepEqual(stub.hosts, []string{"ankerpower-api.anker.com", "ankerpower-api-eu.anker.com"}) {
		t.Fatalf("hosts=%v server=%s err=%v", stub.hosts, auth.ServerBase(), err)
	}
	// A mainland or unknown code never moves an email login.
	for _, code := range []string{"CN", "ZZ", ""} {
		client, stub := stubClient(respond(code))
		if _, err := (&AccountClient{HTTP: client}).Authenticate(context.Background(), "a@example.com", "test", "US"); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(stub.hosts, []string{"ankerpower-api.anker.com"}) {
			t.Errorf("%q: hosts = %v", code, stub.hosts)
		}
	}
}

func TestLoginIgnoresADomainOutsideTheAllowlist(t *testing.T) {
	client, stub := stubClient(func(*http.Request, []byte) (int, []byte) {
		return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{
			"user_id": strings.Repeat("e", 40), "auth_token": "test-token",
			"token_expires_at": 2_000_000_000, "domain": "https://ankerpower-api-eu.anker.com.example.org",
		}})
	})
	auth, err := (&AccountClient{HTTP: client}).Authenticate(context.Background(), "a@example.com", "test", "JP")
	if err != nil || auth.ServerBase() != EUServer || !reflect.DeepEqual(stub.hosts, []string{"ankerpower-api-eu.anker.com"}) {
		t.Fatalf("hosts=%v server=%s err=%v", stub.hosts, auth.ServerBase(), err)
	}
	tampered := `{"account":{"userID":"u"},"authToken":"t","tokenExpiresAt":"1970-01-01T00:00:00Z","regionCode":"US","server":"https://example.org"}`
	var decoded Authentication
	if err := json.Unmarshal([]byte(tampered), &decoded); err != nil || decoded.ServerBase() != ComServer {
		t.Fatalf("tampered record -> %s (%v)", decoded.ServerBase(), err)
	}
}

func TestSMSCloudRequiresExpiration(t *testing.T) {
	client, _ := stubClient(func(*http.Request, []byte) (int, []byte) {
		return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{"user_id": "test", "auth_token": "test-token"}})
	})
	_, err := (&AccountClient{HTTP: client}).AuthenticatePhone(context.Background(), "13800138000", "001234")
	if !errors.Is(err, &LoginError{Kind: LoginErrMissingTokenExpiration}) {
		t.Fatalf("err = %v", err)
	}
}

func TestSMSFlowUsesCNAndPreservesLeadingZeroCode(t *testing.T) {
	client, _ := stubClient(func(r *http.Request, body []byte) (int, []byte) {
		if r.URL.Host != "aiot-api-cn.anker.com.cn" || r.Method != http.MethodPost ||
			r.Header.Get("X-App-Key") != "CN" || r.Header.Get("Model-Type") != "PHONE" || r.Header.Get("Openudid") != "" {
			t.Errorf("request %s %s headers %v", r.Method, r.URL, r.Header)
		}
		json := decodeBody(t, body)
		if json["phone_number"] != "13800138000" {
			t.Errorf("phone = %v", json["phone_number"])
		}
		if r.URL.Path == "/passport/phone_verification_code" {
			if len(json) != 2 || json["kind"] != "login" {
				t.Errorf("send body = %v", json)
			}
			return jsonResponse(t, map[string]any{"code": 0})
		}
		if r.URL.Path != "/passport/phone_verification_login" || len(json) != 3 || json["verify_code"] != "001234" {
			t.Errorf("login %s body = %v", r.URL.Path, json)
		}
		secret, _ := json["client_secret_info"].(map[string]any)
		pk, _ := secret["public_key"].(string)
		if len(pk) != 130 || !strings.HasPrefix(pk, "04") {
			t.Errorf("public key %q", pk)
		}
		return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{
			"user_id": strings.Repeat("c", 40), "auth_token": "test-cn-token", "token_expires_at": "2000000000000",
		}})
	})
	c := &AccountClient{HTTP: client}
	if err := c.SendPhoneVerificationCode(context.Background(), "13800138000"); err != nil {
		t.Fatal(err)
	}
	auth, err := c.AuthenticatePhone(context.Background(), "13800138000", "001234")
	if err != nil {
		t.Fatal(err)
	}
	if auth.RegionCode != "CN" || auth.ServerBase() != CNServer || auth.AuthToken != "test-cn-token" ||
		!auth.TokenExpiresAt.Equal(time.Unix(2_000_000_000, 0)) {
		t.Fatalf("auth = %v", auth)
	}
}

func TestSMSFailureDoesNotLeakBackendEchoOrRetry(t *testing.T) {
	client, stub := stubClient(func(*http.Request, []byte) (int, []byte) {
		return jsonResponse(t, map[string]any{"code": 100053, "msg": "13800138000 001234 SECRET_TOKEN"})
	})
	err := (&AccountClient{HTTP: client}).SendPhoneVerificationCode(context.Background(), "13800138000")
	var le *LoginError
	if !errors.As(err, &le) || le.Kind != LoginErrServer || le.Code != 100053 || !le.Message.IsZero() {
		t.Fatalf("err = %#v", err)
	}
	if strings.Contains(err.Error(), "SECRET") || stub.calls != 1 {
		t.Fatalf("leaked or retried: %q, %d calls", err.Error(), stub.calls)
	}
	client, _ = stubClient(func(*http.Request, []byte) (int, []byte) {
		return jsonResponse(t, map[string]any{"code": 26124, "msg": "echo"})
	})
	err = (&AccountClient{HTTP: client}).SendPhoneVerificationCode(context.Background(), "13800138000")
	if got := TextOf(err).String(); got != "该手机号尚未注册，请先在安克 App 注册并绑定设备（代码 26124）" {
		t.Fatalf("text = %q", got)
	}
}

func TestPhoneOwnerIDDoesNotRequireTokenButCloudDoes(t *testing.T) {
	client, _ := stubClient(func(*http.Request, []byte) (int, []byte) {
		return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{"user_id": strings.Repeat("d", 40)}})
	})
	c := &AccountClient{HTTP: client}
	account, err := c.LoginPhone(context.Background(), "13800138000", "001234")
	if err != nil || account.UserID != strings.Repeat("d", 40) {
		t.Fatalf("account = %v %v", account, err)
	}
	if _, err := c.AuthenticatePhone(context.Background(), "13800138000", "001234"); !errors.Is(err, &LoginError{Kind: LoginErrMissingAuthToken}) {
		t.Fatalf("err = %v", err)
	}
}

func TestCNBoundDevicesKeepTokenOnCNHost(t *testing.T) {
	auth := NewAuthentication(Account{UserID: strings.Repeat("c", 40)}, "cn-test", farFuture(), "CN", "")
	client, _ := stubClient(func(r *http.Request, _ []byte) (int, []byte) {
		if r.URL.Host != "aiot-api-cn.anker.com.cn" || r.Header.Get("x-auth-token") != "cn-test" ||
			r.Header.Get("X-App-Key") != "CN" || r.Header.Get("Model-Type") != "PHONE" {
			t.Errorf("request %s %v", r.URL, r.Header)
		}
		return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{"data": []any{}}})
	})
	devices, err := NewCloudClient(auth, client, nil).BoundDevices(context.Background(), "")
	if err != nil || len(devices) != 0 {
		t.Fatalf("devices = %v %v", devices, err)
	}
}

func TestAuthenticatedLoginKeepsTokenAndRegionWhileLegacyLoginStillReturnsAccount(t *testing.T) {
	expiration := time.Unix(2_000_000_000, 0)
	client, _ := stubClient(func(r *http.Request, body []byte) (int, []byte) {
		if r.URL.Host != "ankerpower-api-eu.anker.com" || r.URL.Path != "/passport/login" || r.Header.Get("country") != "JP" {
			t.Errorf("request %s %v", r.URL, r.Header)
		}
		json := decodeBody(t, body)
		if json["ab"] != "JP" || json["password"] == "do-not-send-in-clear" || strings.Contains(string(body), "do-not-send-in-clear") {
			t.Errorf("body leaks or misses ab: %s", body)
		}
		return jsonResponse(t, map[string]any{"code": 0, "msg": "success", "data": map[string]any{
			"user_id": strings.Repeat("a", 40), "nick_name": "tester",
			"auth_token": "test-token", "token_expires_at": expiration.Unix(),
		}})
	})
	c := &AccountClient{HTTP: client}
	auth, err := c.Authenticate(context.Background(), "person@example.com", "do-not-send-in-clear", "jp")
	if err != nil {
		t.Fatal(err)
	}
	if auth.Account.Nickname != "tester" || auth.AuthToken != "test-token" || !auth.TokenExpiresAt.Equal(expiration) ||
		auth.RegionCode != "JP" || auth.ServerBase() != EUServer {
		t.Fatalf("auth = %v", auth)
	}
	legacy, err := c.Login(context.Background(), "person@example.com", "do-not-send-in-clear", "JP")
	if err != nil || legacy.UserID != auth.Account.UserID || legacy.Nickname != "tester" {
		t.Fatalf("legacy = %v %v", legacy, err)
	}
	if strings.Contains(auth.String(), "test-token") || strings.Contains(auth.GoString(), "test-token") {
		t.Fatal("String() leaks the token")
	}
}

func TestLegacyLoginAcceptsAnAccountOnlyResponseButCloudAuthenticationFailsClosed(t *testing.T) {
	client, _ := stubClient(func(*http.Request, []byte) (int, []byte) {
		return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{"user_id": strings.Repeat("b", 40)}})
	})
	c := &AccountClient{HTTP: client}
	if a, err := c.Login(context.Background(), "person@example.com", "password", "JP"); err != nil || a.UserID != strings.Repeat("b", 40) {
		t.Fatalf("login = %v %v", a, err)
	}
	if _, err := c.Authenticate(context.Background(), "person@example.com", "password", "JP"); !errors.Is(err, &LoginError{Kind: LoginErrMissingAuthToken}) {
		t.Fatalf("err = %v", err)
	}
}

func testAuthentication() Authentication {
	return NewAuthentication(Account{UserID: strings.Repeat("a", 40), Nickname: "tester"}, "test-token",
		time.Unix(2_000_000_000, 0), "JP", "")
}

func fixedNow() time.Time { return time.Unix(1_900_000_000, 0) }

func TestBoundDevicesUsesAuthenticatedHeadersAndFiltersA2345(t *testing.T) {
	auth := testAuthentication()
	client, _ := stubClient(func(r *http.Request, body []byte) (int, []byte) {
		if r.URL.Path != "/power_service/v1/app/get_relate_and_bind_devices" || r.Method != http.MethodPost ||
			r.Header.Get("x-auth-token") != "test-token" || r.Header.Get("gtoken") != md5Hex(auth.Account.UserID) ||
			r.Header.Get("country") != "JP" || string(body) != "{}" {
			t.Errorf("request %s %v %s", r.URL, r.Header, body)
		}
		return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{"data": []any{
			map[string]any{
				"device_sn": "SERIALA2345", "product_code": "A2345", "device_name": "Prime Charger",
				"alias_name": "Desk charger", "wifi_online": true, "device_sw_version": "2.1.1.6",
			},
			map[string]any{"device_sn": "SERIALA2687", "product_code": "A2687"},
		}}})
	})
	devices, err := NewCloudClient(auth, client, fixedNow).BoundDevices(context.Background(), "a2345")
	if err != nil || len(devices) != 1 {
		t.Fatalf("devices = %v %v", devices, err)
	}
	d := devices[0]
	if d.DeviceSerial != "SERIALA2345" || d.DisplayName() != "Desk charger" || d.WiFiOnline == nil || !*d.WiFiOnline || d.SoftwareVersion != "2.1.1.6" {
		t.Fatalf("device = %+v", d)
	}
}

func TestMQTTCredentialsDecodePEMIdentityAndBuildAReadTopic(t *testing.T) {
	client, _ := stubClient(func(r *http.Request, _ []byte) (int, []byte) {
		if r.URL.Path != "/app/devicemanage/get_user_mqtt_info" {
			t.Errorf("path %s", r.URL.Path)
		}
		return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{
			"user_id": strings.Repeat("a", 40), "app_name": "anker_power", "thing_name": "thing-name",
			"certificate_id": "certificate-id", "endpoint_addr": "aiot-mqtt-eu.anker.com",
			"certificate_pem": "-----BEGIN CERTIFICATE-----\nAQIDBA==\n-----END CERTIFICATE-----",
			"private_key":     "-----BEGIN RSA PRIVATE KEY-----\nBQYHCA==\n-----END RSA PRIVATE KEY-----",
		}})
	})
	creds, err := NewCloudClient(testAuthentication(), client, fixedNow).MQTTCredentials(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if creds.Endpoint != "aiot-mqtt-eu.anker.com" || !reflect.DeepEqual(creds.CertificateDER, []byte{1, 2, 3, 4}) ||
		!reflect.DeepEqual(creds.PrivateKeyDER, []byte{5, 6, 7, 8}) || creds.PrivateKeyPEMType != "RSA PRIVATE KEY" {
		t.Fatalf("creds = %#v", creds)
	}
	if creds.ClientID(42) != "thing-name_00042" {
		t.Fatalf("client id %q", creds.ClientID(42))
	}
	device := BoundDevice{DeviceSerial: "SERIAL123", ProductCode: "A2345"}
	if s, _ := creds.SubscriptionTopic(device); s != "dt/anker_power/A2345/SERIAL123/#" {
		t.Fatalf("subscription %q", s)
	}
	if s, _ := creds.CommandTopic(device); s != "cmd/anker_power/A2345/SERIAL123/req" {
		t.Fatalf("command %q", s)
	}
	if strings.Contains(creds.String(), "BQYH") || strings.Contains(creds.GoString(), "[5 6 7 8]") {
		t.Fatal("String() leaks the key")
	}
	if _, err := creds.TLSCertificate(); err == nil {
		t.Fatal("garbage DER formed an identity")
	}
}

func TestMQTTCredentialsRejectMalformedPEMWithoutRetainingServerText(t *testing.T) {
	client, _ := stubClient(func(*http.Request, []byte) (int, []byte) {
		return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{
			"user_id": strings.Repeat("a", 40), "app_name": "anker_power", "thing_name": "thing-name",
			"certificate_id": "certificate-id", "endpoint_addr": "aiot-mqtt-eu.anker.com",
			"certificate_pem": "not a certificate", "private_key": "not a private key",
		}})
	})
	_, err := NewCloudClient(testAuthentication(), client, fixedNow).MQTTCredentials(context.Background())
	if !errors.Is(err, &CloudError{Kind: CloudErrMissingMQTTCredentials}) || strings.Contains(err.Error(), "not a") {
		t.Fatalf("err = %v", err)
	}
}

func TestExpiredAuthenticationStopsBeforeNetwork(t *testing.T) {
	client, stub := stubClient(func(*http.Request, []byte) (int, []byte) { return 500, nil })
	auth := testAuthentication()
	auth.TokenExpiresAt = time.Unix(100, 0)
	_, err := NewCloudClient(auth, client, func() time.Time { return time.Unix(200, 0) }).BoundDevices(context.Background(), "")
	if !errors.Is(err, ErrExpiredAuthentication) || stub.calls != 0 {
		t.Fatalf("err=%v calls=%d", err, stub.calls)
	}
}

func TestServerAuthenticationFailuresAreNormalized(t *testing.T) {
	for _, h := range []func(*http.Request, []byte) (int, []byte){
		func(*http.Request, []byte) (int, []byte) { return 401, nil },
		func(*http.Request, []byte) (int, []byte) {
			return jsonResponse(t, map[string]any{"code": 26_084, "msg": "session expired"})
		},
	} {
		client, _ := stubClient(h)
		if _, err := NewCloudClient(testAuthentication(), client, fixedNow).BoundDevices(context.Background(), ""); !errors.Is(err, ErrExpiredAuthentication) {
			t.Fatalf("err = %v", err)
		}
	}
}

func TestAuthenticationRecordContainsNoPasswordField(t *testing.T) {
	encoded, _ := json.Marshal(testAuthentication())
	text := string(encoded)
	if !strings.Contains(text, "test-token") || strings.Contains(strings.ToLower(text), "password") {
		t.Fatalf("record = %s", text)
	}
	var back Authentication
	if err := json.Unmarshal(encoded, &back); err != nil || !reflect.DeepEqual(back, testAuthentication()) {
		t.Fatalf("round trip = %v %v", back, err)
	}
}

func plainAuth() Authentication {
	return NewAuthentication(Account{UserID: "u"}, "t", farFuture(), "JP", "")
}

func TestA2345CloudSettingsReadNestedDeviceSettingAndIdentity(t *testing.T) {
	client, _ := stubClient(func(r *http.Request, body []byte) (int, []byte) {
		if decodeBody(t, body)["device_sn"] != "SN1" {
			t.Errorf("body %s", body)
		}
		switch r.URL.Path {
		case "/mini_power/v1/app/setting/get_device_setting":
			return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{"device_setting": map[string]any{
				"charging_mode_status": 1, "compatibility_status": 0, "charging_device_identity_status": 1,
			}}})
		case "/mini_power/v1/app/setting/get_charging_device_identity_status_default_true":
			return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{"charging_device_identity_status_default_true": 0}})
		}
		t.Errorf("unexpected %s", r.URL.Path)
		return jsonResponse(t, map[string]any{"code": 1})
	})
	s, err := NewCloudClient(plainAuth(), client, nil).A2345CloudSettings(context.Background(), "SN1")
	if err != nil || s.CustomModeEnabled == nil || !*s.CustomModeEnabled || s.MaxCompatibility == nil || *s.MaxCompatibility ||
		s.DeviceIdentification == nil || *s.DeviceIdentification {
		t.Fatalf("settings = %+v %v", s, err)
	}
}

func TestA2345SwitchWritesSendIntegerFlagsAndAcceptNullData(t *testing.T) {
	client, _ := stubClient(func(r *http.Request, body []byte) (int, []byte) {
		b := decodeBody(t, body)
		if r.URL.Path != "/mini_power/v1/app/setting/set_compatibility_status" || b["device_sn"] != "SN1" || b["compatibility_status"] != float64(1) {
			t.Errorf("request %s %s", r.URL.Path, body)
		}
		return 200, []byte(`{"code":0,"msg":"ok","data":null}`)
	})
	if err := NewCloudClient(plainAuth(), client, nil).SetA2345MaxCompatibility(context.Background(), true, "SN1"); err != nil {
		t.Fatal(err)
	}
}

func TestA2345ChargingModesRoundTripTheOfficialShape(t *testing.T) {
	client, _ := stubClient(func(r *http.Request, body []byte) (int, []byte) {
		switch r.URL.Path {
		case "/mini_power/v1/app/charging/get_charging_mode_list":
			return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{"charging_mode_list": []any{map[string]any{
				"id": 42, "number": 2, "name": "Desk", "total_power": 115, "max_total_power": 250,
				"auto_exit": 1, "has_charge_protocol": 1,
				"power_settings": []any{
					map[string]any{"name": "C1", "power": 65, "max_power": 140, "scp": 0, "ufcs": 1, "pd12v": 1, "pps11v": 1, "pps16v": 0, "pps20v": 1, "huawei": 0, "xiaomi": 0},
					map[string]any{"name": "C2", "power": 30, "max_power": 100, "scp": 1, "ufcs": 1, "pd12v": 0, "pps11v": 0, "pps16v": 0, "pps20v": 0, "huawei": 0, "xiaomi": 0},
					map[string]any{"name": "C3", "power": 0, "max_power": 100},
					map[string]any{"name": "C4", "power": 0, "max_power": 100},
					map[string]any{"name": "A", "power": 15, "max_power": 24},
				},
			}}}})
		case "/mini_power/v1/app/charging/update_charging_mode":
			b := decodeBody(t, body)
			if b["id"] != float64(42) || b["device_sn"] != nil || b["number"] != nil || b["auto_exit"] != float64(1) || b["total_power"] != float64(105) {
				t.Errorf("update body %s", body)
			}
			ports, _ := b["power_settings"].([]any)
			first, _ := ports[0].(map[string]any)
			if first["pps20v"] != float64(1) || first["max_power"] != float64(140) {
				t.Errorf("port body %v", first)
			}
			return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{}})
		}
		t.Errorf("unexpected path %s", r.URL.Path)
		return jsonResponse(t, map[string]any{"code": 1})
	})
	c := NewCloudClient(plainAuth(), client, nil)
	modes, err := c.A2345ChargingModes(context.Background(), "SN1")
	if err != nil || len(modes) != 1 {
		t.Fatalf("modes = %v %v", modes, err)
	}
	want := a2345.CustomChargingProfile{Number: 2, AutoExit: true, Watts: []byte{65, 30, 0, 0, 15}}
	if !reflect.DeepEqual(modes[0].Profile(), want) {
		t.Fatalf("profile = %+v", modes[0].Profile())
	}
	p := modes[0].Protocols(false).Ports
	if p[0] != a2345.ProtoUFCS|a2345.ProtoPD12V|a2345.ProtoPPS11V|a2345.ProtoPPS21V || p[1] != a2345.ProtoSCP|a2345.ProtoUFCS {
		t.Fatalf("protocols = %v", p)
	}
	modes[0].PowerSettings[1].Power = 25
	if err := c.UpdateA2345ChargingMode(context.Background(), modes[0]); err != nil {
		t.Fatal(err)
	}
}

func TestA2345ThemesParseHexCRCAndColor(t *testing.T) {
	client, _ := stubClient(func(r *http.Request, body []byte) (int, []byte) {
		if r.URL.Path != "/mini_power/v1/app/style/get_clock_screensavers" || decodeBody(t, body)["product_code"] != "A2345" ||
			r.Header.Get("Language") != "zh-Hans" {
			t.Errorf("request %s %s %v", r.URL.Path, body, r.Header)
		}
		return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{"category": []any{map[string]any{
			"category": 1, "category_name": "Nature",
			"list": []any{map[string]any{"id": "7", "title": "Sea", "image_url": "https://x/s.jpg", "short_url": "s",
				"file_crc32": "0x1A2B3C4D", "text_color": "0xFFFFFF00"}},
		}}}})
	})
	themes, err := NewCloudClient(plainAuth(), client, nil).A2345ClockThemes(context.Background(), ThemeLanguage(true))
	color := uint32(0xFFFF_FF00)
	want := []CloudTheme{{ID: 7, Title: "Sea", Category: "Nature", ImageURL: "https://x/s.jpg", ShortURL: "s",
		CRC32: 0x1A2B_3C4D, TextColor: &color, Kind: a2345.ThemePicture}}
	if err != nil || !reflect.DeepEqual(themes, want) {
		t.Fatalf("themes = %+v %v", themes, err)
	}
}

func TestCustomPicturesReadPrefixedHashCodeAndApplyOverA7(t *testing.T) {
	client, _ := stubClient(func(r *http.Request, body []byte) (int, []byte) {
		if decodeBody(t, body)["sn"] != "SN1" {
			t.Errorf("body %s", body)
		}
		return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{"list": []any{
			map[string]any{"id": 9, "img_url": "https://x/p.jpg", "hash_code": "0x00000010"},
			map[string]any{"id": 10, "img_url": "https://x/q.jpg", "hash_code": "16"},
			map[string]any{"id": 11, "img_url": ""},
		}}})
	})
	pics, err := NewCloudClient(plainAuth(), client, nil).A2345CustomScreensavers(context.Background(), "SN1")
	if err != nil || len(pics) != 2 || pics[0].CRC32 != 16 || pics[1].CRC32 != 16 || pics[0].Kind != a2345.ThemeCustom {
		t.Fatalf("pictures = %+v %v", pics, err)
	}
	r := pics[0].Request(true)
	if r.Kind != a2345.ThemeCustom || r.CustomURL != "https://x/p.jpg" || r.URL != "" || r.ThemeID == nil || *r.ThemeID != 9 {
		t.Fatalf("request = %+v", r)
	}
}

func TestUploadCustomPictureFollowsTheOfficialThreeSteps(t *testing.T) {
	var steps []string
	jpeg := []byte("jpeg-bytes")
	client, _ := stubClient(func(r *http.Request, body []byte) (int, []byte) {
		steps = append(steps, r.Method+" "+r.URL.Host+r.URL.Path)
		switch {
		case r.URL.Path == "/app/cloudstor/get_app_up_token_general":
			b := decodeBody(t, body)
			if r.Header.Get("user_id") != "u" || b["file_size"] != float64(len(jpeg)) || b["type"] != float64(106) {
				t.Errorf("ticket request %v %s", r.Header, body)
			}
			return jsonResponse(t, map[string]any{"code": 0, "data": map[string]any{"uptoken": "https://upload.example.com/slot?sig=1", "key_prefix": "k/abc"}})
		case r.Method == http.MethodPut:
			if r.Header.Get("x-auth-token") != "" || string(body) != string(jpeg) {
				t.Errorf("upload carries Anker headers or wrong body")
			}
			return 200, nil
		default:
			b := decodeBody(t, body)
			if b["img_url"] != "k/abc" || b["hash_code"] != "0x"+strings.ToLower(hex8(CRC32(jpeg))) {
				t.Errorf("register body %s", body)
			}
			return 200, []byte(`{"code":0,"data":null}`)
		}
	})
	if err := NewCloudClient(plainAuth(), client, nil).UploadA2345CustomPicture(context.Background(), jpeg, "SN1"); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"POST ankerpower-api-eu.anker.com/app/cloudstor/get_app_up_token_general",
		"PUT upload.example.com/slot",
		"POST ankerpower-api-eu.anker.com/mini_power/v1/app/style/add_manual_clock_screensavers",
	}
	if !reflect.DeepEqual(steps, want) {
		t.Fatalf("steps = %v", steps)
	}
}

func hex8(v uint32) string {
	const digits = "0123456789abcdef"
	out := make([]byte, 8)
	for i := 7; i >= 0; i-- {
		out[i] = digits[v&0xF]
		v >>= 4
	}
	return string(out)
}

func TestChargingModeTemplateUsesTheOfficialDefaults(t *testing.T) {
	m := ChargingModeTemplate(1, "办公桌", false)
	if m.TotalPower != 250 || m.MaxTotalPower != 250 || !m.HasChargeProtocol || len(m.PowerSettings) != 5 {
		t.Fatalf("template = %+v", m)
	}
	c4, _ := m.Setting(a2345.GroupC4)
	if c4.Power != 25 || c4.MaxPower != 100 || !c4.SCP || c4.PPS16V || c4.PD12V {
		t.Fatalf("C4 = %+v", c4)
	}
	if mainland := ChargingModeTemplate(1, "x", true); mainland.PowerSettings[1].MaxPower != 120 {
		t.Fatal("mainland C2 limit")
	}
}

func TestEndpointValidationRefusesPathTricks(t *testing.T) {
	c := NewCloudClient(plainAuth(), nil, nil)
	for _, p := range []string{"", "/abs", "a/../b", "https://evil", "a?b", "a#b"} {
		if _, err := c.endpointURL(p); !errors.Is(err, &CloudError{Kind: CloudErrInvalidEndpoint}) {
			t.Errorf("%q accepted", p)
		}
	}
}
