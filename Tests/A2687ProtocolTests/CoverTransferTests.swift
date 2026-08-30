import XCTest
@testable import A2687Protocol

/// The chunk arithmetic and the hash are the two things a cover transfer cannot
/// get wrong without failing silently: a miscounted chunk list is accepted frame
/// by frame and simply never renders, and a wrong `hash_code` makes the charger
/// acknowledge the image and then ignore it.
///
/// The three byte counts below are real transfers recorded upstream
/// (`LYJW131/anker-prime-ble` docs/screensaver.md), which is why they are pinned
/// here rather than a round number: they are the only end-to-end evidence that
/// 156 is the chunk size the firmware actually expects.
final class CoverTransferTests: XCTestCase {
    func testChunkCountMatchesTheRecordedTransfers() {
        // 25397 B was the official app's own upload, captured on the wire.
        XCTAssertEqual(CoverTransfer.chunkCount(forByteCount: 25397), 163)
        XCTAssertEqual(CoverTransfer.chunkCount(forByteCount: 20876), 134)
        XCTAssertEqual(CoverTransfer.chunkCount(forByteCount: 18539), 119)
    }

    func testFinalChunkIsZeroPaddedToAFullFrame() throws {
        // 163 × 156 − 25397 = 31 bytes of padding, per the capture.
        let jpeg = [UInt8](repeating: 0xAB, count: 25397)
        let plan = try XCTUnwrap(CoverTransfer.Plan(jpeg: jpeg))
        XCTAssertEqual(plan.chunkCount, 163)
        XCTAssertEqual(plan.padding, 31)

        let last = try XCTUnwrap(CoverTransfer.chunk(jpeg, at: 162))
        XCTAssertEqual(last.count, CoverTransfer.chunkPayloadSize)
        XCTAssertEqual(last.prefix(125), ArraySlice(repeatElement(0xAB, count: 125)))
        XCTAssertEqual(last.suffix(31), ArraySlice(repeatElement(0, count: 31)))
    }

    func testExactMultipleNeedsNoPadding() throws {
        let jpeg = [UInt8](repeating: 0x5A, count: 156 * 4)
        let plan = try XCTUnwrap(CoverTransfer.Plan(jpeg: jpeg))
        XCTAssertEqual(plan.chunkCount, 4)
        XCTAssertEqual(plan.padding, 0)
        XCTAssertEqual(CoverTransfer.chunk(jpeg, at: 3)?.suffix(1), [0x5A])
    }

    /// Walking off the end must be an error, not an empty frame: an empty frame
    /// would be written to the charger as if it were image data.
    func testOutOfRangeChunkIsRejected() {
        let jpeg = [UInt8](repeating: 1, count: 200)
        XCTAssertEqual(CoverTransfer.chunkCount(forByteCount: 200), 2)
        XCTAssertNotNil(CoverTransfer.chunk(jpeg, at: 1))
        XCTAssertNil(CoverTransfer.chunk(jpeg, at: 2))
        XCTAssertNil(CoverTransfer.chunk(jpeg, at: -1))
    }

    func testEmptyImageIsNotATransfer() {
        XCTAssertEqual(CoverTransfer.chunkCount(forByteCount: 0), 0)
        XCTAssertNil(CoverTransfer.Plan(jpeg: []))
    }

    /// The canonical IEEE CRC-32 check value, so a broken implementation is
    /// caught here rather than by the charger silently refusing to display.
    func testCRC32MatchesTheStandardCheckValue() {
        XCTAssertEqual(CoverTransfer.crc32(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CoverTransfer.crc32([]), 0)
        XCTAssertEqual(CoverTransfer.crc32([0x00]), 0xD202_EF8D)
    }

    func testPlanIsSelfConsistent() throws {
        for size in [1, 155, 156, 157, 18539, 20876, 25397] {
            let jpeg = (0..<size).map { UInt8($0 % 251) }
            let plan = try XCTUnwrap(CoverTransfer.Plan(jpeg: jpeg))
            XCTAssertEqual(plan.byteCount, size)
            XCTAssertEqual(
                plan.chunkCount * CoverTransfer.chunkPayloadSize,
                plan.byteCount + plan.padding,
                "chunk grid must cover the image exactly once, size \(size)"
            )
            // Reassembling the chunks and trimming the padding must give the
            // original back — this is what the charger does at the far end.
            var rebuilt: [UInt8] = []
            for index in 0..<plan.chunkCount {
                rebuilt += try XCTUnwrap(CoverTransfer.chunk(jpeg, at: index))
            }
            XCTAssertEqual(Array(rebuilt.prefix(size)), jpeg)
        }
    }
}
