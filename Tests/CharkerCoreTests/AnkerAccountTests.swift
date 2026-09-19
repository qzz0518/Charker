import CryptoKit
import XCTest
@testable import CharkerCore

/// The login crypto has to match Anker's server byte for byte — a mismatch just
/// looks like a wrong password. These vectors were produced with the same
/// primitives the Python reference client uses, from a fixed private scalar.
final class AnkerAccountTests: XCTestCase {
    private let clientPrivateKeyHex =
        "7dfbea61cd95cee49c458ad7419e817f1ade9a66136de3c7d5787af1458e39f4"
    private let expectedSharedKeyHex =
        "9eab5f3f93c514a483763eb8dd755c7540f391a00d9fd539fb1124fe12cbede7"
    private let expectedClientPublicKeyHex =
        "04060ea168f232aedb37fb2d120c49180329ac72ab5ec3eb8fd30a2f252dc5e151"
        + "dabccd9b1dc1e288704ca760a0d8c918e5c94823a1f609a4bf07fb4c33ee2190"

    private func fixedKey() throws -> P256.KeyAgreement.PrivateKey {
        try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(clientPrivateKeyHex.hexBytes))
    }

    func testSharedKeyMatchesTheReferenceImplementation() throws {
        let shared = try AnkerAccountClient.sharedKey(privateKey: try fixedKey())
        XCTAssertEqual(shared.hexString, expectedSharedKeyHex)
        XCTAssertEqual(shared.count, 32)
    }

    func testClientPublicKeyIsAnUncompressedPoint() throws {
        let raw = [UInt8](try fixedKey().publicKey.x963Representation)
        XCTAssertEqual(raw.hexString, expectedClientPublicKeyHex)
        XCTAssertEqual(raw.first, 0x04)
        XCTAssertEqual(raw.count, 65)
    }

    func testPasswordEncryptionMatchesKnownVectors() throws {
        let key = expectedSharedKeyHex.hexBytes
        let vectors: [(String, String)] = [
            ("hunter2", "wCJPQmgOLDIjflE00kSqkA=="),
            ("", "zFCwJ1eg7fuGOK/0t4G4kg=="),
            (String(repeating: "a", count: 16), "1aU4/yoR9bUa6XpgKmuE8VDoHvRr7DuiMxAXGS+SiH4="),
            ("密码测试", "l1+tJ01LiarN+CqBudbmjw=="),
        ]
        for (plaintext, expected) in vectors {
            XCTAssertEqual(try AnkerAccountClient.encrypt(plaintext, with: key), expected, plaintext)
        }
    }

    func testEncryptionRejectsAWrongSizedKey() {
        XCTAssertThrowsError(try AnkerAccountClient.encrypt("x", with: [UInt8](repeating: 0, count: 16)))
    }

    func testServerSelection() {
        // The reset-mail domain is the tell: ankerpower-api-eu means EU served.
        XCTAssertEqual(AnkerAccountClient.serverBase(for: "JP"), AnkerAccountClient.euServer)
        XCTAssertEqual(AnkerAccountClient.serverBase(for: "de"), AnkerAccountClient.euServer)
        // The charging app's own `.com` table is exactly these seven.
        for code in ["AR", "AU", "BR", "CA", "MX", "NZ", "US"] {
            XCTAssertEqual(AnkerAccountClient.serverBase(for: code), AnkerAccountClient.comServer, code)
        }
        // anker-solix-api lists these under `.com`; for chargers that server
        // accepts the login and then reports no devices.
        for code in ["HK", "TW", "SG", "KR", "IN", "ZA"] {
            XCTAssertEqual(AnkerAccountClient.serverBase(for: code), AnkerAccountClient.euServer, code)
        }
        // Mainland accounts use the independently verified CN service.
        XCTAssertEqual(AnkerAccountClient.serverBase(for: "CN"), AnkerAccountClient.cnServer)
        XCTAssertEqual(AnkerAccountClient.serverBase(for: "ZZ"), AnkerAccountClient.euServer)
    }

    func testGMTStringFormat() {
        let text = AnkerAccountClient.gmtString(for: Date())
        XCTAssertTrue(text.hasPrefix("GMT"), text)
        XCTAssertEqual(text.count, 9, text)
        XCTAssertTrue(text.contains(":"), text)
    }

    func testInputValidationHappensBeforeAnyNetworkCall() async {
        let client = AnkerAccountClient()
        do {
            _ = try await client.login(email: "nope", password: "x", country: "JP")
            XCTFail("should reject a malformed address")
        } catch {
            XCTAssertEqual(error as? AnkerLoginError, .invalidEmail)
        }
        do {
            _ = try await client.login(email: "a@b.com", password: "", country: "JP")
            XCTFail("should reject an empty password")
        } catch {
            XCTAssertEqual(error as? AnkerLoginError, .emptyPassword)
        }
    }
}

private extension String {
    var hexBytes: [UInt8] {
        var out: [UInt8] = []
        var index = startIndex
        while index < endIndex, let next = self.index(index, offsetBy: 2, limitedBy: endIndex) {
            out.append(UInt8(self[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }
}

private extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

final class AnkerRegionTests: XCTestCase {
    func testEveryRegionResolvesToAServer() {
        XCTAssertFalse(AnkerRegion.all.isEmpty)
        for region in AnkerRegion.all {
            XCTAssertEqual(region.code.count, 2, region.code)
            XCTAssertFalse(region.name.isEmpty, region.code)
            XCTAssertTrue(["ankerpower-api-eu.anker.com", "ankerpower-api.anker.com", "aiot-api-cn.anker.com.cn"].contains(region.serverHost), region.code)
        }
    }

    func testNoDuplicateCodes() {
        let codes = AnkerRegion.all.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
    }

    func testServerMappingMatchesAnkersTable() {
        XCTAssertTrue(XCTUnwrap0(AnkerRegion.named("JP")).isEUServed)
        XCTAssertFalse(XCTUnwrap0(AnkerRegion.named("CN")).isEUServed)
        XCTAssertFalse(XCTUnwrap0(AnkerRegion.named("US")).isEUServed)
        XCTAssertTrue(XCTUnwrap0(AnkerRegion.named("HK")).isEUServed)
    }

    func testLookupIsCaseInsensitiveAndRejectsJunk() {
        XCTAssertEqual(AnkerRegion.named("jp")?.code, "JP")
        XCTAssertNil(AnkerRegion.named("ZZ"))
    }

    private func XCTUnwrap0(_ region: AnkerRegion?) -> AnkerRegion {
        region ?? AnkerRegion.common[0]
    }
}

final class MailDomainsTests: XCTestCase {
    func testCommonDomainsLeadWithChineseProviders() {
        XCTAssertEqual(MailDomains.common.first, "qq.com")
        XCTAssertTrue(MailDomains.common.contains("163.com"))
        XCTAssertTrue(MailDomains.common.contains("gmail.com"))
        XCTAssertEqual(Set(MailDomains.common).count, MailDomains.common.count)
    }

    func testCustomTagCannotCollideWithARealDomain() {
        XCTAssertFalse(MailDomains.common.contains(MailDomains.customTag))
        XCTAssertFalse(MailDomains.customTag.contains("."))
    }

    func testSplitPastedAddress() {
        let parts = MailDomains.split(" Charker.User@Gmail.com ")
        XCTAssertEqual(parts?.local, "Charker.User")
        XCTAssertEqual(parts?.domain, "gmail.com", "domain is lowercased, local part is not")
    }

    func testSplitRejectsIncompleteInput() {
        XCTAssertNil(MailDomains.split("charker"))
        XCTAssertNil(MailDomains.split("charker@"))
        XCTAssertNil(MailDomains.split("@gmail.com"))
        XCTAssertNil(MailDomains.split(""))
    }

    func testSplitTakesTheFirstAtSign() {
        XCTAssertEqual(MailDomains.split("a@b@c.com")?.domain, "b@c.com")
    }
}
