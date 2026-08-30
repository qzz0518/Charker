import A2687Protocol
import Foundation

/// Wires ``CoverTransferSession`` onto a live ``ChargerSession``.
///
/// The state machine deliberately knows nothing about BLE, polling or write
/// gating; this is where those meet it. Two responsibilities beyond plumbing:
///
/// - **The poll has to stand down.** A push streams `0x0221` for ten seconds or
///   more, and the safety-net poll would drop a `0x0200` read into the middle of
///   that. Whether the firmware tolerates an interleaved frame mid-transfer is
///   not something anyone has measured, and the one client known to work does
///   nothing else while transferring. The hold is taken before the first cover
///   command and released on every exit path.
/// - **Readiness is checked once, here.** Not per frame: a 163-frame sequence
///   that could stop being permitted halfway through is worse than one that was
///   never allowed to start. Readiness is all this layer checks — the consent
///   for the write itself is ``CoverTransferSession``'s
///   `acknowledgedIrreversible`, which is about this image and is asked at the
///   moment of the push.
public struct CoverTransferAdapter: CoverTransferLink {
    private let session: ChargerSession
    private let acknowledgementTimeout: Duration

    public init(session: ChargerSession, acknowledgementTimeout: Duration = .seconds(5)) {
        self.session = session
        self.acknowledgementTimeout = acknowledgementTimeout
    }

    // MARK: - CoverTransferLink

    /// Non-zero status is returned rather than thrown. Which codes are fatal
    /// depends on where in the push we are — `0x11` means "id known, pixels
    /// absent", which is a failure when selecting a resident cover and the
    /// expected state when starting a transfer — and only the state machine has
    /// that context.
    public func selectCover(_ image: CoverImageReference) async throws -> Payload {
        try await session.send(
            CoverCommands.selectCover(image),
            awaitOpcode: A2687.Opcode.setScreensaver
        )
    }

    /// Nothing is unpacked and re-paired here on the way to the builder. It used
    /// to be — `pictureID: image.pictureID, plan: plan` — and that one line was
    /// the only place the two commands' ids could diverge, with a failure the
    /// firmware acknowledges all the way through and no command can undo.
    public func beginCoverTransfer(_ ticket: CoverTransferTicket) async throws -> Payload {
        try await session.send(
            CoverCommands.startTransfer(ticket),
            awaitOpcode: A2687.Opcode.coverTransferStart
        )
    }

    // Neither of the two sends below states whether a reply is coming; both
    // hand the builder `(index, chunkCount)` and let it derive that. So the
    // frame a fill produces cannot claim a reply is coming, and the one a
    // checkpoint produces cannot claim the opposite — the schedule split the
    // two on the same predicate the builder asks. While that flag was an
    // argument here, "fill" and "checkpoint" were only as trustworthy as the
    // literal typed beside them, and a `false` next to index 9 is the `12 A1 01
    // 31` wedge with a hundred unerasable slices already written.

    /// Throws when the bytes never left. The distinction matters: the fire-and-
    /// forget dispatch elsewhere in the session swallows write errors, which
    /// would turn a slice that never went out into a progress mismatch nine
    /// slices later instead of a stop at the slice that failed.
    public func send(fill chunk: CoverFillChunk) async throws {
        try await session.send(
            CoverCommands.transferChunk(
                sequence: chunk.index, of: chunk.chunkCount, payload: chunk.payload
            )
        )
    }

    public func send(
        checkpoint chunk: CoverCheckpointChunk, timeout: Duration
    ) async throws -> Payload {
        try await session.send(
            CoverCommands.transferChunk(
                sequence: chunk.index, of: chunk.chunkCount, payload: chunk.payload
            ),
            awaitOpcode: A2687.Opcode.coverTransferChunk,
            timeout: timeout
        )
    }

    /// Reads `0xE1` out of a fresh telemetry frame.
    ///
    /// Goes through a `0x0200` read rather than waiting for the next pushed
    /// `0x0300`: the caller needs the value *now*, both before the push as a
    /// baseline and after it as the only witness that the screen changed.
    /// Returns nil when the field is absent or too short — nil is "could not
    /// read", which the state machine treats differently from a value that
    /// disagrees.
    public func readCoverPictureID() async throws -> UInt16? {
        let payload = try await session.send(
            CommandEncoder.readAll(), awaitOpcode: A2687.Opcode.realtimeReport
        )
        return Self.coverPictureID(in: payload)
    }

    /// `0xE1` is a ten byte struct whose bytes 2..3 are the cover id, little
    /// endian. The surrounding bytes are not understood — byte 0..1 has been
    /// seen as both `00 03` and `80 03` — so only those two are read.
    static func coverPictureID(in payload: Payload) -> UInt16? {
        guard let raw = payload.typed(coverStateField)?.payload, raw.count >= 4 else { return nil }
        return UInt16(raw[2]) | UInt16(raw[3]) << 8
    }

    /// Not in `A2687.Field`: this id was found by diffing live frames against a
    /// third party's capture, not in either pinned reference implementation.
    static let coverStateField: UInt8 = 0xE1
}

public extension ChargerSession {
    /// Pushes a cover image, holding the poll down for the duration.
    ///
    /// `acknowledgedIrreversible` is passed straight through to
    /// ``CoverTransferSession/push(jpeg:as:acknowledgedIrreversible:onProgress:)``
    /// and carries the same meaning: the caller is claiming the person driving
    /// this has been told the image cannot be deleted afterwards. There is no
    /// default, and there should never be one. It is also the *only* consent
    /// this write asks for. It used to additionally require
    /// `SessionConfiguration.writesEnabled`, which is the settings switch about
    /// turning ports on and off — so a user who wanted to change the charger's
    /// screen had to first permit something else entirely. See
    /// ``ChargerSession/requireWritable()``.
    ///
    /// Not `@discardableResult`, for the same reason `push` is not: a caller
    /// that only checks for a thrown error never learns whether the screen was
    /// witnessed changing, and `.finished` looks identical either way. Read
    /// ``CoverTransferOutcome/verification``.
    ///
    /// - Throws: ``SessionError/notReady`` before anything is sent when the
    ///   handshake has not finished,
    ///   ``CoverTransferError/irreversibilityNotAcknowledged`` when the caller
    ///   cannot claim the confirmation, and whatever the state machine raises
    ///   after that. ``CoverTransferError/pixelsMayHaveLanded`` tells the caller
    ///   whether a failure left bytes on the device.
    func pushCover(
        jpeg: [UInt8],
        as image: CoverImageReference,
        acknowledgedIrreversible: Bool,
        options: CoverTransferSession.Options = CoverTransferSession.Options(),
        onProgress: (@Sendable (CoverTransferProgress) -> Void)? = nil
    ) async throws -> CoverTransferOutcome {
        try requireSessionReady()
        let adapter = CoverTransferAdapter(
            session: self, acknowledgementTimeout: options.acknowledgementTimeout
        )
        let transfer = CoverTransferSession(link: adapter, options: options)
        // Held from before the first cover command to after the last one. Via
        // `withPollingHeld` rather than a hand-rolled suspend/defer pair: the
        // release is then a property of the scope instead of something a reader
        // has to check every exit path for. A push that throws or is cancelled
        // must not leave the poll suspended for the rest of the session — 0x0300
        // would keep arriving and the 0x0200 readAll would never come back.
        //
        // The ceiling is derived from `options`, not left to
        // `SessionConfiguration.pollHoldTimeout`: the backstop is a fixed number
        // that knows nothing about a caller-supplied budget, and the day someone
        // raises `totalBudget` a fixed watchdog starts taking the poll back
        // mid-transfer — the exact failure the hold exists to prevent, arriving
        // only for the people who tuned the options.
        //
        // And `totalBudget` alone is *not* the worst case. `stopIfAsked` is the
        // only thing that reads the deadline and it runs at slice boundaries
        // only, so the last checkpoint's round trip and the entire verify tail
        // run after the final deadline check. Everything below is what can still
        // happen past that check:
        let attempts = max(1, options.verifyAttempts)
        let worstCase = options.totalBudget
            + options.acknowledgementTimeout                  // last checkpoint
            + options.settleBeforeVerify
            + ChargerSession.defaultReplyTimeout * attempts   // readCoverPictureID ×N
            + options.verifyRetryDelay * (attempts - 1)
        return try await withPollingHeld(
            reason: L10n.text("正在推送封面", table: "Core"),
            // Margin for BLE being slow, not for arithmetic — the sum above is
            // meant to be exact. At default options it is 265.4s, which the old
            // 300s backstop was clearing by under five seconds.
            timeout: worstCase + .seconds(30)
        ) {
            try await transfer.push(
                jpeg: jpeg, as: image,
                acknowledgedIrreversible: acknowledgedIrreversible,
                onProgress: onProgress
            )
        }
    }

    /// Switches to a cover whose pixels are already on the charger.
    ///
    /// Cheap and, unlike a push, reversible: no pixels move, no slot is spent,
    /// and selecting a different cover undoes it. So readiness is the only gate.
    /// There is nothing here to warn anyone about beforehand, and its one caller
    /// is a button the user presses on purpose — the retry offered when a push
    /// landed its pixels but the screen did not change. No poll hold either:
    /// this is one frame, not a stream.
    @discardableResult
    func selectCover(_ image: CoverImageReference) async throws -> UInt16? {
        try requireSessionReady()
        let transfer = CoverTransferSession(link: CoverTransferAdapter(session: self))
        return try await transfer.select(image)
    }
}
