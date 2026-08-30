import Foundation

/// Turns the raw notification stream into whole frames.
///
/// CoreBluetooth delivers ATT notifications that may split one frame across
/// several callbacks, or carry several frames in one. Anything that is not a
/// well formed frame is dropped into ``FrameReassembler/droppedBytes`` rather
/// than being guessed at.
public struct FrameReassembler: Sendable {
    private var buffer: [UInt8] = []
    /// Bytes discarded while resynchronising on the `FF 09` header.
    public private(set) var droppedBytes = 0
    /// Frames rejected by ``PacketCodec/decode(_:)`` (checksum, pattern, ...).
    public private(set) var rejectedFrames = 0
    /// Why the last rejection happened, and the head of the offending bytes.
    /// Framing bytes are not user data, so this is safe to surface in diagnostics
    /// — and without it a rejection is indistinguishable from silence.
    public private(set) var lastRejection: (error: FrameError, head: [UInt8])?

    public init() {}

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    public mutating func append(_ chunk: [UInt8]) -> [Frame] {
        buffer += chunk
        var frames: [Frame] = []

        while true {
            guard let start = resyncIndex() else {
                droppedBytes += buffer.count
                buffer.removeAll(keepingCapacity: true)
                break
            }
            if start > 0 {
                droppedBytes += start
                buffer.removeFirst(start)
            }
            guard buffer.count >= 4 else { break }

            let length = Int(buffer[2]) | Int(buffer[3]) << 8
            guard length >= PacketCodec.overhead, length <= PacketCodec.maxFrameLength else {
                // Bogus length: drop this header and rescan.
                droppedBytes += 2
                buffer.removeFirst(2)
                rejectedFrames += 1
                continue
            }
            guard buffer.count >= length else { break }

            let candidate = Array(buffer[0..<length])
            buffer.removeFirst(length)
            do {
                frames.append(try PacketCodec.decode(candidate))
            } catch let error as FrameError {
                rejectedFrames += 1
                lastRejection = (error, Array(candidate.prefix(12)))
            } catch {
                rejectedFrames += 1
            }
        }
        return frames
    }

    /// Index of the next plausible `FF 09` header, or nil if none is buffered.
    private func resyncIndex() -> Int? {
        guard buffer.count >= 2 else { return buffer.isEmpty ? nil : (buffer[0] == 0xFF ? 0 : nil) }
        var i = 0
        while i + 1 < buffer.count {
            if buffer[i] == 0xFF && buffer[i + 1] == 0x09 { return i }
            i += 1
        }
        // A trailing lone 0xFF may still become a header once more bytes arrive.
        return buffer.last == 0xFF ? buffer.count - 1 : nil
    }
}
