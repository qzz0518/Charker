package anker

import (
	"context"
	"crypto/ecdh"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"
)

// The login crypto has to match Anker's server byte for byte — a mismatch just
// looks like a wrong password. These vectors were produced with the same
// primitives the Python reference client uses, from a fixed private scalar.
const (
	clientPrivateKeyHex        = "7dfbea61cd95cee49c458ad7419e817f1ade9a66136de3c7d5787af1458e39f4"
	expectedSharedKeyHex       = "9eab5f3f93c514a483763eb8dd755c7540f391a00d9fd539fb1124fe12cbede7"
	expectedClientPublicKeyHex = "04060ea168f232aedb37fb2d120c49180329ac72ab5ec3eb8fd30a2f252dc5e151" +
		"dabccd9b1dc1e288704ca760a0d8c918e5c94823a1f609a4bf07fb4c33ee2190"
)

func fixedKey(t *testing.T) *ecdh.PrivateKey {
	t.Helper()
	k, err := ecdh.P256().NewPrivateKey(mustHex(t, clientPrivateKeyHex))
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestSharedKeyMatchesTheReferenceImplementation(t *testing.T) {
	shared, err := SharedKey(fixedKey(t))
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(shared) != expectedSharedKeyHex || len(shared) != 32 {
		t.Fatalf("shared = %x", shared)
	}
}

func TestClientPublicKeyIsAnUncompressedPoint(t *testing.T) {
	raw := fixedKey(t).PublicKey().Bytes()
	if hex.EncodeToString(raw) != expectedClientPublicKeyHex || raw[0] != 0x04 || len(raw) != 65 {
		t.Fatalf("public = %x", raw)
	}
}

func TestPasswordEncryptionMatchesKnownVectors(t *testing.T) {
	key := mustHex(t, expectedSharedKeyHex)
	for _, v := range []struct{ plain, want string }{
		{"hunter2", "wCJPQmgOLDIjflE00kSqkA=="},
		{"", "zFCwJ1eg7fuGOK/0t4G4kg=="},
		{strings.Repeat("a", 16), "1aU4/yoR9bUa6XpgKmuE8VDoHvRr7DuiMxAXGS+SiH4="},
		{"密码测试", "l1+tJ01LiarN+CqBudbmjw=="},
	} {
		got, err := EncryptPassword(v.plain, key)
		if err != nil || got != v.want {
			t.Errorf("%q: got %q, %v; want %q", v.plain, got, err, v.want)
		}
	}
}

func TestEncryptionRejectsAWrongSizedKey(t *testing.T) {
	if _, err := EncryptPassword("x", make([]byte, 16)); err == nil {
		t.Fatal("16-byte key accepted")
	}
}

func TestServerSelection(t *testing.T) {
	// The reset-mail domain is the tell: ankerpower-api-eu means EU served.
	if ServerBase("JP") != EUServer || ServerBase("de") != EUServer {
		t.Error("JP/DE must be EU")
	}
	// The charging app's own `.com` table is exactly these seven.
	for _, c := range []string{"AR", "AU", "BR", "CA", "MX", "NZ", "US"} {
		if ServerBase(c) != ComServer {
			t.Errorf("%s not .com", c)
		}
	}
	// anker-solix-api lists these under `.com`; for chargers that server
	// accepts the login and then reports no devices.
	for _, c := range []string{"HK", "TW", "SG", "KR", "IN", "ZA"} {
		if ServerBase(c) != EUServer {
			t.Errorf("%s not EU", c)
		}
	}
	if ServerBase("CN") != CNServer || ServerBase("ZZ") != EUServer {
		t.Error("CN/ZZ routing")
	}
}

func TestGMTStringFormat(t *testing.T) {
	text := GMTString(time.Now())
	if !strings.HasPrefix(text, "GMT") || len(text) != 9 || !strings.Contains(text, ":") {
		t.Fatalf("GMTString = %q", text)
	}
	if got := GMTString(time.Date(2026, 1, 1, 0, 0, 0, 0, time.FixedZone("x", -(5*3600+30*60)))); got != "GMT-05:30" {
		t.Fatalf("negative offset = %q", got)
	}
}

func TestInputValidationHappensBeforeAnyNetworkCall(t *testing.T) {
	client, stub := stubClient(func(*http.Request, []byte) (int, []byte) {
		t.Error("invalid input must not reach the network")
		return 500, nil
	})
	c := &AccountClient{HTTP: client}
	ctx := context.Background()
	if _, err := c.Login(ctx, "nope", "x", "JP"); !errors.Is(err, &LoginError{Kind: LoginErrInvalidEmail}) {
		t.Errorf("malformed address: %v", err)
	}
	if _, err := c.Login(ctx, "a@b.com", "", "JP"); !errors.Is(err, &LoginError{Kind: LoginErrEmptyPassword}) {
		t.Errorf("empty password: %v", err)
	}
	if _, err := c.Login(ctx, "person@example.com", "secret", "CN"); !errors.Is(err, &LoginError{Kind: LoginErrPhoneLoginRequired}) {
		t.Errorf("CN email: %v", err)
	}
	for _, phone := range []string{"", "+8613800138000", "1380013800", "１３８００１３８０００", "1380013800x"} {
		if err := c.SendPhoneVerificationCode(ctx, phone); !errors.Is(err, &LoginError{Kind: LoginErrInvalidPhoneNumber}) {
			t.Errorf("phone %q: %v", phone, err)
		}
	}
	for _, code := range []string{"", "12345", "1234567", "１２３４５６"} {
		if _, err := c.LoginPhone(ctx, "13800138000", code); !errors.Is(err, &LoginError{Kind: LoginErrInvalidVerificationCode}) {
			t.Errorf("code %q: %v", code, err)
		}
	}
	if stub.calls != 0 {
		t.Fatalf("%d requests sent", stub.calls)
	}
}

func TestRegionTable(t *testing.T) {
	seen := map[string]bool{}
	for _, r := range AllRegions {
		if len(r.Code) != 2 || r.Name == "" {
			t.Errorf("bad region %+v", r)
		}
		if seen[r.Code] {
			t.Errorf("duplicate %s", r.Code)
		}
		seen[r.Code] = true
		switch r.ServerHost() {
		case "ankerpower-api-eu.anker.com", "ankerpower-api.anker.com", "aiot-api-cn.anker.com.cn":
		default:
			t.Errorf("%s -> %s", r.Code, r.ServerHost())
		}
	}
	jp, _ := RegionNamed("jp")
	cn, _ := RegionNamed("CN")
	us, _ := RegionNamed("US")
	hk, _ := RegionNamed("HK")
	if jp.Code != "JP" || !jp.IsEUServed() || cn.IsEUServed() || us.IsEUServed() || !hk.IsEUServed() {
		t.Error("region server mapping")
	}
	if _, ok := RegionNamed("ZZ"); ok {
		t.Error("ZZ accepted")
	}
	uk, _ := RegionNamed("UK")
	el, _ := RegionNamed("EL")
	if uk.LocaleRegionCode() != "GB" || el.LocaleRegionCode() != "GR" || jp.LocaleRegionCode() != "JP" {
		t.Error("locale region codes")
	}
	if DefaultCountryCode("jp") != "JP" || DefaultCountryCode("ZZ") != "CN" {
		t.Error("default country")
	}
}

func TestMailDomains(t *testing.T) {
	if MailCommonDomains[0] != "qq.com" {
		t.Error("qq.com first")
	}
	seen := map[string]bool{}
	for _, d := range MailCommonDomains {
		if seen[d] || d == MailCustomTag {
			t.Errorf("domain %q", d)
		}
		seen[d] = true
	}
	if strings.Contains(MailCustomTag, ".") {
		t.Error("custom tag looks like a domain")
	}
	if l, d, ok := SplitMailAddress(" Charker.User@Gmail.com "); !ok || l != "Charker.User" || d != "gmail.com" {
		t.Errorf("split = %q %q %v", l, d, ok)
	}
	for _, bad := range []string{"charker", "charker@", "@gmail.com", ""} {
		if _, _, ok := SplitMailAddress(bad); ok {
			t.Errorf("%q split", bad)
		}
	}
	if _, d, _ := SplitMailAddress("a@b@c.com"); d != "b@c.com" {
		t.Errorf("first @: %q", d)
	}
}

func TestTextRendersNestedArguments(t *testing.T) {
	text := T("%@（代码 %d）", T("服务器返回 HTTP %d", 403), 7)
	if text.String() != "服务器返回 HTTP 403（代码 7）" {
		t.Fatalf("%q", text.String())
	}
	if TextOf(errors.New("plain")).Key != "plain" {
		t.Fatal("fallback key")
	}
}
