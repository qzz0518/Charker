import A2345Protocol
import Foundation

/// A2345 settings the official app keeps on Anker's servers. The app pushes
/// the stored compatibility and identification values back to the charger
/// whenever it opens, so Charker writes them here as well as to the charger.
public struct A2345CloudSettings: Sendable, Equatable {
    /// The 实验室 switch that makes custom charging mode available.
    public var customModeEnabled: Bool?
    public var maxCompatibility: Bool?
    public var deviceIdentification: Bool?

    public init(customModeEnabled: Bool? = nil, maxCompatibility: Bool? = nil, deviceIdentification: Bool? = nil) {
        self.customModeEnabled = customModeEnabled
        self.maxCompatibility = maxCompatibility
        self.deviceIdentification = deviceIdentification
    }
}

/// One stored custom charging profile (`charging/get_charging_mode_list`).
public struct A2345CloudChargingMode: Sendable, Equatable, Identifiable, Codable {
    public struct PortSetting: Sendable, Equatable, Codable {
        /// "C1" … "C4" or "A".
        public var name: String
        public var power: Int
        public var maxPower: Int
        public var scp: Bool
        public var ufcs: Bool
        public var pd12V: Bool
        public var pps11V: Bool
        public var pps16V: Bool
        public var pps21V: Bool
        public var huawei: Bool
        public var xiaomi: Bool

        public init(
            name: String, power: Int, maxPower: Int,
            scp: Bool = true, ufcs: Bool = true, pd12V: Bool = true,
            pps11V: Bool = true, pps16V: Bool = true, pps21V: Bool = true,
            huawei: Bool = true, xiaomi: Bool = true
        ) {
            self.name = name
            self.power = power
            self.maxPower = maxPower
            self.scp = scp
            self.ufcs = ufcs
            self.pd12V = pd12V
            self.pps11V = pps11V
            self.pps16V = pps16V
            self.pps21V = pps21V
            self.huawei = huawei
            self.xiaomi = xiaomi
        }

        private enum CodingKeys: String, CodingKey {
            case name, power, scp, ufcs, huawei, xiaomi
            case maxPower = "max_power"
            case pd12V = "pd12v"
            case pps11V = "pps11v"
            case pps16V = "pps16v"
            case pps21V = "pps20v"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            power = c.flexibleInt(.power) ?? 0
            maxPower = c.flexibleInt(.maxPower) ?? 0
            scp = c.flexibleBool(.scp) ?? false
            ufcs = c.flexibleBool(.ufcs) ?? false
            pd12V = c.flexibleBool(.pd12V) ?? false
            pps11V = c.flexibleBool(.pps11V) ?? false
            pps16V = c.flexibleBool(.pps16V) ?? false
            pps21V = c.flexibleBool(.pps21V) ?? false
            huawei = c.flexibleBool(.huawei) ?? false
            xiaomi = c.flexibleBool(.xiaomi) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(power, forKey: .power)
            try c.encode(maxPower, forKey: .maxPower)
            try c.encode(scp ? 1 : 0, forKey: .scp)
            try c.encode(ufcs ? 1 : 0, forKey: .ufcs)
            try c.encode(pd12V ? 1 : 0, forKey: .pd12V)
            try c.encode(pps11V ? 1 : 0, forKey: .pps11V)
            try c.encode(pps16V ? 1 : 0, forKey: .pps16V)
            try c.encode(pps21V ? 1 : 0, forKey: .pps21V)
            try c.encode(huawei ? 1 : 0, forKey: .huawei)
            try c.encode(xiaomi ? 1 : 0, forKey: .xiaomi)
        }
    }

    public var id: Int
    public var number: Int
    public var name: String
    public var totalPower: Int
    public var maxTotalPower: Int
    public var autoExit: Bool
    public var hasChargeProtocol: Bool
    public var powerSettings: [PortSetting]

    public init(
        id: Int = 0,
        number: Int,
        name: String,
        autoExit: Bool,
        hasChargeProtocol: Bool = true,
        powerSettings: [PortSetting]
    ) {
        self.id = id
        self.number = number
        self.name = name
        self.totalPower = powerSettings.reduce(0) { $0 + $1.power }
        self.maxTotalPower = A2345CustomChargingProfile.totalLimit
        self.autoExit = autoExit
        self.hasChargeProtocol = hasChargeProtocol
        self.powerSettings = powerSettings
    }

    public static let portNames = ["C1", "C2", "C3", "C4", "A"]

    /// A new profile with the official editor's defaults for each power band:
    /// PD 12V off, the PPS ranges the port's limit can use.
    public static func template(number: Int, name: String, mainland: Bool) -> A2345CloudChargingMode {
        let watts = [100, 65, 45, 25, 15]
        let settings = zip(portNames, A2345PortGroup.allCases).enumerated().map { index, pair in
            let power = watts[index]
            let mid = power >= 21
            let high = power >= 45
            return PortSetting(
                name: pair.0,
                power: power,
                maxPower: Int(A2345CustomChargingProfile.maximumWatts(pair.1, mainland: mainland)),
                scp: mid, ufcs: true, pd12V: false,
                pps11V: mid, pps16V: high, pps21V: high,
                huawei: mid, xiaomi: false
            )
        }
        return A2345CloudChargingMode(number: number, name: name, autoExit: false, powerSettings: settings)
    }

    public func setting(_ group: A2345PortGroup) -> PortSetting? {
        let name = Self.portNames[group.rawValue]
        return powerSettings.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? (powerSettings.indices.contains(group.rawValue) ? powerSettings[group.rawValue] : nil)
    }

    public var profile: A2345CustomChargingProfile {
        A2345CustomChargingProfile(
            number: UInt8(clamping: number),
            autoExit: autoExit,
            watts: A2345PortGroup.allCases.map { UInt8(clamping: setting($0)?.power ?? 0) }
        )
    }

    /// The per-port protocol bitmap 0x0206 carries. Mainland firmware puts
    /// Huawei where overseas firmware puts SCP and adds Xiaomi on bit 6.
    public func protocols(mainland: Bool) -> A2345PortProtocols {
        A2345PortProtocols(ports: [A2345PortGroup.c1, .c2, .c3, .c4].map { group in
            guard let setting = setting(group) else { return [] }
            var flags: A2345PortProtocols.Flags = []
            if mainland ? setting.huawei : setting.scp { flags.insert(.scp) }
            if setting.ufcs { flags.insert(.ufcs) }
            if setting.pd12V { flags.insert(.pd12V) }
            if setting.pps11V { flags.insert(.pps11V) }
            if setting.pps16V { flags.insert(.pps16V) }
            if setting.pps21V { flags.insert(.pps21V) }
            if mainland, setting.xiaomi { flags.insert(.xiaomi) }
            return flags
        })
    }

    private enum CodingKeys: String, CodingKey {
        case id, number, name
        case totalPower = "total_power"
        case maxTotalPower = "max_total_power"
        case autoExit = "auto_exit"
        case hasChargeProtocol = "has_charge_protocol"
        case powerSettings = "power_settings"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexibleInt(.id) ?? 0
        number = c.flexibleInt(.number) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        totalPower = c.flexibleInt(.totalPower) ?? 0
        maxTotalPower = c.flexibleInt(.maxTotalPower) ?? A2345CustomChargingProfile.totalLimit
        autoExit = c.flexibleBool(.autoExit) ?? false
        hasChargeProtocol = c.flexibleBool(.hasChargeProtocol) ?? false
        powerSettings = (try? c.decode([PortSetting].self, forKey: .powerSettings)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(powerSettings.reduce(0) { $0 + $1.power }, forKey: .totalPower)
        try c.encode(maxTotalPower, forKey: .maxTotalPower)
        try c.encode(autoExit ? 1 : 0, forKey: .autoExit)
        try c.encode(hasChargeProtocol ? 1 : 0, forKey: .hasChargeProtocol)
        try c.encode(powerSettings, forKey: .powerSettings)
    }
}

/// A clock picture theme from `style/get_clock_screensavers` (kind 3) or one
/// of the user's own pictures from `style/get_manual_clock_screensavers`
/// (kind 5).
public struct A2345CloudTheme: Sendable, Equatable, Identifiable {
    public var id: UInt32
    public var title: String
    public var category: String
    public var imageURL: String
    public var shortURL: String?
    public var crc32: UInt32
    public var textColor: UInt32?
    public var kind: A2345ThemeKind

    public init(
        id: UInt32, title: String, category: String, imageURL: String,
        shortURL: String? = nil, crc32: UInt32, textColor: UInt32? = nil, kind: A2345ThemeKind
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.imageURL = imageURL
        self.shortURL = shortURL
        self.crc32 = crc32
        self.textColor = textColor
        self.kind = kind
    }

    /// `0x0205` applying this theme with the clock switched on or off.
    public func request(clockOn: Bool) -> A2345ClockThemeRequest {
        switch kind {
        case .custom:
            return A2345ClockThemeRequest(
                clockOn: clockOn, kind: .custom, themeID: id, imageCRC: crc32,
                url: "", customURL: imageURL
            )
        default:
            return A2345ClockThemeRequest(
                clockOn: clockOn, kind: .picture, themeID: id, imageCRC: crc32,
                url: imageURL
            )
        }
    }
}

public extension AnkerCloudClient {
    static let a2345DeviceSettingPath = "mini_power/v1/app/setting/get_device_setting"

    func a2345CloudSettings(serial: String) async throws -> A2345CloudSettings {
        let payload: DeviceSettingPayload = try await post(
            Self.a2345DeviceSettingPath, body: SerialBody(deviceSerial: serial)
        )
        var settings = payload.deviceSetting ?? payload.flat
        // `charging_device_identity_status` in that reply belongs to the A2687;
        // the A2345 keeps its switch behind the `_default_true` endpoint.
        settings.deviceIdentification = try? await a2345DeviceIdentification(serial: serial)
        return settings
    }

    func a2345DeviceIdentification(serial: String) async throws -> Bool? {
        let payload: IdentityPayload = try await post(
            "mini_power/v1/app/setting/get_charging_device_identity_status_default_true",
            body: SerialBody(deviceSerial: serial)
        )
        return payload.value
    }

    func setA2345CustomModeEnabled(_ enabled: Bool, serial: String) async throws {
        try await postIgnoringData(
            "mini_power/v1/app/setting/set_charging_mode_status",
            body: SwitchBody(deviceSerial: serial, key: "charging_mode_status", value: enabled)
        )
    }

    func setA2345MaxCompatibility(_ enabled: Bool, serial: String) async throws {
        try await postIgnoringData(
            "mini_power/v1/app/setting/set_compatibility_status",
            body: SwitchBody(deviceSerial: serial, key: "compatibility_status", value: enabled)
        )
    }

    func setA2345DeviceIdentification(_ enabled: Bool, serial: String) async throws {
        try await postIgnoringData(
            "mini_power/v1/app/setting/set_charging_device_identity_status_default_true",
            body: SwitchBody(
                deviceSerial: serial,
                key: "charging_device_identity_status_default_true",
                value: enabled
            )
        )
    }

    func a2345ChargingModes(serial: String) async throws -> [A2345CloudChargingMode] {
        let payload: ChargingModeListPayload = try await post(
            "mini_power/v1/app/charging/get_charging_mode_list",
            body: SerialBody(deviceSerial: serial)
        )
        return payload.list.sorted { $0.number < $1.number }
    }

    func addA2345ChargingMode(_ mode: A2345CloudChargingMode, serial: String) async throws {
        try await postIgnoringData(
            "mini_power/v1/app/charging/add_charging_mode",
            body: ChargingModeBody(mode: mode, deviceSerial: serial, includesNumber: true)
        )
    }

    func updateA2345ChargingMode(_ mode: A2345CloudChargingMode) async throws {
        try await postIgnoringData(
            "mini_power/v1/app/charging/update_charging_mode",
            body: ChargingModeBody(mode: mode, deviceSerial: nil, includesNumber: false)
        )
    }

    func deleteA2345ChargingMode(id: Int) async throws {
        try await postIgnoringData(
            "mini_power/v1/app/charging/delete_charging_mode",
            body: IDBody(id: id)
        )
    }

    func a2345ClockThemes() async throws -> [A2345CloudTheme] {
        let payload: ThemeCategoriesPayload = try await post(
            "mini_power/v1/app/style/get_clock_screensavers",
            body: ProductBody(productCode: "A2345")
        )
        return payload.categories.flatMap { category in
            category.list.compactMap { item -> A2345CloudTheme? in
                guard let id = item.id, let url = item.imageURL, !url.isEmpty else { return nil }
                return A2345CloudTheme(
                    id: id,
                    title: item.title ?? "",
                    category: category.name ?? "",
                    imageURL: url,
                    shortURL: item.shortURL,
                    crc32: item.crc32 ?? 0,
                    textColor: item.textColor,
                    kind: .picture
                )
            }
        }
    }

    func a2345CustomScreensavers(serial: String) async throws -> [A2345CloudTheme] {
        let payload: ManualScreensaverPayload = try await post(
            "mini_power/v1/app/style/get_manual_clock_screensavers",
            body: SnBody(sn: serial)
        )
        return payload.list.compactMap { item in
            guard let id = item.id, let url = item.imageURL, !url.isEmpty else { return nil }
            return A2345CloudTheme(
                id: id,
                title: item.title ?? "",
                category: "",
                imageURL: url,
                shortURL: item.shortURL,
                crc32: item.crc32 ?? 0,
                kind: .custom
            )
        }
    }
}

public extension AnkerCloudClient {
    /// The official app keeps at most eight of the user's own pictures.
    static let a2345CustomPictureLimit = 8

    /// Uploads one prepared 480×200 JPEG and registers it as a custom clock
    /// picture, the way the official app does: a signed upload slot from
    /// `cloudstor`, a plain PUT, then `add_manual_clock_screensavers` with the
    /// slot's short path and the file's CRC-32.
    func uploadA2345CustomPicture(_ jpeg: Data, serial: String) async throws {
        let ticket: UploadTicketPayload = try await post(
            "app/cloudstor/get_app_up_token_general",
            body: UploadTicketBody(fileSize: jpeg.count),
            headers: ["user_id": accountUserID]
        )
        guard let url = URL(string: ticket.uploadToken), !ticket.keyPrefix.isEmpty else {
            throw AnkerCloudError.malformedResponse
        }
        try await putSignedUpload(jpeg, to: url, contentType: "binary/octet-stream")
        try await postIgnoringData(
            "mini_power/v1/app/style/add_manual_clock_screensavers",
            body: AddPictureBody(
                sn: serial,
                imageURL: ticket.keyPrefix,
                hashCode: String(format: "0x%08x", CRC32.checksum(jpeg))
            )
        )
    }

    func deleteA2345CustomPicture(id: UInt32) async throws {
        try await postIgnoringData(
            "mini_power/v1/app/style/delete_manual_clock_screensavers",
            body: IDBody(id: Int(id))
        )
    }
}

/// zlib's CRC-32 (init and final XOR 0xFFFFFFFF), which the charger uses to
/// recognise a picture it has already downloaded.
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private struct UploadTicketBody: Encodable, Sendable {
    var fileSize: Int

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode("cropped_image.jpg", forKey: AnyKey("file_name"))
        try c.encode("binary/octet-stream", forKey: AnyKey("content_type"))
        try c.encode(fileSize, forKey: AnyKey("file_size"))
        try c.encode(false, forKey: AnyKey("disable_ssl"))
        try c.encode(106, forKey: AnyKey("type"))
    }
}

private struct UploadTicketPayload: Decodable, Sendable {
    var uploadToken: String
    var keyPrefix: String

    private enum CodingKeys: String, CodingKey {
        case uploadToken = "uptoken"
        case keyPrefix = "key_prefix"
    }
}

private struct AddPictureBody: Encodable, Sendable {
    var sn: String
    var imageURL: String
    var hashCode: String

    private enum CodingKeys: String, CodingKey {
        case sn
        case imageURL = "img_url"
        case hashCode = "hash_code"
    }
}

// MARK: - Wire shapes

private struct SerialBody: Encodable, Sendable {
    var deviceSerial: String
    enum CodingKeys: String, CodingKey { case deviceSerial = "device_sn" }
}

private struct SnBody: Encodable, Sendable {
    var sn: String
}

private struct IDBody: Encodable, Sendable {
    var id: Int
}

private struct ProductBody: Encodable, Sendable {
    var productCode: String
    enum CodingKeys: String, CodingKey { case productCode = "product_code" }
}

private struct SwitchBody: Encodable, Sendable {
    var deviceSerial: String
    var key: String
    var value: Bool

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(deviceSerial, forKey: AnyKey("device_sn"))
        try c.encode(value ? 1 : 0, forKey: AnyKey(key))
    }
}

private struct ChargingModeBody: Encodable, Sendable {
    var mode: A2345CloudChargingMode
    var deviceSerial: String?
    var includesNumber: Bool

    func encode(to encoder: Encoder) throws {
        try mode.encode(to: encoder)
        var c = encoder.container(keyedBy: AnyKey.self)
        if let deviceSerial {
            try c.encode(deviceSerial, forKey: AnyKey("device_sn"))
        } else {
            try c.encode(mode.id, forKey: AnyKey("id"))
        }
        if includesNumber {
            try c.encode(mode.number, forKey: AnyKey("number"))
        }
    }
}

private struct DeviceSettingPayload: Decodable, Sendable {
    var deviceSetting: A2345CloudSettings?
    var flat: A2345CloudSettings

    private enum CodingKeys: String, CodingKey {
        case deviceSetting = "device_setting"
        case chargingModeStatus = "charging_mode_status"
        case compatibilityStatus = "compatibility_status"
        case identityStatus = "charging_device_identity_status"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        flat = A2345CloudSettings(
            customModeEnabled: c.flexibleBool(.chargingModeStatus),
            maxCompatibility: c.flexibleBool(.compatibilityStatus),
            deviceIdentification: c.flexibleBool(.identityStatus)
        )
        if let nested = try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .deviceSetting) {
            deviceSetting = A2345CloudSettings(
                customModeEnabled: nested.flexibleBool(.chargingModeStatus),
                maxCompatibility: nested.flexibleBool(.compatibilityStatus),
                deviceIdentification: nested.flexibleBool(.identityStatus)
            )
        } else {
            deviceSetting = nil
        }
    }
}

private struct IdentityPayload: Decodable, Sendable {
    var value: Bool?

    private enum CodingKeys: String, CodingKey {
        case value = "charging_device_identity_status_default_true"
        case status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = c.flexibleBool(.value) ?? c.flexibleBool(.status)
    }
}

private struct ChargingModeListPayload: Decodable, Sendable {
    var list: [A2345CloudChargingMode]

    private enum CodingKeys: String, CodingKey {
        case list = "charging_mode_list"
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            list = (try? c.decode([A2345CloudChargingMode].self, forKey: .list)) ?? []
        } else {
            list = (try? decoder.singleValueContainer().decode([A2345CloudChargingMode].self)) ?? []
        }
    }
}

private struct ThemeItem: Decodable, Sendable {
    var id: UInt32?
    var title: String?
    var imageURL: String?
    var shortURL: String?
    var crc32: UInt32?
    var textColor: UInt32?

    private enum CodingKeys: String, CodingKey {
        case id, title, name
        case imageURL = "image_url"
        case imgURL = "img_url"
        case shortURL = "short_url"
        case crc32 = "file_crc32"
        case hashCode = "hash_code"
        case textColor = "text_color"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexibleInt(.id).flatMap { UInt32(exactly: $0) }
        title = (try? c.decode(String.self, forKey: .title)) ?? (try? c.decode(String.self, forKey: .name))
        imageURL = (try? c.decode(String.self, forKey: .imageURL)) ?? (try? c.decode(String.self, forKey: .imgURL))
        shortURL = try? c.decode(String.self, forKey: .shortURL)
        // `file_crc32` is always hex; `hash_code` is read like Dart's
        // int.tryParse: hex with a 0x prefix, decimal without.
        crc32 = c.hexUInt32(.crc32) ?? c.prefixedUInt32(.hashCode)
        textColor = c.hexUInt32(.textColor)
    }
}

private struct ThemeCategoriesPayload: Decodable, Sendable {
    struct Category: Decodable, Sendable {
        var name: String?
        var list: [ThemeItem]

        private enum CodingKeys: String, CodingKey {
            case name = "category_name"
            case list
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try? c.decode(String.self, forKey: .name)
            list = (try? c.decode([ThemeItem].self, forKey: .list)) ?? []
        }
    }

    var categories: [Category]

    private enum CodingKeys: String, CodingKey { case category }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self),
           let categories = try? c.decode([Category].self, forKey: .category) {
            self.categories = categories
        } else {
            categories = (try? decoder.singleValueContainer().decode([Category].self)) ?? []
        }
    }
}

private struct ManualScreensaverPayload: Decodable, Sendable {
    var list: [ThemeItem]

    private enum CodingKeys: String, CodingKey { case list }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            list = (try? c.decode([ThemeItem].self, forKey: .list)) ?? []
        } else {
            list = (try? decoder.singleValueContainer().decode([ThemeItem].self)) ?? []
        }
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer {
    /// Anker returns the same number as an int, a string or occasionally a bool.
    func flexibleInt(_ key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Int(value) }
        if let value = try? decode(Bool.self, forKey: key) { return value ? 1 : 0 }
        if let value = try? decode(Double.self, forKey: key) { return Int(exactly: value) }
        return nil
    }

    func flexibleBool(_ key: Key) -> Bool? {
        flexibleInt(key).map { $0 == 1 }
    }

    func prefixedUInt32(_ key: Key) -> UInt32? {
        if let value = try? decode(Int.self, forKey: key) { return UInt32(truncatingIfNeeded: value) }
        guard let text = try? decode(String.self, forKey: key) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") { return UInt32(trimmed.dropFirst(2), radix: 16) }
        return UInt32(trimmed)
    }

    /// `"0x1a2b3c4d"`, `"1a2b3c4d"` or a plain number.
    func hexUInt32(_ key: Key) -> UInt32? {
        if let value = try? decode(UInt32.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return UInt32(truncatingIfNeeded: value) }
        guard var text = try? decode(String.self, forKey: key) else { return nil }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("0x") { text.removeFirst(2) }
        return UInt32(text, radix: 16)
    }
}
