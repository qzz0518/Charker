import Foundation

/// A country Anker will accept at login, and which of its two servers it maps to.
///
/// The code is not cosmetic: it selects the API endpoint and is also sent as the
/// `ab` field of the login body, so the wrong one fails the login outright rather
/// than returning something different.
public struct AnkerRegion: Sendable, Identifiable, Hashable {
    public let code: String
    public let name: String

    public var id: String { code }
    public var isEUServed: Bool { AnkerAccountClient.isEUServed(code) }
    public var serverHost: String {
        isEUServed ? "ankerpower-api-eu.anker.com" : "ankerpower-api.anker.com"
    }

    public var label: String { localizedLabel() }

    /// Anker uses two legacy country codes that Foundation does not recognise as
    /// region identifiers. Keep the wire/API code unchanged and translate only
    /// for the locale lookup used by the picker.
    public var localeRegionCode: String {
        switch code {
        case "UK": return "GB"
        case "EL": return "GR"
        default: return code
        }
    }

    public func localizedName(
        locale: Locale? = nil,
        bundle: Bundle = .main
    ) -> String {
        (locale ?? L10n.locale(for: bundle))
            .localizedString(forRegionCode: localeRegionCode) ?? name
    }

    public func localizedLabel(
        locale: Locale? = nil,
        bundle: Bundle = .main
    ) -> String {
        L10n.format(
            "%@（%@）", localizedName(locale: locale, bundle: bundle), code,
            table: "Core", bundle: bundle
        )
    }

    init(_ code: String, _ name: String) {
        self.code = code
        self.name = name
    }

    /// Shown first because they cover almost every user of this charger.
    public static let common: [AnkerRegion] = [
        AnkerRegion("CN", "中国大陆"),
        AnkerRegion("JP", "日本"),
        AnkerRegion("US", "美国"),
        AnkerRegion("HK", "中国香港"),
        AnkerRegion("TW", "中国台湾"),
        AnkerRegion("SG", "新加坡"),
        AnkerRegion("KR", "韩国"),
        AnkerRegion("UK", "英国"),
        AnkerRegion("DE", "德国"),
    ]

    /// Everything else Anker's country table lists, alphabetically by code.
    public static let others: [AnkerRegion] = [
        AnkerRegion("AL", "阿尔巴尼亚"), AnkerRegion("AM", "亚美尼亚"),
        AnkerRegion("AR", "阿根廷"), AnkerRegion("AT", "奥地利"),
        AnkerRegion("AU", "澳大利亚"), AnkerRegion("AZ", "阿塞拜疆"),
        AnkerRegion("BA", "波黑"), AnkerRegion("BE", "比利时"),
        AnkerRegion("BG", "保加利亚"), AnkerRegion("BR", "巴西"),
        AnkerRegion("BY", "白俄罗斯"), AnkerRegion("CA", "加拿大"),
        AnkerRegion("CH", "瑞士"), AnkerRegion("CY", "塞浦路斯"),
        AnkerRegion("CZ", "捷克"), AnkerRegion("DK", "丹麦"),
        AnkerRegion("DZ", "阿尔及利亚"), AnkerRegion("EE", "爱沙尼亚"),
        AnkerRegion("EG", "埃及"), AnkerRegion("EL", "希腊"),
        AnkerRegion("ES", "西班牙"), AnkerRegion("FI", "芬兰"),
        AnkerRegion("FR", "法国"), AnkerRegion("GE", "格鲁吉亚"),
        AnkerRegion("HR", "克罗地亚"), AnkerRegion("HU", "匈牙利"),
        AnkerRegion("IE", "爱尔兰"), AnkerRegion("IL", "以色列"),
        AnkerRegion("IN", "印度"), AnkerRegion("IS", "冰岛"),
        AnkerRegion("IT", "意大利"), AnkerRegion("JO", "约旦"),
        AnkerRegion("LB", "黎巴嫩"), AnkerRegion("LI", "列支敦士登"),
        AnkerRegion("LT", "立陶宛"), AnkerRegion("LU", "卢森堡"),
        AnkerRegion("LV", "拉脱维亚"), AnkerRegion("LY", "利比亚"),
        AnkerRegion("MA", "摩洛哥"), AnkerRegion("MD", "摩尔多瓦"),
        AnkerRegion("ME", "黑山"), AnkerRegion("MK", "北马其顿"),
        AnkerRegion("MT", "马耳他"), AnkerRegion("MX", "墨西哥"),
        AnkerRegion("NG", "尼日利亚"), AnkerRegion("NL", "荷兰"),
        AnkerRegion("NO", "挪威"), AnkerRegion("NZ", "新西兰"),
        AnkerRegion("PL", "波兰"), AnkerRegion("PS", "巴勒斯坦"),
        AnkerRegion("PT", "葡萄牙"), AnkerRegion("RO", "罗马尼亚"),
        AnkerRegion("RS", "塞尔维亚"), AnkerRegion("RU", "俄罗斯"),
        AnkerRegion("SE", "瑞典"), AnkerRegion("SI", "斯洛文尼亚"),
        AnkerRegion("SK", "斯洛伐克"), AnkerRegion("SY", "叙利亚"),
        AnkerRegion("TN", "突尼斯"), AnkerRegion("TR", "土耳其"),
        AnkerRegion("UA", "乌克兰"), AnkerRegion("XK", "科索沃"),
        AnkerRegion("ZA", "南非"),
    ]

    public static let all: [AnkerRegion] = common + others

    public static func named(_ code: String) -> AnkerRegion? {
        let code = code.uppercased()
        return all.first { $0.code == code }
    }
}

/// Mail domains offered in the sign-in domain picker, weighted towards the
/// providers this app's users actually have.
public enum MailDomains {
    public static let common = [
        "qq.com", "163.com", "126.com", "foxmail.com", "139.com", "sina.com",
        "aliyun.com", "gmail.com", "outlook.com", "hotmail.com", "icloud.com",
        "me.com", "yahoo.com",
    ]

    /// Sentinel for "type your own", so an address on any other provider still works.
    public static let customTag = "\u{0000}custom"

    /// Splits a full address, so pasting one into the local-part field does the
    /// right thing instead of producing `a@b.com@gmail.com`.
    public static func split(_ address: String) -> (local: String, domain: String)? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@") else { return nil }
        let local = String(trimmed[trimmed.startIndex..<at])
        let domain = String(trimmed[trimmed.index(after: at)...]).lowercased()
        guard !local.isEmpty, !domain.isEmpty else { return nil }
        return (local, domain)
    }
}
