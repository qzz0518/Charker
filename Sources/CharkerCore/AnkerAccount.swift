import CommonCrypto
import CryptoKit
import Foundation

/// Account and cloud requests carry credentials. Refuse HTTP redirects so an
/// origin selected from Charker's fixed regional allowlist cannot forward an
/// encrypted password or auth token to a different host.
final class AnkerNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// The public account identity used by the A2687 BLE handshake and cloud UI.
/// Authentication material lives separately in ``AnkerAuthentication`` so code
/// that only needs the id cannot accidentally retain a token.
public struct AnkerAccount: Sendable, Equatable, Codable {
    public var userID: String
    public var nickname: String?

    public init(userID: String, nickname: String? = nil) {
        self.userID = userID
        self.nickname = nickname
    }
}

public enum AnkerLoginError: LocalizedError, Equatable {
    case invalidEmail
    case invalidPhoneNumber
    case invalidVerificationCode
    case phoneLoginRequired
    case emptyPassword
    case network(String)
    /// The App Sandbox blocked the connection — the app is missing
    /// `com.apple.security.network.client`. Worth naming separately because it
    /// looks like a generic network failure but no amount of retrying fixes it.
    case sandboxBlocked
    case server(code: Int, message: String)
    case malformedResponse
    case missingUserID
    case missingAuthToken
    case missingTokenExpiration

    public var errorDescription: String? {
        switch self {
        case .invalidPhoneNumber:
            return L10n.text("请输入 11 位中国大陆手机号", table: "Core")
        case .invalidVerificationCode:
            return L10n.text("请输入 6 位短信验证码", table: "Core")
        case .phoneLoginRequired:
            return L10n.text("中国大陆账号请使用手机号和验证码登录", table: "Core")
        case .invalidEmail:
            return L10n.text("邮箱格式不对", table: "Core")
        case .emptyPassword:
            return L10n.text("请输入密码", table: "Core")
        case .network(let detail):
            return L10n.format("网络错误：%@", detail, table: "Core")
        case .sandboxBlocked:
            return L10n.text(
                "系统沙盒拦截了这次连接。应用缺少出站网络授权（com.apple.security.network.client），需要重新构建并签名。",
                table: "Core"
            )
        case .server(let code, let message):
            // The server's own message is the most useful thing here; wrong
            // password and wrong region look nothing alike.
            return message.isEmpty
                ? L10n.format("登录失败（代码 %d）", code, table: "Core")
                : L10n.format("%@（代码 %d）", message, code, table: "Core")
        case .malformedResponse:
            return L10n.text("服务器返回了无法解析的内容", table: "Core")
        case .missingUserID:
            return L10n.text("登录成功，但没有返回账号 ID", table: "Core")
        case .missingAuthToken:
            return L10n.text("登录成功，但没有返回云端访问令牌", table: "Core")
        case .missingTokenExpiration:
            return L10n.text("登录成功，但没有返回访问令牌有效期", table: "Core")
        }
    }
}

/// The authenticated result required by Anker's HTTP and MQTT bootstrap APIs.
///
/// `authToken` is a credential. Callers must either keep this value in memory or
/// persist it through ``AnkerKeychainAuthenticationStore``; it must never enter
/// UserDefaults, diagnostics or command-line arguments. The account password is
/// deliberately absent and cannot be recovered from this value.
public struct AnkerAuthentication: Sendable, Equatable, Codable {
    public var account: AnkerAccount
    public var authToken: String
    public var tokenExpiresAt: Date
    public var regionCode: String
    private var chinaService: Bool

    public init(
        account: AnkerAccount,
        authToken: String,
        tokenExpiresAt: Date,
        regionCode: String
    ) {
        self.account = account
        self.authToken = authToken
        self.tokenExpiresAt = tokenExpiresAt
        self.regionCode = regionCode.uppercased()
        self.chinaService = self.regionCode == "CN"
    }

    private enum CodingKeys: String, CodingKey {
        case account, authToken, tokenExpiresAt, regionCode, chinaService
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        account = try values.decode(AnkerAccount.self, forKey: .account)
        authToken = try values.decode(String.self, forKey: .authToken)
        tokenExpiresAt = try values.decode(Date.self, forKey: .tokenExpiresAt)
        regionCode = try values.decode(String.self, forKey: .regionCode).uppercased()
        // Earlier development builds allowed CN email accounts on the EU host.
        // Never forward an existing EU token to CN merely because routing changed.
        chinaService = try values.decodeIfPresent(Bool.self, forKey: .chinaService) ?? false
    }

    public var serverBase: URL {
        if regionCode == "CN", !chinaService { return URL(string: AnkerAccountClient.euServer)! }
        return URL(string: AnkerAccountClient.serverBase(for: regionCode))!
    }

    public func isValid(at date: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        !authToken.isEmpty && tokenExpiresAt.timeIntervalSince(date) > leeway
    }
}

/// Signs in to Anker to read the account identity and, when explicitly requested,
/// the short-lived authentication material needed by the cloud read path.
///
/// The compatibility ``login(email:password:country:)`` method still returns only
/// the account id used by the A2687 BLE handshake. ``authenticate`` returns the
/// token as well for an explicitly selected cloud connection. In both cases the
/// password exists for the duration of this request and is never logged or
/// persisted.
public struct AnkerAccountClient: Sendable {
    public static let euServer = "https://ankerpower-api-eu.anker.com"
    public static let comServer = "https://ankerpower-api.anker.com"
    public static let cnServer = "https://aiot-api-cn.anker.com.cn"

    /// Anker's fixed login public key: an uncompressed P-256 point. The password is
    /// encrypted to it so it is never on the wire in the clear, even inside TLS.
    private static let serverPublicKeyHex =
        "04c5c00c4f8d1197cc7c3167c52bf7acb054d722f0ef08dcd7e0883236e0d72a"
        + "3868d9750cb47fa4619248f3d83f0f662671dadc6e2d31c2f41db0161651c7c076"

    /// Countries served by the `.com` endpoint. Mainland China has its own
    /// endpoint; other countries fall back to the EU endpoint.
    private static let comCountries: Set<String> = [
        "AR", "AU", "BR", "CA", "DZ", "EG", "HK", "IN", "JO", "KR", "LB", "LY",
        "MA", "MX", "NG", "NZ", "PS", "RU", "SG", "SY", "TN", "TW", "US", "ZA",
    ]

    /// The country code decides which server to talk to, and is also sent as the
    /// `ab` field of the login body. Pick it from the domain in Anker's own
    /// password-reset mail: `ankerpower-api-eu` means an EU-served account.
    public static func serverBase(for country: String) -> String {
        if country.uppercased() == "CN" { return cnServer }
        return comCountries.contains(country.uppercased()) ? comServer : euServer
    }

    public static func isEUServed(_ country: String) -> Bool {
        serverBase(for: country) == euServer
    }

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            // Ephemeral: no cookies, no credential store, no disk cache. A one-shot
            // login has no business leaving anything behind.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            self.session = URLSession(
                configuration: configuration,
                delegate: AnkerNoRedirectDelegate(),
                delegateQueue: nil
            )
        }
    }

    public func login(email: String, password: String, country: String) async throws -> AnkerAccount {
        let result = try await loginPayload(email: email, password: password, country: country)
        return result.account
    }

    /// Performs the same login as ``login(email:password:country:)`` but retains
    /// the returned auth token and expiry for the A2345 cloud bootstrap.
    public func authenticate(
        email: String,
        password: String,
        country: String
    ) async throws -> AnkerAuthentication {
        let result = try await loginPayload(email: email, password: password, country: country)
        guard let authToken = result.authToken, !authToken.isEmpty else {
            throw AnkerLoginError.missingAuthToken
        }
        guard let tokenExpiresAt = result.tokenExpiresAt else {
            throw AnkerLoginError.missingTokenExpiration
        }
        return AnkerAuthentication(
            account: result.account,
            authToken: authToken,
            tokenExpiresAt: tokenExpiresAt,
            regionCode: result.regionCode
        )
    }

    private struct LoginPayload {
        var account: AnkerAccount
        var authToken: String?
        var tokenExpiresAt: Date?
        var regionCode: String
    }

    private func loginPayload(
        email: String,
        password: String,
        country: String
    ) async throws -> LoginPayload {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let country = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard country != "CN" else { throw AnkerLoginError.phoneLoginRequired }
        guard email.contains("@"), email.count >= 5 else { throw AnkerLoginError.invalidEmail }
        guard !password.isEmpty else { throw AnkerLoginError.emptyPassword }

        let privateKey = P256.KeyAgreement.PrivateKey()
        let sharedKey = try Self.sharedKey(privateKey: privateKey)
        let clientPublicKey = privateKey.publicKey.x963Representation.map {
            String(format: "%02x", $0)
        }.joined()

        let now = Date()
        let offsetMilliseconds = TimeZone.current.secondsFromGMT(for: now) * 1000
        let body: [String: Any] = [
            "ab": country,
            "client_secret_info": ["public_key": clientPublicKey],
            "enc": 0,
            "email": email,
            "password": try Self.encrypt(password, with: sharedKey),
            "time_zone": offsetMilliseconds,
            "transaction": String(Int(now.timeIntervalSince1970 * 1000)),
        ]

        guard let url = URL(string: "\(Self.serverBase(for: country))/passport/login"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw AnkerLoginError.malformedResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("DESKTOP", forHTTPHeaderField: "model-type")
        request.setValue("anker_power", forHTTPHeaderField: "app-name")
        request.setValue("android", forHTTPHeaderField: "os-type")
        request.setValue(country, forHTTPHeaderField: "country")
        request.setValue(Self.gmtString(for: now), forHTTPHeaderField: "timezone")

        let root = try await execute(request)
        return try Self.parseLoginPayload(root, country: country)
    }

    private func execute(_ request: URLRequest, redactServerMessage: Bool = false) async throws -> [String: Any] {
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as NSError {
            // EPERM from the POSIX domain is the sandbox refusing to open the
            // socket, not a transient failure.
            if error.domain == NSPOSIXErrorDomain && error.code == 1 {
                throw AnkerLoginError.sandboxBlocked
            }
            if error.domain == NSURLErrorDomain
                && error.code == NSURLErrorNotConnectedToInternet {
                throw AnkerLoginError.network(L10n.text("没有网络连接", table: "Core"))
            }
            throw AnkerLoginError.network(error.localizedDescription)
        }

        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AnkerLoginError.server(
                code: http.statusCode,
                message: L10n.format("服务器返回 HTTP %d", http.statusCode, table: "Core")
            )
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnkerLoginError.malformedResponse
        }
        let code = (root["code"] as? Int) ?? -1
        guard code == 0 else {
            throw AnkerLoginError.server(code: code, message: redactServerMessage ? Self.phoneErrorMessage(code) : (root["msg"] as? String) ?? "")
        }
        return root
    }

    private static func parseLoginPayload(_ root: [String: Any], country: String) throws -> LoginPayload {
        guard let payloadObject = root["data"] as? [String: Any] else {
            throw AnkerLoginError.malformedResponse
        }
        guard let userID = payloadObject["user_id"] as? String, !userID.isEmpty else {
            throw AnkerLoginError.missingUserID
        }
        return LoginPayload(
            account: AnkerAccount(
                userID: userID,
                nickname: payloadObject["nick_name"] as? String
            ),
            authToken: payloadObject["auth_token"] as? String,
            tokenExpiresAt: Self.tokenExpiration(payloadObject["token_expires_at"]),
            regionCode: country
        )
    }

    private static func tokenExpiration(_ raw: Any?) -> Date? {
        let seconds: TimeInterval?
        switch raw {
        case let value as NSNumber: seconds = value.doubleValue
        case let value as String: seconds = TimeInterval(value)
        default: seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
    }

    // MARK: - Mainland China SMS login

    public static func isValidPhoneNumber(_ value: String) -> Bool {
        value.utf8.count == 11 && value.first == "1" && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    public static func isValidVerificationCode(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    /// A single user-initiated send, with no automatic retry or account creation.
    /// Real-account testing confirmed these endpoints work without terminal ID.
    public func sendPhoneVerificationCode(phoneNumber: String) async throws {
        let phone = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidPhoneNumber(phone) else { throw AnkerLoginError.invalidPhoneNumber }
        _ = try await phoneRequest("phone_verification_code", body: ["phone_number": phone, "kind": "login"])
    }

    public func login(phoneNumber: String, verificationCode: String) async throws -> AnkerAccount {
        try await phoneLoginPayload(phoneNumber: phoneNumber, verificationCode: verificationCode).account
    }

    public func authenticate(phoneNumber: String, verificationCode: String) async throws -> AnkerAuthentication {
        let result = try await phoneLoginPayload(phoneNumber: phoneNumber, verificationCode: verificationCode)
        guard let token = result.authToken, !token.isEmpty else { throw AnkerLoginError.missingAuthToken }
        guard let expiration = result.tokenExpiresAt else { throw AnkerLoginError.missingTokenExpiration }
        return AnkerAuthentication(account: result.account, authToken: token, tokenExpiresAt: expiration, regionCode: "CN")
    }

    private func phoneLoginPayload(phoneNumber: String, verificationCode: String) async throws -> LoginPayload {
        let phone = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidPhoneNumber(phone) else { throw AnkerLoginError.invalidPhoneNumber }
        guard Self.isValidVerificationCode(code) else { throw AnkerLoginError.invalidVerificationCode }
        let key = P256.KeyAgreement.PrivateKey()
        let publicKey = key.publicKey.x963Representation.map { String(format: "%02x", $0) }.joined()
        let root = try await phoneRequest("phone_verification_login", body: [
            "phone_number": phone, "verify_code": code, "client_secret_info": ["public_key": publicKey],
        ])
        withExtendedLifetime(key) {}
        return try Self.parseLoginPayload(root, country: "CN")
    }

    private func phoneRequest(_ endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "\(Self.cnServer)/passport/\(endpoint)")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.allHTTPHeaderFields = Self.chinaHeaders()
        return try await execute(request, redactServerMessage: true)
    }

    /// Shared with the authenticated CN cloud path, matching the tested probe.
    static func chinaHeaders(at now: Date = Date()) -> [String: String] {
        ["Content-Type": "application/json", "Model-Type": "PHONE",
         "App-Name": "anker_power", "App-Version": "3.23.0", "Os-Type": "android",
         "Country": "CN", "Language": "zh-Hans", "X-App-Key": "CN",
         "Timezone": gmtString(for: now), "X-Auth-TS": String(Int(now.timeIntervalSince1970))]
    }

    private static func phoneErrorMessage(_ code: Int) -> String {
        // Backend messages can echo account input; use local copy for SMS.
        switch code {
        case 26124: return L10n.text("该手机号尚未注册，请先在安克 App 注册并绑定设备", table: "Core")
        case 26008, 26125: return L10n.text("验证码发送失败，请稍后重试", table: "Core")
        default: return ""
        }
    }

    // MARK: - Crypto

    static func sharedKey(privateKey: P256.KeyAgreement.PrivateKey) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var index = serverPublicKeyHex.startIndex
        while index < serverPublicKeyHex.endIndex,
              let next = serverPublicKeyHex.index(index, offsetBy: 2, limitedBy: serverPublicKeyHex.endIndex) {
            bytes.append(UInt8(serverPublicKeyHex[index..<next], radix: 16) ?? 0)
            index = next
        }
        guard let serverKey = try? P256.KeyAgreement.PublicKey(x963Representation: Data(bytes)),
              let secret = try? privateKey.sharedSecretFromKeyAgreement(with: serverKey) else {
            throw AnkerLoginError.malformedResponse
        }
        return secret.withUnsafeBytes { Array($0) }
    }

    /// AES-256-CBC with the 32-byte shared secret as the key and its first 16 bytes
    /// as the IV, PKCS7 padded, base64 encoded — the shape Anker's login expects.
    static func encrypt(_ text: String, with key: [UInt8]) throws -> String {
        guard key.count == 32 else { throw AnkerLoginError.malformedResponse }
        let plaintext = Array(text.utf8)
        var output = [UInt8](repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            key, key.count,
            Array(key[0..<16]),
            plaintext, plaintext.count,
            &output, output.count, &moved
        )
        guard status == kCCSuccess else { throw AnkerLoginError.malformedResponse }
        return Data(output[0..<moved]).base64EncodedString()
    }

    static func gmtString(for date: Date) -> String {
        let offset = TimeZone.current.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let hours = abs(offset) / 3600
        let minutes = (abs(offset) % 3600) / 60
        return String(format: "GMT%@%02d:%02d", sign, hours, minutes)
    }
}
