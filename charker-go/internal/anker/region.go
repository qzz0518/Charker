package anker

import (
	"net/url"
	"strings"
)

// Region is a country Anker will accept at login and the regional server it
// maps to (AnkerRegion).
//
// The code is not cosmetic: it selects the API endpoint and is also sent as
// the `ab` field of the login body, so the wrong one fails the login outright
// rather than returning something different.
type Region struct {
	Code string `json:"code"`
	// Name is the Chinese fallback name the Swift table carries; the UI
	// localizes the country through LocaleRegionCode.
	Name string `json:"name"`
}

// IsEUServed reports whether the region signs in on the EU server.
func (r Region) IsEUServed() bool { return IsEUServed(r.Code) }

// ServerHost is the host of the region's API server.
func (r Region) ServerHost() string {
	u, err := url.Parse(ServerBase(r.Code))
	if err != nil {
		return ""
	}
	return u.Host
}

// LocaleRegionCode translates the two legacy codes Anker uses (UK, EL) to the
// ISO region identifiers a locale lookup recognises. The wire code stays as is.
func (r Region) LocaleRegionCode() string {
	switch r.Code {
	case "UK":
		return "GB"
	case "EL":
		return "GR"
	}
	return r.Code
}

// CommonRegions are shown first because they cover almost every user of this
// charger.
var CommonRegions = []Region{
	{"CN", "中国大陆"},
	{"JP", "日本"},
	{"US", "美国"},
	{"HK", "中国香港"},
	{"TW", "中国台湾"},
	{"SG", "新加坡"},
	{"KR", "韩国"},
	{"UK", "英国"},
	{"DE", "德国"},
}

// OtherRegions is everything else Anker's country table lists,
// alphabetically by code.
var OtherRegions = []Region{
	{"AL", "阿尔巴尼亚"}, {"AM", "亚美尼亚"},
	{"AR", "阿根廷"}, {"AT", "奥地利"},
	{"AU", "澳大利亚"}, {"AZ", "阿塞拜疆"},
	{"BA", "波黑"}, {"BE", "比利时"},
	{"BG", "保加利亚"}, {"BR", "巴西"},
	{"BY", "白俄罗斯"}, {"CA", "加拿大"},
	{"CH", "瑞士"}, {"CY", "塞浦路斯"},
	{"CZ", "捷克"}, {"DK", "丹麦"},
	{"DZ", "阿尔及利亚"}, {"EE", "爱沙尼亚"},
	{"EG", "埃及"}, {"EL", "希腊"},
	{"ES", "西班牙"}, {"FI", "芬兰"},
	{"FR", "法国"}, {"GE", "格鲁吉亚"},
	{"HR", "克罗地亚"}, {"HU", "匈牙利"},
	{"IE", "爱尔兰"}, {"IL", "以色列"},
	{"IN", "印度"}, {"IS", "冰岛"},
	{"IT", "意大利"}, {"JO", "约旦"},
	{"LB", "黎巴嫩"}, {"LI", "列支敦士登"},
	{"LT", "立陶宛"}, {"LU", "卢森堡"},
	{"LV", "拉脱维亚"}, {"LY", "利比亚"},
	{"MA", "摩洛哥"}, {"MD", "摩尔多瓦"},
	{"ME", "黑山"}, {"MK", "北马其顿"},
	{"MT", "马耳他"}, {"MX", "墨西哥"},
	{"NG", "尼日利亚"}, {"NL", "荷兰"},
	{"NO", "挪威"}, {"NZ", "新西兰"},
	{"PL", "波兰"}, {"PS", "巴勒斯坦"},
	{"PT", "葡萄牙"}, {"RO", "罗马尼亚"},
	{"RS", "塞尔维亚"}, {"RU", "俄罗斯"},
	{"SE", "瑞典"}, {"SI", "斯洛文尼亚"},
	{"SK", "斯洛伐克"}, {"SY", "叙利亚"},
	{"TN", "突尼斯"}, {"TR", "土耳其"},
	{"UA", "乌克兰"}, {"XK", "科索沃"},
	{"ZA", "南非"},
}

// AllRegions is CommonRegions followed by OtherRegions.
var AllRegions = append(append([]Region(nil), CommonRegions...), OtherRegions...)

// RegionNamed looks a code up case-insensitively.
func RegionNamed(code string) (Region, bool) {
	code = strings.ToUpper(code)
	for _, r := range AllRegions {
		if r.Code == code {
			return r, true
		}
	}
	return Region{}, false
}

// DefaultCountryCode is the best guess at the account's region from the
// system's, only used to prefill the picker; it falls back to a code Anker
// actually accepts.
func DefaultCountryCode(system string) string {
	if r, ok := RegionNamed(system); ok {
		return r.Code
	}
	return "CN"
}

// MailCommonDomains are offered in the sign-in domain picker, weighted
// towards the providers this app's users actually have.
var MailCommonDomains = []string{
	"qq.com", "163.com", "126.com", "foxmail.com", "139.com", "sina.com",
	"aliyun.com", "gmail.com", "outlook.com", "hotmail.com", "icloud.com",
	"me.com", "yahoo.com",
}

// MailCustomTag is the sentinel for "type your own".
const MailCustomTag = "\x00custom"

// SplitMailAddress splits a full address so pasting one into the local-part
// field does the right thing instead of producing `a@b.com@gmail.com`. The
// domain is lowercased, the local part is not.
func SplitMailAddress(address string) (local, domain string, ok bool) {
	trimmed := strings.TrimSpace(address)
	at := strings.IndexByte(trimmed, '@')
	if at < 0 {
		return "", "", false
	}
	local = trimmed[:at]
	domain = strings.ToLower(trimmed[at+1:])
	if local == "" || domain == "" {
		return "", "", false
	}
	return local, domain, true
}
