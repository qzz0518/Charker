import Foundation

/// Wire-level frame of the Anker Prime / Solix BLE protocol.
///
/// Layout (evidence: SolixBLE `_build_packet` / `_split_packet` @ bb2d398,
/// WebBLE `sendEncryptedCommand` @ ad4355d):
///
///     FF 09                header
///     uint16LE length      total frame length, header..checksum inclusive
///     03 00 group          pattern; group 0x01 = negotiation, 0x0F = session
///     cmdHigh cmdLow       logical opcode OR'd with 0x40 (encrypted) / 0x08 (response)
///     payload              plaintext TLVs, or AES-GCM ciphertext || tag
///     uint8 checksum       XOR of every preceding byte
/// The three pattern bytes between the length and the command.
///
/// Only the first is fixed. The second is the speaker's id — the app sends `0x00`
/// and the charger answers with `0x01` — and the third is a function group that
/// also differs between a request and its reply (`0x0F` out, `0x11` back). Both
/// must be carried through rather than asserted: validating them as constants
/// silently drops every session response the device sends.
public struct FramePattern: Sendable, Equatable {
    public static let protocolVersion: UInt8 = 0x03

    public var version: UInt8
    /// `0x00` from the app, `0x01` from the charger.
    public var slave: UInt8
    public var group: UInt8

    public init(version: UInt8 = FramePattern.protocolVersion, slave: UInt8 = 0, group: UInt8) {
        self.version = version
        self.slave = slave
        self.group = group
    }

    public static let negotiation = FramePattern(group: 0x01)
    public static let session = FramePattern(group: 0x0F)
}

public struct Frame: Sendable, Equatable {
    public var pattern: FramePattern
    /// Command exactly as it appears on the wire, flag bits included.
    public var rawCommand: UInt16
    public var payload: [UInt8]

    public static let negotiationGroup: UInt8 = 0x01
    public static let sessionGroup: UInt8 = 0x0F

    /// Bit set in the high command byte when the payload is AES-GCM sealed.
    public static let encryptedFlag: UInt16 = 0x4000
    /// Bit set in the high command byte when the frame is a device response/ACK.
    public static let responseFlag: UInt16 = 0x0800

    public init(pattern: FramePattern, rawCommand: UInt16, payload: [UInt8]) {
        self.pattern = pattern
        self.rawCommand = rawCommand
        self.payload = payload
    }

    public init(group: UInt8, rawCommand: UInt16, payload: [UInt8]) {
        self.init(pattern: FramePattern(group: group), rawCommand: rawCommand, payload: payload)
    }

    public init(group: UInt8, opcode: UInt16, encrypted: Bool, response: Bool = false, payload: [UInt8]) {
        var raw = opcode
        if encrypted { raw |= Frame.encryptedFlag }
        if response { raw |= Frame.responseFlag }
        self.init(group: group, rawCommand: raw, payload: payload)
    }

    public var group: UInt8 { pattern.group }

    /// Command with the encrypted/response flags stripped, e.g. wire `0x4A07` -> `0x0207`.
    public var opcode: UInt16 { rawCommand & ~(Frame.encryptedFlag | Frame.responseFlag) }
    public var isEncrypted: Bool { rawCommand & Frame.encryptedFlag != 0 }
    public var isResponse: Bool { rawCommand & Frame.responseFlag != 0 }
    /// True when the charger, rather than this app, produced the frame.
    public var isFromDevice: Bool { pattern.slave != 0 || isResponse }
}

public enum FrameError: Error, Equatable, Sendable {
    case tooShort(Int)
    case badHeader
    case lengthMismatch(encoded: Int, actual: Int)
    case badChecksum(encoded: UInt8, computed: UInt8)
    case badProtocolVersion(UInt8)
    case tooLarge(Int)
}

public enum PacketCodec {
    public static let header: [UInt8] = [0xFF, 0x09]
    /// header(2) + length(2) + pattern(3) + command(2) + checksum(1)
    public static let overhead = 10
    /// Defensive ceiling; the largest observed frame is well under 300 bytes.
    public static let maxFrameLength = 2048

    public static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(UInt8(0)) { $0 ^ $1 }
    }

    public static func encode(_ frame: Frame) -> [UInt8] {
        let length = overhead + frame.payload.count
        var out: [UInt8] = []
        out.reserveCapacity(length)
        out += header
        out.append(UInt8(length & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out += [frame.pattern.version, frame.pattern.slave, frame.pattern.group]
        out.append(UInt8(frame.rawCommand >> 8))
        out.append(UInt8(frame.rawCommand & 0xFF))
        out += frame.payload
        out.append(checksum(out[...]))
        return out
    }

    /// Strictly validates and decodes one complete frame. Never repairs malformed input.
    public static func decode(_ bytes: [UInt8]) throws -> Frame {
        guard bytes.count >= overhead else { throw FrameError.tooShort(bytes.count) }
        guard bytes.count <= maxFrameLength else { throw FrameError.tooLarge(bytes.count) }
        guard bytes[0] == header[0], bytes[1] == header[1] else { throw FrameError.badHeader }

        let encodedLength = Int(bytes[2]) | Int(bytes[3]) << 8
        guard encodedLength == bytes.count else {
            throw FrameError.lengthMismatch(encoded: encodedLength, actual: bytes.count)
        }
        // Only the protocol version is a constant. The other two pattern bytes
        // identify the speaker and the function group and legitimately differ
        // between a request and its reply.
        guard bytes[4] == FramePattern.protocolVersion else {
            throw FrameError.badProtocolVersion(bytes[4])
        }

        let computed = checksum(bytes[0..<(bytes.count - 1)])
        guard computed == bytes[bytes.count - 1] else {
            throw FrameError.badChecksum(encoded: bytes[bytes.count - 1], computed: computed)
        }

        let command = UInt16(bytes[7]) << 8 | UInt16(bytes[8])
        return Frame(
            pattern: FramePattern(version: bytes[4], slave: bytes[5], group: bytes[6]),
            rawCommand: command,
            payload: Array(bytes[9..<(bytes.count - 1)])
        )
    }
}
