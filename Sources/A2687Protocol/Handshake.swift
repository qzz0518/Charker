import CryptoKit
import Foundation

/// Which key schedule an outgoing message must be sealed with.
public enum Encryption: Sendable, Equatable {
    /// The firmware's static negotiation key, used until the ECDH exchange lands.
    case negotiation
    /// The derived per-connection session key.
    case session
}

/// A message the handshake wants sent, still in plaintext.
public struct OutgoingMessage: Sendable, Equatable {
    public var group: UInt8
    public var opcode: UInt16
    public var plaintext: [UInt8]
    public var encryption: Encryption
    /// Whether the handshake blocks on a response for this message.
    public var expectsResponse: Bool

    public init(
        group: UInt8, opcode: UInt16, plaintext: [UInt8],
        encryption: Encryption, expectsResponse: Bool
    ) {
        self.group = group
        self.opcode = opcode
        self.plaintext = plaintext
        self.encryption = encryption
        self.expectsResponse = expectsResponse
    }
}

/// The negotiation is a strict ladder. Each state names what we are waiting for,
/// so `sharedSecretDerived` deliberately does **not** mean the session is usable:
/// AES metadata and user auth still have to complete before writes are allowed.
public enum HandshakeStage: Int, Sendable, Comparable, CaseIterable {
    case idle = 0
    case initialConnect
    case capability
    case baseInfo
    case setCapability
    case publicKeyExchange
    case sharedSecretDerived
    case aesMetadata
    case userAuth
    case sessionReady

    public static func < (lhs: HandshakeStage, rhs: HandshakeStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Logical opcode whose response advances this stage.
    var awaitedOpcode: UInt16? {
        switch self {
        case .initialConnect: return A2687.Opcode.initialConnect
        case .capability: return A2687.Opcode.capability
        case .baseInfo: return A2687.Opcode.baseInfo
        case .setCapability: return A2687.Opcode.setCapability
        case .publicKeyExchange: return A2687.Opcode.publicKey
        case .aesMetadata: return A2687.Opcode.aesMetadata
        case .userAuth: return A2687.Opcode.userAuth
        case .idle, .sharedSecretDerived, .sessionReady: return nil
        }
    }

    public var isTerminal: Bool { self == .sessionReady }
}

public enum HandshakeError: Error, Equatable, Sendable {
    case notStarted
    case deviceRejected(stage: HandshakeStage, status: UInt8)
    case missingField(stage: HandshakeStage, id: UInt8)
    case crypto(A2687Crypto.CryptoError)
    case unexpectedStage(HandshakeStage)
}

/// Pure state machine for the A2687 negotiation.
///
/// It owns no I/O and no timers: it consumes decrypted responses and produces the
/// next plaintext messages, so it can be exercised end to end in tests.
public struct HandshakeEngine: @unchecked Sendable {
    public private(set) var stage: HandshakeStage = .idle
    public private(set) var deviceInfo = DeviceInfo()
    public private(set) var sessionKeys: A2687Crypto.Keys?
    /// MTU the device asked for in its capability response.
    public private(set) var negotiatedMTU: UInt16 = 0x0129
    public private(set) var authMethod: UInt8 = 0x44
    public private(set) var encryptionMethod: UInt8 = 0x02

    private var privateKey: P256.KeyAgreement.PrivateKey?
    private let clientID: String
    private let timeZoneRule: String
    private let countryCode: String
    /// The Anker account id the charger is bound to, if the user has supplied it.
    ///
    /// Hardened firmware refuses `0x0027` with status `0x09` and then silently
    /// ignores every session command unless this field carries the *owning*
    /// account. It is an account identity, not a device secret, and there is no
    /// way to derive it locally — see `docs/real-device-findings.md`.
    private let ownerUserID: String?
    private let now: @Sendable () -> Date

    public init(
        clientID: String,
        timeZoneRule: String,
        countryCode: String,
        ownerUserID: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clientID = clientID
        self.timeZoneRule = timeZoneRule
        self.countryCode = countryCode
        self.ownerUserID = ownerUserID
        self.now = now
    }

    /// `0x0027` registration. Hardened firmware only arms telemetry when `A2`
    /// carries the account that owns the charger, so the local pseudonymous id is
    /// only a fallback for older firmware that accepts anything.
    private func userAuthMessage() -> OutgoingMessage {
        negotiation(A2687.Opcode.userAuth, [
            TLV(id: A2687.Field.a1, value: timestamp()),
            TLV(id: A2687.Field.a2, value: Array((ownerUserID ?? clientID).utf8)),
        ])
    }

    /// Epoch seconds, little endian — the protocol's replay guard.
    private func timestamp() -> [UInt8] {
        let seconds = UInt32(truncatingIfNeeded: Int(now().timeIntervalSince1970))
        return [
            UInt8(seconds & 0xFF), UInt8((seconds >> 8) & 0xFF),
            UInt8((seconds >> 16) & 0xFF), UInt8((seconds >> 24) & 0xFF),
        ]
    }

    private func negotiation(_ opcode: UInt16, _ fields: [TLV]) -> OutgoingMessage {
        OutgoingMessage(
            group: Frame.negotiationGroup, opcode: opcode,
            plaintext: TLVCodec.encode(fields),
            encryption: stage >= .sharedSecretDerived ? .session : .negotiation,
            expectsResponse: true
        )
    }

    public mutating func start() -> OutgoingMessage {
        stage = .initialConnect
        privateKey = A2687Crypto.makeEphemeralKey()
        return negotiation(A2687.Opcode.initialConnect, [TLV(id: A2687.Field.a1, value: timestamp())])
    }

    /// Feeds one decrypted device response in. Frames that do not belong to the
    /// awaited stage — asynchronous reports, duplicates — return no messages
    /// instead of derailing the ladder.
    public mutating func handle(opcode: UInt16, payload: Payload) throws -> [OutgoingMessage] {
        guard stage != .idle else { throw HandshakeError.notStarted }
        guard let awaited = stage.awaitedOpcode, awaited == opcode else { return [] }
        guard payload.isOK else {
            throw HandshakeError.deviceRejected(stage: stage, status: payload.status ?? 0xFF)
        }

        switch stage {
        case .initialConnect:
            stage = .capability
            return [negotiation(A2687.Opcode.capability, [
                TLV(id: A2687.Field.a1, value: timestamp()),
                TLV(id: A2687.Field.a3, value: [0x20]),
                TLV(id: A2687.Field.a4, value: [0x00, 0xF0]),
            ])]

        case .capability:
            if let mtu = payload[A2687.Field.a2], mtu.count >= 2 {
                negotiatedMTU = UInt16(mtu[0]) | UInt16(mtu[1]) << 8
            }
            if let auth = payload[A2687.Field.a3]?.first { authMethod = auth }
            if let encryption = payload[A2687.Field.a5]?.first { encryptionMethod = encryption }
            stage = .baseInfo
            return [negotiation(A2687.Opcode.baseInfo, [TLV(id: A2687.Field.a1, value: timestamp())])]

        case .baseInfo:
            deviceInfo = DeviceInfo.decode(payload)
            stage = .setCapability
            return [negotiation(A2687.Opcode.setCapability, [
                TLV(id: A2687.Field.a1, value: timestamp()),
                TLV(id: A2687.Field.a3, value: [0x20]),
                TLV(id: A2687.Field.a4, value: [UInt8(negotiatedMTU & 0xFF), UInt8(negotiatedMTU >> 8)]),
                TLV(id: A2687.Field.a5, value: [authMethod]),
                TLV(id: A2687.Field.a6, value: [encryptionMethod]),
            ])]

        case .setCapability:
            guard let privateKey else { throw HandshakeError.notStarted }
            stage = .publicKeyExchange
            return [negotiation(A2687.Opcode.publicKey, [
                TLV(id: A2687.Field.a1, value: A2687Crypto.rawPublicKey(privateKey)),
            ])]

        case .publicKeyExchange:
            guard let privateKey else { throw HandshakeError.notStarted }
            guard let point = payload[A2687.Field.a1], point.count == 64 else {
                throw HandshakeError.missingField(stage: stage, id: A2687.Field.a1)
            }
            do {
                let secret = try A2687Crypto.sharedSecret(privateKey: privateKey, devicePoint: point)
                sessionKeys = try A2687Crypto.Keys(secretPrefix: secret)
            } catch let error as A2687Crypto.CryptoError {
                throw HandshakeError.crypto(error)
            }
            // The ephemeral private key has done its job; drop it immediately.
            self.privateKey = nil
            stage = .aesMetadata
            return [negotiation(A2687.Opcode.aesMetadata, [
                TLV(id: A2687.Field.a1, value: timestamp()),
                TLV(id: A2687.Field.a3, value: HandshakeEngine.aesMetadataCapability),
                TLV(id: A2687.Field.a5, value: Array(timeZoneRule.utf8)),
            ])]

        case .aesMetadata:
            stage = .userAuth
            return [userAuthMessage()]

        case .userAuth:
            stage = .sessionReady
            return sessionOpeningMessages()

        case .idle, .sharedSecretDerived, .sessionReady:
            throw HandshakeError.unexpectedStage(stage)
        }
    }

    /// `0x0022` and `0x0027` are documented as not always ACKing on some firmware.
    /// Rather than stalling forever the session layer may nudge the ladder once a
    /// stage times out; every other stage stays strictly blocking.
    public var canSkipCurrentStage: Bool {
        stage == .aesMetadata || stage == .userAuth
    }

    public mutating func skipCurrentStage() throws -> [OutgoingMessage] {
        switch stage {
        case .aesMetadata:
            stage = .userAuth
            return [userAuthMessage()]
        case .userAuth:
            stage = .sessionReady
            return sessionOpeningMessages()
        default:
            throw HandshakeError.unexpectedStage(stage)
        }
    }

    /// Capability bitmap the official `0x0022` generator sends. Verified against
    /// the app teardown; an all-zero value is accepted too but is not what the
    /// firmware is written for.
    static let aesMetadataCapability: [UInt8] = [0x80, 0x8F, 0xFF, 0xFF]

    /// Fired once the session opens: read the full state, announce the bind, then
    /// arm the stream. The trigger is the step that actually makes a hardened unit
    /// start reporting; the first two alone leave it silent.
    private func sessionOpeningMessages() -> [OutgoingMessage] {
        let now = self.now()
        return [
            CommandEncoder.readAll(at: now),
            CommandEncoder.realtimeProbe(countryCode: countryCode, ownerUserID: ownerUserID, at: now),
            CommandEncoder.realtimeTrigger(at: now),
        ]
    }
}
