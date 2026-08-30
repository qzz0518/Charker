import XCTest
@testable import A2687Protocol

final class HandshakeTests: XCTestCase {
    private func engine() -> HandshakeEngine {
        HandshakeEngine(
            clientID: "79ebed35-dc9c-4904-b40c-72c4e863aa10",
            timeZoneRule: "CST-8",
            countryCode: "CN"
        )
    }

    private func payload(_ hex: String) throws -> Payload {
        try Payload.parse(hex.hexBytes)
    }

    func testLadderWalksTheRecordedDeviceResponses() throws {
        var engine = engine()
        let first = engine.start()
        XCTAssertEqual(first.opcode, A2687.Opcode.initialConnect)
        XCTAssertEqual(first.encryption, .negotiation)
        XCTAssertEqual(engine.stage, .initialConnect)

        var next = try engine.handle(
            opcode: A2687.Opcode.initialConnect,
            payload: payload(Fixtures.plainDeviceInitialConnect)
        )
        XCTAssertEqual(next.map(\.opcode), [A2687.Opcode.capability])
        XCTAssertEqual(engine.stage, .capability)

        next = try engine.handle(
            opcode: A2687.Opcode.capability, payload: payload(Fixtures.plainDeviceCapability)
        )
        XCTAssertEqual(next.map(\.opcode), [A2687.Opcode.baseInfo])
        XCTAssertEqual(engine.negotiatedMTU, 297)
        XCTAssertEqual(engine.authMethod, 0x44)
        XCTAssertEqual(engine.encryptionMethod, 0x02)

        next = try engine.handle(
            opcode: A2687.Opcode.baseInfo, payload: payload(Fixtures.plainDeviceBaseInfo)
        )
        XCTAssertEqual(engine.deviceInfo.productName, "Charging")
        XCTAssertEqual(engine.deviceInfo.firmwareVersion, "v0.0.5.0")
        // These two come from the upstream MIT capture and belong to that project
        // author's charger, not to anything here. They cannot be genericised: the
        // decoder is being checked against the exact bytes of a real response.
        XCTAssertEqual(engine.deviceInfo.serialNumber, "ASHDK7U1F51501771")
        XCTAssertEqual(engine.deviceInfo.macAddress, "7C:E9:13:81:46:02")

        // The MTU the device asked for is echoed back in set-capability.
        let setCapability = try XCTUnwrap(next.first)
        let fields = try Payload.parse(setCapability.plaintext)
        XCTAssertEqual(fields[A2687.Field.a4], [0x29, 0x01])
        XCTAssertEqual(fields[A2687.Field.a5], [0x44])
        XCTAssertEqual(fields[A2687.Field.a6], [0x02])

        next = try engine.handle(
            opcode: A2687.Opcode.setCapability, payload: payload(Fixtures.plainDeviceSetCapability)
        )
        let publicKey = try XCTUnwrap(next.first)
        XCTAssertEqual(publicKey.opcode, A2687.Opcode.publicKey)
        XCTAssertEqual(publicKey.encryption, .negotiation)
        XCTAssertEqual(try Payload.parse(publicKey.plaintext)[A2687.Field.a1]?.count, 64)

        XCTAssertNil(engine.sessionKeys)
        next = try engine.handle(
            opcode: A2687.Opcode.publicKey, payload: payload(Fixtures.plainDevicePublicKey)
        )
        XCTAssertNotNil(engine.sessionKeys)
        XCTAssertEqual(engine.stage, .aesMetadata)
        XCTAssertEqual(next.first?.encryption, .session, "metadata must move to the session key")

        next = try engine.handle(opcode: A2687.Opcode.aesMetadata, payload: payload("00"))
        XCTAssertEqual(next.map(\.opcode), [A2687.Opcode.userAuth])

        next = try engine.handle(opcode: A2687.Opcode.userAuth, payload: payload("00"))
        XCTAssertEqual(engine.stage, .sessionReady)
        XCTAssertEqual(
            next.map(\.opcode),
            [A2687.Opcode.readAll, A2687.Opcode.bindSuccess, A2687.Opcode.realtimeTrigger]
        )
        XCTAssertTrue(next.allSatisfy { $0.group == Frame.sessionGroup })

        // With no account id configured the bind getter carries no identity: a
        // foreign one is worse than none.
        let bind = try Payload.parse(next[1].plaintext)
        XCTAssertNil(bind[A2687.Field.a3])
    }

    func testSharedSecretAloneIsNotSessionReady() throws {
        var engine = engine()
        _ = engine.start()
        _ = try engine.handle(opcode: A2687.Opcode.initialConnect, payload: payload(Fixtures.plainDeviceInitialConnect))
        _ = try engine.handle(opcode: A2687.Opcode.capability, payload: payload(Fixtures.plainDeviceCapability))
        _ = try engine.handle(opcode: A2687.Opcode.baseInfo, payload: payload(Fixtures.plainDeviceBaseInfo))
        _ = try engine.handle(opcode: A2687.Opcode.setCapability, payload: payload(Fixtures.plainDeviceSetCapability))
        _ = try engine.handle(opcode: A2687.Opcode.publicKey, payload: payload(Fixtures.plainDevicePublicKey))
        XCTAssertNotNil(engine.sessionKeys)
        XCTAssertNotEqual(engine.stage, .sessionReady)
        XCTAssertTrue(engine.stage < .sessionReady)
    }

    func testOutOfOrderAndAsynchronousFramesAreIgnored() throws {
        var engine = engine()
        _ = engine.start()
        XCTAssertTrue(try engine.handle(opcode: A2687.Opcode.realtimeReport, payload: payload("00")).isEmpty)
        XCTAssertTrue(try engine.handle(opcode: A2687.Opcode.userAuth, payload: payload("00")).isEmpty)
        XCTAssertEqual(engine.stage, .initialConnect)
    }

    func testRejectionStopsTheLadder() throws {
        var engine = engine()
        _ = engine.start()
        XCTAssertThrowsError(
            try engine.handle(opcode: A2687.Opcode.initialConnect, payload: Payload(status: 3, fields: []))
        ) { error in
            XCTAssertEqual(error as? HandshakeError, .deviceRejected(stage: .initialConnect, status: 3))
        }
    }

    func testOnlyTheKnownFlakyStagesMayBeSkipped() throws {
        var engine = engine()
        _ = engine.start()
        XCTAssertFalse(engine.canSkipCurrentStage)
        XCTAssertThrowsError(try engine.skipCurrentStage())

        _ = try engine.handle(opcode: A2687.Opcode.initialConnect, payload: payload(Fixtures.plainDeviceInitialConnect))
        _ = try engine.handle(opcode: A2687.Opcode.capability, payload: payload(Fixtures.plainDeviceCapability))
        _ = try engine.handle(opcode: A2687.Opcode.baseInfo, payload: payload(Fixtures.plainDeviceBaseInfo))
        _ = try engine.handle(opcode: A2687.Opcode.setCapability, payload: payload(Fixtures.plainDeviceSetCapability))
        _ = try engine.handle(opcode: A2687.Opcode.publicKey, payload: payload(Fixtures.plainDevicePublicKey))

        XCTAssertTrue(engine.canSkipCurrentStage)
        XCTAssertEqual(try engine.skipCurrentStage().map(\.opcode), [A2687.Opcode.userAuth])
        XCTAssertEqual(
            try engine.skipCurrentStage().map(\.opcode),
            [A2687.Opcode.readAll, A2687.Opcode.bindSuccess, A2687.Opcode.realtimeTrigger]
        )
        XCTAssertEqual(engine.stage, .sessionReady)
    }

    func testHandlingBeforeStartIsRefused() {
        var engine = engine()
        XCTAssertThrowsError(try engine.handle(opcode: A2687.Opcode.initialConnect, payload: Payload(status: 0, fields: [])))
    }
}
