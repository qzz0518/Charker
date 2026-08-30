import XCTest
@testable import A2687Protocol

final class TLVTests: XCTestCase {
    func testParsesRealCapabilityResponse() throws {
        let payload = try Payload.parse(Fixtures.plainDeviceCapability.hexBytes)
        XCTAssertEqual(payload.status, 0)
        XCTAssertTrue(payload.isOK)
        XCTAssertEqual(payload[A2687.Field.a1], [0x02])
        XCTAssertEqual(payload[A2687.Field.a2], [0x29, 0x01])   // MTU 297, little endian
        XCTAssertEqual(payload[A2687.Field.a3], [0x44])
        XCTAssertEqual(payload[A2687.Field.a5], [0x02])
    }

    func testRequestPayloadHasNoStatusByte() throws {
        let payload = try Payload.parse(Fixtures.plainClientCapability.hexBytes)
        XCTAssertNil(payload.status)
        XCTAssertEqual(payload[A2687.Field.a1]?.count, 4)
    }

    func testEncodeDecodeRoundTrip() throws {
        let records = [
            TLV(id: 0xA1, value: [0x21]),
            TLV(id: 0xA2, value: TypedValue.u8(2).encoded),
            TLV(id: 0xFE, value: [1, 2, 3, 4]),
        ]
        XCTAssertEqual(try TLVCodec.decode(TLVCodec.encode(records)), records)
    }

    func testRejectsTruncatedRecord() {
        XCTAssertThrowsError(try TLVCodec.decode([0xA1, 0x04, 0x01, 0x02]))
        XCTAssertThrowsError(try TLVCodec.decode([0xA1]))
    }

    func testTypedValues() {
        XCTAssertEqual(TypedValue.decode([0x00, 0x76, 0x31]), .text("v1"))
        XCTAssertEqual(TypedValue.decode([0x01, 0x07]), .u8(7))
        XCTAssertEqual(TypedValue.decode([0x02, 0x29, 0x01]), .u16(297))
        XCTAssertEqual(TypedValue.decode([0x03, 0x01, 0x00, 0x00, 0x00]), .u32(1))
        XCTAssertEqual(TypedValue.decode([0x04, 0xAB]), .bytes([0xAB]))
        XCTAssertEqual(TypedValue.decode([0x09, 0xAB]), .unknown(type: 0x09, payload: [0xAB]))
    }

    func testShortTypedValueIsNotGuessed() {
        // A u16 with only one byte must not silently become a u8.
        XCTAssertEqual(TypedValue.decode([0x02, 0x29]), .unknown(type: 0x02, payload: [0x29]))
    }

    func testTypedEncodingRoundTrips() {
        for value: TypedValue in [.text("GB"), .u8(1), .u16(600), .u32(1_700_000_000), .bytes([1, 2, 3])] {
            XCTAssertEqual(TypedValue.decode(value.encoded), value)
        }
    }

    func testScalarAccessor() {
        XCTAssertEqual(TypedValue.u16(297).scalar, 297)
        XCTAssertNil(TypedValue.text("x").scalar)
    }
}
