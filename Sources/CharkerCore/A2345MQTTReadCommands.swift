import A2345Protocol
import Foundation

/// The complete outbound device-command vocabulary exposed to the MQTT layer.
/// Both cases are read requests; arbitrary opcodes and arbitrary frame bytes are
/// intentionally not representable here.
enum A2345MQTTReadRequest: Equatable, Sendable {
    case statusSnapshot
    case realtimeTrigger

    func frame(at date: Date) -> Data {
        switch self {
        case .statusSnapshot:
            return Data(A2345ReadRequestEncoder.statusSnapshot(at: date))
        case .realtimeTrigger:
            return Data(A2345ReadRequestEncoder.realtimeTrigger(at: date))
        }
    }
}

/// A pure transition used by the live subscriber and unit tests. MQTT 3.1.1
/// permits a broker to grant QoS 1, but Charker requested exactly one QoS 0
/// subscription and fails closed unless the acknowledgement is exactly `[0]`.
struct A2345MQTTSubscriptionTransition: Equatable, Sendable {
    let nextState: A2345MQTTSubscriberState
    let initialReadRequests: [A2345MQTTReadRequest]

    static func accept(
        state: A2345MQTTSubscriberState,
        packetIdentifier: UInt16,
        returnCodes: [UInt8]
    ) throws -> Self {
        guard case .awaitingSuback(let expectedIdentifier) = state,
              packetIdentifier == expectedIdentifier,
              returnCodes.count == 1
        else {
            throw A2345MQTTError.protocolViolation
        }

        let returnCode = returnCodes[0]
        if returnCode == 0x80 {
            throw A2345MQTTError.subscriptionRejected(returnCode)
        }
        guard returnCode == 0x00 else {
            throw A2345MQTTError.protocolViolation
        }

        return Self(
            nextState: .subscribed,
            initialReadRequests: [.statusSnapshot, .realtimeTrigger]
        )
    }
}

/// Constructs the exact Anker JSON envelope and QoS-0 MQTT packet for the two
/// closed read requests. It stores no certificate material and cannot accept raw
/// command bytes.
struct A2345MQTTReadCommandBuilder: Sendable {
    static let sessionID = "1234-5678"

    let subscriptionTopic: String
    let commandTopic: String

    private let clientIdentifier: String
    private let accountID: String
    private let productCode: String
    private let deviceSerial: String

    init(
        credentials: AnkerMQTTCredentials,
        device: AnkerBoundDevice,
        subscriptionTopic: String
    ) throws {
        guard device.productCode == "A2345",
              !credentials.userID.isEmpty,
              !credentials.certificateID.isEmpty,
              credentials.userID.utf8.count <= 1_024,
              credentials.certificateID.utf8.count <= 1_024
        else {
            throw A2345MQTTError.invalidConfiguration
        }

        let expectedSubscriptionTopic: String
        let commandTopic: String
        do {
            expectedSubscriptionTopic = try credentials.subscriptionTopic(for: device)
            commandTopic = try credentials.commandTopic(for: device)
        } catch {
            throw A2345MQTTError.invalidConfiguration
        }
        guard subscriptionTopic == expectedSubscriptionTopic else {
            throw A2345MQTTError.invalidConfiguration
        }

        let ownerID = device.ownerUserID.flatMap { value in
            value.isEmpty ? nil : value
        } ?? credentials.userID
        guard ownerID.utf8.count <= 1_024 else {
            throw A2345MQTTError.invalidConfiguration
        }

        self.subscriptionTopic = expectedSubscriptionTopic
        self.commandTopic = commandTopic
        self.clientIdentifier = [
            "android",
            credentials.appName,
            credentials.userID,
            credentials.certificateID,
        ].joined(separator: "-")
        self.accountID = ownerID
        self.productCode = device.productCode
        self.deviceSerial = device.deviceSerial
    }

    /// Broker-side subscription filtering is not treated as an identity check.
    /// The delimiter is included in the prefix comparison so a serial such as
    /// `SERIAL1234` cannot collide with the subscribed `SERIAL123` device.
    func acceptsInboundTopic(_ topic: String) -> Bool {
        let wildcardSuffix = "/#"
        guard subscriptionTopic.hasSuffix(wildcardSuffix) else { return false }
        let root = String(subscriptionTopic.dropLast(wildcardSuffix.count))
        return topic == root || topic.hasPrefix(root + "/")
    }

    func envelopeData(
        for request: A2345MQTTReadRequest,
        at date: Date,
        sessionID: String = Self.sessionID
    ) throws -> Data {
        let timestamp = Int64(date.timeIntervalSince1970.rounded(.down))
        guard timestamp >= 0,
              timestamp <= Int64(UInt32.max),
              !sessionID.isEmpty,
              sessionID.utf8.count <= 128
        else {
            throw A2345MQTTError.invalidConfiguration
        }

        let payload = Payload(
            deviceSerial: deviceSerial,
            accountID: accountID,
            data: request.frame(at: date).base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let compactPayload = try encoder.encode(payload)
        guard let payloadString = String(data: compactPayload, encoding: .utf8) else {
            throw A2345MQTTError.protocolViolation
        }

        return try encoder.encode(Envelope(
            head: Head(
                version: "1.0.0.1",
                clientIdentifier: clientIdentifier,
                sessionID: sessionID,
                messageSequence: 1,
                seed: 1,
                timestamp: timestamp,
                commandStatus: 2,
                command: 17,
                signCode: 1,
                productCode: productCode,
                deviceSerial: deviceSerial
            ),
            payload: payloadString
        ))
    }

    func mqttPacket(
        for request: A2345MQTTReadRequest,
        at date: Date
    ) throws -> Data {
        try A2345MQTTCodec.publishQoSZero(
            topic: commandTopic,
            payload: envelopeData(for: request, at: date)
        )
    }
}

private extension A2345MQTTReadCommandBuilder {
    struct Envelope: Encodable {
        let head: Head
        let payload: String
    }

    struct Head: Encodable {
        let version: String
        let clientIdentifier: String
        let sessionID: String
        let messageSequence: Int
        let seed: Int
        let timestamp: Int64
        let commandStatus: Int
        let command: Int
        let signCode: Int
        let productCode: String
        let deviceSerial: String

        enum CodingKeys: String, CodingKey {
            case version
            case clientIdentifier = "client_id"
            case sessionID = "sess_id"
            case messageSequence = "msg_seq"
            case seed
            case timestamp
            case commandStatus = "cmd_status"
            case command = "cmd"
            case signCode = "sign_code"
            case productCode = "device_pn"
            case deviceSerial = "device_sn"
        }
    }

    struct Payload: Encodable {
        let deviceSerial: String
        let accountID: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case deviceSerial = "device_sn"
            case accountID = "account_id"
            case data
        }
    }
}
