import Foundation

/// Byte-exact builders for the two established A2345 read requests.
///
/// The public surface is deliberately closed: callers can request a full state
/// snapshot or arm realtime reporting, but cannot supply an arbitrary message
/// type or payload. Transport code remains responsible for deciding whether and
/// when either read request may be sent.
public enum A2345ReadRequestEncoder {
    /// `0x0200` — requests one full device-state snapshot.
    public static func statusSnapshot(at date: Date = Date()) -> [UInt8] {
        encode(messageType: 0x0200, at: date)
    }

    /// `0x020B` — asks the device to begin realtime telemetry reporting.
    public static func realtimeTrigger(at date: Date = Date()) -> [UInt8] {
        encode(messageType: 0x020B, at: date)
    }

    private static func encode(messageType: UInt16, at date: Date) -> [UInt8] {
        let epoch = UInt32(truncatingIfNeeded: Int(date.timeIntervalSince1970))
        var bytes: [UInt8] = [
            A2345PacketCodec.header[0], A2345PacketCodec.header[1],
            0x00, 0x00, // Total length, filled after the fixed fields are appended.
            A2345FramePattern.protocolVersion, 0x00, 0x0F,
            UInt8(messageType >> 8), UInt8(messageType & 0xFF),
            A2345.Field.a1, 0x01, 0x22,
            A2345.Field.timestamp, 0x05, A2345.ValueType.variable,
            UInt8(epoch & 0xFF),
            UInt8((epoch >> 8) & 0xFF),
            UInt8((epoch >> 16) & 0xFF),
            UInt8((epoch >> 24) & 0xFF),
        ]

        let encodedLength = UInt16(bytes.count + 1)
        bytes[2] = UInt8(encodedLength & 0xFF)
        bytes[3] = UInt8(encodedLength >> 8)
        bytes.append(A2345PacketCodec.checksum(bytes[...]))
        return bytes
    }
}
