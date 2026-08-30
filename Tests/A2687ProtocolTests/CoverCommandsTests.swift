import XCTest
@testable import A2687Protocol

/// The cover commands write to storage the charger has no delete command for, so
/// a wrong byte here is not a retryable mistake. These tests pin the plaintext
/// lengths the captures recorded — 47 / 49 / 167 — and the exact bytes of the
/// fields that are easy to get subtly wrong: the typed epoch, the text-tagged URL
/// slot, and the mixed wrapping of the two ids.
final class CoverCommandsTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 0x1234_5678)

    private func reference(
        _ id: UInt32, hash: UInt32, url: String = CoverCommands.urlPlaceholder
    ) -> CoverImageReference {
        CoverImageReference(pictureID: id, hash: hash, urlKey: url)
    }

    /// The only way to build a `0x0220`. The hash comes from the plan, so these
    /// tests cannot accidentally construct the divergence the ticket exists to
    /// prevent — which is the point: neither can production code.
    private func ticket(_ id: UInt32, _ plan: CoverTransfer.Plan) throws -> CoverTransferTicket {
        try XCTUnwrap(CoverTransferTicket(
            image: CoverImageReference(pictureID: id, hash: plan.hash), plan: plan
        ))
    }

    // MARK: - Plaintext lengths

    func testSelectCoverPlaintextIs47Bytes() {
        let message = CoverCommands.selectCover(reference(24551, hash: 0xDEAD_BEEF), at: epoch)
        XCTAssertEqual(message.plaintext.count, 47)
        XCTAssertEqual(message.opcode, 0x021F)
        XCTAssertEqual(message.group, Frame.sessionGroup)
    }

    func testStartTransferPlaintextIs49Bytes() throws {
        let plan = try XCTUnwrap(CoverTransfer.Plan(jpeg: [UInt8](repeating: 0, count: 25397)))
        let message = CoverCommands.startTransfer(try ticket(24551, plan), at: epoch)
        XCTAssertEqual(message.plaintext.count, 49)
        XCTAssertEqual(message.opcode, 0x0220)
    }

    func testChunkPlaintextIs167Bytes() {
        let payload = [UInt8](repeating: 0xAB, count: CoverTransfer.chunkPayloadSize)
        let message = CoverCommands.transferChunk(
            sequence: 0, of: 163, payload: payload, at: epoch
        )
        XCTAssertEqual(message.plaintext.count, 167)
        XCTAssertEqual(message.opcode, 0x0221)
    }

    // MARK: - The bytes that are easy to get wrong

    /// Cover commands carry the epoch as a *typed* u32 (`FE 05 03 …`), unlike
    /// every other session command, which sends four bare bytes (`FE 04 …`).
    /// Getting this wrong yields a frame the firmware answers with silence.
    func testEpochIsATypedU32NotBareBytes() throws {
        let message = CoverCommands.selectCover(reference(1, hash: 2), at: epoch)
        let fields = try XCTUnwrap(try? Payload.parse(message.plaintext)).fields
        let stamp = try XCTUnwrap(fields.last)
        XCTAssertEqual(stamp.id, A2687.Field.timestamp)
        XCTAssertEqual(stamp.value, [TypedValue.u32Type, 0x78, 0x56, 0x34, 0x12])
        // Length byte on the wire: 5, not the 4 a bare stamp would use.
        XCTAssertEqual(stamp.value.count, 5)
    }

    /// `FD 11 00 "SmallChargingUrl"` — 0x11 = 17 = one text tag plus 16 characters.
    func testURLSlotIsTextTaggedAndSeventeenBytes() throws {
        let message = CoverCommands.selectCover(reference(1, hash: 2), at: epoch)
        let fields = try XCTUnwrap(try? Payload.parse(message.plaintext)).fields
        let slot = try XCTUnwrap(fields.first { $0.id == A2687.Field.fd })
        XCTAssertEqual(slot.value.count, 17)
        XCTAssertEqual(slot.value.first, TypedValue.textType)
        XCTAssertEqual(String(decoding: slot.value.dropFirst(), as: UTF8.self), "SmallChargingUrl")
        XCTAssertEqual(CoverCommands.urlPlaceholder.utf8.count, 16)
    }

    /// The id and the hash go out as `04` byte blocks while the size goes as an
    /// `03` typed u32. The asymmetry is in the captures; this pins it so a later
    /// "tidy-up" cannot quietly make them consistent.
    func testIdAndHashAreByteBlocksWhileSizeIsATypedU32() throws {
        let plan = try XCTUnwrap(CoverTransfer.Plan(jpeg: [UInt8](repeating: 7, count: 1000)))
        let message = CoverCommands.startTransfer(try ticket(0x0000_5FE7, plan), at: epoch)
        let fields = try XCTUnwrap(try? Payload.parse(message.plaintext)).fields

        let id = try XCTUnwrap(fields.first { $0.id == A2687.Field.a3 })
        XCTAssertEqual(id.value, [TypedValue.bytesType, 0xE7, 0x5F, 0x00, 0x00])

        let hash = try XCTUnwrap(fields.first { $0.id == A2687.Field.a4 })
        XCTAssertEqual(hash.value.first, TypedValue.bytesType)
        XCTAssertEqual(Array(hash.value.dropFirst()), CoverCommands.u32Bytes(plan.hash))

        let size = try XCTUnwrap(fields.first { $0.id == A2687.Field.a5 })
        XCTAssertEqual(size.value, [TypedValue.u32Type, 0xE8, 0x03, 0x00, 0x00])
    }

    /// Chunk geometry is declared in the header and then has to be obeyed by the
    /// loop, so both must come from the same plan.
    func testStartTransferDeclaresTheGeometryTheLoopWillUse() throws {
        let plan = try XCTUnwrap(CoverTransfer.Plan(jpeg: [UInt8](repeating: 1, count: 25397)))
        let message = CoverCommands.startTransfer(try ticket(1, plan), at: epoch)
        let fields = try XCTUnwrap(try? Payload.parse(message.plaintext)).fields

        // A6 = acknowledge every 10 chunks.
        XCTAssertEqual(fields.first { $0.id == A2687.Field.a6 }?.value, [TypedValue.u8Type, 10])
        // A7 = 156 bytes per chunk, u16 little endian: 9C 00.
        XCTAssertEqual(
            fields.first { $0.id == A2687.Field.a7 }?.value,
            [TypedValue.u16Type, 0x9C, 0x00]
        )
        // A8 = 163 chunks for this image.
        XCTAssertEqual(plan.chunkCount, 163)
        XCTAssertEqual(
            fields.first { $0.id == A2687.Field.a8 }?.value,
            [TypedValue.u16Type, 0xA3, 0x00]
        )
    }

    func testChunkCarriesSequenceAndPayloadOnly() throws {
        var payload = [UInt8](repeating: 0, count: CoverTransfer.chunkPayloadSize)
        payload[0] = 0xFF
        payload[155] = 0x11
        let message = CoverCommands.transferChunk(
            sequence: 258, of: 1000, payload: payload, at: epoch
        )
        let fields = try XCTUnwrap(try? Payload.parse(message.plaintext)).fields

        XCTAssertEqual(fields.count, 3, "chunks carry no epoch — only marker, sequence, slice")
        XCTAssertNil(fields.first { $0.id == A2687.Field.timestamp })
        // 258 = 0x0102 little endian.
        XCTAssertEqual(
            fields.first { $0.id == A2687.Field.a2 }?.value,
            [TypedValue.u16Type, 0x02, 0x01]
        )
        let slice = try XCTUnwrap(fields.first { $0.id == A2687.Field.a3 })
        XCTAssertEqual(slice.value.count, 157, "0x9D = one type byte plus 156")
        XCTAssertEqual(slice.value.first, TypedValue.bytesType)
        XCTAssertEqual(Array(slice.value.dropFirst()), payload)
    }

    // MARK: - Which slices have to be waited for

    /// The frame is what tells the transport whether a reply is coming, and the
    /// builder derives that from the slice's position rather than being told.
    /// It used to be told, and `(sequence: 9, expectsAcknowledgement: false)`
    /// compiled into a perfectly legal 167-byte frame — the entry point to the
    /// `12 A1 01 31` overrun, where the sender fires the next ten slices while
    /// the charger is still holding an unread reply and the pixels already
    /// written cannot be taken back. There is no argument left to get wrong;
    /// what this pins is that the derivation is actually wired to the flag.
    func testChunkFrameDerivesWhetherAReplyIsComing() {
        let payload = [UInt8](repeating: 0, count: CoverTransfer.chunkPayloadSize)
        let fill = CoverCommands.transferChunk(
            sequence: 3, of: 163, payload: payload, at: epoch
        )
        let checkpoint = CoverCommands.transferChunk(
            sequence: 9, of: 163, payload: payload, at: epoch
        )
        XCTAssertFalse(fill.expectsResponse)
        XCTAssertTrue(checkpoint.expectsResponse)
        // Only the flag differs; the bytes on the wire are identical.
        XCTAssertEqual(fill.plaintext.count, checkpoint.plaintext.count)
        // The same index in a shorter transfer is the last slice, so the flag
        // flips — which is why the count has to travel with the index.
        XCTAssertTrue(
            CoverCommands.transferChunk(sequence: 3, of: 4, payload: payload, at: epoch)
                .expectsResponse
        )
    }

    /// Every tenth slice and the last one, and the two rules must not both fire
    /// on the same index twice or a checkpoint would be counted as two.
    func testAcknowledgedIndicesForARealImage() {
        let count = 163
        let acknowledged = (0..<count).filter {
            CoverCommands.isAcknowledged(chunkIndex: $0, of: count)
        }
        XCTAssertEqual(acknowledged.first, 9)
        XCTAssertEqual(acknowledged.last, count - 1)
        XCTAssertEqual(acknowledged.count, 17)
        XCTAssertTrue(CoverCommands.isAcknowledged(chunkIndex: count - 1, of: count))
    }

    /// A single-slice image: index 0 is both the first and the last, and the
    /// firmware still answers it. Getting this wrong means never waiting at all.
    func testSingleSliceImageIsAllCheckpoint() {
        XCTAssertTrue(CoverCommands.isAcknowledged(chunkIndex: 0, of: 1))
        XCTAssertFalse(CoverCommands.isAcknowledged(chunkIndex: 0, of: 2))
    }

    // MARK: - The URL slot's length byte

    /// TLV lengths are one byte and the encoder truncates. The placeholder is 16
    /// bytes, but the cloud fallback carries a real key, and a value long enough
    /// to wrap the length byte would misalign every field after it — in a command
    /// that writes to storage with no erase. 254 bytes is the last legal size:
    /// 254 + the text type tag = 255.
    func testLongestLegalURLStillClosesItsLengthByte() throws {
        let url = String(repeating: "k", count: 254)
        let message = CoverCommands.selectCover(reference(1, hash: 2, url: url), at: epoch)
        let fields = try XCTUnwrap(try? Payload.parse(message.plaintext)).fields
        let slot = try XCTUnwrap(fields.first { $0.id == A2687.Field.fd })
        XCTAssertEqual(slot.value.count, 255)
        XCTAssertEqual(String(decoding: slot.value.dropFirst(), as: UTF8.self), url)
        // The epoch still parses, which is the thing a wrong length byte breaks.
        XCTAssertEqual(fields.last?.id, A2687.Field.timestamp)
    }

    // MARK: - The one id, the one hash

    /// The id in `0x021F` and the id in `0x0220` are now the same stored
    /// property read twice. This is the failure that used to be reachable by
    /// mistyping one argument: pixels stored under one id, the screen told to
    /// display another, every frame acknowledged, nothing ever shown, and no
    /// command to erase either.
    func testBothCommandsCarryTheSameID() throws {
        let bytes = [UInt8](repeating: 3, count: 1000)
        let image = CoverImageReference(pictureID: 0x0000_5FE7, jpeg: bytes)
        let plan = try XCTUnwrap(CoverTransfer.Plan(jpeg: bytes))
        let ticket = try XCTUnwrap(CoverTransferTicket(image: image, plan: plan))

        let selectFields = try XCTUnwrap(
            try? Payload.parse(CoverCommands.selectCover(ticket.image, at: epoch).plaintext)
        ).fields
        let startFields = try XCTUnwrap(
            try? Payload.parse(CoverCommands.startTransfer(ticket, at: epoch).plaintext)
        ).fields

        // Different field ids — A4 in the select, A3 in the start — same bytes.
        let selected = try XCTUnwrap(selectFields.first { $0.id == A2687.Field.a4 })
        let declared = try XCTUnwrap(startFields.first { $0.id == A2687.Field.a3 })
        XCTAssertEqual(selected.value, declared.value)
        XCTAssertEqual(Array(selected.value.dropFirst()), CoverCommands.u32Bytes(image.pictureID))

        // And the same for the hash: A5 in the select, A4 in the start.
        XCTAssertEqual(
            selectFields.first { $0.id == A2687.Field.a5 }?.value,
            startFields.first { $0.id == A2687.Field.a4 }?.value
        )
    }

    /// A reference whose hash is not the hash of the bytes cannot become a
    /// ticket, and without a ticket there is no way to build a `0x0220` at all.
    /// The check therefore happens before a frame exists, not before it is sent.
    func testTicketRefusesAHashThatIsNotThePlansOwn() throws {
        let plan = try XCTUnwrap(CoverTransfer.Plan(jpeg: [UInt8](repeating: 3, count: 1000)))
        XCTAssertNil(CoverTransferTicket(
            image: CoverImageReference(pictureID: 1, hash: 0xDEAD_BEEF), plan: plan
        ))
        XCTAssertNotNil(CoverTransferTicket(
            image: CoverImageReference(pictureID: 1, hash: plan.hash), plan: plan
        ))
    }

    /// An ACK from `0x021F` is not evidence the picture is showing — the firmware
    /// answers even when the named image has no pixels on the device. This test
    /// exists to keep the reasoning attached to the code.
    func testFirstFieldIsAlwaysTheActionMarker() throws {
        for message in [
            CoverCommands.selectCover(reference(1, hash: 2), at: epoch),
            CoverCommands.startTransfer(
                try ticket(1, try XCTUnwrap(CoverTransfer.Plan(jpeg: [1, 2, 3]))),
                at: epoch
            ),
            CoverCommands.transferChunk(
                sequence: 0, of: 1,
                payload: [UInt8](repeating: 0, count: CoverTransfer.chunkPayloadSize),
                at: epoch
            ),
        ] {
            let fields = try XCTUnwrap(try? Payload.parse(message.plaintext)).fields
            XCTAssertEqual(fields.first?.id, A2687.Field.a1)
            XCTAssertEqual(fields.first?.value, [A2687.sessionAction])
        }
    }
}
