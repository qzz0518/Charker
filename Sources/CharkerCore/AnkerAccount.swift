import CommonCrypto
import CryptoKit
import Foundation

/// The one piece of account information Charker needs: the id the charger checks
/// at `0x0027`. Nothing else from the login response is kept — in particular the
/// auth token is deliberately discarded, because the app never talks to Anker again.
public struct AnkerAccount: Sendable, Equatable {
    public var userID: String
    public var nickname: String?

    public init(userID: String, nickname: String? = nil) {
        self.userID = userID
        self.nickname = nickname
    }
}

public enum AnkerLoginError: LocalizedError, Equatable {
    case invalidEmail
    case emptyPassword
    case network(String)
    /// The App Sandbox blocked the connection — the app is missing
    /// `com.apple.security.network.client`. Worth naming separately because it
    /// looks like a generic network failure but no amount of retrying fixes it.
    case sandboxBlocked
    case server(code: Int, message: String)
    case malformedResponse
    case missingUserID

    public var errorDescription: String? {
        switch self {
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
        }
    }
}

/// Signs in to Anker once to read the account's `user_id`.
///
/// This is the only network call in the whole app, it happens only when the user
/// asks for it, and nothing from it is written to disk except the resulting id.
/// The password exists for the duration of the request and is never logged,
/// persisted, or sent anywhere but Anker's own login endpoint over TLS.
public struct AnkerAccountClient: Sendable {
    public static let euServer = "https://ankerpower-api-eu.anker.com"
    public static let comServer = "https://ankerpower-api.anker.com"

    /// Anker's fixed login public key: an uncompressed P-256 point. The password is
    /// encrypted to it so it is never on the wire in the clear, even inside TLS.
    private static let serverPublicKeyHex =
        "04c5c00c4f8d1197cc7c3167c52bf7acb054d722f0ef08dcd7e0883236e0d72a"
        + "3868d9750cb47fa4619248f3d83f0f662671dadc6e2d31c2f41db0161651c7c076"

    /// Countries served by the `.com` endpoint. Everything else — including codes
    /// that appear in neither list, such as `CN` — resolves to the EU endpoint.
    private static let comCountries: Set<String> = [
        "AR", "AU", "BR", "CA", "DZ", "EG", "HK", "IN", "JO", "KR", "LB", "LY",
        "MA", "MX", "NG", "NZ", "PS", "RU", "SG", "SY", "TN", "TW", "US", "ZA",
    ]

    /// The country code decides which server to talk to, and is also sent as the
    /// `ab` field of the login body. Pick it from the domain in Anker's own
    /// password-reset mail: `ankerpower-api-eu` means an EU-served account.
    public static func serverBase(for country: String) -> String {
        comCountries.contains(country.uppercased()) ? comServer : euServer
    }

    public static func isEUServed(_ country: String) -> Bool {
        !comCountries.contains(country.uppercased())
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
            self.session = URLSession(configuration: configuration)
        }
    }

    public func login(email: String, password: String, country: String) async throws -> AnkerAccount {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let country = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
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

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode),
           (try? JSONSerialization.jsonObject(with: data)) == nil {
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
            throw AnkerLoginError.server(code: code, message: (root["msg"] as? String) ?? "")
        }
        guard let payloadObject = root["data"] as? [String: Any] else {
            throw AnkerLoginError.malformedResponse
        }
        guard let userID = payloadObject["user_id"] as? String, !userID.isEmpty else {
            throw AnkerLoginError.missingUserID
        }
        return AnkerAccount(userID: userID, nickname: payloadObject["nick_name"] as? String)
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
