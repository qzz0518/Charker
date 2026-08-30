import Foundation

// MARK: - What the firmware is told about the picture

/// The three things every cover command has to name: which picture, what its
/// bytes hash to, and the URL slot's contents.
///
/// This lives in the protocol layer, below the transfer state machine, for one
/// reason: `0x021F` and `0x0220` both carry the picture id, and if they can be
/// handed two *different* ids the failure is silent and permanent — the pixels
/// land under id A while the screen is told to display id B, every frame is
/// acknowledged, nothing is ever shown, and no BLE command erases either. The
/// builders below therefore take this whole value rather than loose `UInt32`s,
/// so the id in one command and the id in the other are the same stored
/// property and not two arguments a caller re-typed by hand.
///
/// `urlKey` is the open question of this feature. The official `0x021F` carries
/// a 16-character `0x00`-tagged ASCII field, and the only value ever seen in it
/// is the literal `SmallChargingUrl` — the 47-byte body's length arithmetic
/// closes on exactly that string, and the same literal is present in the
/// official app's string pool. Whether the firmware *validates* it or merely
/// carries it is unverified. If the placeholder is accepted, a cover push never
/// has to visit the cloud; if it is not, the caller has to register the picture
/// with Anker first and pass the real values. Evidence B — needs the hardware.
public struct CoverImageReference: Sendable, Equatable {
    /// Cloud picture id. Also what `0xE1` reports back once the pixels land.
    public var pictureID: UInt32

    /// IEEE CRC-32 of the JPEG bytes — see ``CoverTransfer/crc32(_:)``.
    ///
    /// This value goes out in `0x021F` while `0x0220` sends the hash the
    /// ``CoverTransfer/Plan`` computed from the bytes actually being pushed.
    /// They describe the same image and nothing in the protocol makes them
    /// agree, which is why the only way to reach ``startTransfer(_:at:)`` is
    /// through a ``CoverTransferTicket``, whose initialiser refuses to build one
    /// when they differ. Prefer ``init(pictureID:jpeg:urlKey:)``, which cannot
    /// get it wrong; the explicit initialiser exists for the cloud path, where
    /// `hash_code` comes back from Anker and *should* equal the local CRC-32 —
    /// if it does not, the bytes that were uploaded are not the bytes about to
    /// be pushed, which is worth stopping for.
    public var hash: UInt32

    /// Contents of the `FD` slot in `0x021F`. No default here on purpose — the
    /// initialisers below default it once, to the placeholder, and that is the
    /// only place the choice is made. See ``CoverCommands/urlPlaceholder``.
    public var urlKey: String

    /// Same literal the encoder emits; aliased rather than repeated so the two
    /// cannot drift if the real key turns out to be something else.
    public static let placeholderURLKey = CoverCommands.urlPlaceholder

    public init(
        pictureID: UInt32,
        hash: UInt32,
        urlKey: String = CoverImageReference.placeholderURLKey
    ) {
        self.pictureID = pictureID
        self.hash = hash
        self.urlKey = urlKey
    }

    /// Derives the hash from the very bytes that will be sent.
    ///
    /// The only way to build a reference that cannot disagree with its own
    /// transfer. Use it everywhere the JPEG is already in hand.
    public init(
        pictureID: UInt32,
        jpeg: [UInt8],
        urlKey: String = CoverImageReference.placeholderURLKey
    ) {
        self.init(pictureID: pictureID, hash: CoverTransfer.crc32(jpeg), urlKey: urlKey)
    }

    /// The id as `0xE1` reports it. The field is a `u16`, so an id above 65535
    /// would alias onto a different picture's low half; every id observed on a
    /// real account is five digits, and the read-back check upstream compares
    /// this value rather than the full id because that is all the charger says.
    public var reportedID: UInt16 { UInt16(truncatingIfNeeded: pictureID) }
}

/// A picture and the transfer that will carry it, proven to describe the same
/// image.
///
/// Existing is the whole contract. ``startTransfer(_:at:)`` takes one of these
/// instead of an id and a plan, so the `0x0220` that declares the upload and the
/// `0x021F` that points the screen at it read their id out of the same stored
/// ``CoverImageReference``, and their two hashes were compared before either
/// frame could be built. Both mistakes this closes are unrecoverable in the same
/// way: the charger acknowledges everything and then displays nothing, in a slot
/// with no erase command.
public struct CoverTransferTicket: Sendable, Equatable {
    public let image: CoverImageReference
    public let plan: CoverTransfer.Plan

    /// Fails when the reference's hash is not the hash of the bytes the plan was
    /// built from. Nil is the only failure, so the caller already knows why —
    /// it has both values and can report them.
    public init?(image: CoverImageReference, plan: CoverTransfer.Plan) {
        guard image.hash == plan.hash else { return nil }
        self.image = image
        self.plan = plan
    }
}

/// Builders for the three messages that put a custom image on the charger's own
/// display: `0x021F` names the picture, `0x0220` announces the upload, and
/// `0x0221` carries the JPEG 156 bytes at a time.
///
/// **These are writes to the charger's persistent storage, and there is no known
/// command to undo them.** The official app deletes covers through its cloud, not
/// over BLE, so a pushed image stays until a later push evicts it. Callers must
/// say so before sending anything.
///
/// That warning currently exists only here, in comments. Nothing in the app
/// instantiates `CoverTransferSession`, nothing implements `CoverTransferLink`,
/// and no screen mentions covers at all — so there is no user-facing sentence
/// anywhere saying the write cannot be undone. **Whoever lands the UI writes that
/// sentence first**, through `L10n`, shown before the first `0x021F` goes out and
/// not as a footnote under a progress bar. Until then the only thing standing
/// between a stray call and a permanently occupied slot is the
/// `acknowledgedIrreversible` argument on `CoverTransferSession.push`, which is a
/// lock on the door, not a sign on it.
///
/// Evidence grade is lower than the rest of this module — see the note on
/// ``A2687/Opcode/coverTransferChunk``. The layouts below are transcribed from a
/// third party's XOR recovery, checked here only by arithmetic: the three
/// plaintexts come to 47, 49 and 167 bytes, which is what the captures showed.
/// That is consistency, not proof.
public enum CoverCommands {
    /// The literal that goes in the `FD` slot of `0x021F`.
    ///
    /// This 16-character string is the most interesting unknown in the whole
    /// feature. It appears verbatim in the official app's 3.23.0 binary, and the
    /// TLV length closes exactly around it (`FD 11` = 17 = one type byte + 16
    /// characters), so it is unlikely to be a misread of something else.
    ///
    /// What we do not know is whether the firmware *checks* it. If a locally
    /// supplied placeholder is accepted, then pushing a cover needs no Anker
    /// account and no cloud round trip at all, and the whole upload half of this
    /// feature disappears. If instead the charger insists on an id the cloud
    /// minted, the placeholder path fails and we fall back to signing in. Only a
    /// first real write can tell the two apart, which is why this is a named
    /// constant rather than an inline string.
    public static let urlPlaceholder = "SmallChargingUrl"

    /// `screenSaverType` value that selects a user-supplied image.
    public static let customScreensaverType: UInt8 = 3

    /// Whether the firmware answers the slice at `index`, and therefore whether
    /// the sender has to stop and collect that answer before sending the next.
    ///
    /// Every tenth slice plus the final one. This lives next to the frame
    /// builder rather than in the transfer loop because the two must agree: the
    /// frame's claim that a reply is coming and the loop's decision to wait are
    /// the same fact, and when they drifted the result was the `12 A1 01 31`
    /// overrun wedged at index 10. ``transferChunk(sequence:of:payload:at:)``
    /// now calls this itself, so the frame half of that pair can no longer be
    /// stated independently — only the loop still has to ask.
    public static func isAcknowledged(chunkIndex index: Int, of chunkCount: Int) -> Bool {
        index == chunkCount - 1 || (index + 1) % CoverTransfer.acknowledgeEvery == 0
    }

    /// Little-endian bytes of a `UInt32`, for the fields that carry a raw four
    /// byte block rather than a typed integer.
    static func u32Bytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ]
    }

    /// Assembles a cover message.
    ///
    /// Deliberately not `CommandEncoder.session(_:_:at:)`, even though the two
    /// look interchangeable: that one appends the epoch as `FE 04` followed by
    /// four bare bytes, while every cover command carries it as `FE 05 03` — a
    /// *typed* u32. Reusing the session builder would produce a frame one byte
    /// short with a missing type tag, and the firmware's only reply to that is
    /// silence. The action marker is spelled out here for the same reason.
    static func message(_ opcode: UInt16, _ fields: [TLV], at date: Date) -> OutgoingMessage {
        let epoch = UInt32(truncatingIfNeeded: Int(date.timeIntervalSince1970))
        var all: [TLV] = [TLV(id: A2687.Field.a1, value: [A2687.sessionAction])]
        all += fields
        all.append(TLV(id: A2687.Field.timestamp, value: TypedValue.u32(epoch).encoded))
        return OutgoingMessage(
            group: Frame.sessionGroup, opcode: opcode,
            plaintext: TLVCodec.encode(all), encryption: .session, expectsResponse: true
        )
    }

    /// `0x021F` — show the picture this reference names. 47 byte plaintext.
    ///
    /// Sending this for an image whose pixels are not on the device is not an
    /// error: the firmware acknowledges it and simply leaves the display alone.
    /// That is why an ACK here proves nothing, and why the caller has to read
    /// `E1` back to know whether anything actually happened.
    ///
    /// The whole ``CoverImageReference`` goes in rather than its three fields
    /// separately, and there is no `url:` default to forget: the same value
    /// reaches ``startTransfer(_:at:)`` through the ticket, so the id these two
    /// frames carry is one stored property read twice, not two arguments.
    ///
    /// Note the asymmetry in how the two ids are wrapped — `pictureID` and `hash`
    /// go out as `04` byte blocks while `0x0220` sends the size as a `03` typed
    /// u32. That inconsistency is in the captures, not a mistake here.
    public static func selectCover(
        _ image: CoverImageReference, at date: Date = Date()
    ) -> OutgoingMessage {
        // TLV lengths are one byte and `TLVCodec.encode` truncates rather than
        // failing, so a long url would not produce a rejected frame — it would
        // produce a frame whose `FD` length byte is wrong, shifting every byte
        // after it, including the epoch, into garbage the firmware reads as
        // some other field. The placeholder is 16 bytes and can never trip
        // this, but the cloud fallback carries a real key or URL of unknown
        // length, and that is the path that ends in a write nothing can erase.
        // 254 = 255 minus the text type tag.
        precondition(
            image.urlKey.utf8.count <= 254,
            "cover url must fit a one byte TLV length: \(image.urlKey.utf8.count) + 1 type byte > 255"
        )
        return message(A2687.Opcode.setScreensaver, [
            TLV(id: A2687.Field.a3, value: TypedValue.u8(customScreensaverType).encoded),
            TLV(id: A2687.Field.a4, value: TypedValue.bytes(u32Bytes(image.pictureID)).encoded),
            TLV(id: A2687.Field.a5, value: TypedValue.bytes(u32Bytes(image.hash)).encoded),
            TLV(id: A2687.Field.fd, value: TypedValue.text(image.urlKey).encoded),
        ], at: date)
    }

    /// `0x0220` — announce the upload. 49 byte plaintext.
    ///
    /// Takes the ticket, not an id and a plan. The id here has to be the id
    /// `0x021F` named and the hash here has to be the hash of the bytes about to
    /// be sent; a ``CoverTransferTicket`` is the proof of both, obtained once
    /// before anything goes out.
    ///
    /// The chunk geometry is declared here and then has to be obeyed exactly by
    /// the chunk loop, so both come from the same ``CoverTransfer/Plan``.
    public static func startTransfer(
        _ ticket: CoverTransferTicket, at date: Date = Date()
    ) -> OutgoingMessage {
        let plan = ticket.plan
        return message(A2687.Opcode.coverTransferStart, [
            TLV(id: A2687.Field.a2, value: TypedValue.u8(1).encoded),
            TLV(
                id: A2687.Field.a3,
                value: TypedValue.bytes(u32Bytes(ticket.image.pictureID)).encoded
            ),
            TLV(id: A2687.Field.a4, value: TypedValue.bytes(u32Bytes(plan.hash)).encoded),
            TLV(id: A2687.Field.a5, value: TypedValue.u32(UInt32(plan.byteCount)).encoded),
            TLV(
                id: A2687.Field.a6,
                value: TypedValue.u8(UInt8(CoverTransfer.acknowledgeEvery)).encoded
            ),
            TLV(
                id: A2687.Field.a7,
                value: TypedValue.u16(UInt16(CoverTransfer.chunkPayloadSize)).encoded
            ),
            TLV(id: A2687.Field.a8, value: TypedValue.u16(UInt16(plan.chunkCount)).encoded),
        ], at: date)
    }

    /// `0x0221` — one slice. 167 byte plaintext, the same for every chunk
    /// including the last, which is zero-padded rather than sent short.
    ///
    /// `sequence` is zero-based. The firmware echoes the *next* index it expects
    /// in its periodic ACK, so a caller that tracks its own counter without
    /// comparing against that echo will not notice a dropped slice.
    ///
    /// The slice's position in the whole transfer is what decides whether the
    /// firmware answers it, so that is what this takes — `chunkCount`, not a
    /// `Bool` saying what the answer already is. The builder used to accept
    /// `expectsAcknowledgement:` directly, which made a legal 167-byte frame out
    /// of `(sequence: 9, expectsAcknowledgement: false)`: index 9 is the first
    /// slice the firmware answers, the transport would be told no reply is
    /// coming, the sender would run on past an unread acknowledgement, and the
    /// result is the observed `12 A1 01 31` wedge at index 10 with a hundred
    /// slices already in storage that has no erase command. Removing the
    /// argument removes the way to say it wrongly: `(index, chunkCount)` and
    /// ``isAcknowledged(chunkIndex:of:)`` derive it, and the loop asks the same
    /// function about the same pair.
    public static func transferChunk(
        sequence index: Int, of chunkCount: Int,
        payload: [UInt8], at date: Date = Date()
    ) -> OutgoingMessage {
        precondition(
            payload.count == CoverTransfer.chunkPayloadSize,
            "chunk payload must be padded to \(CoverTransfer.chunkPayloadSize) bytes"
        )
        // `A2` here and `A8` in the start frame are both u16, so a transfer that
        // does not fit is unrepresentable rather than wrapped. The upper bound
        // is checked on `chunkCount` and the index is checked against it, which
        // also rules out the off-by-one that would mark the wrong slice as the
        // last one.
        precondition(
            chunkCount >= 1 && chunkCount <= Int(UInt16.max),
            "chunk count out of range for a u16 sequence: \(chunkCount)"
        )
        precondition(
            index >= 0 && index < chunkCount,
            "chunk index \(index) is outside a transfer of \(chunkCount) slices"
        )
        // No trailing FE here: the chunk frames in the captures carry only the
        // action marker, the sequence and the slice.
        let fields: [TLV] = [
            TLV(id: A2687.Field.a1, value: [A2687.sessionAction]),
            TLV(id: A2687.Field.a2, value: TypedValue.u16(UInt16(index)).encoded),
            TLV(id: A2687.Field.a3, value: TypedValue.bytes(payload).encoded),
        ]
        return OutgoingMessage(
            group: Frame.sessionGroup, opcode: A2687.Opcode.coverTransferChunk,
            plaintext: TLVCodec.encode(fields), encryption: .session,
            // The transport is told the truth about this particular slice. It
            // used to be told `false` unconditionally, which meant the one layer
            // that had to wait was handed a frame that said "no reply coming".
            expectsResponse: isAcknowledged(chunkIndex: index, of: chunkCount)
        )
    }
}
