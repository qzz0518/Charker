import XCTest
@testable import A2687Protocol

final class FrameTests: XCTestCase {
    func testDecodesRealDeviceFrame() throws {
        let frame = try PacketCodec.decode(Fixtures.deviceCapability.hexBytes)
        XCTAssertEqual(frame.group, Frame.negotiationGroup)
        XCTAssertEqual(frame.rawCommand, 0x4803)
        XCTAssertEqual(frame.opcode, A2687.Opcode.capability)
        XCTAssertTrue(frame.isEncrypted)
        XCTAssertTrue(frame.isResponse)
    }

    func testEncodeIsByteIdenticalToCapture() throws {
        let original = Fixtures.clientInitialConnect.hexBytes
        let frame = try PacketCodec.decode(original)
        XCTAssertEqual(PacketCodec.encode(frame).hexString, Fixtures.clientInitialConnect)
    }

    func testEncodedLengthCoversWholeFrame() {
        let frame = Frame(group: Frame.sessionGroup, opcode: 0x0207, encrypted: true, payload: [1, 2, 3])
        let bytes = PacketCodec.encode(frame)
        XCTAssertEqual(bytes.count, 13)
        XCTAssertEqual(Int(bytes[2]) | Int(bytes[3]) << 8, bytes.count)
        XCTAssertEqual(bytes[7], 0x42)
    }

    func testRejectsBadChecksum() {
        var bytes = Fixtures.deviceSetCapability.hexBytes
        bytes[bytes.count - 1] ^= 0xFF
        XCTAssertThrowsError(try PacketCodec.decode(bytes))
    }

    func testRejectsLengthMismatch() {
        var bytes = Fixtures.deviceSetCapability.hexBytes
        bytes[2] = 0x40
        XCTAssertThrowsError(try PacketCodec.decode(bytes))
    }

    func testRejectsBadHeader() {
        var bytes = Fixtures.deviceSetCapability.hexBytes
        bytes[0] = 0xFE
        XCTAssertThrowsError(try PacketCodec.decode(bytes))
    }

    func testRejectsUnknownProtocolVersion() {
        var bytes = Fixtures.deviceSetCapability.hexBytes
        bytes[4] = 0x04
        bytes[bytes.count - 1] = PacketCodec.checksum(bytes[0..<(bytes.count - 1)])
        XCTAssertThrowsError(try PacketCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? FrameError, .badProtocolVersion(0x04))
        }
    }

    /// The charger answers session commands with pattern `03 01 11` while the app
    /// sends `03 00 0F`. Asserting those two bytes as constants silently discarded
    /// every telemetry frame the device sent.
    func testAcceptsTheDeviceSideSessionPattern() throws {
        var bytes: [UInt8] = [0xFF, 0x09, 0x00, 0x00, 0x03, 0x01, 0x11, 0x4A, 0x00, 0xAB, 0xCD]
        bytes[2] = UInt8(bytes.count + 1)
        bytes.append(PacketCodec.checksum(bytes[...]))
        let frame = try PacketCodec.decode(bytes)
        XCTAssertEqual(frame.pattern, FramePattern(version: 0x03, slave: 0x01, group: 0x11))
        XCTAssertEqual(frame.opcode, A2687.Opcode.readAll)
        XCTAssertTrue(frame.isResponse)
        XCTAssertTrue(frame.isEncrypted)
        XCTAssertTrue(frame.isFromDevice)
        XCTAssertEqual(frame.payload, [0xAB, 0xCD])
    }

    func testPatternRoundTrips() throws {
        let original = Frame(
            pattern: FramePattern(version: 0x03, slave: 0x01, group: 0x11),
            rawCommand: 0x4A0B, payload: [0x01]
        )
        XCTAssertEqual(try PacketCodec.decode(PacketCodec.encode(original)), original)
    }

    func testRejectsTooShort() {
        XCTAssertThrowsError(try PacketCodec.decode([0xFF, 0x09, 0x04, 0x00]))
    }
}

final class FrameReassemblerTests: XCTestCase {
    func testReassemblesFrameSplitAcrossNotifications() {
        var reassembler = FrameReassembler()
        let bytes = Fixtures.deviceBaseInfo.hexBytes
        var frames: [Frame] = []
        for chunk in stride(from: 0, to: bytes.count, by: 20) {
            frames += reassembler.append(Array(bytes[chunk..<min(chunk + 20, bytes.count)]))
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.opcode, A2687.Opcode.baseInfo)
    }

    func testSplitsConcatenatedFrames() {
        var reassembler = FrameReassembler()
        let frames = reassembler.append(
            Fixtures.deviceInitialConnect.hexBytes + Fixtures.deviceSetCapability.hexBytes
        )
        XCTAssertEqual(frames.map(\.opcode), [A2687.Opcode.initialConnect, A2687.Opcode.setCapability])
    }

    func testResynchronisesAfterGarbage() {
        var reassembler = FrameReassembler()
        let frames = reassembler.append([0x01, 0x02, 0x03] + Fixtures.deviceSetCapability.hexBytes)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(reassembler.droppedBytes, 3)
    }

    func testCorruptFrameIsRejectedNotRepaired() {
        var reassembler = FrameReassembler()
        var bytes = Fixtures.deviceSetCapability.hexBytes
        bytes[bytes.count - 1] ^= 0x01
        let frames = reassembler.append(bytes)
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(reassembler.rejectedFrames, 1)
    }

    func testImplausibleLengthDoesNotStallTheStream() {
        var reassembler = FrameReassembler()
        _ = reassembler.append([0xFF, 0x09, 0x02, 0x00])
        let frames = reassembler.append(Fixtures.deviceSetCapability.hexBytes)
        XCTAssertEqual(frames.count, 1)
    }
}
