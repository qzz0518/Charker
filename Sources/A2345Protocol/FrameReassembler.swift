import Foundation

/// Reassembles split or coalesced MQTT byte chunks into strict FF09 frames.
/// Garbage and malformed candidates are dropped; they are never repaired.
public struct A2345FrameReassembler: Sendable {
    private var buffer: [UInt8] = []

    public private(set) var droppedBytes = 0
    public private(set) var rejectedFrames = 0
    public private(set) var lastRejection: (error: A2345FrameError, head: [UInt8])?

    public init() {}

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    public mutating func append(_ chunk: [UInt8]) -> [A2345Frame] {
        buffer += chunk
        var frames: [A2345Frame] = []

        while true {
            guard let headerOffset = nextHeaderOffset() else {
                preservePossibleHeaderPrefix()
                break
            }
            if headerOffset > 0 {
                droppedBytes += headerOffset
                buffer.removeFirst(headerOffset)
            }
            guard buffer.count >= 4 else { break }

            let length = Int(buffer[2]) | Int(buffer[3]) << 8
            guard length >= A2345PacketCodec.minimumFrameLength,
                  length <= A2345PacketCodec.maximumFrameLength else {
                rejectedFrames += 1
                droppedBytes += 2
                buffer.removeFirst(2)
                continue
            }
            guard buffer.count >= length else {
                // A plausible but corrupt length can otherwise pin the stream
                // forever: the buffer may already contain a later, complete
                // checksum-valid FF09 frame while the false candidate keeps us
                // waiting for up to 2 KiB. Only resynchronise when that later
                // candidate fully validates, so FF09 bytes inside a legitimate
                // fragmented payload cannot cause an eager drop.
                guard let recoveryOffset = nextCompleteValidFrameOffset(after: 2) else {
                    break
                }
                rejectedFrames += 1
                lastRejection = (
                    .lengthMismatch(encoded: length, actual: recoveryOffset),
                    Array(buffer.prefix(min(12, recoveryOffset)))
                )
                droppedBytes += recoveryOffset
                buffer.removeFirst(recoveryOffset)
                continue
            }

            let candidate = Array(buffer[0..<length])
            do {
                frames.append(try A2345PacketCodec.decode(candidate))
                buffer.removeFirst(length)
            } catch let error as A2345FrameError {
                rejectedFrames += 1
                lastRejection = (error, Array(candidate.prefix(12)))
                // Drop only the bad marker. If a corrupt declared length spans
                // another valid frame, the next scan can still recover it.
                droppedBytes += 2
                buffer.removeFirst(2)
            } catch {
                rejectedFrames += 1
                droppedBytes += 2
                buffer.removeFirst(2)
            }
        }

        return frames
    }

    private func nextHeaderOffset() -> Int? {
        guard buffer.count >= 2 else { return nil }
        for index in 0..<(buffer.count - 1) {
            if buffer[index] == 0xFF, buffer[index + 1] == 0x09 {
                return index
            }
        }
        return nil
    }

    private func nextCompleteValidFrameOffset(after start: Int) -> Int? {
        guard buffer.count >= start + A2345PacketCodec.minimumFrameLength else { return nil }
        for index in start..<(buffer.count - 1) {
            guard buffer[index] == 0xFF, buffer[index + 1] == 0x09,
                  index + 4 <= buffer.count else { continue }
            let length = Int(buffer[index + 2]) | Int(buffer[index + 3]) << 8
            guard length >= A2345PacketCodec.minimumFrameLength,
                  length <= A2345PacketCodec.maximumFrameLength,
                  index + length <= buffer.count else { continue }
            if (try? A2345PacketCodec.decode(Array(buffer[index..<(index + length)]))) != nil {
                return index
            }
        }
        return nil
    }

    private mutating func preservePossibleHeaderPrefix() {
        if buffer.last == 0xFF {
            droppedBytes += max(0, buffer.count - 1)
            buffer = [0xFF]
        } else {
            droppedBytes += buffer.count
            buffer.removeAll(keepingCapacity: true)
        }
    }
}
