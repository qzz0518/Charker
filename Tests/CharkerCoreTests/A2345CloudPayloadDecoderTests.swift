import Foundation
import XCTest
@testable import CharkerCore

final class A2345CloudPayloadDecoderTests: XCTestCase {
    private let acknowledgement = makeHexData("ff090e0003010f0a0b00a1013460")
    private let versionInfo = makeHexData(
        "ff093e0003010f0830a10600312e302e30a20800322e312e312e36a306004132333435a40a0041323334355f6d6375a50c0041323334355f657370333214"
    )

    func testReturnsRawFF09PayloadUnchanged() throws {
        XCTAssertEqual(
            try A2345CloudPayloadDecoder.decode(acknowledgement),
            [UInt8](acknowledgement)
        )
    }

    func testDecodesOuterPayloadStringContainingNestedJSON() throws {
        let nested = try jsonData([
            "data": acknowledgement.base64EncodedString(),
        ])
        let outer = try jsonData([
            "payload": try XCTUnwrap(String(data: nested, encoding: .utf8)),
        ])

        XCTAssertEqual(
            try A2345CloudPayloadDecoder.decode(outer),
            [UInt8](acknowledgement)
        )
    }

    func testFindsBase64FrameUnderArbitrarilyNestedDataOrPayloadKeys() throws {
        let mqttPayload = try jsonData([
            "metadata": ["ignored": true],
            "items": [
                ["wrapper": ["payload": acknowledgement.base64EncodedString()]],
            ],
        ])

        XCTAssertEqual(
            try A2345CloudPayloadDecoder.decode(mqttPayload),
            [UInt8](acknowledgement)
        )
    }

    func testAllowsDuplicateCopiesOfTheSameFrame() throws {
        let encoded = acknowledgement.base64EncodedString()
        let mqttPayload = try jsonData([
            "data": encoded,
            "nested": [["payload": encoded]],
        ])

        XCTAssertEqual(
            try A2345CloudPayloadDecoder.decode(mqttPayload),
            [UInt8](acknowledgement)
        )
    }

    func testValidFrameWinsOverUnrelatedInvalidDataSibling() throws {
        let mqttPayload = try jsonData([
            "data": "ordinary-envelope-metadata",
            "message": [
                "payload": acknowledgement.base64EncodedString(),
            ],
        ])

        XCTAssertEqual(
            try A2345CloudPayloadDecoder.decode(mqttPayload),
            [UInt8](acknowledgement)
        )
    }

    func testRejectsAmbiguousDistinctFrames() throws {
        let mqttPayload = try jsonData([
            "data": acknowledgement.base64EncodedString(),
            "nested": ["payload": versionInfo.base64EncodedString()],
        ])

        XCTAssertThrowsError(try A2345CloudPayloadDecoder.decode(mqttPayload)) {
            XCTAssertEqual($0 as? A2345CloudPayloadError, .ambiguousFrames)
        }
    }

    func testRejectsInvalidBase64Candidate() throws {
        let mqttPayload = try jsonData(["data": "%%%not-base64%%%"])

        XCTAssertThrowsError(try A2345CloudPayloadDecoder.decode(mqttPayload)) {
            XCTAssertEqual($0 as? A2345CloudPayloadError, .invalidBase64)
        }
    }

    func testRejectsBase64ThatDoesNotContainFF09() throws {
        let mqttPayload = try jsonData([
            "payload": Data("ordinary text".utf8).base64EncodedString(),
        ])

        XCTAssertThrowsError(try A2345CloudPayloadDecoder.decode(mqttPayload)) {
            XCTAssertEqual($0 as? A2345CloudPayloadError, .nonFF09Payload)
        }
    }

    func testRejectsRawNonFF09Payload() {
        XCTAssertThrowsError(
            try A2345CloudPayloadDecoder.decode(Data([0x01, 0x02, 0x03]))
        ) {
            XCTAssertEqual($0 as? A2345CloudPayloadError, .nonFF09Payload)
        }
    }

    func testRejectsFF09FrameWithInvalidChecksum() {
        var corrupt = acknowledgement
        corrupt[corrupt.index(before: corrupt.endIndex)] ^= 1

        XCTAssertThrowsError(try A2345CloudPayloadDecoder.decode(corrupt)) {
            XCTAssertEqual($0 as? A2345CloudPayloadError, .invalidFrame)
        }
    }

    func testRejectsMalformedOuterAndNestedJSON() throws {
        XCTAssertThrowsError(
            try A2345CloudPayloadDecoder.decode(Data("{\"data\": ".utf8))
        ) {
            XCTAssertEqual($0 as? A2345CloudPayloadError, .malformedJSON)
        }

        let nested = try jsonData(["payload": "  {not-json}"])
        XCTAssertThrowsError(try A2345CloudPayloadDecoder.decode(nested)) {
            XCTAssertEqual($0 as? A2345CloudPayloadError, .malformedJSON)
        }
    }

    func testRejectsEmptyPayloadAndJSONWithoutCandidate() throws {
        XCTAssertThrowsError(try A2345CloudPayloadDecoder.decode(Data())) {
            XCTAssertEqual($0 as? A2345CloudPayloadError, .emptyPayload)
        }

        let noCandidate = try jsonData(["message": ["value": "ignored"]])
        XCTAssertThrowsError(try A2345CloudPayloadDecoder.decode(noCandidate)) {
            XCTAssertEqual($0 as? A2345CloudPayloadError, .frameNotFound)
        }
    }

    func testRejectsOversizedMQTTPayloadAndCandidateBeforeDecoding() throws {
        let oversizedInput = Data(
            repeating: 0x20,
            count: A2345CloudPayloadDecoder.maximumInputBytes + 1
        )
        XCTAssertThrowsError(try A2345CloudPayloadDecoder.decode(oversizedInput)) {
            XCTAssertEqual($0 as? A2345CloudPayloadError, .inputTooLarge)
        }

        let oversizedCandidate = String(
            repeating: "A",
            count: A2345CloudPayloadDecoder.maximumBase64Characters + 1
        )
        let json = try jsonData(["data": oversizedCandidate])
        XCTAssertThrowsError(try A2345CloudPayloadDecoder.decode(json)) {
            XCTAssertEqual($0 as? A2345CloudPayloadError, .candidateTooLarge)
        }
    }

    func testRejectsJSONBeyondMaximumDepth() throws {
        var object: Any = ["data": acknowledgement.base64EncodedString()]
        for _ in 0...A2345CloudPayloadDecoder.maximumJSONDepth {
            object = ["nested": object]
        }
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try A2345CloudPayloadDecoder.decode(data)) {
            XCTAssertEqual($0 as? A2345CloudPayloadError, .maximumDepthExceeded)
        }
    }

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

}

private func makeHexData(_ value: String) -> Data {
    var bytes: [UInt8] = []
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<next], radix: 16) else {
            preconditionFailure("invalid fixture hex")
        }
        bytes.append(byte)
        index = next
    }
    return Data(bytes)
}
