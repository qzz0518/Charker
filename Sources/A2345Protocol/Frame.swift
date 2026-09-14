import Foundation

/// The unencrypted FF09 envelope used by A2345 MQTT messages.
///
/// Layout:
///
///     FF 09                  marker
///     uint16LE totalLength   includes the trailing checksum
///     version speaker group  three-byte pattern
///     uint16BE messageType
///     [increment]            present when the next byte is not a TLV id
///     TLVs                   id | uint8 length | value
///     xorChecksum            XOR of all previous bytes
///
/// `increment` is deliberately optional. Captured `0303` and fourteen-byte ACK
/// messages carry it, while the captured 62-byte `0830` message starts directly
/// with field `A1`.
public struct A2345FramePattern: Sendable, Equatable {
    public static let protocolVersion: UInt8 = 0x03

    public var version: UInt8
    public var speaker: UInt8
    public var group: UInt8

    public init(version: UInt8, speaker: UInt8, group: UInt8) {
        self.version = version
        self.speaker = speaker
        self.group = group
    }
}

/// One wire-order TLV. `rawValue` includes a value-type prefix when the field
/// has one; no interpretation is discarded at the framing boundary.
public struct A2345TLV: Sendable, Equatable {
    public var id: UInt8
    public var rawValue: [UInt8]

    public init(id: UInt8, rawValue: [UInt8]) {
        self.id = id
        self.rawValue = rawValue
    }

    /// The common A2345 value-type prefix. Single-byte marker fields have none.
    public var valueType: UInt8? { rawValue.count > 1 ? rawValue.first : nil }
}

public struct A2345Frame: Sendable, Equatable {
    public var pattern: A2345FramePattern
    public var messageType: UInt16
    public var increment: UInt8?
    public var fields: [A2345TLV]
    public var encodedLength: Int
    public var checksum: UInt8

    public init(
        pattern: A2345FramePattern,
        messageType: UInt16,
        increment: UInt8?,
        fields: [A2345TLV],
        encodedLength: Int,
        checksum: UInt8
    ) {
        self.pattern = pattern
        self.messageType = messageType
        self.increment = increment
        self.fields = fields
        self.encodedLength = encodedLength
        self.checksum = checksum
    }
}

public enum A2345FrameError: Error, Sendable, Equatable {
    case tooShort(Int)
    case tooLarge(Int)
    case badHeader
    case invalidLength(Int)
    case lengthMismatch(encoded: Int, actual: Int)
    case unsupportedVersion(UInt8)
    case badChecksum(encoded: UInt8, computed: UInt8)
    case truncatedTLV(at: Int)
}

public enum A2345PacketCodec {
    public static let header: [UInt8] = [0xFF, 0x09]
    /// Header without increment or fields, plus the checksum byte.
    public static let minimumFrameLength = 10
    /// Defensive ceiling. Observed A2345 messages are below 300 bytes.
    public static let maximumFrameLength = 2_048

    public static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(UInt8(0), ^)
    }

    /// Strictly validates and decodes one complete MQTT frame. It never repairs
    /// length, checksum or TLV boundary errors and never returns partial fields.
    public static func decode(_ bytes: [UInt8]) throws -> A2345Frame {
        guard bytes.count >= minimumFrameLength else {
            throw A2345FrameError.tooShort(bytes.count)
        }
        guard bytes.count <= maximumFrameLength else {
            throw A2345FrameError.tooLarge(bytes.count)
        }
        guard bytes[0] == header[0], bytes[1] == header[1] else {
            throw A2345FrameError.badHeader
        }

        let encodedLength = Int(bytes[2]) | Int(bytes[3]) << 8
        guard encodedLength >= minimumFrameLength, encodedLength <= maximumFrameLength else {
            throw A2345FrameError.invalidLength(encodedLength)
        }
        guard encodedLength == bytes.count else {
            throw A2345FrameError.lengthMismatch(encoded: encodedLength, actual: bytes.count)
        }
        guard bytes[4] == A2345FramePattern.protocolVersion else {
            throw A2345FrameError.unsupportedVersion(bytes[4])
        }

        let computedChecksum = checksum(bytes[0..<(bytes.count - 1)])
        guard computedChecksum == bytes[bytes.count - 1] else {
            throw A2345FrameError.badChecksum(
                encoded: bytes[bytes.count - 1],
                computed: computedChecksum
            )
        }

        let pattern = A2345FramePattern(
            version: bytes[4],
            speaker: bytes[5],
            group: bytes[6]
        )
        let messageType = UInt16(bytes[7]) << 8 | UInt16(bytes[8])
        let fieldsEnd = bytes.count - 1
        var fieldOffset = 9
        var increment: UInt8?

        // All fields observed on A2345 are in the A0...FF namespace. An earlier
        // byte is the optional message increment, not a guessed TLV id.
        if fieldOffset < fieldsEnd, bytes[fieldOffset] < 0xA0 {
            increment = bytes[fieldOffset]
            fieldOffset += 1
        }

        var fields: [A2345TLV] = []
        while fieldOffset < fieldsEnd {
            guard fieldOffset + 2 <= fieldsEnd else {
                throw A2345FrameError.truncatedTLV(at: fieldOffset)
            }
            let id = bytes[fieldOffset]
            let length = Int(bytes[fieldOffset + 1])
            let valueStart = fieldOffset + 2
            let valueEnd = valueStart + length
            guard valueEnd <= fieldsEnd else {
                throw A2345FrameError.truncatedTLV(at: fieldOffset)
            }
            fields.append(A2345TLV(id: id, rawValue: Array(bytes[valueStart..<valueEnd])))
            fieldOffset = valueEnd
        }

        return A2345Frame(
            pattern: pattern,
            messageType: messageType,
            increment: increment,
            fields: fields,
            encodedLength: encodedLength,
            checksum: bytes[bytes.count - 1]
        )
    }
}
