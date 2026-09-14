import Foundation
import XCTest
@testable import A2345Protocol

final class A2345CommandsTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    func testStatusSnapshotMatchesFixedVector() {
        XCTAssertEqual(
            A2345ReadRequestEncoder.statusSnapshot(at: epoch).hexString,
            "ff09140003000f0200a10122fe050300f1536551"
        )
    }

    func testRealtimeTriggerMatchesFixedVector() {
        XCTAssertEqual(
            A2345ReadRequestEncoder.realtimeTrigger(at: epoch).hexString,
            "ff09140003000f020ba10122fe050300f153655a"
        )
    }

    func testBothReadRequestsRoundTripThroughStrictDecoder() throws {
        for (expectedType, bytes) in [
            (UInt16(0x0200), A2345ReadRequestEncoder.statusSnapshot(at: epoch)),
            (UInt16(0x020B), A2345ReadRequestEncoder.realtimeTrigger(at: epoch)),
        ] {
            let frame = try A2345PacketCodec.decode(bytes)

            XCTAssertEqual(frame.pattern, A2345FramePattern(version: 3, speaker: 0, group: 15))
            XCTAssertEqual(frame.messageType, expectedType)
            XCTAssertNil(frame.increment)
            XCTAssertEqual(frame.encodedLength, 20)
            XCTAssertEqual(frame.fields, [
                A2345TLV(id: A2345.Field.a1, rawValue: [0x22]),
                A2345TLV(
                    id: A2345.Field.timestamp,
                    rawValue: [A2345.ValueType.variable, 0x00, 0xF1, 0x53, 0x65]
                ),
            ])
        }
    }

    func testReadRequestsDifferOnlyByMessageTypeAndChecksum() {
        let status = A2345ReadRequestEncoder.statusSnapshot(at: epoch)
        let realtime = A2345ReadRequestEncoder.realtimeTrigger(at: epoch)

        XCTAssertEqual(status.count, realtime.count)
        XCTAssertEqual(
            zip(status, realtime).indicesWhereElementsDiffer,
            [8, status.count - 1]
        )
    }
}

private extension Array where Element == UInt8 {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Zip2Sequence<[UInt8], [UInt8]> {
    var indicesWhereElementsDiffer: [Int] {
        enumerated().compactMap { index, pair in
            pair.0 == pair.1 ? nil : index
        }
    }
}
