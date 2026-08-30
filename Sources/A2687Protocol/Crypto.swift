import CryptoKit
import Foundation

/// AES-GCM / P-256 layer of the A2687 session.
///
/// Two key schedules exist:
///
/// * **Negotiation** — a static key/nonce baked into the firmware, used until the
///   ECDH exchange completes. Knowing it buys no confidentiality, it only makes
///   the handshake parseable.
/// * **Session** — the P-256 shared secret: bytes `0..<16` are the AES-128 key,
///   bytes `16..<28` are the GCM nonce.
///
/// The protocol reuses one nonce for every message under a session key and does
/// not cover the frame header with the AAD. Those are protocol weaknesses we must
/// tolerate to interoperate; they are the reason ``open(_:with:)`` is strictly
/// fail-closed and callers additionally constrain opcode, TLV schema and state.
public enum A2687Crypto {
    /// Additional authenticated data, constant across the protocol.
    public static let aad: [UInt8] = [
        0x33, 0x22, 0x11, 0x00, 0x77, 0x66, 0x55, 0x44,
        0xBB, 0xAA, 0x99, 0x88, 0xFF, 0xEE, 0xDD, 0xCC,
    ]
    static let negotiationKeyBytes: [UInt8] = [
        0xB8, 0xFF, 0x74, 0x22, 0x95, 0x5D, 0x4E, 0xB6,
        0xD5, 0x54, 0xA2, 0xC4, 0x70, 0x28, 0x05, 0x59,
    ]
    static let negotiationNonceBytes: [UInt8] = [
        0x6B, 0xA3, 0xE3, 0xF2, 0xF3, 0xA6, 0x0F, 0x29, 0x71, 0xCE, 0x5D, 0x1F,
    ]

    public static let tagLength = 16

    /// A key/nonce pair. Never persisted, never logged, never surfaced in the UI.
    public struct Keys: @unchecked Sendable {
        let key: SymmetricKey
        let nonce: AES.GCM.Nonce

        init(key: SymmetricKey, nonce: AES.GCM.Nonce) {
            self.key = key
            self.nonce = nonce
        }

        public init(secretPrefix bytes: [UInt8]) throws {
            guard bytes.count >= 28 else { throw CryptoError.shortSharedSecret(bytes.count) }
            self.key = SymmetricKey(data: Data(bytes[0..<16]))
            self.nonce = try AES.GCM.Nonce(data: Data(bytes[16..<28]))
        }

        public static let negotiation: Keys = {
            // Force-try is safe: both inputs are compile-time constants of the right length.
            let nonce = try! AES.GCM.Nonce(data: Data(negotiationNonceBytes))
            return Keys(key: SymmetricKey(data: Data(negotiationKeyBytes)), nonce: nonce)
        }()
    }

    public enum CryptoError: Error, Equatable, Sendable {
        case shortSharedSecret(Int)
        case payloadTooShort(Int)
        /// GCM tag verification failed. The payload is discarded, never decrypted anyway.
        case authenticationFailed
        case badPublicKey
        case sealFailed
    }

    /// Returns `ciphertext || tag`.
    public static func seal(_ plaintext: [UInt8], with keys: Keys) throws -> [UInt8] {
        do {
            let box = try AES.GCM.seal(plaintext, using: keys.key, nonce: keys.nonce, authenticating: aad)
            return [UInt8](box.ciphertext) + [UInt8](box.tag)
        } catch {
            throw CryptoError.sealFailed
        }
    }

    /// Fail-closed open of `ciphertext || tag`.
    ///
    /// Unlike the SolixBLE reference, a tag mismatch is terminal for the packet:
    /// unauthenticated plaintext must never reach the telemetry state or the UI.
    public static func open(_ payload: [UInt8], with keys: Keys) throws -> [UInt8] {
        guard payload.count > tagLength else { throw CryptoError.payloadTooShort(payload.count) }
        let ciphertext = Data(payload[0..<(payload.count - tagLength)])
        let tag = Data(payload[(payload.count - tagLength)...])
        do {
            let box = try AES.GCM.SealedBox(nonce: keys.nonce, ciphertext: ciphertext, tag: tag)
            return [UInt8](try AES.GCM.open(box, using: keys.key, authenticating: aad))
        } catch {
            throw CryptoError.authenticationFailed
        }
    }

    /// Fresh ephemeral key agreement pair. A new one is generated for every connection.
    public static func makeEphemeralKey() -> P256.KeyAgreement.PrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    /// Uncompressed `X || Y`, i.e. the x963 representation without its `0x04` prefix,
    /// which is exactly what TLV `A1` of opcode `0x0021` carries.
    public static func rawPublicKey(_ key: P256.KeyAgreement.PrivateKey) -> [UInt8] {
        Array(key.publicKey.x963Representation.dropFirst())
    }

    /// Derives the 32 byte shared secret from the device's raw 64 byte point.
    public static func sharedSecret(
        privateKey: P256.KeyAgreement.PrivateKey,
        devicePoint: [UInt8]
    ) throws -> [UInt8] {
        guard devicePoint.count == 64 else { throw CryptoError.badPublicKey }
        guard let publicKey = try? P256.KeyAgreement.PublicKey(
            x963Representation: Data([0x04] + devicePoint)
        ) else { throw CryptoError.badPublicKey }
        guard let secret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey) else {
            throw CryptoError.badPublicKey
        }
        return secret.withUnsafeBytes { Array($0) }
    }
}
