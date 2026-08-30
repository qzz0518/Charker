import A2687Protocol
import Foundation

/// Drives the three-command dance that puts a custom picture on the charger's
/// own screen: `0x021F` names it, `0x0220` declares the transfer, `0x0221`
/// carries the JPEG 156 bytes at a time.
///
/// Nothing here touches Bluetooth. Every byte leaves through an injected
/// ``CoverTransferLink`` so the ordering rules below can be tested against a
/// fake charger, and so the one component that must not be wrong — the pacing —
/// is not entangled with the link's own retry and timeout behaviour.
///
/// Evidence: the wire layout comes from `LYJW131/anker-prime-ble` @ f23a07d
/// (`docs/screensaver.md`, `anker_prime_ble/cover.py`), recovered by XORing an
/// official 2026-08-19 add-cover capture against a known plaintext. One unit,
/// one firmware, but the author ran the whole path end to end. The status codes
/// quoted in the comments below are the ones that capture actually produced;
/// everything else about the firmware's error space is unknown.

// `CoverImageReference` and `CoverTransferTicket` are in A2687Protocol, one
// layer down, even though only this file drives them. They have to be where the
// frame builders can accept them whole: the id `0x021F` names and the id
// `0x0220` names must be one stored property read twice, never two arguments
// copied across by hand. That copy is the one mistake in this feature that is
// both silent and permanent — pixels under one id, the screen pointed at
// another, every frame acknowledged, no command to erase either.

// MARK: - Chunks

/// A `0x0221` slice that is sent without waiting for anything.
///
/// Only ``CoverTransferSchedule`` can make one, and it only makes one for an
/// index the firmware is not going to acknowledge. That is the whole point of
/// the type: see ``CoverCheckpointChunk``.
public struct CoverFillChunk: Sendable, Equatable {
    public let index: Int
    /// How many slices the whole transfer has.
    ///
    /// Carried on the chunk because the frame builder needs it: `0x0221` derives
    /// "is a reply coming" from the pair rather than accepting a `Bool`, so the
    /// link has to be able to hand it both halves. A chunk that knew only its
    /// own index would force the link to source the count separately, which is
    /// the seam the pair exists to close.
    public let chunkCount: Int
    /// Always ``CoverTransfer/chunkPayloadSize`` bytes, zero-padded.
    public let payload: [UInt8]

    fileprivate init(index: Int, chunkCount: Int, payload: [UInt8]) {
        self.index = index
        self.chunkCount = chunkCount
        self.payload = payload
    }
}

/// A `0x0221` slice the firmware answers, and which therefore must not be sent
/// without collecting that answer.
///
/// The firmware acknowledges every tenth chunk and the final one. Sending past
/// an unanswered checkpoint overruns it: the observed failure is a `12 A1 01 31`
/// status with the transfer wedged at index 10 — not a lost frame a retry would
/// paper over, and not something the count of bytes written can detect.
///
/// This is a separate type from ``CoverFillChunk`` so that "forgot to wait" is a
/// compile error rather than a code-review item: ``CoverTransferLink``'s
/// fire-and-forget `send(fill:)` does not accept this type, and the only method
/// that does returns the reply.
public struct CoverCheckpointChunk: Sendable, Equatable {
    public let index: Int
    /// See ``CoverFillChunk/chunkCount``.
    public let chunkCount: Int
    public let payload: [UInt8]
    /// What the acknowledgement's `A2` has to say. The firmware reports the
    /// index it expects *next*, so this is `index + 1` — including the final
    /// checkpoint, where it equals the chunk count.
    public var expectedNextIndex: Int { index + 1 }

    fileprivate init(index: Int, chunkCount: Int, payload: [UInt8]) {
        self.index = index
        self.chunkCount = chunkCount
        self.payload = payload
    }
}

/// Every frame of a transfer, in order, each already labelled with whether it
/// has to be waited on.
///
/// Built once up front rather than decided inside the send loop. A loop that
/// recomputes "is this the tenth one" while it is also counting retries is one
/// off-by-one away from the overrun described on ``CoverCheckpointChunk``.
public struct CoverTransferSchedule: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        case fill(CoverFillChunk)
        case checkpoint(CoverCheckpointChunk)
    }

    public let plan: CoverTransfer.Plan
    public let steps: [Step]

    public var chunkCount: Int { plan.chunkCount }
    public var checkpointCount: Int {
        steps.reduce(0) { count, step in
            if case .checkpoint = step { return count + 1 }
            return count
        }
    }

    public init(jpeg: [UInt8]) throws {
        guard let plan = CoverTransfer.Plan(jpeg: jpeg) else {
            throw CoverTransferError.emptyImage
        }
        // `A8` in the start frame and `A2` in every slice are both u16. A JPEG
        // that needs more slices than that cannot be described to the firmware
        // at all, so it is rejected here rather than silently wrapping.
        guard plan.chunkCount <= Int(UInt16.max) else {
            throw CoverTransferError.tooManyChunks(plan.chunkCount)
        }
        self.plan = plan
        var steps: [Step] = []
        steps.reserveCapacity(plan.chunkCount)
        for index in 0..<plan.chunkCount {
            guard let payload = CoverTransfer.chunk(jpeg, at: index) else {
                throw CoverTransferError.emptyImage
            }
            // Same predicate the frame builder uses to set `expectsResponse`,
            // deliberately not a second copy of the rule: the loop's decision to
            // wait and the frame's claim that a reply is coming have to be one
            // fact, or the transport waits for nothing while the firmware waits
            // to be read.
            if CoverCommands.isAcknowledged(chunkIndex: index, of: plan.chunkCount) {
                steps.append(.checkpoint(CoverCheckpointChunk(
                    index: index, chunkCount: plan.chunkCount, payload: payload
                )))
            } else {
                steps.append(.fill(CoverFillChunk(
                    index: index, chunkCount: plan.chunkCount, payload: payload
                )))
            }
        }
        self.steps = steps
    }

    /// Floor on how long the transfer takes: the deliberate pauses only.
    ///
    /// It excludes every round trip, because the time a checkpoint takes to come
    /// back has not been measured. Present it as "at least", never as an ETA.
    public func minimumDuration(with options: CoverTransferSession.Options) -> Duration {
        let fills = chunkCount - checkpointCount
        return options.settleAfterSelect
            + options.settleAfterStart
            + options.chunkSpacing * fills
            + options.settleBeforeVerify
    }
}

// MARK: - Acknowledgements

public enum CoverAcknowledgement {
    /// The index the firmware says it wants next, from a `0x0221` reply.
    ///
    /// The observed reply is `00 A1 01 31 A2=<next index>`. Whether `A2` there
    /// carries the usual type prefix is not recorded in the capture notes, so
    /// both shapes are accepted: a typed scalar first, then a bare little-endian
    /// pair. Returns nil when the reply carries no `A2` at all, which the caller
    /// must treat as "progress unverified", not as "progress fine".
    public static func nextIndex(in payload: Payload) -> Int? {
        guard let raw = payload[A2687.Field.a2] else { return nil }
        if let scalar = TypedValue.decode(raw).scalar { return Int(scalar) }
        if raw.count == 2 { return Int(raw[0]) | Int(raw[1]) << 8 }
        return nil
    }
}

// MARK: - Failures

/// Why a cover push stopped. The cases are split by what the user should do
/// next, not by where in the code the throw happens.
public enum CoverTransferError: Error, Equatable, Sendable {
    case emptyImage
    case tooManyChunks(Int)
    case alreadyRunning

    /// The caller did not state that it knows the write cannot be undone.
    ///
    /// Not a defensive check on a value that "should" be true: it is the only
    /// gate this feature has, because there is no UI yet and therefore no place
    /// where a person has been told anything. See the note atop `CoverCommands`.
    case irreversibilityNotAcknowledged

    /// `0x021F` would have named one hash and `0x0220` another.
    ///
    /// The two commands describe the same picture, and the firmware believes
    /// both. Sending them anyway is the worst failure this feature has: every
    /// slice is acknowledged, all 163 land in a slot that cannot be cleared, and
    /// the charger then never shows the image because the hash it was told to
    /// look for is not the hash of what it stored. Thrown before the first byte.
    case hashMismatch(image: UInt32, plan: UInt32)

    /// `0x021F` went out and nothing came back.
    case selectUnanswered
    /// `0x021F` was refused. Only thrown by ``CoverTransferSession/select(_:)``:
    /// during a push a non-zero status here is expected, see the push itself.
    case selectRejected(status: UInt8)

    /// `0x0220` went out and nothing came back. Upstream treats this as fatal
    /// and so does this state machine — the firmware has not been told how many
    /// slices to expect, so the slices would be uninterpretable.
    case startUnanswered
    case startRejected(status: UInt8)

    case chunkSendFailed(chunkIndex: Int)
    case acknowledgementTimedOut(chunkIndex: Int)
    case chunkRejected(chunkIndex: Int, status: UInt8)
    /// The firmware named an index other than the one we were about to send.
    /// Slices have gone missing; continuing would write a corrupt image.
    case progressMismatch(expected: Int, reported: Int)

    case cancelled(chunksSent: Int, chunkCount: Int)
    case budgetExhausted(chunksSent: Int, chunkCount: Int)

    /// Every slice was acknowledged, and `0xE1` still does not name the new
    /// picture. Distinct from every case above because the pixels are in the
    /// charger — the transfer worked and the *selection* did not take.
    case notShownAfterTransfer(expected: UInt16, reported: UInt16?)

    /// Whether image bytes reached the charger before this failure. Anything
    /// true here has left the device in a state no BLE command can undo.
    public var pixelsMayHaveLanded: Bool {
        switch self {
        case .emptyImage, .tooManyChunks, .alreadyRunning,
             .irreversibilityNotAcknowledged, .hashMismatch,
             .selectUnanswered, .selectRejected, .startUnanswered, .startRejected:
            return false
        case .chunkSendFailed, .acknowledgementTimedOut, .chunkRejected,
             .progressMismatch, .cancelled, .budgetExhausted, .notShownAfterTransfer:
            return true
        }
    }

    /// One line for the diagnostics log, deliberately untranslated.
    ///
    /// This is the half of a failure nobody charging a phone can use: slice
    /// indices, status bytes, the pair of cover ids. It exists so a bug report
    /// still carries them now that the failure card does not, and it is English
    /// for the same reason `AppModel`'s cover evidence line is — a log line that
    /// changes shape with the reader's language is one nobody can grep.
    ///
    /// The sentence a person reads is deliberately *not* here. It is built one
    /// layer up out of what is now inside the charger and what to do about it,
    /// because that is the whole of what anyone can act on, and because this
    /// file cannot know which of those sentences the card has already said.
    /// See `CoverPushFailure` in the app.
    public var diagnostic: String {
        switch self {
        case .emptyImage:
            return "empty image: no JPEG bytes to send"
        case .tooManyChunks(let count):
            return "image needs \(count) chunks, past the u16 the protocol can express"
        case .alreadyRunning:
            return "a cover push is already running"
        case .irreversibilityNotAcknowledged:
            return "caller did not acknowledge the write is irreversible"
        case .hashMismatch(let image, let plan):
            return "hash mismatch: 0x021F would name \(image), 0x0220 \(plan)"
        case .selectUnanswered:
            return "0x021F unanswered"
        case .selectRejected(let status):
            return String(format: "0x021F rejected, status 0x%02X", Int(status))
        case .startUnanswered:
            return "0x0220 unanswered"
        case .startRejected(let status):
            return String(format: "0x0220 rejected, status 0x%02X", Int(status))
        case .chunkSendFailed(let index):
            return "chunk \(index) failed to send"
        case .acknowledgementTimedOut(let index):
            return "no acknowledgement for chunk \(index)"
        case .chunkRejected(let index, let status):
            return String(format: "chunk %d rejected, status 0x%02X", index, Int(status))
        case .progressMismatch(let expected, let reported):
            return "progress mismatch: expected chunk \(expected), firmware reports \(reported)"
        case .cancelled(let sent, let total):
            return "cancelled at chunk \(sent)/\(total)"
        case .budgetExhausted(let sent, let total):
            return "budget exhausted at chunk \(sent)/\(total)"
        case .notShownAfterTransfer(let expected, let reported):
            let shown = reported.map { String($0) } ?? "nothing"
            return "0xE1 reports \(shown) after the transfer, expected \(expected)"
        }
    }
}

// MARK: - Progress

public struct CoverTransferProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        case idle
        case selecting
        case starting
        case sending
        /// Slices are all in; waiting for `0xE1` to name the new picture.
        case verifying
        case finished
    }

    public var stage: Stage
    public var chunksSent: Int
    public var chunkCount: Int

    public init(stage: Stage = .idle, chunksSent: Int = 0, chunkCount: Int = 0) {
        self.stage = stage
        self.chunksSent = chunksSent
        self.chunkCount = chunkCount
    }

    public var fraction: Double {
        guard chunkCount > 0 else { return 0 }
        return Double(chunksSent) / Double(chunkCount)
    }
}

/// Whether the read-back could tell a change from a coincidence.
///
/// An enum rather than the `Bool` this used to be, because the two answers need
/// different sentences on screen and a `Bool` lets a caller render only one of
/// them. `switch`ing over this makes the "cannot confirm" branch a compile-time
/// obligation: ``CoverTransferProgress/Stage`` stops at `.finished` in both
/// cases, so a progress bar that reads only the stage cannot tell them apart,
/// and the difference is exactly whether anybody watched the screen change.
public enum CoverVerification: Sendable, Equatable {
    /// `0xE1` named a different picture before the push and the expected one
    /// after it. The only state in which "the cover changed" is an observation
    /// rather than an inference.
    case witnessed(before: UInt16)

    /// The push completed — every slice was acknowledged and `0xE1` reports the
    /// expected id — but nothing distinguishes that from the charger having
    /// shown this picture all along. Not a failure; not a confirmation either.
    case inconclusive(reason: Reason)

    public enum Reason: Sendable, Equatable {
        /// `0xE1` already reported this id before a single byte went out. What a
        /// wholly failed push looks like when the caller reuses a picture id, or
        /// picks one whose low 16 bits collide with a cover already resident in
        /// one of the four slots.
        case alreadyShowingThisPicture(UInt16)
        /// The pre-push `0xE1` read failed, so there is no "before" to compare
        /// against. Refusing to push over this would be worse than pushing with
        /// a weaker claim, so the push goes ahead and the claim is weakened here.
        case beforeStateUnreadable
    }
}

public struct CoverTransferOutcome: Sendable, Equatable {
    public let pictureID: UInt32
    public let byteCount: Int
    public let chunkCount: Int
    /// Status the pre-transfer `0x021F` answered with. `0x11` here is normal and
    /// not a failure: it means the id is known but its pixels are not resident,
    /// which is the state the transfer then fixes.
    public let selectStatus: UInt8?
    /// Checkpoints whose acknowledgement actually carried an index. Anything
    /// below ``checkpointCount`` means part of the progress went unchecked.
    public let indexedCheckpoints: Int
    public let checkpointCount: Int
    /// What `0xE1` reported after the transfer. Equal to the picture's low 16
    /// bits, or the push would have thrown.
    public let reportedPictureID: UInt16

    /// Whether anyone actually watched the screen change.
    ///
    /// Comparing `0xE1` against the expected id only says "the charger shows
    /// this picture", never "this push changed anything" — the pre-push read is
    /// what turns the second claim into an observation. Callers must render both
    /// cases; see ``CoverVerification``.
    public let verification: CoverVerification
}

// MARK: - Link

/// Everything the state machine needs from the BLE session.
///
/// Implementations answer with the decoded ``Payload`` and let this file judge
/// it: which status codes are fatal depends on where in the sequence we are, and
/// that context only exists here. Throwing is reserved for "nothing came back".
public protocol CoverTransferLink: Sendable {
    /// `0x021F`. Non-zero status is a normal answer, not an error to throw on.
    func selectCover(_ image: CoverImageReference) async throws -> Payload

    /// `0x0220`. Must wait for the reply and throw if none arrives — a silent
    /// start is the one failure that looks identical to success from here.
    ///
    /// Takes the ticket rather than a plan and an image side by side: the
    /// implementation has nothing left to pair up, so it cannot pair them wrong.
    func beginCoverTransfer(_ ticket: CoverTransferTicket) async throws -> Payload

    /// `0x0221`, no reply expected. Only accepts a chunk the schedule marked as
    /// unacknowledged, which is what keeps the pacing rule enforceable.
    func send(fill chunk: CoverFillChunk) async throws

    /// `0x0221` at a checkpoint. Must not return before the reply or `timeout`.
    func send(checkpoint chunk: CoverCheckpointChunk, timeout: Duration) async throws -> Payload

    /// Low 16 bits of the cover id the charger is currently showing: `0xE1`
    /// bytes 2–3 of a `0x0200` / `0x0300` body. Nil when the field is absent.
    func readCoverPictureID() async throws -> UInt16?
}

// MARK: - The state machine

public actor CoverTransferSession {
    /// Status the firmware answers the last slice with once the whole image has
    /// landed. Not in any reference implementation — measured here, twice, on
    /// the owner's v0.0.5.2 unit.
    static let transferCompleteStatus: UInt8 = 0x10

    public struct Options: Sendable {
        /// Upstream's pauses, kept as-is. They are not derived from anything —
        /// they are what the working client does, and the firmware's real
        /// tolerances are unknown, so shortening them is an experiment.
        public var settleAfterSelect: Duration = .milliseconds(150)
        public var settleAfterStart: Duration = .milliseconds(200)
        public var chunkSpacing: Duration = .milliseconds(40)
        public var acknowledgementTimeout: Duration = .seconds(5)
        /// `0xE1` does not flip the instant the last slice lands.
        public var settleBeforeVerify: Duration = .milliseconds(400)
        public var verifyAttempts = 3
        public var verifyRetryDelay: Duration = .seconds(1)
        /// Ceiling on the whole push. It bounds the loop, not a single wedged
        /// write — the link is responsible for timing out its own transport.
        public var totalBudget: Duration = .seconds(240)

        public init() {}
    }

    private let link: CoverTransferLink
    private let options: Options

    private var running = false
    private var cancelRequested = false
    public private(set) var progress = CoverTransferProgress()

    public init(link: CoverTransferLink, options: Options = Options()) {
        self.link = link
        self.options = options
    }

    /// Stops the push at the next slice boundary.
    ///
    /// It cannot unsend anything. Slices already written stay in the charger's
    /// staging area and there is no BLE command to erase them; the only cleanup
    /// is that the screen should not change, because a `0x021F` for a picture
    /// whose pixels are incomplete answers `0x11` and leaves `0xE1` alone. That
    /// last part is inferred from the cloud-only-id observation, not from an
    /// interrupted transfer anyone has actually watched.
    public func cancel() {
        cancelRequested = true
    }

    /// `0x021F` on its own: point the screen at a picture already resident in
    /// one of the four device slots. No pixels move, so this is cheap and
    /// reversible — unlike
    /// ``push(jpeg:as:acknowledgedIrreversible:onProgress:)``.
    @discardableResult
    public func select(_ image: CoverImageReference) async throws -> UInt16? {
        let reply: Payload
        do {
            reply = try await link.selectCover(image)
        } catch {
            throw CoverTransferError.selectUnanswered
        }
        if let status = reply.status, status != 0 {
            throw CoverTransferError.selectRejected(status: status)
        }
        return try? await link.readCoverPictureID()
    }

    /// The full push. Returns only when `0xE1` names the new picture.
    ///
    /// `acknowledgedIrreversible` has no default. Passing `true` is a claim that
    /// the person driving this has been told the image cannot be deleted from the
    /// charger afterwards — no BLE command erases it, and the official app's
    /// delete goes through Anker's cloud. Today no caller can honestly pass
    /// `true`, because there is no UI that says any of this; the argument exists
    /// so that whoever builds one cannot skip past the sentence.
    ///
    /// Deliberately not `@discardableResult`. "It did not throw" is the weaker
    /// half of the answer: the outcome also says whether the screen was ever
    /// witnessed changing, and a caller allowed to drop the return value warning
    /// free would never have to find that out. See ``CoverVerification``.
    public func push(
        jpeg: [UInt8],
        as image: CoverImageReference,
        acknowledgedIrreversible: Bool,
        onProgress: (@Sendable (CoverTransferProgress) -> Void)? = nil
    ) async throws -> CoverTransferOutcome {
        guard acknowledgedIrreversible else {
            throw CoverTransferError.irreversibilityNotAcknowledged
        }
        guard !running else { throw CoverTransferError.alreadyRunning }
        let schedule = try CoverTransferSchedule(jpeg: jpeg)
        // `0x021F` carries `image.hash` while `0x0220` carries `plan.hash`, and
        // the two describe the same picture. Nothing further down the stack can
        // catch a divergence: the firmware acknowledges both hashes happily, and
        // the only symptom is a permanently occupied slot the charger declines
        // to display. This is the last point at which nothing has been sent —
        // and the ticket is the only way to reach the `0x0220` builder at all,
        // so past this line the two frames cannot describe different images.
        guard let ticket = CoverTransferTicket(image: image, plan: schedule.plan) else {
            throw CoverTransferError.hashMismatch(image: image.hash, plan: schedule.plan.hash)
        }
        running = true
        cancelRequested = false
        defer { running = false }

        let total = schedule.chunkCount
        let deadline = ContinuousClock.now.advanced(by: options.totalBudget)
        var sent = 0

        func report(_ stage: CoverTransferProgress.Stage) {
            progress = CoverTransferProgress(stage: stage, chunksSent: sent, chunkCount: total)
            onProgress?(progress)
        }

        // 0. What the screen says now, before anything is touched.
        //
        //    The read-back in step 4 is the only witness that the display
        //    changed, and a witness needs a "before". Read failures are not
        //    fatal here — they only cost the outcome its ability to claim the
        //    change was witnessed, and refusing to push over an unreadable
        //    `0xE1` would be worse than pushing with a weaker claim.
        let pictureIDBeforePush = try? await link.readCoverPictureID()

        // 1. Name the picture.
        report(.selecting)
        try stopIfAsked(sent: sent, total: total, deadline: deadline)
        let selectReply: Payload
        do {
            // `ticket.image`, not the argument: both commands read their id out
            // of the value the ticket vouched for.
            selectReply = try await link.selectCover(ticket.image)
        } catch {
            throw CoverTransferError.selectUnanswered
        }
        // Deliberately not checked. A fresh picture answers `0x11` here — the
        // charger is saying "I know that id and I do not have its pixels", which
        // is the entire reason the next two commands exist. Treating it as a
        // rejection would make every first push fail.
        let selectStatus = selectReply.status
        try await pause(options.settleAfterSelect, sent: sent, total: total)

        // 2. Declare the transfer. Nothing has been written yet, so every
        //    failure from here up to the first slice is safely retryable.
        report(.starting)
        try stopIfAsked(sent: sent, total: total, deadline: deadline)
        let startReply: Payload
        do {
            startReply = try await link.beginCoverTransfer(ticket)
        } catch {
            throw CoverTransferError.startUnanswered
        }
        if let status = startReply.status, status != 0 {
            throw CoverTransferError.startRejected(status: status)
        }
        try await pause(options.settleAfterStart, sent: sent, total: total)

        // 3. Slices. The switch is the pacing rule: a checkpoint physically
        //    cannot take the fire-and-forget branch, because `send(fill:)` does
        //    not accept its type. Adding a third kind of step would fail to
        //    compile here rather than quietly skipping its wait.
        report(.sending)
        var indexedCheckpoints = 0
        for step in schedule.steps {
            try stopIfAsked(sent: sent, total: total, deadline: deadline)
            switch step {
            case .fill(let chunk):
                do {
                    try await link.send(fill: chunk)
                } catch {
                    throw CoverTransferError.chunkSendFailed(chunkIndex: chunk.index)
                }
                sent += 1
                report(.sending)
                try await pause(options.chunkSpacing, sent: sent, total: total)

            case .checkpoint(let chunk):
                let reply: Payload
                do {
                    reply = try await link.send(
                        checkpoint: chunk, timeout: options.acknowledgementTimeout
                    )
                } catch {
                    throw CoverTransferError.acknowledgementTimedOut(chunkIndex: chunk.index)
                }
                // `0x10` on the *final* slice is the firmware saying it has the
                // whole image, not a rejection. Measured on the owner's unit:
                // 101 slices, ten checkpoints answered `0x00`, and the last one
                // answered `0x10` about three seconds later — the write to flash.
                // The picture was on the screen afterwards. Treating it as an
                // error reported a completed transfer as a failure, and told the
                // user a slot had been half-written when it had not.
                //
                // Deliberately scoped to the last slice: a `0x10` arriving in the
                // middle would mean something else entirely, and there is no
                // capture of that to reason from.
                let isFinalSlice = chunk.index == schedule.chunkCount - 1
                if let status = reply.status, status != 0,
                   !(isFinalSlice && status == Self.transferCompleteStatus) {
                    throw CoverTransferError.chunkRejected(chunkIndex: chunk.index, status: status)
                }
                // The firmware's own count, not ours. `12 A1 01 31` with `A2`
                // stuck at 10 is exactly what an overrun looks like, and a
                // counter incremented locally would have reported 20 by then.
                if let reported = CoverAcknowledgement.nextIndex(in: reply) {
                    guard reported == chunk.expectedNextIndex else {
                        throw CoverTransferError.progressMismatch(
                            expected: chunk.expectedNextIndex, reported: reported
                        )
                    }
                    indexedCheckpoints += 1
                }
                sent += 1
                // No pause: the round trip already spaced this one out.
                report(.sending)
            }
        }

        // 4. Read back. An acknowledged transfer is not a shown picture: the
        //    charger ACKs a `0x021F` for an id whose pixels it does not hold and
        //    leaves `0xE1` pointing at the old cover. `0xE1` is the only witness
        //    that the screen actually changed — and only when it differs from
        //    what step 0 read. When it does not, the transfer still succeeded as
        //    far as anyone can tell, but the outcome says the check could not
        //    distinguish that from nothing having happened at all.
        try await pause(options.settleBeforeVerify, sent: sent, total: total)
        report(.verifying)
        let expected = ticket.image.reportedID
        var reported: UInt16?
        for attempt in 0..<max(1, options.verifyAttempts) {
            if attempt > 0 {
                try await pause(options.verifyRetryDelay, sent: sent, total: total)
            }
            reported = try? await link.readCoverPictureID()
            if reported == expected { break }
        }
        guard reported == expected else {
            throw CoverTransferError.notShownAfterTransfer(expected: expected, reported: reported)
        }

        report(.finished)
        let verification: CoverVerification
        switch pictureIDBeforePush {
        case .none:
            verification = .inconclusive(reason: .beforeStateUnreadable)
        case .some(let before) where before == expected:
            verification = .inconclusive(reason: .alreadyShowingThisPicture(before))
        case .some(let before):
            verification = .witnessed(before: before)
        }
        return CoverTransferOutcome(
            pictureID: ticket.image.pictureID,
            byteCount: ticket.plan.byteCount,
            chunkCount: total,
            selectStatus: selectStatus,
            indexedCheckpoints: indexedCheckpoints,
            checkpointCount: schedule.checkpointCount,
            reportedPictureID: expected,
            verification: verification
        )
    }

    /// Cancellation and the overall budget, checked at every slice boundary.
    ///
    /// Both the caller's `cancel()` and a cancelled enclosing task count. The
    /// error carries how far the transfer got, because "nothing was written" and
    /// "half an image is in there" are different things to tell the user.
    private func stopIfAsked(sent: Int, total: Int, deadline: ContinuousClock.Instant) throws {
        if cancelRequested || Task.isCancelled {
            throw CoverTransferError.cancelled(chunksSent: sent, chunkCount: total)
        }
        if ContinuousClock.now >= deadline {
            throw CoverTransferError.budgetExhausted(chunksSent: sent, chunkCount: total)
        }
    }

    /// A sleep whose cancellation is reported in this feature's own terms, so a
    /// bare `CancellationError` never escapes to a UI that would show it raw.
    private func pause(_ duration: Duration, sent: Int, total: Int) async throws {
        do {
            try await Task.sleep(for: duration)
        } catch {
            throw CoverTransferError.cancelled(chunksSent: sent, chunkCount: total)
        }
    }
}
