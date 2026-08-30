import A2687Protocol
import Foundation

/// Bounded, redacted event trace used for the diagnostics export.
///
/// Raw payload bytes are only recorded when the user explicitly turns on developer
/// capture; key material, nonces and shared secrets are never routed here at all.
public final class DiagnosticsLog: @unchecked Sendable {
    public struct Entry: Sendable {
        public var at: Date
        public var direction: String
        public var text: String
    }

    /// One run of consecutive byte-identical frames, per direction and opcode.
    private struct FrameKey: Hashable {
        let direction: String
        let opcode: UInt16
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let baseCapacity: Int
    /// Optional mirror so a session can be inspected after the app has quit.
    private let mirror: FileLog?
    /// Last plaintext seen for each direction+opcode, and how many identical
    /// frames have been swallowed since. Both only touched under `lock`.
    private var lastFrame: [FrameKey: [UInt8]] = [:]
    private var suppressed: [FrameKey: Int] = [:]
    private var rawCapture = false

    /// Raw capture is a stopwatch-length experiment, not the steady state.
    ///
    /// The decisive measurement is "baseline frame → let go of the link → change
    /// a setting on the phone → come back → second frame", and that round trip
    /// takes minutes. At 1 Hz the 400-entry ring holds under seven of them, so
    /// the baseline was routinely evicted before the user got back to the Mac.
    /// Five times the ring buys half an hour, at the cost of a few MB of
    /// resident strings — only while the user has explicitly asked for raw
    /// bytes, and gone again the moment the switch goes off.
    private static let rawCaptureMultiplier = 5

    /// Read and written under `lock`; the mirror's size cap follows it.
    public var captureRawPayloads: Bool {
        get { lock.withLock { rawCapture } }
        set {
            let changed: Bool = lock.withLock {
                guard rawCapture != newValue else { return false }
                rawCapture = newValue
                // Shrinking back drops the oldest entries immediately rather
                // than holding the enlarged buffer until it happens to churn.
                if entries.count > capacityLocked {
                    entries.removeFirst(entries.count - capacityLocked)
                }
                return true
            }
            guard changed else { return }
            // Otherwise a charger sitting idle repeats one frame forever and the
            // switch looks broken: nothing new would be written, at any detail
            // level, until some byte finally moved.
            resetFrameSuppression()
            mirror?.setExpandedForRawCapture(newValue)
        }
    }

    private var capacityLocked: Int {
        rawCapture ? baseCapacity * Self.rawCaptureMultiplier : baseCapacity
    }

    public init(capacity: Int = 400, mirror: FileLog? = nil) {
        self.baseCapacity = capacity
        self.mirror = mirror
    }

    public func record(_ direction: String, _ text: String) {
        lock.lock()
        entries.append(Entry(at: Date(), direction: direction, text: text))
        if entries.count > capacityLocked {
            entries.removeFirst(entries.count - capacityLocked)
        }
        lock.unlock()
        mirror?.write("\(direction)  \(text)")
    }

    /// Logs one frame, collapsing runs of byte-identical ones.
    ///
    /// A charger with nothing plugged in repeats the same `0x0300` every second,
    /// and the poll repeats the same two `TX` frames forever; left alone they
    /// evict the handshake and the pre-experiment baseline for no information at
    /// all. The comparison is over the *whole* plaintext, before any parsing, so
    /// a single byte moving anywhere — in a port struct or in the settings TLVs
    /// this tool exists to find — ends the run and gets written out.
    ///
    /// The count of what was skipped is written into the log when the run ends,
    /// and ``snapshot()`` reports every run that is *still* open on top of that,
    /// so neither a finished log nor an export taken mid-run implies the device
    /// went quiet. ``clear()`` is the one place a count is dropped instead of
    /// reported — see the note there.
    public func frame(_ direction: String, opcode: UInt16, group: UInt8, payload: [UInt8]) {
        let key = FrameKey(direction: direction, opcode: opcode)
        // An identity frame appears once per handshake, so collapsing runs of it
        // saves nothing — and the price would be keeping the plaintext that holds
        // the serial number in memory for the rest of the session.
        let comparable = !Self.carriesIdentity(direction: direction, opcode: opcode)
        let outcome: (raw: Bool, skipped: Int)? = lock.withLock {
            guard comparable else { return (rawCapture, 0) }
            guard lastFrame[key] != payload else {
                suppressed[key, default: 0] += 1
                return nil
            }
            lastFrame[key] = payload
            let run = suppressed[key] ?? 0
            suppressed[key] = 0
            return (rawCapture, run)
        }
        guard let outcome else { return }
        note(suppressed: outcome.skipped, for: key)
        record(direction, Self.describe(
            direction: direction, opcode: opcode, group: group,
            payload: payload, rawAllowed: outcome.raw
        ))
    }

    /// Forgets what the last frame looked like, so the next one is always written.
    ///
    /// Called when the link restarts. The whole point of the experiment is the
    /// frame that arrives *after* a reconnect, and if the user changed nothing —
    /// or changed something the charger does not report — that frame is identical
    /// to the last one before the disconnect. Collapsing it would hide the one
    /// answer the run was asking for.
    public func resetFrameSuppression() {
        let pending: [(FrameKey, Int)] = lock.withLock {
            let runs = suppressed.filter { $0.value > 0 }.map { ($0.key, $0.value) }
            lastFrame.removeAll()
            suppressed.removeAll()
            return runs
        }
        for (key, count) in pending { note(suppressed: count, for: key) }
    }

    private func note(suppressed count: Int, for key: FrameKey) {
        guard count > 0 else { return }
        record(key.direction, Self.suppressionNote(key, count: count, ongoing: false))
    }

    /// One line of "this many frames were identical".
    ///
    /// `ongoing` marks a run that is still swallowing frames as the reader looks
    /// at it. The distinction is carried by a leading ellipsis rather than a
    /// second sentence so both localizations get it from the one string that
    /// already exists — the number in an ongoing line is a running total and
    /// will keep climbing, where a closed line is final.
    private static func suppressionNote(_ key: FrameKey, count: Int, ongoing: Bool) -> String {
        let text = L10n.format(
            "%@ 省略了 %d 帧完全相同的报文", Redact.opcode(key.opcode), count, table: "Core"
        )
        return ongoing ? "… " + text : text
    }

    /// Renders one frame as its TLV inventory, and — only with raw capture on —
    /// as one indented line per field.
    ///
    /// The whole point is that "change a setting in the official app, see which
    /// byte moved" should be readable straight out of the export. Before this,
    /// a `0x0300` report logged as `196 B` and the other ~120 bytes of every
    /// second were unrecoverable.
    ///
    /// Deliberately one ring-buffer *entry* per frame, not one per field: a
    /// report carries about two dozen TLVs, so per-field entries would evict the
    /// 400-entry history every sixteen seconds and the handshake that explains a
    /// failure would never survive to the export. The entry text is multi-line
    /// instead, which both the export and the file mirror already tolerate.
    ///
    /// Nothing here interprets a field. Deciding what `0xB1` *means* is the TLV
    /// bench's job; this layer only has to be able to prove what arrived.
    static func describe(
        direction: String, opcode: UInt16, group: UInt8, payload: [UInt8], rawAllowed: Bool
    ) -> String {
        let head = "\(Redact.opcode(opcode)) group=0x\(String(format: "%02X", group))"
        // Decided before the parse, not after it. A `0x0029` response that fails
        // to split into TLVs still holds the serial number and the MAC, and the
        // fallback below prints the packet whole — so an identity frame that
        // arrives malformed is exactly the one that used to leak.
        let expandable = rawAllowed && !carriesIdentity(direction: direction, opcode: opcode)
        guard let parsed = try? Payload.parse(payload), !parsed.fields.isEmpty else {
            // A payload that will not split into TLVs is exactly the one whose raw
            // bytes are worth seeing, so fall back to the whole-packet summary.
            return "\(head) \(Redact.payload(payload, rawAllowed: expandable))"
        }

        var text = "\(head) \(payload.count) B"
        // The result code is not user data and is often the only thing that
        // explains a refusal, so it is named on both paths.
        if let status = parsed.status { text += String(format: " status=0x%02X", status) }

        guard expandable else {
            // Redacted path: which fields were present and how long each was.
            // That is enough to spot a field appearing or changing length, it
            // leaks nothing, and it keeps the export at one line per frame.
            return text + " ids=" + parsed.fields
                .map { String(format: "%02x:%d", $0.id, $0.value.count) }
                .joined(separator: " ")
        }

        for field in parsed.fields {
            let length = "len=\(field.value.count)".padding(toLength: 7, withPad: " ", startingAt: 0)
            let hex = field.value.map { String(format: "%02x", $0) }.joined(separator: " ")
            let reading = numericReading(field.value).map { "  (\($0))" } ?? ""
            text += String(format: "\n  %02x ", field.id) + length + " " + hex + reading
        }
        return text
    }

    /// Payloads that carry an identity rather than a reading, kept at id-and-length
    /// even when the user has turned raw capture on.
    ///
    /// `0x0029`'s response holds the serial number and the MAC; the `0x0027` and
    /// `0x020A` *requests* carry the Anker account id. Byte-level expansion exists
    /// to diff `0x0300` reports, and it is not worth writing an account id into a
    /// file the user is expected to paste into a bug report. The `0x020A`
    /// *response* is deliberately not covered — it is one of the frames this
    /// expansion was built to look at.
    static func carriesIdentity(direction: String, opcode: UInt16) -> Bool {
        switch opcode {
        case A2687.Opcode.baseInfo: return direction.hasPrefix("RX")
        case A2687.Opcode.userAuth, A2687.Opcode.bindSuccess: return direction.hasPrefix("TX")
        default: return false
        }
    }

    /// Two faithful numeric readings and no more: the value read through its
    /// ``TypedValue`` prefix, and — when that yields no scalar — the whole value
    /// read as a bare little-endian integer.
    ///
    /// Both are aids for spotting which byte moved; neither claims the field is a
    /// number. Text is never rendered: `0x0029`'s ASCII fields carry no type
    /// prefix, so a `0x00` lead byte decoding as text would be a coincidence, and
    /// the hex is right there anyway.
    static func numericReading(_ value: [UInt8]) -> String? {
        switch TypedValue.decode(value) {
        case .u8(let v): return "u8 = \(v)"
        case .u16(let v): return "u16 = \(v)"
        case .u32(let v): return "u32 = \(v)"
        default: break
        }
        switch value.count {
        case 1:
            return "u8 = \(value[0])"
        case 2:
            return "u16 = \(UInt16(value[0]) | UInt16(value[1]) << 8)"
        case 4:
            let wide = UInt32(value[0]) | UInt32(value[1]) << 8
                | UInt32(value[2]) << 16 | UInt32(value[3]) << 24
            return "u32 = \(wide)"
        default:
            return nil
        }
    }

    /// The recorded entries, plus one line for every suppression run still open.
    ///
    /// An export is most likely to be taken in the *middle* of a run, not after
    /// one: an idle charger repeats a byte-identical `0x0300` for as long as
    /// nothing is plugged in, so the last real entry can be hours old while the
    /// link is perfectly healthy. Without the trailing lines the export ends at
    /// the last frame that changed and reads exactly like a device that died.
    ///
    /// Reported rather than flushed. This is a pure read — it takes no second
    /// pass over the lock, writes nothing to the file mirror and leaves the
    /// counters alone — so it stays safe to call at UI rates and the closing
    /// "省略了 N 帧" line still lands, with the full count, when the run ends.
    public func snapshot() -> [Entry] {
        let (rows, open): ([Entry], [FrameKey: Int]) = lock.withLock {
            (entries, suppressed.filter { $0.value > 0 })
        }
        guard !open.isEmpty else { return rows }
        // Sorted: two exports taken back to back must not differ by dictionary
        // order alone, or diffing them shows movement that never happened.
        let now = Date()
        return rows + open
            .sorted { ($0.key.direction, $0.key.opcode) < ($1.key.direction, $1.key.opcode) }
            .map { key, count in
                Entry(
                    at: now, direction: key.direction,
                    text: Self.suppressionNote(key, count: count, ongoing: true)
                )
            }
    }

    /// Drops the trace, including the pending suppression counts.
    ///
    /// Those counts go unreported, which is the one gap in the promise made on
    /// ``frame(_:opcode:group:payload:)``: everywhere else a swallowed run is
    /// either written out or shown by ``snapshot()``. It is deliberate here —
    /// the user asked for an empty log, and flushing "省略了 N 帧" lines into a
    /// log they just cleared would be a worse answer than losing the count.
    public func clear() {
        lock.withLock {
            entries.removeAll()
            lastFrame.removeAll()
            suppressed.removeAll()
        }
    }

    /// Plain-text export. Callers should still eyeball it before sharing.
    public func export(header: [String: String]) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["# \(L10n.text("Charker 诊断报告", table: "Core"))"]
        for key in header.keys.sorted() { lines.append("\(key): \(header[key] ?? "")") }
        lines.append("")
        for entry in snapshot() {
            lines.append("\(formatter.string(from: entry.at))  \(entry.direction)  \(entry.text)")
        }
        return lines.joined(separator: "\n")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
