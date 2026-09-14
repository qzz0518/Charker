import Foundation
import XCTest
@testable import CharkerCore

final class A2345MQTTTests: XCTestCase {
    func testConnectPacketIsMQTT311WithCleanSessionAndNoCredentials() throws {
        XCTAssertEqual(
            try A2345MQTTCodec.connect(clientID: "cid", keepAlive: 60),
            Data([
                0x10, 0x0F,
                0x00, 0x04, 0x4D, 0x51, 0x54, 0x54,
                0x04, 0x02, 0x00, 0x3C,
                0x00, 0x03, 0x63, 0x69, 0x64,
            ])
        )
    }

    func testSubscribePacketUsesRequiredFlagsAndQoSZero() throws {
        XCTAssertEqual(
            try A2345MQTTCodec.subscribe(
                topic: "dt/a/#", packetIdentifier: 0x1234
            ),
            Data([
                0x82, 0x0B, 0x12, 0x34,
                0x00, 0x06, 0x64, 0x74, 0x2F, 0x61, 0x2F, 0x23,
                0x00,
            ])
        )
    }

    func testPublishPacketIsExactQoSZeroWithoutRetainOrPacketIdentifier() throws {
        XCTAssertEqual(
            try A2345MQTTCodec.publishQoSZero(
                topic: "cmd/a",
                payload: Data("{}".utf8)
            ),
            Data([
                0x30, 0x09,
                0x00, 0x05, 0x63, 0x6D, 0x64, 0x2F, 0x61,
                0x7B, 0x7D,
            ])
        )
    }

    func testPublishPacketRejectsWildcardTopicNames() {
        for topic in ["", "cmd/a/+", "cmd/a/#"] {
            XCTAssertThrowsError(
                try A2345MQTTCodec.publishQoSZero(
                    topic: topic,
                    payload: Data()
                )
            ) {
                XCTAssertEqual($0 as? A2345MQTTCodecError, .malformedPacket)
            }
        }
    }

    func testFragmentedConnackDoesNotConsumeBytesUntilComplete() throws {
        var buffer = Data([0x20, 0x02, 0x00])
        XCTAssertNil(try A2345MQTTCodec.decodeNext(from: &buffer))
        XCTAssertEqual(buffer, Data([0x20, 0x02, 0x00]))

        buffer.append(0x00)
        XCTAssertEqual(
            try A2345MQTTCodec.decodeNext(from: &buffer),
            .connack(sessionPresent: false, returnCode: 0)
        )
        XCTAssertTrue(buffer.isEmpty)
    }

    func testQoSOnePublishDecodesAndHasMatchingPubAck() throws {
        let topic = Data("dt/anker_power/A2345/SERIAL/data".utf8)
        let payload = Data([0x01, 0x02, 0x03])
        var body = Data([UInt8(topic.count >> 8), UInt8(topic.count & 0xFF)])
        body.append(topic)
        body.append(contentsOf: [0x22, 0x33])
        body.append(payload)
        var packet = Data([0x32, UInt8(body.count)])
        packet.append(body)

        XCTAssertEqual(
            try A2345MQTTCodec.decodeNext(from: &packet),
            .publish(
                topic: "dt/anker_power/A2345/SERIAL/data",
                payload: payload,
                qos: 1,
                packetIdentifier: 0x2233
            )
        )
        XCTAssertEqual(
            try A2345MQTTCodec.pubAck(packetIdentifier: 0x2233),
            Data([0x40, 0x02, 0x22, 0x33])
        )
    }

    func testDecoderHandlesMultiByteRemainingLengthAndLeavesFollowingPacket() throws {
        let topic = Data("a".utf8)
        let payload = Data(repeating: 0x7A, count: 130)
        var body = Data([0x00, 0x01])
        body.append(topic)
        body.append(payload)
        XCTAssertEqual(body.count, 133)
        var packet = Data([0x30, 0x85, 0x01])
        packet.append(body)
        packet.append(contentsOf: [0xD0, 0x00])

        XCTAssertEqual(
            try A2345MQTTCodec.decodeNext(from: &packet),
            .publish(topic: "a", payload: payload, qos: 0, packetIdentifier: nil)
        )
        XCTAssertEqual(
            try A2345MQTTCodec.decodeNext(from: &packet),
            .pingResponse
        )
        XCTAssertTrue(packet.isEmpty)
    }

    func testMalformedRemainingLengthAndQoSTwoFailClosed() {
        var malformed = Data([0x30, 0x80, 0x80, 0x80, 0x80, 0x00])
        XCTAssertThrowsError(try A2345MQTTCodec.decodeNext(from: &malformed)) {
            XCTAssertEqual($0 as? A2345MQTTCodecError, .malformedPacket)
        }

        var qosTwo = Data([0x34, 0x04, 0x00, 0x01, 0x61, 0x00])
        XCTAssertThrowsError(try A2345MQTTCodec.decodeNext(from: &qosTwo)) {
            XCTAssertEqual($0 as? A2345MQTTCodecError, .unsupportedQoS(2))
        }
    }

    func testDeclaredPacketAboveBusinessLimitFailsBeforeBodyArrives() {
        let oversized = A2345MQTTCodec.maximumPacketBytes + 1
        var remaining = oversized
        var encodedLength: [UInt8] = []
        repeat {
            var byte = UInt8(remaining % 128)
            remaining /= 128
            if remaining > 0 { byte |= 0x80 }
            encodedLength.append(byte)
        } while remaining > 0
        var packet = Data([0x30])
        packet.append(contentsOf: encodedLength)

        XCTAssertThrowsError(try A2345MQTTCodec.decodeNext(from: &packet)) {
            XCTAssertEqual($0 as? A2345MQTTCodecError, .malformedPacket)
        }
    }

    func testPingAndDisconnectAreTwoByteControlPackets() {
        XCTAssertEqual(A2345MQTTCodec.pingRequest(), Data([0xC0, 0x00]))
        XCTAssertEqual(A2345MQTTCodec.disconnect(), Data([0xE0, 0x00]))
    }

    func testHandshakeWatchdogCoversEveryPreSubscriptionPhaseOnly() {
        XCTAssertEqual(A2345MQTTSubscriber.handshakeTimeout, 20)
        XCTAssertEqual(A2345MQTTSubscriber.realtimeRefreshInterval, 8)
        XCTAssertFalse(A2345MQTTSubscriberState.idle.requiresHandshakeWatchdog)
        XCTAssertTrue(A2345MQTTSubscriberState.connecting.requiresHandshakeWatchdog)
        XCTAssertTrue(A2345MQTTSubscriberState.awaitingConnack.requiresHandshakeWatchdog)
        XCTAssertTrue(A2345MQTTSubscriberState.awaitingSuback(1).requiresHandshakeWatchdog)
        XCTAssertFalse(A2345MQTTSubscriberState.subscribed.requiresHandshakeWatchdog)
        XCTAssertFalse(A2345MQTTSubscriberState.stopped.requiresHandshakeWatchdog)
    }

    func testTopicBuilderRejectsWildcardsFromServerIdentity() {
        let credentials = AnkerMQTTCredentials(
            userID: "user",
            appName: "anker_power",
            thingName: "thing",
            certificateID: "certificate",
            endpoint: "aiot-mqtt-eu.anker.com",
            certificateDER: Data([1]),
            privateKeyDER: Data([2])
        )
        XCTAssertThrowsError(try credentials.subscriptionTopic(for: AnkerBoundDevice(
            deviceSerial: "SERIAL/#", productCode: "A2345"
        ))) {
            XCTAssertEqual($0 as? AnkerCloudError, .invalidMQTTTopicComponent)
        }
        XCTAssertThrowsError(try credentials.commandTopic(for: AnkerBoundDevice(
            deviceSerial: "SERIAL/+", productCode: "A2345"
        ))) {
            XCTAssertEqual($0 as? AnkerCloudError, .invalidMQTTTopicComponent)
        }
    }

    func testReadCommandEnvelopeAndNestedPayloadAreExactCompactJSON() throws {
        let builder = try makeReadCommandBuilder(ownerUserID: "owner")
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)

        let data = try builder.envelopeData(for: .statusSnapshot, at: epoch)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"head":{"client_id":"android-anker_power-user-certificate","cmd":17,"cmd_status":2,"device_pn":"A2345","device_sn":"SERIAL123","msg_seq":1,"seed":1,"sess_id":"1234-5678","sign_code":1,"timestamp":1700000000,"version":"1.0.0.1"},"payload":"{\"account_id\":\"owner\",\"data\":\"/wkUAAMADwIAoQEi/gUDAPFTZVE=\",\"device_sn\":\"SERIAL123\"}"}"#
        )
    }

    func testReadCommandPacketUsesValidatedCommandTopicAndQoSZero() throws {
        let builder = try makeReadCommandBuilder()
        let packet = try builder.mqttPacket(
            for: .realtimeTrigger,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        var buffer = packet
        guard case .publish(let topic, let payload, let qos, let identifier) =
            try A2345MQTTCodec.decodeNext(from: &buffer)
        else {
            return XCTFail("expected a PUBLISH packet")
        }
        XCTAssertEqual(topic, "cmd/anker_power/A2345/SERIAL123/req")
        XCTAssertEqual(qos, 0)
        XCTAssertNil(identifier)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains(
            "/wkUAAMADwILoQEi/gUDAPFTZVo="
        ))
    }

    func testReadCommandBuilderCrossChecksExplicitDeviceAndSubscriptionTopic() {
        XCTAssertThrowsError(try A2345MQTTReadCommandBuilder(
            credentials: makeCredentials(),
            device: AnkerBoundDevice(
                deviceSerial: "OTHER",
                productCode: "A2345"
            ),
            subscriptionTopic: "dt/anker_power/A2345/SERIAL123/#"
        )) {
            XCTAssertEqual($0 as? A2345MQTTError, .invalidConfiguration)
        }

        XCTAssertThrowsError(try A2345MQTTReadCommandBuilder(
            credentials: makeCredentials(),
            device: AnkerBoundDevice(
                deviceSerial: "SERIAL123",
                productCode: "A2687"
            ),
            subscriptionTopic: "dt/anker_power/A2687/SERIAL123/#"
        )) {
            XCTAssertEqual($0 as? A2345MQTTError, .invalidConfiguration)
        }
    }

    func testInboundTopicMustBelongToTheExactExplicitDeviceRoot() throws {
        let builder = try makeReadCommandBuilder()

        XCTAssertTrue(builder.acceptsInboundTopic(
            "dt/anker_power/A2345/SERIAL123"
        ))
        XCTAssertTrue(builder.acceptsInboundTopic(
            "dt/anker_power/A2345/SERIAL123/data"
        ))
        XCTAssertFalse(builder.acceptsInboundTopic(
            "dt/anker_power/A2345/OTHER/data"
        ))
        XCTAssertFalse(builder.acceptsInboundTopic(
            "dt/anker_power/A2345/SERIAL1234/data"
        ))
    }

    func testSuccessfulSubackTransitionPinsStateAndInitialReadOrder() throws {
        let transition = try A2345MQTTSubscriptionTransition.accept(
            state: .awaitingSuback(7),
            packetIdentifier: 7,
            returnCodes: [0x00]
        )

        XCTAssertEqual(transition.nextState, .subscribed)
        XCTAssertEqual(
            transition.initialReadRequests,
            [.statusSnapshot, .realtimeTrigger]
        )
    }

    func testSubackMustContainExactlyOneQoSZeroGrant() {
        let cases: [(UInt16, [UInt8], A2345MQTTError)] = [
            (8, [0x00], .protocolViolation),
            (7, [], .protocolViolation),
            (7, [0x00, 0x00], .protocolViolation),
            (7, [0x01], .protocolViolation),
            (7, [0x80], .subscriptionRejected(0x80)),
        ]

        for (identifier, codes, expectedError) in cases {
            XCTAssertThrowsError(try A2345MQTTSubscriptionTransition.accept(
                state: .awaitingSuback(7),
                packetIdentifier: identifier,
                returnCodes: codes
            )) {
                XCTAssertEqual($0 as? A2345MQTTError, expectedError)
            }
        }
    }

    private func makeCredentials() -> AnkerMQTTCredentials {
        AnkerMQTTCredentials(
            userID: "user",
            appName: "anker_power",
            thingName: "thing",
            certificateID: "certificate",
            endpoint: "aiot-mqtt-eu.anker.com",
            certificateDER: Data([1]),
            privateKeyDER: Data([2])
        )
    }

    private func makeReadCommandBuilder(
        ownerUserID: String? = nil
    ) throws -> A2345MQTTReadCommandBuilder {
        try A2345MQTTReadCommandBuilder(
            credentials: makeCredentials(),
            device: AnkerBoundDevice(
                deviceSerial: "SERIAL123",
                productCode: "A2345",
                ownerUserID: ownerUserID
            ),
            subscriptionTopic: "dt/anker_power/A2345/SERIAL123/#"
        )
    }
}
