import CryptoKit
import Foundation
import XCTest
@testable import CharkerCore

final class AnkerCloudTests: XCTestCase {
    override func tearDown() {
        CloudURLProtocol.handler = nil
        super.tearDown()
    }

    func testLegacyCNEmailRecordStaysOnEUWhileNewSMSRecordStaysOnCN() throws {
        let auth = AnkerAuthentication(account: AnkerAccount(userID: "test"), authToken: "test", tokenExpiresAt: .distantFuture, regionCode: "CN")
        let encoded = try JSONEncoder().encode(auth)
        XCTAssertEqual(try JSONDecoder().decode(AnkerAuthentication.self, from: encoded).serverBase.host, "aiot-api-cn.anker.com.cn")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "chinaService")
        let restored = try JSONDecoder().decode(AnkerAuthentication.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.serverBase.host, "ankerpower-api-eu.anker.com")
    }

    func testAlreadyCancelledSMSRequestDoesNotSend() async {
        CloudURLProtocol.handler = { _ in XCTFail("Cancelled request must not send"); return Self.response(["code": 0]) }
        let client = AnkerAccountClient(session: stubSession())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await client.sendPhoneVerificationCode(phoneNumber: "13800138000")
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSMSRejectsHTTPFailureEvenWithSuccessEnvelope() async {
        CloudURLProtocol.handler = { _ in (403, Data("{\"code\":0,\"data\":{}}".utf8)) }
        do {
            try await AnkerAccountClient(session: stubSession()).sendPhoneVerificationCode(phoneNumber: "13800138000")
            XCTFail("HTTP failure must not count as sent")
        } catch {
            guard case .server(let code, _) = error as? AnkerLoginError else { return XCTFail("Expected HTTP error") }
            XCTAssertEqual(code, 403)
        }
    }

    func testSMSCloudRequiresExpiration() async {
        CloudURLProtocol.handler = { _ in Self.response(["code": 0, "data": ["user_id": "test", "auth_token": "test-token"]]) }
        do {
            _ = try await AnkerAccountClient(session: stubSession()).authenticate(phoneNumber: "13800138000", verificationCode: "001234")
            XCTFail("Cloud requires expiration")
        } catch { XCTAssertEqual(error as? AnkerLoginError, .missingTokenExpiration) }
    }

    func testSMSFlowUsesCNAndPreservesLeadingZeroCode() async throws {
        CloudURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "aiot-api-cn.anker.com.cn")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-App-Key"), "CN")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Model-Type"), "PHONE")
            XCTAssertNil(request.value(forHTTPHeaderField: "Openudid"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any])
            XCTAssertEqual(json["phone_number"] as? String, "13800138000")
            if request.url?.path == "/passport/phone_verification_code" {
                XCTAssertEqual(Set(json.keys), ["phone_number", "kind"])
                XCTAssertEqual(json["kind"] as? String, "login")
                return Self.response(["code": 0])
            }
            XCTAssertEqual(request.url?.path, "/passport/phone_verification_login")
            XCTAssertEqual(Set(json.keys), ["phone_number", "verify_code", "client_secret_info"])
            XCTAssertEqual(json["verify_code"] as? String, "001234")
            let secret = try XCTUnwrap(json["client_secret_info"] as? [String: String])
            let publicKey = try XCTUnwrap(secret["public_key"])
            XCTAssertEqual(publicKey.count, 130)
            XCTAssertTrue(publicKey.hasPrefix("04"))
            return Self.response(["code": 0, "data": [
                "user_id": String(repeating: "c", count: 40), "auth_token": "test-cn-token",
                "token_expires_at": "2000000000000",
            ]])
        }
        let client = AnkerAccountClient(session: stubSession())
        try await client.sendPhoneVerificationCode(phoneNumber: "13800138000")
        let auth = try await client.authenticate(phoneNumber: "13800138000", verificationCode: "001234")
        XCTAssertEqual(auth.regionCode, "CN")
        XCTAssertEqual(auth.serverBase.host, "aiot-api-cn.anker.com.cn")
        XCTAssertEqual(auth.authToken, "test-cn-token")
        XCTAssertEqual(auth.tokenExpiresAt, Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testSMSValidationRejectsInvalidInputBeforeNetwork() async throws {
        CloudURLProtocol.handler = { _ in XCTFail("Invalid input must not reach the network"); return Self.response(["code": 0]) }
        let client = AnkerAccountClient(session: stubSession())
        for phone in ["", "+8613800138000", "1380013800", "１３８００１３８０００", "1380013800x"] {
            do { try await client.sendPhoneVerificationCode(phoneNumber: phone); XCTFail("Expected invalid phone") }
            catch { XCTAssertEqual(error as? AnkerLoginError, .invalidPhoneNumber) }
        }
        for code in ["", "12345", "1234567", "１２３４５６"] {
            do { _ = try await client.login(phoneNumber: "13800138000", verificationCode: code); XCTFail("Expected invalid code") }
            catch { XCTAssertEqual(error as? AnkerLoginError, .invalidVerificationCode) }
        }
        do { _ = try await client.login(email: "person@example.com", password: "secret", country: "CN"); XCTFail("CN requires phone login") }
        catch { XCTAssertEqual(error as? AnkerLoginError, .phoneLoginRequired) }
    }

    func testSMSFailureDoesNotLeakBackendEchoOrRetry() async throws {
        var calls = 0
        CloudURLProtocol.handler = { _ in
            calls += 1
            return Self.response(["code": 100053, "msg": "13800138000 001234 SECRET_TOKEN"])
        }
        do {
            try await AnkerAccountClient(session: stubSession()).sendPhoneVerificationCode(phoneNumber: "13800138000")
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error as? AnkerLoginError, .server(code: 100053, message: "")) }
        XCTAssertEqual(calls, 1)
    }

    func testPhoneOwnerIDDoesNotRequireTokenButCloudDoes() async throws {
        CloudURLProtocol.handler = { _ in Self.response(["code": 0, "data": ["user_id": String(repeating: "d", count: 40)]]) }
        let client = AnkerAccountClient(session: stubSession())
        let account = try await client.login(phoneNumber: "13800138000", verificationCode: "001234")
        XCTAssertEqual(account.userID, String(repeating: "d", count: 40))
        do { _ = try await client.authenticate(phoneNumber: "13800138000", verificationCode: "001234"); XCTFail("Cloud requires token") }
        catch { XCTAssertEqual(error as? AnkerLoginError, .missingAuthToken) }
    }

    func testCNBoundDevicesKeepTokenOnCNHost() async throws {
        let auth = AnkerAuthentication(account: AnkerAccount(userID: String(repeating: "c", count: 40)), authToken: "cn-test", tokenExpiresAt: .distantFuture, regionCode: "CN")
        CloudURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "aiot-api-cn.anker.com.cn")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-auth-token"), "cn-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-App-Key"), "CN")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Model-Type"), "PHONE")
            return Self.response(["code": 0, "data": ["data": []]])
        }
        let devices = try await AnkerCloudClient(authentication: auth, session: stubSession()).boundDevices()
        XCTAssertTrue(devices.isEmpty)
    }

    func testAuthenticatedLoginKeepsTokenAndRegionWhileLegacyLoginStillReturnsAccount() async throws {
        let expiration = Date(timeIntervalSince1970: 2_000_000_000)
        CloudURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "ankerpower-api-eu.anker.com")
            XCTAssertEqual(request.url?.path, "/passport/login")
            XCTAssertEqual(request.value(forHTTPHeaderField: "country"), "JP")
            let body = try Self.requestBody(request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["ab"] as? String, "JP")
            XCTAssertNotEqual(json["password"] as? String, "do-not-send-in-clear")
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("do-not-send-in-clear"))
            return Self.response([
                "code": 0,
                "msg": "success",
                "data": [
                    "user_id": String(repeating: "a", count: 40),
                    "nick_name": "tester",
                    "auth_token": "test-token",
                    "token_expires_at": Int(expiration.timeIntervalSince1970),
                ],
            ])
        }
        let client = AnkerAccountClient(session: stubSession())

        let authentication = try await client.authenticate(
            email: "person@example.com",
            password: "do-not-send-in-clear",
            country: "jp"
        )
        XCTAssertEqual(authentication.account.nickname, "tester")
        XCTAssertEqual(authentication.authToken, "test-token")
        XCTAssertEqual(authentication.tokenExpiresAt, expiration)
        XCTAssertEqual(authentication.regionCode, "JP")
        XCTAssertEqual(authentication.serverBase.host, "ankerpower-api-eu.anker.com")

        let legacy = try await client.login(
            email: "person@example.com",
            password: "do-not-send-in-clear",
            country: "JP"
        )
        XCTAssertEqual(legacy.userID, authentication.account.userID)
        XCTAssertEqual(legacy.nickname, "tester")
    }

    func testLegacyLoginAcceptsAnAccountOnlyResponseButCloudAuthenticationFailsClosed() async throws {
        CloudURLProtocol.handler = { _ in
            Self.response([
                "code": 0,
                "data": ["user_id": String(repeating: "b", count: 40)],
            ])
        }
        let client = AnkerAccountClient(session: stubSession())
        let account = try await client.login(
            email: "person@example.com", password: "password", country: "JP"
        )
        XCTAssertEqual(account.userID, String(repeating: "b", count: 40))
        do {
            _ = try await client.authenticate(
                email: "person@example.com", password: "password", country: "JP"
            )
            XCTFail("cloud authentication must require a token")
        } catch {
            XCTAssertEqual(error as? AnkerLoginError, .missingAuthToken)
        }
    }

    func testBoundDevicesUsesAuthenticatedHeadersAndFiltersA2345() async throws {
        let authentication = makeAuthentication()
        CloudURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/power_service/v1/app/get_relate_and_bind_devices"
            )
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-auth-token"), "test-token")
            let expectedGToken = Insecure.MD5.hash(data: Data(authentication.account.userID.utf8))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(request.value(forHTTPHeaderField: "gtoken"), expectedGToken)
            XCTAssertEqual(request.value(forHTTPHeaderField: "country"), "JP")
            XCTAssertEqual(try Self.requestBody(request), Data("{}".utf8))
            return Self.response([
                "code": 0,
                "data": [
                    "data": [
                        [
                            "device_sn": "SERIALA2345",
                            "product_code": "A2345",
                            "device_name": "Prime Charger",
                            "alias_name": "Desk charger",
                            "wifi_online": true,
                            "device_sw_version": "2.1.1.6",
                        ],
                        [
                            "device_sn": "SERIALA2687",
                            "product_code": "A2687",
                        ],
                    ],
                ],
            ])
        }

        let client = AnkerCloudClient(
            authentication: authentication,
            session: stubSession(),
            now: { Date(timeIntervalSince1970: 1_900_000_000) }
        )
        let devices = try await client.boundDevices(productCode: "a2345")
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].deviceSerial, "SERIALA2345")
        XCTAssertEqual(devices[0].displayName, "Desk charger")
        XCTAssertEqual(devices[0].wifiOnline, true)
        XCTAssertEqual(devices[0].softwareVersion, "2.1.1.6")
    }

    func testMQTTCredentialsDecodePEMIdentityAndBuildAReadTopic() async throws {
        CloudURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app/devicemanage/get_user_mqtt_info")
            return Self.response([
                "code": 0,
                "data": [
                    "user_id": String(repeating: "a", count: 40),
                    "app_name": "anker_power",
                    "thing_name": "thing-name",
                    "certificate_id": "certificate-id",
                    "endpoint_addr": "aiot-mqtt-eu.anker.com",
                    "certificate_pem": """
                    -----BEGIN CERTIFICATE-----
                    AQIDBA==
                    -----END CERTIFICATE-----
                    """,
                    "private_key": """
                    -----BEGIN RSA PRIVATE KEY-----
                    BQYHCA==
                    -----END RSA PRIVATE KEY-----
                    """,
                ],
            ])
        }
        let client = AnkerCloudClient(
            authentication: makeAuthentication(),
            session: stubSession(),
            now: { Date(timeIntervalSince1970: 1_900_000_000) }
        )
        let credentials = try await client.mqttCredentials()
        XCTAssertEqual(credentials.endpoint, "aiot-mqtt-eu.anker.com")
        XCTAssertEqual(credentials.certificateDER, Data([1, 2, 3, 4]))
        XCTAssertEqual(credentials.privateKeyDER, Data([5, 6, 7, 8]))
        XCTAssertEqual(credentials.clientID(randomSuffix: 42), "thing-name_00042")

        let device = AnkerBoundDevice(
            deviceSerial: "SERIAL123", productCode: "A2345"
        )
        XCTAssertEqual(
            try credentials.subscriptionTopic(for: device),
            "dt/anker_power/A2345/SERIAL123/#"
        )
        XCTAssertEqual(
            try credentials.commandTopic(for: device),
            "cmd/anker_power/A2345/SERIAL123/req"
        )
    }

    func testMQTTCredentialsRejectMalformedPEMWithoutRetainingServerText() async {
        CloudURLProtocol.handler = { _ in
            Self.response([
                "code": 0,
                "data": [
                    "user_id": String(repeating: "a", count: 40),
                    "app_name": "anker_power",
                    "thing_name": "thing-name",
                    "certificate_id": "certificate-id",
                    "endpoint_addr": "aiot-mqtt-eu.anker.com",
                    "certificate_pem": "not a certificate",
                    "private_key": "not a private key",
                ],
            ])
        }
        let client = AnkerCloudClient(
            authentication: makeAuthentication(),
            session: stubSession(),
            now: { Date(timeIntervalSince1970: 1_900_000_000) }
        )

        do {
            _ = try await client.mqttCredentials()
            XCTFail("malformed PEM identity must fail closed")
        } catch {
            XCTAssertEqual(error as? AnkerCloudError, .missingMQTTCredentials)
        }
    }

    func testExpiredAuthenticationStopsBeforeNetwork() async {
        CloudURLProtocol.handler = { _ in
            XCTFail("expired authentication must not reach URLSession")
            return Self.response(["code": 0, "data": ["data": []]])
        }
        var authentication = makeAuthentication()
        authentication.tokenExpiresAt = Date(timeIntervalSince1970: 100)
        let client = AnkerCloudClient(
            authentication: authentication,
            session: stubSession(),
            now: { Date(timeIntervalSince1970: 200) }
        )
        do {
            _ = try await client.boundDevices()
            XCTFail("expired authentication must fail")
        } catch {
            XCTAssertEqual(error as? AnkerCloudError, .expiredAuthentication)
        }
    }

    func testServerAuthenticationFailuresAreNormalized() async {
        let authentication = makeAuthentication()
        let client = AnkerCloudClient(
            authentication: authentication,
            session: stubSession(),
            now: { Date(timeIntervalSince1970: 1_900_000_000) }
        )

        CloudURLProtocol.handler = { _ in (401, Data()) }
        do {
            _ = try await client.boundDevices()
            XCTFail("HTTP authentication failure must be normalized")
        } catch {
            XCTAssertEqual(error as? AnkerCloudError, .expiredAuthentication)
        }

        CloudURLProtocol.handler = { _ in
            Self.response(["code": 26_084, "msg": "session expired"])
        }
        do {
            _ = try await client.boundDevices()
            XCTFail("API authentication failure must be normalized")
        } catch {
            XCTAssertEqual(error as? AnkerCloudError, .expiredAuthentication)
        }
    }

    func testAuthenticationRecordContainsNoPasswordField() throws {
        let encoded = try JSONEncoder().encode(makeAuthentication())
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("test-token"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("password"))
        XCTAssertEqual(
            try JSONDecoder().decode(AnkerAuthentication.self, from: encoded),
            makeAuthentication()
        )
    }

    private func makeAuthentication() -> AnkerAuthentication {
        AnkerAuthentication(
            account: AnkerAccount(userID: String(repeating: "a", count: 40), nickname: "tester"),
            authToken: "test-token",
            tokenExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            regionCode: "JP"
        )
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(_ object: [String: Any]) -> (Int, Data) {
        (200, try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else {
                throw try XCTUnwrap(stream.streamError)
            }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class CloudURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, data) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "application/json"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
