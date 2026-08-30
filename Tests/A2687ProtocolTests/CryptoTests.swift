import CryptoKit
import XCTest
@testable import A2687Protocol

final class CryptoTests: XCTestCase {
    private func payload(_ hex: String) throws -> [UInt8] {
        try PacketCodec.decode(hex.hexBytes).payload
    }

    func testOpensRealNegotiationFramesWithTheStaticKey() throws {
        let cases: [(String, String)] = [
            (Fixtures.clientInitialConnect, Fixtures.plainClientInitialConnect),
            (Fixtures.clientCapability, Fixtures.plainClientCapability),
            (Fixtures.deviceInitialConnect, Fixtures.plainDeviceInitialConnect),
            (Fixtures.deviceCapability, Fixtures.plainDeviceCapability),
            (Fixtures.deviceBaseInfo, Fixtures.plainDeviceBaseInfo),
            (Fixtures.deviceSetCapability, Fixtures.plainDeviceSetCapability),
            (Fixtures.devicePublicKey, Fixtures.plainDevicePublicKey),
        ]
        for (frame, expected) in cases {
            let opened = try A2687Crypto.open(try payload(frame), with: .negotiation)
            XCTAssertEqual(opened.hexString, expected)
        }
    }

    func testSealRoundTripsAndReproducesTheCapture() throws {
        let sealed = try A2687Crypto.seal(Fixtures.plainClientCapability.hexBytes, with: .negotiation)
        XCTAssertEqual(sealed.hexString, try payload(Fixtures.clientCapability).hexString)
    }

    func testTamperedTagFailsClosed() throws {
        var sealed = try payload(Fixtures.deviceCapability)
        sealed[sealed.count - 1] ^= 0x01
        XCTAssertThrowsError(try A2687Crypto.open(sealed, with: .negotiation)) { error in
            XCTAssertEqual(error as? A2687Crypto.CryptoError, .authenticationFailed)
        }
    }

    func testTamperedCiphertextFailsClosed() throws {
        var sealed = try payload(Fixtures.deviceCapability)
        sealed[0] ^= 0x01
        XCTAssertThrowsError(try A2687Crypto.open(sealed, with: .negotiation))
    }

    func testRejectsPayloadShorterThanTheTag() {
        XCTAssertThrowsError(try A2687Crypto.open([UInt8](repeating: 0, count: 16), with: .negotiation))
    }

    func testKeyScheduleSplitsTheSharedSecret() throws {
        let secret = (0..<32).map { UInt8($0) }
        let keys = try A2687Crypto.Keys(secretPrefix: secret)
        // Round-tripping proves the 16/12 split is what both sides use.
        let sealed = try A2687Crypto.seal([0xAA, 0xBB], with: keys)
        XCTAssertEqual(try A2687Crypto.open(sealed, with: keys), [0xAA, 0xBB])
        XCTAssertThrowsError(try A2687Crypto.Keys(secretPrefix: Array(secret.prefix(27))))
    }

    func testEphemeralAgreementMatchesOnBothSides() throws {
        let client = A2687Crypto.makeEphemeralKey()
        let device = A2687Crypto.makeEphemeralKey()
        let clientSide = try A2687Crypto.sharedSecret(
            privateKey: client, devicePoint: A2687Crypto.rawPublicKey(device)
        )
        let deviceSide = try A2687Crypto.sharedSecret(
            privateKey: device, devicePoint: A2687Crypto.rawPublicKey(client)
        )
        XCTAssertEqual(clientSide, deviceSide)
        XCTAssertEqual(clientSide.count, 32)
    }

    func testEveryConnectionUsesAFreshKey() {
        let first = A2687Crypto.rawPublicKey(A2687Crypto.makeEphemeralKey())
        let second = A2687Crypto.rawPublicKey(A2687Crypto.makeEphemeralKey())
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.count, 64)
    }

    func testRejectsMalformedDevicePoint() {
        let key = A2687Crypto.makeEphemeralKey()
        XCTAssertThrowsError(try A2687Crypto.sharedSecret(privateKey: key, devicePoint: [0x00]))
        XCTAssertThrowsError(
            try A2687Crypto.sharedSecret(privateKey: key, devicePoint: [UInt8](repeating: 0xFF, count: 64))
        )
    }

    func testAgreesWithARealDevicePoint() throws {
        let payload = try Payload.parse(Fixtures.plainDevicePublicKey.hexBytes)
        let point = try XCTUnwrap(payload[A2687.Field.a1])
        XCTAssertEqual(point.count, 64)
        let secret = try A2687Crypto.sharedSecret(
            privateKey: A2687Crypto.makeEphemeralKey(), devicePoint: point
        )
        XCTAssertEqual(secret.count, 32)
    }
}
