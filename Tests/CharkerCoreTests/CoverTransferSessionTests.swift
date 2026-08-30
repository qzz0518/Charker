import A2687Protocol
import XCTest
@testable import CharkerCore

private actor FakeLink: CoverTransferLink {
    var fills: [Int] = []
    var checkpoints: [Int] = []
    /// `0x021F` writes no pixels but does change what the screen displays, so
    /// "nothing was sent" has to count this too — `startCalled` and `fills`
    /// alone are satisfied by a select that already went out.
    var selectCalls = 0
    var startCalled = false
    var ackIndexOverride: Int?
    var readback: UInt16?
    var startStatus: UInt8 = 0
    /// Answers handed out before `readback` takes over, so a test can make the
    /// charger report one cover before the push and another after it.
    var readbackQueue: [UInt16?] = []
    var reads = 0

    func setReadback(_ v: UInt16?) { readback = v }
    func setAckOverride(_ v: Int?) { ackIndexOverride = v }
    func setStartStatus(_ v: UInt8) { startStatus = v }
    func setReadbackQueue(_ v: [UInt16?]) { readbackQueue = v }
    func setFinalCheckpointStatus(_ v: UInt8?) { finalCheckpointStatus = v }
    func setMidCheckpointStatus(_ v: UInt8?) { midCheckpointStatus = v }

    func selectCover(_ image: CoverImageReference) async throws -> Payload {
        selectCalls += 1
        return Payload(status: 0x11, fields: [TLV(id: 0xA1, value: [0x31])])
    }

    func beginCoverTransfer(_ ticket: CoverTransferTicket) async throws -> Payload {
        startCalled = true
        return Payload(status: startStatus, fields: [])
    }

    func send(fill chunk: CoverFillChunk) async throws {
        XCTAssertEqual(chunk.payload.count, CoverTransfer.chunkPayloadSize)
        fills.append(chunk.index)
    }

    /// Status for the slice the schedule marked as last. Real firmware answers
    /// `0x10` there once the image has landed.
    var finalCheckpointStatus: UInt8?
    /// Status for a checkpoint that is *not* the last one.
    var midCheckpointStatus: UInt8?

    func send(checkpoint chunk: CoverCheckpointChunk, timeout: Duration) async throws -> Payload {
        checkpoints.append(chunk.index)
        let next = ackIndexOverride ?? chunk.expectedNextIndex
        let isFinal = chunk.index == chunk.chunkCount - 1
        let status = isFinal ? (finalCheckpointStatus ?? 0) : (midCheckpointStatus ?? 0)
        return Payload(status: status, fields: [
            TLV(id: 0xA1, value: [0x31]),
            TLV(id: 0xA2, value: TypedValue.u16(UInt16(next)).encoded),
        ])
    }

    func readCoverPictureID() async throws -> UInt16? {
        reads += 1
        if !readbackQueue.isEmpty { return readbackQueue.removeFirst() }
        return readback
    }
}

final class CoverTransferSessionTests: XCTestCase {
    private func jpeg(_ n: Int) -> [UInt8] { (0..<n).map { UInt8($0 % 251) } }

    private func fastOptions() -> CoverTransferSession.Options {
        var o = CoverTransferSession.Options()
        o.settleAfterSelect = .zero
        o.settleAfterStart = .zero
        o.chunkSpacing = .zero
        o.settleBeforeVerify = .zero
        o.verifyRetryDelay = .zero
        return o
    }

    func testScheduleCheckpoints() throws {
        let s = try CoverTransferSchedule(jpeg: jpeg(25397))
        XCTAssertEqual(s.chunkCount, 163)
        var acks: [Int] = []
        for step in s.steps { if case .checkpoint(let c) = step { acks.append(c.index) } }
        XCTAssertEqual(acks.first, 9)
        XCTAssertEqual(acks.last, 162)
        XCTAssertEqual(acks.count, 17)
        if case .checkpoint = s.steps.last! {} else { XCTFail("last step must be a checkpoint") }
    }

    func testHappyPath() async throws {
        let link = FakeLink()
        // A different cover before the push, so the read-back afterwards is
        // evidence of a change rather than of a coincidence.
        await link.setReadbackQueue([24551])
        await link.setReadback(45470)
        let session = CoverTransferSession(link: link, options: fastOptions())
        let bytes = jpeg(25397)
        let ref = CoverImageReference(pictureID: 45470, jpeg: bytes)
        let outcome = try await session.push(
            jpeg: bytes, as: ref, acknowledgedIrreversible: true
        )
        XCTAssertEqual(outcome.chunkCount, 163)
        XCTAssertEqual(outcome.selectStatus, 0x11)
        XCTAssertEqual(outcome.indexedCheckpoints, 17)
        XCTAssertEqual(outcome.checkpointCount, 17)
        XCTAssertEqual(outcome.verification, .witnessed(before: 24551))
        let fills = await link.fills.count
        let cps = await link.checkpoints.count
        XCTAssertEqual(fills + cps, 163)
    }

    /// The read-back said the right thing, and it had said the right thing
    /// before a single byte went out. Nothing was witnessed, so the outcome must
    /// not pretend otherwise — this is the shape a wholly failed push takes when
    /// the caller reuses a picture id, or picks one whose low 16 bits collide
    /// with a cover already sitting in one of the four slots.
    func testReadBackThatCouldNotHaveWitnessedAnything() async throws {
        let link = FakeLink()
        await link.setReadback(45470)
        let session = CoverTransferSession(link: link, options: fastOptions())
        let bytes = jpeg(500)
        let outcome = try await session.push(
            jpeg: bytes,
            as: CoverImageReference(pictureID: 45470, jpeg: bytes),
            acknowledgedIrreversible: true
        )
        XCTAssertEqual(outcome.reportedPictureID, 45470)
        XCTAssertEqual(
            outcome.verification, .inconclusive(reason: .alreadyShowingThisPicture(45470))
        )
    }

    /// An unreadable `0xE1` before the push is not fatal — it only costs the
    /// outcome its claim.
    func testUnreadableBeforeStateIsNotFatalButIsNotAWitnessEither() async throws {
        let link = FakeLink()
        await link.setReadbackQueue([nil])
        await link.setReadback(45470)
        let session = CoverTransferSession(link: link, options: fastOptions())
        let bytes = jpeg(500)
        let outcome = try await session.push(
            jpeg: bytes,
            as: CoverImageReference(pictureID: 45470, jpeg: bytes),
            acknowledgedIrreversible: true
        )
        XCTAssertEqual(outcome.verification, .inconclusive(reason: .beforeStateUnreadable))
    }

    /// `0x021F` carries the reference's hash, `0x0220` the plan's. When they
    /// disagree the firmware acknowledges everything and then never displays the
    /// image — into a slot with no erase command. Nothing may go out.
    func testHashMismatchSendsNothing() async throws {
        let link = FakeLink()
        await link.setReadback(45470)
        let session = CoverTransferSession(link: link, options: fastOptions())
        do {
            _ = try await session.push(
                jpeg: jpeg(25397),
                as: CoverImageReference(pictureID: 45470, hash: 0xDEAD_BEEF),
                acknowledgedIrreversible: true
            )
            XCTFail("expected the two hashes to be compared")
        } catch let error as CoverTransferError {
            guard case .hashMismatch(let image, let plan) = error else {
                return XCTFail("wrong case \(error)")
            }
            XCTAssertEqual(image, 0xDEAD_BEEF)
            XCTAssertEqual(plan, CoverTransfer.crc32(jpeg(25397)))
            XCTAssertNotEqual(image, plan)
            XCTAssertFalse(error.pixelsMayHaveLanded)
            let started = await link.startCalled
            let fills = await link.fills.count
            XCTAssertFalse(started)
            XCTAssertEqual(fills, 0)
            // The two above hold even when `0x021F` has already gone out, which
            // is why they are not the assertion this test is named for. A select
            // writes no pixels and is still a change to what the screen shows —
            // pointed, in this case, at an id whose hash the charger will never
            // match. Nothing may leave, including the read that precedes it.
            let selects = await link.selectCalls
            let reads = await link.reads
            XCTAssertEqual(selects, 0)
            XCTAssertEqual(reads, 0)
        }
    }

    /// The reference built from the bytes cannot produce that mismatch.
    func testReferenceDerivedFromTheBytesMatchesItsOwnPlan() throws {
        let bytes = jpeg(25397)
        let schedule = try CoverTransferSchedule(jpeg: bytes)
        XCTAssertEqual(CoverImageReference(pictureID: 1, jpeg: bytes).hash, schedule.plan.hash)
    }

    /// The only gate this feature has while it has no UI.
    func testPushRefusesWithoutAnAcknowledgement() async throws {
        let link = FakeLink()
        await link.setReadback(45470)
        let session = CoverTransferSession(link: link, options: fastOptions())
        let bytes = jpeg(500)
        do {
            _ = try await session.push(
                jpeg: bytes,
                as: CoverImageReference(pictureID: 45470, jpeg: bytes),
                acknowledgedIrreversible: false
            )
            XCTFail("expected a refusal")
        } catch let error as CoverTransferError {
            XCTAssertEqual(error, .irreversibilityNotAcknowledged)
            XCTAssertFalse(error.pixelsMayHaveLanded)
            // Checked before anything is read, let alone written.
            let reads = await link.reads
            XCTAssertEqual(reads, 0)
        }
    }

    /// The schedule's "wait here" and the frame's "a reply is coming" have to be
    /// the same predicate, or the transport is told not to wait for a slice the
    /// loop is waiting on.
    func testScheduleAgreesWithTheFrameBuilder() throws {
        let schedule = try CoverTransferSchedule(jpeg: jpeg(25397))
        for step in schedule.steps {
            switch step {
            case .fill(let chunk):
                XCTAssertFalse(CoverCommands.isAcknowledged(
                    chunkIndex: chunk.index, of: schedule.chunkCount
                ))
            case .checkpoint(let chunk):
                XCTAssertTrue(CoverCommands.isAcknowledged(
                    chunkIndex: chunk.index, of: schedule.chunkCount
                ))
            }
        }
    }

    func testProgressMismatch() async throws {
        let link = FakeLink()
        await link.setAckOverride(10)
        await link.setReadback(45470)
        let session = CoverTransferSession(link: link, options: fastOptions())
        let bytes = jpeg(25397)
        do {
            _ = try await session.push(
                jpeg: bytes,
                as: CoverImageReference(pictureID: 45470, jpeg: bytes),
                acknowledgedIrreversible: true
            )
            XCTFail("expected mismatch")
        } catch let error as CoverTransferError {
            guard case .progressMismatch(let expected, let reported) = error else {
                return XCTFail("wrong case \(error)")
            }
            XCTAssertEqual(expected, 20)
            XCTAssertEqual(reported, 10)
            XCTAssertTrue(error.pixelsMayHaveLanded)
        }
    }

    func testStartRejectedLeavesNothingWritten() async throws {
        let link = FakeLink()
        await link.setStartStatus(0x04)
        let session = CoverTransferSession(link: link, options: fastOptions())
        let bytes = jpeg(500)
        do {
            _ = try await session.push(
                jpeg: bytes,
                as: CoverImageReference(pictureID: 1, jpeg: bytes),
                acknowledgedIrreversible: true
            )
            XCTFail("expected rejection")
        } catch let error as CoverTransferError {
            XCTAssertEqual(error, .startRejected(status: 0x04))
            XCTAssertFalse(error.pixelsMayHaveLanded)
            let fills = await link.fills.count
            XCTAssertEqual(fills, 0)
        }
    }

    func testAckedButNotShown() async throws {
        let link = FakeLink()
        await link.setReadback(24551)
        let session = CoverTransferSession(link: link, options: fastOptions())
        let bytes = jpeg(500)
        do {
            _ = try await session.push(
                jpeg: bytes,
                as: CoverImageReference(pictureID: 45470, jpeg: bytes),
                acknowledgedIrreversible: true
            )
            XCTFail("expected verification failure")
        } catch let error as CoverTransferError {
            XCTAssertEqual(error, .notShownAfterTransfer(expected: 45470, reported: 24551))
            XCTAssertTrue(error.pixelsMayHaveLanded)
        }
    }

    func testCancelStops() async throws {
        let link = FakeLink()
        await link.setReadback(45470)
        var o = fastOptions()
        o.chunkSpacing = .milliseconds(5)
        let session = CoverTransferSession(link: link, options: o)
        let bytes = jpeg(25397)
        let ref = CoverImageReference(pictureID: 45470, jpeg: bytes)
        let task = Task {
            try await session.push(jpeg: bytes, as: ref, acknowledgedIrreversible: true)
        }
        // Wait for the loop to actually be sending instead of guessing at a
        // duration. The CRC-32 and the 163 chunk builds in front of the first
        // slice take tens of milliseconds in a debug build, which is enough to
        // swallow a fixed sleep and make this test fail for the wrong reason.
        var waited = Duration.zero
        while await session.progress.chunksSent == 0, waited < .seconds(5) {
            try await Task.sleep(for: .milliseconds(5))
            waited += .milliseconds(5)
        }
        let started = await session.progress.chunksSent
        XCTAssertGreaterThan(started, 0, "the transfer never reached its first slice")
        await session.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as CoverTransferError {
            guard case .cancelled(let sent, let total) = error else { return XCTFail("wrong case \(error)") }
            XCTAssertGreaterThan(sent, 0)
            XCTAssertLessThan(sent, total)
        }
    }

    func testEmptyImage() {
        XCTAssertThrowsError(try CoverTransferSchedule(jpeg: []))
    }

    func testBareLittleEndianAck() {
        let p = Payload(status: 0, fields: [TLV(id: 0xA2, value: [0x0A, 0x00])])
        XCTAssertEqual(CoverAcknowledgement.nextIndex(in: p), 10)
        let typed = Payload(status: 0, fields: [TLV(id: 0xA2, value: TypedValue.u16(163).encoded)])
        XCTAssertEqual(CoverAcknowledgement.nextIndex(in: typed), 163)
    }
    /// The last slice comes back `0x10`, not `0x00`, and that is success.
    ///
    /// Measured on the owner's charger: 101 slices, ten checkpoints answered
    /// `0x00`, the final one answered `0x10` roughly three seconds later, and the
    /// image was on the display afterwards. Before this was understood the push
    /// threw `chunkRejected` on that byte and told the user a slot had been
    /// half-written — a completed, irreversible write reported as a failure.
    func testFinalSliceStatus0x10CompletesTheTransfer() async throws {
        let jpeg = [UInt8](repeating: 0x5A, count: 156 * 3)
        let image = CoverImageReference(pictureID: 4242, jpeg: jpeg)
        let link = FakeLink()
        await link.setFinalCheckpointStatus(0x10)
        // 推送前屏幕上是另一张图，推送后变成这张 —— 这样读回才有区分力。
        await link.setReadbackQueue([45470, image.reportedID])
        let session = CoverTransferSession(link: link)
        let outcome = try await session.push(
            jpeg: jpeg, as: image, acknowledgedIrreversible: true
        )
        XCTAssertEqual(outcome.chunkCount, 3)
        if case .inconclusive = outcome.verification {
            XCTFail("0xE1 moved to the new id, so this witnessed a change")
        }
    }

    /// Same byte anywhere but the end still stops the push. There is no capture
    /// of a mid-transfer `0x10`, so it stays an error rather than a guess.
    func testStatus0x10BeforeTheLastSliceStillFails() async throws {
        let jpeg = [UInt8](repeating: 0x5A, count: 156 * 12)
        let image = CoverImageReference(pictureID: 4243, jpeg: jpeg)
        let link = FakeLink()
        await link.setMidCheckpointStatus(0x10)
        let session = CoverTransferSession(link: link)
        do {
            _ = try await session.push(jpeg: jpeg, as: image, acknowledgedIrreversible: true)
            XCTFail("a 0x10 that is not the final slice must not be read as done")
        } catch let error as CoverTransferError {
            guard case .chunkRejected(_, let status) = error else {
                return XCTFail("expected chunkRejected, got \(error)")
            }
            XCTAssertEqual(status, 0x10)
        }
    }

}
