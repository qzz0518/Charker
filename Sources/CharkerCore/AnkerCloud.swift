import CryptoKit
import Foundation
import Security

public enum AnkerCloudError: LocalizedError, Equatable, Sendable {
    case expiredAuthentication
    case invalidEndpoint
    case invalidRequestBody
    case network(String)
    case httpStatus(Int)
    case server(code: Int, message: String)
    case malformedResponse
    case missingMQTTCredentials
    case invalidMQTTTopicComponent

    public var errorDescription: String? {
        switch self {
        case .expiredAuthentication:
            return L10n.text("Anker 登录已过期，请重新登录。", table: "Core")
        case .invalidEndpoint:
            return L10n.text("云端接口地址无效。", table: "Core")
        case .invalidRequestBody:
            return L10n.text("无法编码云端请求。", table: "Core")
        case .network(let detail):
            return L10n.format("网络错误：%@", detail, table: "Core")
        case .httpStatus(let status):
            return L10n.format("服务器返回 HTTP %d", status, table: "Core")
        case .server(let code, let message):
            return message.isEmpty
                ? L10n.format("请求失败（代码 %d）", code, table: "Core")
                : L10n.format("%@（代码 %d）", message, code, table: "Core")
        case .malformedResponse:
            return L10n.text("服务器返回了无法解析的内容", table: "Core")
        case .missingMQTTCredentials:
            return L10n.text("服务器没有返回完整的 MQTT 临时凭据。", table: "Core")
        case .invalidMQTTTopicComponent:
            return L10n.text("设备身份包含无法用于 MQTT 主题的字符。", table: "Core")
        }
    }
}

public enum AnkerCredentialStoreError: LocalizedError, Equatable, Sendable {
    case keychain(OSStatus)
    case malformedRecord

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return L10n.format("钥匙串操作失败（%d）。", status, table: "Core")
        case .malformedRecord:
            return L10n.text("钥匙串中的 Anker 登录记录无法读取。", table: "Core")
        }
    }
}

/// Stores the cloud auth token in the macOS Keychain. Passwords and MQTT client
/// certificates never pass through this type.
public struct AnkerKeychainAuthenticationStore: Sendable {
    private let service: String
    private let account = "active"

    public init(service: String = "dev.charker.Charker.anker-cloud") {
        self.service = service
    }

    public func load() throws -> AnkerAuthentication? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            baseQuery.merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, rhs in rhs } as CFDictionary,
            &result
        )
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AnkerCredentialStoreError.keychain(status)
        }
        guard let data = result as? Data,
              let authentication = try? JSONDecoder().decode(AnkerAuthentication.self, from: data)
        else {
            throw AnkerCredentialStoreError.malformedRecord
        }
        return authentication
    }

    public func save(_ authentication: AnkerAuthentication) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(authentication)
        } catch {
            throw AnkerCredentialStoreError.malformedRecord
        }

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AnkerCredentialStoreError.keychain(updateStatus)
        }

        let addStatus = SecItemAdd(
            baseQuery.merging([
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable as String: false,
            ]) { _, rhs in rhs } as CFDictionary,
            nil
        )
        guard addStatus == errSecSuccess else {
            throw AnkerCredentialStoreError.keychain(addStatus)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AnkerCredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

public struct AnkerBoundDevice: Sendable, Equatable, Decodable, Identifiable {
    public var deviceSerial: String
    public var productCode: String
    public var deviceName: String?
    public var aliasName: String?
    public var wifiOnline: Bool?
    public var softwareVersion: String?
    public var ownerUserID: String?

    public var id: String { deviceSerial }
    public var displayName: String {
        if let aliasName, !aliasName.isEmpty { return aliasName }
        if let deviceName, !deviceName.isEmpty { return deviceName }
        return productCode
    }

    public init(
        deviceSerial: String,
        productCode: String,
        deviceName: String? = nil,
        aliasName: String? = nil,
        wifiOnline: Bool? = nil,
        softwareVersion: String? = nil,
        ownerUserID: String? = nil
    ) {
        self.deviceSerial = deviceSerial
        self.productCode = productCode
        self.deviceName = deviceName
        self.aliasName = aliasName
        self.wifiOnline = wifiOnline
        self.softwareVersion = softwareVersion
        self.ownerUserID = ownerUserID
    }

    private enum CodingKeys: String, CodingKey {
        case deviceSerial = "device_sn"
        case productCode = "product_code"
        case deviceName = "device_name"
        case aliasName = "alias_name"
        case wifiOnline = "wifi_online"
        case softwareVersion = "device_sw_version"
        case ownerUserID = "owner_user_id"
    }
}

/// Short-lived client material returned by Anker for an AWS IoT MQTT session.
/// The official client consumes the PEM certificate chain and RSA private key
/// directly. Charker decodes both to DER in memory and releases them with the
/// MQTT subscriber; neither value is persisted in Keychain or UserDefaults.
public struct AnkerMQTTCredentials: Sendable, Equatable {
    public var userID: String
    public var appName: String
    public var thingName: String
    public var certificateID: String
    public var endpoint: String
    public var certificateDER: Data
    public var privateKeyDER: Data

    public init(
        userID: String,
        appName: String,
        thingName: String,
        certificateID: String,
        endpoint: String,
        certificateDER: Data,
        privateKeyDER: Data
    ) {
        self.userID = userID
        self.appName = appName
        self.thingName = thingName
        self.certificateID = certificateID
        self.endpoint = endpoint
        self.certificateDER = certificateDER
        self.privateKeyDER = privateKeyDER
    }

    public func clientID(randomSuffix: UInt32) -> String {
        String(format: "%@_%05u", thingName, randomSuffix % 100_000)
    }

    public func subscriptionTopic(for device: AnkerBoundDevice) throws -> String {
        try Self.validateTopicComponents(
            appName,
            device.productCode,
            device.deviceSerial
        )
        return "dt/\(appName)/\(device.productCode)/\(device.deviceSerial)/#"
    }

    /// The only MQTT write topic Charker constructs. The transport keeps the
    /// corresponding payload surface closed to the two established A2345 read
    /// requests, so this does not expose a general device-command API.
    public func commandTopic(for device: AnkerBoundDevice) throws -> String {
        try Self.validateTopicComponents(
            appName,
            device.productCode,
            device.deviceSerial
        )
        return "cmd/\(appName)/\(device.productCode)/\(device.deviceSerial)/req"
    }

    private static func validateTopicComponents(_ values: String...) throws {
        guard values.allSatisfy(isTopicComponent) else {
            throw AnkerCloudError.invalidMQTTTopicComponent
        }
    }

    private static func isTopicComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45 || byte == 95
        }
    }
}

public struct AnkerCloudClient: Sendable {
    public static let bindDevicesPath = "power_service/v1/app/get_relate_and_bind_devices"
    public static let mqttInfoPath = "app/devicemanage/get_user_mqtt_info"

    private let authentication: AnkerAuthentication
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        authentication: AnkerAuthentication,
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authentication = authentication
        self.now = now
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            self.session = URLSession(
                configuration: configuration,
                delegate: AnkerNoRedirectDelegate(),
                delegateQueue: nil
            )
        }
    }

    private func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body,
        response: Response.Type = Response.self
    ) async throws -> Response {
        try await request(path: path, method: "POST", body: body)
    }

    private func post<Response: Decodable & Sendable>(
        _ path: String,
        response: Response.Type = Response.self
    ) async throws -> Response {
        try await request(path: path, method: "POST", body: EmptyBody())
    }

    public func boundDevices(productCode: String? = nil) async throws -> [AnkerBoundDevice] {
        let payload: BoundDevicesPayload = try await post(Self.bindDevicesPath)
        guard let productCode else { return payload.data }
        return payload.data.filter { $0.productCode.caseInsensitiveCompare(productCode) == .orderedSame }
    }

    public func mqttCredentials() async throws -> AnkerMQTTCredentials {
        let payload: MQTTInfoPayload = try await post(Self.mqttInfoPath)
        guard !payload.userID.isEmpty,
              !payload.appName.isEmpty,
              !payload.thingName.isEmpty,
              !payload.certificateID.isEmpty,
              Self.isValidMQTTHost(payload.endpoint),
              let certificateDER = Self.decodePEM(
                  payload.certificatePEM,
                  labels: ["CERTIFICATE"]
              ),
              let privateKeyDER = Self.decodePEM(
                  payload.privateKey,
                  labels: ["RSA PRIVATE KEY", "PRIVATE KEY"]
              )
        else {
            throw AnkerCloudError.missingMQTTCredentials
        }
        return AnkerMQTTCredentials(
            userID: payload.userID,
            appName: payload.appName,
            thingName: payload.thingName,
            certificateID: payload.certificateID,
            endpoint: payload.endpoint,
            certificateDER: certificateDER,
            privateKeyDER: privateKeyDER
        )
    }

    /// Accepts ordinary PEM line wrapping while rejecting extra text, missing
    /// boundaries and empty bodies. Returning DER here keeps the transport free
    /// from string parsing and prevents the original private-key text from
    /// escaping the short-lived response decoder.
    private static func decodePEM(_ value: String, labels: [String]) -> Data? {
        for label in labels {
            let header = "-----BEGIN \(label)-----"
            let footer = "-----END \(label)-----"
            guard let headerRange = value.range(of: header),
                  let footerRange = value.range(of: footer),
                  headerRange.upperBound <= footerRange.lowerBound
            else { continue }

            let prefix = value[..<headerRange.lowerBound]
            let suffix = value[footerRange.upperBound...]
            guard prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }

            let encoded = value[headerRange.upperBound..<footerRange.lowerBound]
                .filter { !$0.isWhitespace }
            guard let decoded = Data(
                base64Encoded: String(encoded),
                options: .ignoreUnknownCharacters
            ), !decoded.isEmpty else { continue }
            return decoded
        }
        return nil
    }

    private func request<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        guard authentication.isValid(at: now()) else {
            throw AnkerCloudError.expiredAuthentication
        }
        let url = try endpointURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("DESKTOP", forHTTPHeaderField: "model-type")
        request.setValue("anker_power", forHTTPHeaderField: "app-name")
        request.setValue("android", forHTTPHeaderField: "os-type")
        request.setValue(authentication.regionCode, forHTTPHeaderField: "country")
        request.setValue(AnkerAccountClient.gmtString(for: now()), forHTTPHeaderField: "timezone")
        if authentication.serverBase.absoluteString == AnkerAccountClient.cnServer {
            for (key, value) in AnkerAccountClient.chinaHeaders(at: now()) {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        request.setValue(authentication.authToken, forHTTPHeaderField: "x-auth-token")
        request.setValue(Self.md5(authentication.account.userID), forHTTPHeaderField: "gtoken")

        if let body {
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                throw AnkerCloudError.invalidRequestBody
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AnkerCloudError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AnkerCloudError.malformedResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AnkerCloudError.expiredAuthentication
        }
        guard (200...299).contains(http.statusCode) else {
            throw AnkerCloudError.httpStatus(http.statusCode)
        }

        let envelope: APIEnvelope<Response>
        do {
            envelope = try JSONDecoder().decode(APIEnvelope<Response>.self, from: data)
        } catch {
            throw AnkerCloudError.malformedResponse
        }
        // Anker has returned both ordinary HTTP auth statuses and an API-level
        // 26084 for revoked/expired sessions. Normalize these so the app can
        // delete the unusable Keychain item and present a real sign-in path
        // instead of retrying the same rejected token five times.
        if envelope.code == 401 || envelope.code == 403 || envelope.code == 26_084 {
            throw AnkerCloudError.expiredAuthentication
        }
        guard envelope.code == 0 else {
            throw AnkerCloudError.server(code: envelope.code, message: envelope.message ?? "")
        }
        guard let payload = envelope.data else {
            throw AnkerCloudError.malformedResponse
        }
        return payload
    }

    private func endpointURL(_ path: String) throws -> URL {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains(".."),
              !path.contains("://"),
              !path.contains("?"),
              !path.contains("#")
        else {
            throw AnkerCloudError.invalidEndpoint
        }
        var components = URLComponents(url: authentication.serverBase, resolvingAgainstBaseURL: false)
        components?.path = "/" + path
        guard let url = components?.url,
              url.scheme == authentication.serverBase.scheme,
              url.host == authentication.serverBase.host
        else {
            throw AnkerCloudError.invalidEndpoint
        }
        return url
    }

    private static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isValidMQTTHost(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.contains("/"),
              !value.contains(":"),
              !value.contains("#"),
              !value.contains("?")
        else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45 || byte == 46
        }
    }

    private struct EmptyBody: Encodable, Sendable {}

    private struct APIEnvelope<Payload: Decodable>: Decodable {
        var code: Int
        var message: String?
        var data: Payload?

        private enum CodingKeys: String, CodingKey {
            case code
            case message = "msg"
            case data
        }
    }

    private struct BoundDevicesPayload: Decodable, Sendable {
        var data: [AnkerBoundDevice]
    }

    private struct MQTTInfoPayload: Decodable, Sendable {
        var userID: String
        var appName: String
        var thingName: String
        var certificateID: String
        var endpoint: String
        var certificatePEM: String
        var privateKey: String

        private enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case appName = "app_name"
            case thingName = "thing_name"
            case certificateID = "certificate_id"
            case endpoint = "endpoint_addr"
            case certificatePEM = "certificate_pem"
            case privateKey = "private_key"
        }
    }
}
