import Foundation

/// The arithmetic behind pushing a custom cover image to the charger's own screen.
///
/// Only the parts that are pure computation live here — chunking and the hash the
/// firmware checks. The TLV builders and the transfer state machine sit elsewhere,
/// because their byte layout rests on weaker evidence than this does: the layout
/// was recovered by exploiting the firmware's reused GCM nonce to XOR a known
/// plaintext, on one machine and one firmware. Chunk size, hash function and the
/// screen's pixel dimensions, by contrast, are checkable against captures that
/// were replayed end to end, and against the panel's datasheet.
///
/// Evidence: `LYJW131/anker-prime-ble` @ f23a07d — `anker_prime_ble/charger.py`
/// for the constants, `image.py` for the encoder, `docs/screensaver.md` for the
/// wire trace. The 240×240 panel is independently corroborated by atc1441's
/// teardown of the same product family (ST7789, 240×240).
public enum CoverTransfer {
    /// JPEG bytes carried per `0x0221` frame. The last chunk is zero-padded to
    /// this length so every frame on the wire is the same size.
    public static let chunkPayloadSize = 156

    /// The firmware acknowledges every tenth chunk. Sending faster than that
    /// overruns it: the observed failure is a `12 A1 01 31` status with the
    /// transfer stuck at index 10, not a dropped frame that a retry would fix.
    public static let acknowledgeEvery = 10

    /// The charger's display is square. Anything else has to be cropped, not
    /// letterboxed — the panel has no notion of a border.
    public static let screenPixelSize = 240

    /// Slots for pixel data inside the charger. The cloud list can hold more,
    /// but a fifth push evicts the oldest resident slot — observed twice, and
    /// notably *not* the slot currently on screen.
    public static let deviceSlotCount = 4

    /// Number of `0x0221` frames a JPEG of this size needs.
    ///
    /// Zero bytes is not a transfer, and the firmware has no representation for
    /// an empty image, so callers get 0 and should refuse to start.
    public static func chunkCount(forByteCount count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (count + chunkPayloadSize - 1) / chunkPayloadSize
    }

    /// The payload of one chunk, zero-padded to ``chunkPayloadSize``.
    ///
    /// Returns nil past the end rather than an empty array: a caller that walked
    /// off the end has a bug, and a silently empty frame would be sent to the
    /// charger as if it were image data.
    public static func chunk(_ data: [UInt8], at index: Int) -> [UInt8]? {
        guard index >= 0, index < chunkCount(forByteCount: data.count) else { return nil }
        let start = index * chunkPayloadSize
        let end = min(start + chunkPayloadSize, data.count)
        var payload = Array(data[start..<end])
        if payload.count < chunkPayloadSize {
            payload.append(contentsOf: repeatElement(0, count: chunkPayloadSize - payload.count))
        }
        return payload
    }

    /// IEEE CRC-32 of the JPEG bytes — the `hash_code` the cloud stores and the
    /// charger checks.
    ///
    /// This is `zlib.crc32`, i.e. the reflected polynomial `0xEDB88320`. Two
    /// plausible-looking alternatives were ruled out upstream by checking five
    /// real images: it is not a hash of the decoded pixel buffer, and not an MD5
    /// prefix. Getting it wrong is not a soft failure — the charger accepts the
    /// `0x021F` that names the image and then simply never shows it.
    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                // Branchless would be tidier but this reads as the textbook
                // definition, and the largest image seen is ~25 KB.
                crc = (crc >> 1) ^ (0xEDB8_8320 & ~((crc & 1) &- 1))
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Everything the `0x0220` header has to declare about a transfer, computed
    /// once so the start frame and the chunk loop cannot disagree about the count.
    public struct Plan: Sendable, Equatable {
        public let byteCount: Int
        public let chunkCount: Int
        public let hash: UInt32
        /// Trailing zero bytes in the final chunk. Diagnostic only — the firmware
        /// learns the real length from ``byteCount``.
        public let padding: Int

        public init?(jpeg: [UInt8]) {
            guard !jpeg.isEmpty else { return nil }
            byteCount = jpeg.count
            chunkCount = CoverTransfer.chunkCount(forByteCount: jpeg.count)
            hash = CoverTransfer.crc32(jpeg)
            padding = chunkCount * CoverTransfer.chunkPayloadSize - jpeg.count
        }
    }
}
