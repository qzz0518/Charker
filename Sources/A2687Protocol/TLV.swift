import Foundation

/// One `id | length | value` record from a frame payload.
public struct TLV: Sendable, Equatable {
    public var id: UInt8
    public var value: [UInt8]

    public init(id: UInt8, value: [UInt8]) {
        self.id = id
        self.value = value
    }
}

/// Most business values carry a one byte type prefix inside the TLV value.
/// (Evidence: WebBLE `readLegacyTypedValue` @ ad4355d.)
public enum TypedValue: Sendable, Equatable {
    case text(String)
    case u8(UInt8)
    case u16(UInt16)
    case u32(UInt32)
    case bytes([UInt8])
    /// Type prefix was present but unrecognised, or the value was too short for its type.
    case unknown(type: UInt8, payload: [UInt8])

    public static let textType: UInt8 = 0x00
    public static let u8Type: UInt8 = 0x01
    public static let u16Type: UInt8 = 0x02
    public static let u32Type: UInt8 = 0x03
    public static let bytesType: UInt8 = 0x04

    public var encoded: [UInt8] {
        switch self {
        case .text(let s):
            return [TypedValue.textType] + Array(s.utf8)
        case .u8(let v):
            return [TypedValue.u8Type, v]
        case .u16(let v):
            return [TypedValue.u16Type, UInt8(v & 0xFF), UInt8(v >> 8)]
        case .u32(let v):
            return [TypedValue.u32Type,
                    UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                    UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        case .bytes(let b):
            return [TypedValue.bytesType] + b
        case .unknown(let t, let p):
            return [t] + p
        }
    }

    /// Numeric reading for the scalar types, nil for text/bytes.
    public var scalar: UInt32? {
        switch self {
        case .u8(let v): return UInt32(v)
        case .u16(let v): return UInt32(v)
        case .u32(let v): return v
        default: return nil
        }
    }

    public var payload: [UInt8] {
        switch self {
        case .text(let s): return Array(s.utf8)
        case .bytes(let b): return b
        case .unknown(_, let p): return p
        case .u8, .u16, .u32: return Array(encoded.dropFirst())
        }
    }

    public static func decode(_ raw: [UInt8]) -> TypedValue {
        guard let type = raw.first else { return .unknown(type: 0xFF, payload: []) }
        let body = Array(raw.dropFirst())
        switch type {
        case textType:
            // Device strings are ASCII and are sometimes right padded with dots or NULs.
            var text = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\0", with: "")
            while text.hasSuffix(".") { text.removeLast() }
            return .text(text)
        case u8Type where body.count >= 1:
            return .u8(body[0])
        case u16Type where body.count >= 2:
            return .u16(UInt16(body[0]) | UInt16(body[1]) << 8)
        case u32Type where body.count >= 4:
            return .u32(UInt32(body[0]) | UInt32(body[1]) << 8 | UInt32(body[2]) << 16 | UInt32(body[3]) << 24)
        case bytesType:
            return .bytes(body)
        default:
            return .unknown(type: type, payload: body)
        }
    }
}

public enum TLVError: Error, Equatable, Sendable {
    case truncated(at: Int)
    case trailingBytes(Int)
}

public enum TLVCodec {
    public static func encode(_ records: [TLV]) -> [UInt8] {
        var out: [UInt8] = []
        for record in records {
            out.append(record.id)
            out.append(UInt8(truncatingIfNeeded: record.value.count))
            out += record.value
        }
        return out
    }

    /// Strict parse: any truncated record is an error, never a partial result.
    public static func decode(_ bytes: [UInt8], from offset: Int = 0) throws -> [TLV] {
        var records: [TLV] = []
        var i = offset
        while i < bytes.count {
            guard i + 2 <= bytes.count else { throw TLVError.truncated(at: i) }
            let id = bytes[i]
            let length = Int(bytes[i + 1])
            guard i + 2 + length <= bytes.count else { throw TLVError.truncated(at: i) }
            records.append(TLV(id: id, value: Array(bytes[(i + 2)..<(i + 2 + length)])))
            i += 2 + length
        }
        return records
    }
}

/// A decrypted payload split into its optional leading status byte and its TLV fields.
///
/// Device responses prefix the TLV list with a result code (`0x00` = OK); requests
/// do not. Evidence: static-key decryption of the pinned SolixBLE negotiation
/// fixtures, and WebBLE's `payload[0] === 0x00 ? 1 : 0` offset heuristic.
public struct Payload: Sendable, Equatable {
    public var status: UInt8?
    public var fields: [TLV]

    public init(status: UInt8?, fields: [TLV]) {
        self.status = status
        self.fields = fields
    }

    public var isOK: Bool { status == nil || status == 0 }

    public subscript(id: UInt8) -> [UInt8]? {
        fields.first(where: { $0.id == id })?.value
    }

    public func typed(_ id: UInt8) -> TypedValue? {
        self[id].map(TypedValue.decode)
    }

    public static func parse(_ bytes: [UInt8]) throws -> Payload {
        guard !bytes.isEmpty else { return Payload(status: nil, fields: []) }
        // Success responses lead with 0x00 and then the fields.
        if bytes[0] == 0x00, let fields = try? TLVCodec.decode(bytes, from: 1) {
            return Payload(status: 0, fields: fields)
        }
        // Requests carry no status byte at all.
        if let fields = try? TLVCodec.decode(bytes) {
            return Payload(status: nil, fields: fields)
        }
        // A rejection: a non-zero result code, optionally with detail fields.
        // Without this branch a bare one-byte refusal looks like a malformed
        // packet, which hides the reason the device said no.
        if let fields = try? TLVCodec.decode(bytes, from: 1) {
            return Payload(status: bytes[0], fields: fields)
        }
        throw TLVError.truncated(at: 0)
    }
}
