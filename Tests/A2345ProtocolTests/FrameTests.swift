import XCTest
@testable import A2345Protocol

final class A2345FrameTests: XCTestCase {
    func testDecodesFrameWithIncrementAndStrictTLVs() throws {
        let frame = try A2345PacketCodec.decode(A2345Fixtures.realtimeOldFirmware.a2345HexBytes)

        XCTAssertEqual(frame.messageType, A2345.MessageType.realtime)
        XCTAssertEqual(frame.pattern, A2345FramePattern(version: 3, speaker: 1, group: 15))
        XCTAssertEqual(frame.increment, 1)
        XCTAssertEqual(frame.fields.map(\.id), [0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xFE])
        XCTAssertEqual(frame.encodedLength, 100)
    }

    func testDecodesSixtyTwoByteFrameWithoutIncrement() throws {
        let bytes = A2345Fixtures.versionInfo.a2345HexBytes
        XCTAssertEqual(bytes.count, 62)

        let frame = try A2345PacketCodec.decode(bytes)
        XCTAssertEqual(frame.messageType, A2345.MessageType.versionInfo)
        XCTAssertNil(frame.increment)
        XCTAssertEqual(frame.fields.map(\.id), [0xA1, 0xA2, 0xA3, 0xA4, 0xA5])
    }

    func testRejectsBadHeader() {
        var bytes = A2345Fixtures.realtimeOldFirmware.a2345HexBytes
        bytes[0] = 0xFE
        XCTAssertThrowsError(try A2345PacketCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? A2345FrameError, .badHeader)
        }
    }

    func testRejectsLengthMismatch() {
        var bytes = A2345Fixtures.realtimeOldFirmware.a2345HexBytes
        bytes[2] &-= 1
        XCTAssertThrowsError(try A2345PacketCodec.decode(bytes)) { error in
            XCTAssertEqual(
                error as? A2345FrameError,
                .lengthMismatch(encoded: 99, actual: 100)
            )
        }
    }

    func testRejectsBadXOR() {
        var bytes = A2345Fixtures.realtimeOldFirmware.a2345HexBytes
        bytes[40] ^= 0x01
        XCTAssertThrowsError(try A2345PacketCodec.decode(bytes)) { error in
            guard case .badChecksum = error as? A2345FrameError else {
                return XCTFail("expected bad checksum, got \(error)")
            }
        }
    }

    func testRejectsUnsupportedVersionAfterChecksumIsRepaired() {
        var bytes = A2345Fixtures.realtimeAcknowledgement.a2345HexBytes
        bytes[4] = 4
        bytes[bytes.count - 1] = A2345PacketCodec.checksum(bytes[0..<(bytes.count - 1)])
        XCTAssertThrowsError(try A2345PacketCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? A2345FrameError, .unsupportedVersion(4))
        }
    }

    func testRejectsTruncatedTLVWithoutReturningPartialFields() {
        var bytes = A2345Fixtures.realtimeAcknowledgement.a2345HexBytes
        bytes[11] = 2 // A1 claims two bytes but only one remains before checksum.
        bytes[bytes.count - 1] = A2345PacketCodec.checksum(bytes[0..<(bytes.count - 1)])
        XCTAssertThrowsError(try A2345PacketCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? A2345FrameError, .truncatedTLV(at: 10))
        }
    }

    func testRejectsTooShortAndOversizedFrames() {
        XCTAssertThrowsError(try A2345PacketCodec.decode([0xFF, 0x09])) { error in
            XCTAssertEqual(error as? A2345FrameError, .tooShort(2))
        }

        let oversized = [UInt8](repeating: 0, count: A2345PacketCodec.maximumFrameLength + 1)
        XCTAssertThrowsError(try A2345PacketCodec.decode(oversized)) { error in
            XCTAssertEqual(error as? A2345FrameError, .tooLarge(oversized.count))
        }
    }

    func testEveryTruncatedPrefixIsRejectedWithoutOutOfBoundsAccess() {
        let bytes = A2345Fixtures.realtimeNewFirmware.a2345HexBytes

        for end in 0..<bytes.count {
            XCTAssertThrowsError(
                try A2345PacketCodec.decode(Array(bytes[..<end])),
                "prefix length \(end) unexpectedly decoded"
            )
        }
    }
}

final class A2345FrameReassemblerTests: XCTestCase {
    func testReassemblesEverySplitBoundary() {
        let bytes = A2345Fixtures.realtimeNewFirmware.a2345HexBytes

        for split in 1..<bytes.count {
            var reassembler = A2345FrameReassembler()
            XCTAssertTrue(reassembler.append(Array(bytes[..<split])).isEmpty)
            let frames = reassembler.append(Array(bytes[split...]))
            XCTAssertEqual(frames.map(\.messageType), [A2345.MessageType.realtime])
        }
    }

    func testSplitsCoalescedFramesAndRetainsTrailingHeaderByte() {
        let first = A2345Fixtures.realtimeAcknowledgement.a2345HexBytes
        let second = A2345Fixtures.versionInfo.a2345HexBytes
        var reassembler = A2345FrameReassembler()

        let frames = reassembler.append(first + second + [0xFF])
        XCTAssertEqual(frames.map(\.messageType), [0x0A0B, 0x0830])
        XCTAssertEqual(reassembler.droppedBytes, 0)

        let third = reassembler.append(Array(first.dropFirst()))
        XCTAssertEqual(third.map(\.messageType), [0x0A0B])
    }

    func testRecoversValidFrameAfterMalformedCandidate() {
        var corrupt = A2345Fixtures.realtimeAcknowledgement.a2345HexBytes
        corrupt[corrupt.count - 1] ^= 1
        let valid = A2345Fixtures.versionInfo.a2345HexBytes
        var reassembler = A2345FrameReassembler()

        let frames = reassembler.append(corrupt + valid)
        XCTAssertEqual(frames.map(\.messageType), [A2345.MessageType.versionInfo])
        XCTAssertEqual(reassembler.rejectedFrames, 1)
        XCTAssertNotNil(reassembler.lastRejection)
    }

    func testImplausibleLengthDoesNotStallStream() {
        var reassembler = A2345FrameReassembler()
        XCTAssertTrue(reassembler.append([0xFF, 0x09, 0x02, 0x00]).isEmpty)

        let frames = reassembler.append(A2345Fixtures.realtimeAcknowledgement.a2345HexBytes)
        XCTAssertEqual(frames.map(\.messageType), [A2345.MessageType.realtimeAcknowledgement])
        XCTAssertEqual(reassembler.rejectedFrames, 1)
    }

    func testPlausibleFalseLengthRecoversWhenLaterFrameFullyValidates() {
        var reassembler = A2345FrameReassembler()
        let falseCandidate: [UInt8] = [0xFF, 0x09, 0x00, 0x08]
        let valid = A2345Fixtures.realtimeAcknowledgement.a2345HexBytes

        let frames = reassembler.append(falseCandidate + valid)

        XCTAssertEqual(frames.map(\.messageType), [A2345.MessageType.realtimeAcknowledgement])
        XCTAssertEqual(reassembler.rejectedFrames, 1)
        XCTAssertEqual(reassembler.droppedBytes, falseCandidate.count)
        XCTAssertEqual(
            reassembler.lastRejection?.error,
            .lengthMismatch(encoded: 2_048, actual: falseCandidate.count)
        )
    }
}
