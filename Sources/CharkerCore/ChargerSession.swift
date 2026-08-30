import A2687Protocol
import Foundation

public struct SessionConfiguration: Sendable {
    /// Stable per-install identifier sent as the auth user id. Not an Anker account.
    public var clientID: String
    /// POSIX TZ rule handed to the charger so its own screen shows local time.
    public var timeZoneRule: String
    public var countryCode: String
    /// The Anker account id this charger is bound to. Optional, user supplied, and
    /// the only thing that gets past `0x0027` on hardened firmware.
    public var ownerUserID: String?
    /// Safety-net poll of `0x0200`. The device also pushes `0x0300` reports on its
    /// own schedule; this interval is deliberately conservative and configurable
    /// because the true minimum has not been measured on hardware.
    public var pollInterval: Duration = .seconds(6)
    public var staleAfter: TimeInterval = 20
    public var stageTimeout: Duration = .seconds(8)
    /// Gap between the messages of the session-opening burst. Firing read, bind and
    /// the realtime trigger back to back overruns the device.
    public var openingBurstSpacing: Duration = .milliseconds(400)
    public var maxBackoff: TimeInterval = 30
    /// How long a poll hold that declares no ceiling of its own may live before
    /// the session takes it back.
    ///
    /// A backstop, not a schedule: every holder is expected to release its own,
    /// and the scoped ``ChargerSession/withPollingHeld(reason:timeout:_:)`` makes
    /// that hard to get wrong. This only bounds the damage when it happens
    /// anyway, turning "the poll is dead for the rest of the session" into "the
    /// poll went quiet for a few minutes, and the log says whose fault it was".
    ///
    /// It is **not** a budget a long holder may lean on, and nothing in the type
    /// system ties it to one. A cover push's worst case is a function of
    /// `CoverTransferSession.Options`: `totalBudget` alone defaults to 240s and
    /// the verify tail runs *outside* that budget, so at the default options the
    /// two numbers sat about half a minute apart — one caller raising
    /// `totalBudget` or `verifyAttempts` would have had this watchdog void the
    /// hold mid-push and drop a `0x0200` read into the slice stream, which is the
    /// exact failure the hold exists to prevent. So a holder that can compute its
    /// own ceiling passes it to
    /// ``ChargerSession/withPollingHeld(reason:timeout:_:)`` and does not inherit
    /// this. If you shorten this number, check who is still inheriting it;
    /// raising it does nothing for the holders that pass their own.
    public var pollHoldTimeout: Duration = .seconds(300)
    /// The user's opt-in for cutting a port's output on or off. Off by default.
    ///
    /// Deliberately *not* a master gate for every write. It is surfaced to the
    /// user as one switch about ports, and the sentence next to it talks about
    /// ports; anything else hiding behind it is asking the user to agree to
    /// something they were not shown. Cover writes go through
    /// ``ChargerSession/requireSessionReady()`` and their own consent instead —
    /// see ``ChargerSession/requireWritable()``.
    public var writesEnabled = false

    public init(
        clientID: String,
        timeZoneRule: String = PosixTimeZone.current(),
        countryCode: String = Locale.current.region?.identifier ?? "US"
    ) {
        self.clientID = clientID
        self.timeZoneRule = timeZoneRule
        self.countryCode = countryCode
    }
}

public enum SessionError: Error, Equatable, Sendable {
    case notReady
    case writesDisabled
    case timedOut(UInt16)
    case deviceRejected(UInt16, status: UInt8)
}

/// The one thing ``ChargerSession/setPortTimer(_:seconds:)`` refuses to send.
///
/// A separate type rather than a fifth ``SessionError`` case on purpose: this is
/// a refusal by *this app*, not an answer from the charger, and every existing
/// `SessionError` case is the latter. Conforming to `LocalizedError` so that a
/// caller which falls back to `localizedDescription` still gets a sentence
/// rather than `CharkerCore.PortTimerError error 0`.
public enum PortTimerError: LocalizedError, Equatable, Sendable {
    /// `seconds == 0` — see ``ChargerSession/setPortTimer(_:seconds:)`` for why
    /// zero is not "cancel" until somebody has watched a real charger take it.
    case cancelUnverified

    public var errorDescription: String? {
        L10n.text("这一版只能给端口设定倒计时时长，还不能取消已经设定的倒计时。", table: "Core")
    }
}

/// A value refused locally before any display-setting frame is sent.
public enum ChargerSettingError: LocalizedError, Equatable, Sendable {
    /// The real charger clamps values below 25 %, so the product UI only exposes
    /// the range that can round-trip exactly.
    case brightnessOutOfRange(UInt8)

    public var errorDescription: String? {
        switch self {
        case .brightnessOutOfRange:
            return L10n.text("屏幕亮度只能设为 25% 到 100%。", table: "Core")
        }
    }
}

/// Owns the link, the handshake ladder and the telemetry state for one charger.
///
/// Everything mutable lives inside the actor; the UI only ever sees immutable
/// ``SessionSnapshot`` values.
public actor ChargerSession {
    private let transport: ChargerTransport
    private let diagnostics: DiagnosticsLog
    private var config: SessionConfiguration

    private var engine: HandshakeEngine?
    private var reassembler = FrameReassembler()
    private var snapshot = SessionSnapshot()
    private var subscribers: [UUID: AsyncStream<SessionSnapshot>.Continuation] = [:]

    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var housekeepingTask: Task<Void, Never>?
    private var stageTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var backoffAttempt = 0
    private var stopped = true
    private var authFailures = 0
    private var pollTick = 0
    private var sessionReadyAt: Date?
    private var scanStartedAt: Date?
    /// Field ids last seen on an opcode that carried no port data, so the polled
    /// replies are reported once each instead of once every few seconds.
    private var fieldOnlyShapes: [UInt16: String] = [:]
    /// The newest ``DeviceSettings`` this link has produced, carried forward onto
    /// the frames that omit it.
    ///
    /// `A9`/`AA`/`B2` ride the full `0x0200` read-all; the 1 Hz `0x0300` realtime
    /// report need not mention them at all. Every frame with port data replaces
    /// `snapshot.telemetry` whole, so a view bound to `telemetry.settings` saw the
    /// settings card blink out at 1 Hz and reappear on every second poll tick.
    /// These values are a handshake-time snapshot by definition (see
    /// `DeviceSettings`), so a frame that says nothing about them is saying
    /// nothing — not "they went away".
    ///
    /// nil means "never read on this link", which is a different fact from a
    /// snapshot that came back empty; an empty-but-present snapshot still wins
    /// here, because the frame did name the ids and an unreadable byte belongs on
    /// screen as a dash rather than as last minute's value.
    ///
    /// Cleared in ``beginHandshake()``: settings are facts about one authenticated
    /// link and must not survive a fresh handshake.
    private var lastSettings: DeviceSettings?

    public init(
        transport: ChargerTransport,
        configuration: SessionConfiguration,
        diagnostics: DiagnosticsLog = DiagnosticsLog()
    ) {
        self.transport = transport
        self.config = configuration
        self.diagnostics = diagnostics
        self.snapshot.writesEnabled = configuration.writesEnabled
        self.snapshot.isDemo = transport is MockChargerTransport
    }

    public var current: SessionSnapshot { snapshot }
    public nonisolated var log: DiagnosticsLog { diagnostics }

    public func updates() -> AsyncStream<SessionSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    public func setWritesEnabled(_ enabled: Bool) {
        config.writesEnabled = enabled
        snapshot.writesEnabled = enabled
        publish()
    }

    public func setPollInterval(_ interval: Duration) {
        config.pollInterval = interval
    }

    /// Starts either the normal reconnect path or a browse-only first-connection
    /// path. Browse-only mode configures the transport before CoreBluetooth
    /// reports its powered-on state, so an already system-connected peripheral
    /// is announced to the picker without being silently attached.
    public func start(preferred: UUID? = nil, autoConnect: Bool = true) {
        guard stopped else { return }
        stopped = false
        // A hold from the previous run must not outlive it: its holder is gone
        // and would never release it, which would leave the poll dead forever.
        clearPollHolds()
        snapshot.peripheralID = preferred ?? snapshot.peripheralID
        set(phase: .scanning)
        eventTask = Task { [weak self] in
            guard let self else { return }
            // No `await` on `transport.events`: the protocol requirement is a
            // plain non-isolated property, and the compiler warns on the
            // redundant one. The `for await` is the real suspension.
            for await event in self.transport.events {
                await self.handle(event)
            }
        }
        transport.start()
        if autoConnect {
            transport.connect(preferred: snapshot.peripheralID)
        } else {
            transport.startScanning()
        }
        startHousekeeping()
    }

    public func stop() {
        stopped = true
        cancelTimers()
        eventTask?.cancel()
        eventTask = nil
        transport.disconnect()
        failPending(SessionError.notReady)
        engine = nil
        set(phase: .idle)
    }

    /// Explicit user-driven retry: drops the link and restarts the ladder now.
    public func reconnectNow() {
        guard !stopped else { return }
        reconnectTask?.cancel()
        backoffAttempt = 0
        transport.disconnect()
        set(phase: .connecting)
        transport.connect(preferred: snapshot.peripheralID)
    }

    // MARK: - Writes

    /// The half of the gate every write shares: the handshake ladder has
    /// finished, so the charger will accept a command at all.
    ///
    /// Call it once at the top of a write *sequence*, not per frame. A cover
    /// push must not discover partway through 163 slices that it was never
    /// allowed to start — the slices already written cannot be taken back, and
    /// there is no BLE command that erases them. `send(_:)` and
    /// `send(_:awaitOpcode:timeout:)` deliberately do not call this, because
    /// both also carry reads.
    ///
    /// Internal, like the two `send` overloads it guards: it is the *inside* of
    /// the gate, and every public write on this actor calls it for its caller.
    /// Handing it out would let a caller ask "may I write?" and then write
    /// through a door this actor never opened.
    func requireSessionReady() throws {
        guard engine?.stage == .sessionReady else { throw SessionError.notReady }
    }

    /// Readiness *plus* the user's port opt-in. What it guards is exactly what
    /// the switch in settings says it guards: turning a port's output on or off.
    ///
    /// **It does not guard cover writes, on purpose.** It used to, and the cost
    /// was that sending a picture to the charger's screen required first turning
    /// on a switch labelled "allow port switching" — two unrelated capabilities
    /// behind one boolean, so the only way to get the one you wanted was to
    /// consent to the other. The screen push is not left ungated by dropping it
    /// from here; it is gated by something stricter and closer to the act:
    /// ``CoverTransferSession/push(jpeg:as:acknowledgedIrreversible:onProgress:)``
    /// refuses outright unless the caller passes `acknowledgedIrreversible`, and
    /// the only honest source of a `true` is the confirmation panel the user
    /// ticks for that one image, having just read that it can never be deleted.
    /// A per-image confirmation shown at the moment of the write is a better
    /// gate for an irreversible write than a global flag set weeks earlier for
    /// another reason entirely.
    ///
    /// So: a new *port-like* write belongs here. A new write with its own
    /// informed confirmation at the point of use belongs on
    /// ``requireSessionReady()``.
    func requireWritable() throws {
        guard config.writesEnabled else { throw SessionError.writesDisabled }
        try requireSessionReady()
    }

    /// Turns one port on or off, then confirms with a read-back rather than
    /// trusting an optimistic UI update.
    @discardableResult
    public func setPortOutput(_ port: A2687.Port, on: Bool) async throws -> Bool {
        try requireWritable()

        let response = try await send(CommandEncoder.setPortOutput(port, on: on), awaitOpcode: A2687.Opcode.portOutput)
        if let status = response.typed(A2687.Field.a1)?.scalar, status != 0 {
            throw SessionError.deviceRejected(A2687.Opcode.portOutput, status: UInt8(truncatingIfNeeded: status))
        }
        _ = try? await send(CommandEncoder.readAll(), awaitOpcode: A2687.Opcode.realtimeReport)
        return snapshot.telemetry?.port(port)?.isOn == on
    }

    /// Switches the charger's power-allocation mode, then reads `AA` back.
    ///
    /// **Why this is on ``requireSessionReady()`` and not ``requireWritable()``.**
    /// The port switch is surfaced to the user as one switch about ports, and
    /// the sentence beside it talks about ports; hiding a second, unrelated
    /// capability behind it would be asking for consent to something that was
    /// never shown — the rule ``requireWritable()`` states for itself. Charging
    /// mode is not a port-like write: it cuts nothing off, and it is reversible
    /// by sending the previous mode back, so it also does not need the
    /// irreversibility acknowledgement a cover push carries. It is not free
    /// either — the charger re-negotiates its allocation, and a device already
    /// drawing power may drop for an instant while it does — but that is a
    /// consequence to state at the moment of the tap, in the UI that offers the
    /// modes, not a global flag ticked weeks earlier for another reason.
    ///
    /// **What the return value means, and what it does not.** `true` is a real
    /// confirmation: `AA` came back holding the code we sent. `false` is *not*
    /// the opposite. Settings fields on this firmware are handshake-time
    /// snapshots, and whether the firmware refreshes `AA` after an in-session
    /// write has never been tested. So an unchanged read-back means "not confirmed", which
    /// covers both "the write did nothing" and "the write worked and the
    /// snapshot simply does not move until the next link". A caller must not
    /// report `false` to the user as a failed write.
    ///
    /// The read-back is here anyway, and is the reason this is the first write
    /// worth having: `AA` is the one settings byte judged on the owner's own
    /// hardware, so a `true` from here is the only self-proving result any write
    /// in this protocol can produce.
    @discardableResult
    public func setChargingMode(_ mode: ChargingMode) async throws -> Bool {
        try requireSessionReady()

        let response = try await send(
            CommandEncoder.setChargingMode(mode), awaitOpcode: A2687.Opcode.chargingMode
        )
        // The result code is the frame's own leading status byte, not anything
        // inside `A1`. Reading it from `A1` looked plausible and was silently
        // dead: on this hardware `A1` is a constant `0x31` carried as a bare
        // value, so `TypedValue.decode([0x31])` yields `.unknown` whose `scalar`
        // is nil — the `if let` never fired and every rejection sailed through as
        // success. The real refusal observed on this firmware is `11 A1 01 31`,
        // where `0x11` is the payload's first byte. Handshake and the cover
        // transfer both read `Payload.status`; this now matches them.
        guard response.isOK else {
            throw SessionError.deviceRejected(
                A2687.Opcode.chargingMode, status: response.status ?? 0xFF
            )
        }
        // A fresh `0x0200` is required, not just the next report: `AA` rides the
        // full read-all and the 1 Hz `0x0300` stream never mentions it, so
        // waiting alone would only ever re-read `lastSettings` — the value from
        // before the write.
        //
        // The wait is on the *report* opcode all the same, exactly as
        // `setPortOutput` does. The read-all answer comes back as `0x0300` from
        // the simulator and as a `0x0200` response on hardware, and either way it
        // is decoded — and `lastSettings` refreshed — before this returns; a wait
        // pinned to `0x0200` would instead sit out the full timeout against the
        // simulator and demo mode.
        _ = try? await send(CommandEncoder.readAll(), awaitOpcode: A2687.Opcode.realtimeReport)
        return snapshot.telemetry?.settings?.chargingMode == mode.code
    }

    /// Sends one of the reversible display settings confirmed on the owner's
    /// A2687, and requires the charger's explicit success acknowledgement.
    ///
    /// These are intentionally independent of the port-write opt-in: none cuts
    /// power, all can be undone by sending another value, and their exact frame
    /// shapes have been exercised on firmware v0.0.5.2. Read-back happens after
    /// a reconnect in `AppModel`, because this firmware freezes settings TLVs at
    /// handshake time. Language has no discovered read-back TLV and therefore
    /// stops at a verified ACK.
    public func setChargerSetting(_ setting: ChargerSetting) async throws {
        try requireSessionReady()
        if case .brightness(let value) = setting, !(25...100).contains(value) {
            throw ChargerSettingError.brightnessOutOfRange(value)
        }

        let response = try await send(
            CommandEncoder.setChargerSetting(setting), awaitOpcode: setting.opcode
        )
        guard response.isOK else {
            throw SessionError.deviceRejected(
                setting.opcode, status: response.status ?? 0xFF
            )
        }
        diagnostics.record(
            "WRITE",
            String(format: "display setting 0x%04X accepted value 0x%02X",
                   Int(setting.opcode), Int(setting.value))
        )
    }

    /// Arms the charger's own auto-off countdown for one port.
    ///
    /// The charger runs the clock, so the consequence outlives this app: the
    /// port cuts power at the appointed time whether the Mac is asleep, shut
    /// down or out of Bluetooth range. Callers must say that where the user can
    /// read it before the write, because nothing afterwards will remind them —
    /// see the note on reading the countdown back, below.
    ///
    /// **Why the gate is ``requireWritable()``.** This is a port-like write in
    /// every way that matters to the person consenting: it cuts a port's output,
    /// the byte layout has never been confirmed against this firmware, and there
    /// is no natural moment to check the result in place. The switch in settings
    /// talks about ports, and so does this.
    ///
    /// **Why the result is read from ``Payload/status`` and not from `A1`.** On
    /// this firmware `A1` is a constant `0x31` carried as a bare value, so
    /// `TypedValue.decode` yields `.unknown`, whose `scalar` is nil, so an
    /// `if let` on it never fires and every rejection sails through as success.
    /// `setChargingMode` shipped with exactly that bug.
    ///
    /// **Why there is no read-back, and no remaining-time getter.** The bytes
    /// that would carry a countdown ride `AC`/`AD`/`AE` — the same twelve-byte
    /// structs the cable capability comes from — at offsets 1 through 9:
    /// `countdownTaskStatus`, then `countdownTotal` and `countdownRemaining` as
    /// two little-endian `UInt32`s. In every fixture captured so far those nine
    /// bytes are identical, an idle placeholder decoding to 300 seconds, and
    /// none of them has ever been observed moving. The split into those three
    /// fields is therefore inference, not measurement, so a "42 minutes left"
    /// printed from it would be a number we made up. Nothing calls this a
    /// confirmed write and nothing shows a remaining time until one hardware
    /// run says otherwise.
    ///
    /// **Why there is no way to cancel.** The official app's countdown sheet
    /// opens with a 「关闭」 item, which is presumably `seconds == 0`. The
    /// firmware's own `CPowerControl` keeps `countdownTaskStatus` and
    /// `countdownTime` in two separate fields, and an idle port on this charger
    /// reports `taskStatus = 0` alongside `time = 300` — that is, "no countdown"
    /// is expressed by the status field, not by a zero time. So writing 0 might
    /// clear the task, or it might arm a countdown that has already expired and
    /// cut the port's power on the spot. Those two outcomes are not close
    /// enough to guess between with somebody's laptop on the other end, so zero
    /// is refused here rather than offered with a disclaimer.
    ///
    /// To settle it on hardware: pick a port with nothing plugged in, write
    /// `120` seconds, and dump that port's twelve-byte `AC`/`AD`/`AE` struct
    /// before and after — whichever bytes move are the countdown's real layout,
    /// and if none move the field is not reported here at all. Then write `0` to
    /// the same idle port and dump it a third time: if the moved bytes go back
    /// to the idle placeholder it was a cancel, and if the port's `isOn` drops
    /// instead it was an immediate cut. Only the first result earns a
    /// 「关闭倒计时」 item.
    ///
    /// - Parameter seconds: How long from now the port should cut power. Must be
    ///   greater than zero; zero throws ``PortTimerError/cancelUnverified``
    ///   without sending anything.
    public func setPortTimer(_ port: A2687.Port, seconds: UInt32) async throws {
        try requireWritable()
        guard seconds > 0 else { throw PortTimerError.cancelUnverified }

        let response = try await send(
            CommandEncoder.setPortTimer(port, seconds: seconds),
            awaitOpcode: A2687.Opcode.portTimer
        )
        guard response.isOK else {
            throw SessionError.deviceRejected(
                A2687.Opcode.portTimer, status: response.status ?? 0xFF
            )
        }
        // The only trace this write leaves. There is nothing to read back and
        // nothing on screen afterwards, so a link that later cuts a port for no
        // visible reason is otherwise unexplainable after the fact.
        diagnostics.record(
            "BLE", "\(Redact.opcode(A2687.Opcode.portTimer)) \(port.label) countdown armed \(seconds)s"
        )
    }

    // MARK: - Discovery

    /// Scans without auto-connecting so the user can pick from everything nearby.
    /// Already-seen devices stay in the list — clearing it here made the picker
    /// flash to its empty state on every visit, and `merge` keeps entries fresh.
    public func browse() {
        guard !stopped else { return }
        guard snapshot.canBrowseNearbyDevices else {
            // Also repairs an older view-triggered scan that raced the link into
            // monitoring before this guard existed.
            transport.stopScanning()
            return
        }
        publish()
        transport.startScanning()
    }

    /// Ends a picker-initiated browse.
    public func stopBrowsing() {
        guard !stopped else { return }
        transport.stopScanning()
    }

    /// Connects to a peripheral the user picked out of the discovery list.
    public func connect(to identifier: UUID) {
        guard !stopped else { return }
        reconnectTask?.cancel()
        backoffAttempt = 0
        snapshot.warning = nil
        snapshot.lastError = nil
        snapshot.peripheralID = identifier
        set(phase: .connecting)
        transport.connect(to: identifier)
    }

    /// Drops the remembered peripheral so the next connect starts from a fresh scan.
    public func forgetDevice() {
        snapshot.peripheralID = nil
        snapshot.deviceInfo = DeviceInfo()
        snapshot.advertisedName = nil
        publish()
    }

    private func merge(_ charger: DiscoveredCharger) {
        guard let index = snapshot.nearbyDevices.firstIndex(where: { $0.id == charger.id }) else {
            snapshot.nearbyDevices.append(charger)
            let diagnosticName = charger.name.flatMap { $0.isEmpty ? nil : $0 }
                ?? "unnamed-\(charger.id.uuidString.prefix(4))"
            diagnostics.record(
                "BLE",
                "发现 \(diagnosticName) rssi=\(charger.rssi) "
                + "匹配=[\(charger.matchReasons.map(\.rawValue).joined(separator: ","))]"
            )
            publish()
            return
        }
        // RSSI ticks constantly; only republish when something the UI shows moved.
        let previous = snapshot.nearbyDevices[index]
        snapshot.nearbyDevices[index] = charger
        let meaningful = previous.name != charger.name
            || previous.matchReasons != charger.matchReasons
            || abs(previous.rssi - charger.rssi) > 6
        if meaningful { publish() }
    }

    private func recordHistory(_ telemetry: ChargerTelemetry) {
        let sample = PowerSample(
            at: telemetry.receivedAt,
            total: telemetry.totalPower,
            perPort: A2687.Port.allCases.map { telemetry.port($0).map { $0.isOn ? $0.power : 0 } ?? 0 }
        )
        snapshot.history.append(sample)
        if snapshot.history.count > Self.historyLimit {
            snapshot.history.removeFirst(snapshot.history.count - Self.historyLimit)
        }
    }

    /// Roughly 20 minutes at the default poll interval.
    private static let historyLimit = 600

    // MARK: - Event handling

    private func handle(_ event: TransportEvent) async {
        switch event {
        case .bluetoothState(let state):
            snapshot.bluetooth = state
            if state.isUsable {
                if case .bluetoothUnavailable = snapshot.phase {
                    set(phase: .scanning)
                }
            } else {
                cancelTimers()
                engine = nil
                snapshot.nearbyDevices.removeAll()
                set(phase: .bluetoothUnavailable(state))
            }

        case .scanning(let active):
            snapshot.isScanning = active
            scanStartedAt = active ? (scanStartedAt ?? Date()) : nil
            if !active { snapshot.scanHint = nil }
            publish()

        case .discovered(let charger):
            merge(charger)

        case .connected(let charger):
            // `attach` normally stopped the transport scan already. Keep the
            // session invariant explicit as well, so a browse queued just before
            // the connection event cannot keep duplicate advertisements flowing.
            transport.stopScanning()
            snapshot.peripheralID = charger.id
            snapshot.advertisedName = charger.name ?? snapshot.advertisedName
            set(phase: .connecting)

        case .ready:
            transport.stopScanning()
            beginHandshake()

        case .notification(let bytes):
            let before = (reassembler.droppedBytes, reassembler.rejectedFrames)
            let frames = reassembler.append(bytes)
            let after = (reassembler.droppedBytes, reassembler.rejectedFrames)
            // Silent drops are how a framing bug hides. Say so when it happens.
            if after != before {
                let detail = reassembler.lastRejection.map { rejection in
                    "，原因 \(rejection.error)，头部 "
                        + rejection.head.map { String(format: "%02x", $0) }.joined()
                } ?? ""
                diagnostics.record(
                    "RX!",
                    "帧被丢弃：无法同步 \(after.0 - before.0) 字节，"
                    + "校验失败 \(after.1 - before.1) 帧\(detail)"
                )
            }
            for frame in frames {
                await process(frame)
            }

        case .disconnected(let reason):
            handleDisconnect(reason: reason)
        }
    }

    private func beginHandshake() {
        reassembler.reset()
        authFailures = 0
        // A new link may be a new firmware, or the same one after a settings
        // change; report each opcode's field shape again rather than assuming
        // the last connection's answer still holds.
        fieldOnlyShapes.removeAll()
        // The settings snapshot belonged to the link that just ended. A new
        // ladder re-reads it within a couple of poll ticks, and until it does,
        // "not read yet" is the honest answer — the alternative is presenting
        // the pre-release brightness as if it were the post-change one.
        lastSettings = nil
        // Same reasoning one layer down: the first frame of a new link is the
        // half of the diff the user went to the phone for, even when it is
        // byte-identical to the last frame of the old one.
        diagnostics.resetFrameSuppression()
        snapshot.authRejected = false
        snapshot.warning = nil
        sessionReadyAt = nil
        var engine = HandshakeEngine(
            clientID: config.clientID,
            timeZoneRule: config.timeZoneRule,
            countryCode: config.countryCode,
            ownerUserID: config.ownerUserID
        )
        let first = engine.start()
        self.engine = engine
        set(phase: .negotiating(engine.stage))
        Task { await self.dispatch([first]) }
        armStageTimeout()
    }

    private func process(_ frame: Frame) async {
        guard var engine else { return }
        let keys: A2687Crypto.Keys
        let fallback: A2687Crypto.Keys?
        if engine.stage > .publicKeyExchange, let session = engine.sessionKeys {
            keys = session
            fallback = .negotiation
        } else {
            keys = .negotiation
            fallback = engine.sessionKeys
        }

        var plaintext: [UInt8]?
        if frame.isEncrypted {
            plaintext = try? A2687Crypto.open(frame.payload, with: keys)
            if plaintext == nil, let fallback {
                plaintext = try? A2687Crypto.open(frame.payload, with: fallback)
            }
        } else {
            // Some firmware has been observed reporting in the clear.
            plaintext = frame.payload
        }
        guard let plaintext else {
            authFailures += 1
            diagnostics.record("RX!", "\(Redact.opcode(frame.opcode)) authentication failed")
            if authFailures >= 5 { reconnectNow() }
            return
        }
        authFailures = 0
        guard let payload = try? Payload.parse(plaintext) else {
            // The status byte is a result code, not user data, so it is always safe
            // to name — and it is the only thing that explains a refusal.
            diagnostics.record(
                "RX!",
                "\(Redact.opcode(frame.opcode)) TLV 解析失败 len=\(plaintext.count) "
                + "lead=0x\(String(format: "%02X", plaintext.first ?? 0))"
            )
            return
        }
        diagnostics.frame("RX", opcode: frame.opcode, group: frame.group, payload: plaintext)

        if engine.stage != .sessionReady, frame.isResponse {
            do {
                let previousStage = engine.stage
                let next = try engine.handle(opcode: frame.opcode, payload: payload)
                if engine.stage != previousStage {
                    diagnostics.record("STAGE", "\(previousStage) -> \(engine.stage)")
                }
                self.engine = engine
                set(phase: engine.stage == .sessionReady ? .monitoring : .negotiating(engine.stage))
                snapshot.deviceInfo = engine.deviceInfo
                publish()
                if !next.isEmpty {
                    // The opening burst has to be paced: firing read, bind and the
                    // realtime trigger back to back overruns the device.
                    await dispatch(next, spacing: engine.stage == .sessionReady ? config.openingBurstSpacing : nil)
                    armStageTimeout()
                }
                if engine.stage == .sessionReady { startPolling() }
            } catch {
                self.engine = engine
                await recover(from: error)
            }
            return
        }

        self.engine = engine
        // Decode every frame, then let `hasPortData` decide whether it may touch
        // the live readings. The old `decode` returned nil for a payload with no
        // A5/A6/A7 in it, so a `0x020A` bind reply or a `0x020B` trigger ack was
        // decoded, found empty and dropped whole — which is why "what does 0x020A
        // actually contain" could not be answered from a running build.
        var decoded = TelemetryDecoder.decodeFrame(payload, opcode: frame.opcode)
        // Settings are remembered from wherever they turn up — including a frame
        // with no port data, which never reaches `snapshot` — and filled back in
        // on the frames that carry none. See `lastSettings` for why this is a
        // property of the link rather than of the frame.
        if let settings = decoded.settings {
            lastSettings = settings
        } else {
            decoded.settings = lastSettings
        }
        if decoded.hasPortData {
            snapshot.telemetry = decoded
            snapshot.isStale = false
            snapshot.lastError = nil
            // The handshake-recovery note says "正在尝试继续以只读方式读取"; data
            // arriving IS that attempt succeeding. Leaving the warning up next to
            // live numbers made the app contradict itself. `authRejected` stays —
            // it is still a fact, and the Devices page words it by outcome.
            if snapshot.warning != nil { snapshot.warning = nil }
            recordHistory(decoded)
            if engine.stage == .sessionReady { set(phase: .monitoring) } else { publish() }
        } else {
            noteFieldsOnly(decoded)
        }
        resume(opcode: frame.opcode, with: payload)
    }

    /// Records the shape of a frame that carried no port struct.
    ///
    /// It deliberately does not touch `snapshot`: assigning an empty telemetry
    /// would blank the live numbers, and the staleness clock reads
    /// `telemetry.receivedAt`, so a `0x020B` ack arriving after the reports stop
    /// would keep claiming the data is fresh.
    ///
    /// Only the field ids, and only when they change for that opcode. The poll
    /// answers `0x020A` every few seconds; ten identical lines a minute would
    /// push the handshake that explains a failure out of the ring buffer. The
    /// bytes are already on the frame line above, behind the raw-capture gate.
    private func noteFieldsOnly(_ telemetry: ChargerTelemetry) {
        guard !telemetry.allFields.isEmpty else { return }
        // Wire order, not sorted, and repeats counted: `allFields` keeps both now,
        // and "does this id appear once or once per port" is one of the questions
        // this line is here to answer.
        let fields = telemetry.allFields
        let shape = fields.ids
            .map { id in
                let count = fields.occurrences(of: id)
                return count > 1
                    ? String(format: "%02x×%d", id, count)
                    : String(format: "%02x", id)
            }
            .joined(separator: " ")
        guard fieldOnlyShapes[telemetry.sourceOpcode] != shape else { return }
        fieldOnlyShapes[telemetry.sourceOpcode] = shape
        diagnostics.record(
            "RX",
            "\(Redact.opcode(telemetry.sourceOpcode)) 无端口数据，字段 \(shape)"
        )
    }

    private func handleDisconnect(reason: String?) {
        cancelTimers()
        engine = nil
        reassembler.reset()
        failPending(SessionError.notReady)
        guard !stopped else { return }

        backoffAttempt += 1
        let delay = min(pow(2.0, Double(min(backoffAttempt, 6))), config.maxBackoff)
        snapshot.lastError = reason
        set(phase: .reconnecting(attempt: backoffAttempt, retryIn: delay))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await self.retryConnect()
        }
    }

    private func retryConnect() {
        guard !stopped else { return }
        set(phase: .connecting)
        transport.connect(preferred: snapshot.peripheralID)
    }

    // MARK: - Sending

    /// Writes a run of messages and hands a failure back to the caller.
    ///
    /// The swallowing variant below is what the handshake ladder, the poll and
    /// the recovery paths use, and it stays that way: each of those has its own
    /// stall detector (the stage timeout, the staleness clock) and a throw from
    /// them would have nowhere to go.
    ///
    /// A cover push cannot use it. `CoverTransferError.chunkSendFailed` exists
    /// precisely because a slice that never left the Mac has to stop the
    /// transfer at that slice; swallowed, the loop keeps counting and the miss
    /// only surfaces up to nine chunks later as a `progressMismatch` — by then
    /// the firmware has been fed a hole in an image no command can erase.
    ///
    /// A message that cannot be encrypted throws rather than being skipped. That
    /// is the one behavioural difference from the old loop's `continue`, and it
    /// is invisible to the existing callers: every multi-message run they build
    /// is homogeneous in `encryption`, so if one member cannot be sealed neither
    /// can its siblings. For a write sequence the old silence was the dangerous
    /// shape — nothing on the wire, no error, caller reports success.
    private func dispatch(throwing messages: [OutgoingMessage], spacing: Duration? = nil) async throws {
        var first = true
        for message in messages {
            if !first, let spacing { try? await Task.sleep(for: spacing) }
            first = false
            guard let engine, let bytes = encode(message, engine: engine) else {
                diagnostics.record("TX!", "\(Redact.opcode(message.opcode)) 无会话密钥，未发送")
                throw SessionError.notReady
            }
            diagnostics.frame("TX", opcode: message.opcode, group: message.group, payload: message.plaintext)
            do {
                try await transport.write(bytes)
            } catch {
                diagnostics.record("TX!", "\(Redact.opcode(message.opcode)) \(error)")
                throw error
            }
        }
    }

    /// Fire-and-forget dispatch: a failed write is logged and the run stops.
    private func dispatch(_ messages: [OutgoingMessage], spacing: Duration? = nil) async {
        try? await dispatch(throwing: messages, spacing: spacing)
    }

    private func encode(_ message: OutgoingMessage, engine: HandshakeEngine) -> [UInt8]? {
        let keys: A2687Crypto.Keys?
        switch message.encryption {
        case .negotiation: keys = .negotiation
        case .session: keys = engine.sessionKeys
        }
        guard let keys, let sealed = try? A2687Crypto.seal(message.plaintext, with: keys) else { return nil }
        return PacketCodec.encode(Frame(
            group: message.group, opcode: message.opcode,
            encrypted: true, response: false, payload: sealed
        ))
    }

    /// Writes one message and waits for the charger's answer to `awaitOpcode`.
    ///
    /// Internal on purpose, and it must stay that way. This overload checks no
    /// gate at all (see ``requireSessionReady()``), so a `public` version would
    /// be a second door into the charger: any caller holding a session — the
    /// app, or anyone linking CharkerCore as a library — could hand it an
    /// arbitrary encrypted frame, port writes included, with `writesEnabled`
    /// off. The two in-module users (``CoverTransferAdapter`` and the cover
    /// extension on this actor) check their gate once at the top of their
    /// sequence, which is the only correct place for it.
    ///
    /// - Parameter timeout: How long to wait before throwing
    ///   ``SessionError/timedOut(_:)``. The default is the value this used to
    ///   hard-code, so every existing caller behaves exactly as before. A cover
    ///   push passes its own acknowledgement timeout instead, because a number
    ///   the state machine advertises and a different number the link actually
    ///   enforces is the same class of lie as an unreported failed write.
    func send(
        _ message: OutgoingMessage,
        awaitOpcode: UInt16,
        timeout: Duration = ChargerSession.defaultReplyTimeout
    ) async throws -> Payload {
        // The waiter is registered *before* the write, never after.
        // `transport.write` suspends, and a reply can be received, decrypted and
        // parsed inside that suspension: with the old order `resume(opcode:)`
        // found nobody home, dropped the payload, and the caller sat out the
        // full timeout waiting for an answer that had already arrived. A cover
        // push blocks at every tenth slice, so a 163-slice image handed that
        // window seventeen chances to hit.
        //
        // Nothing may suspend between the registration and the write, or the
        // actor can admit another message and reorder this opcode's queue —
        // which is why `registerWaiter` is synchronous and stays that way.
        let ticket = registerWaiter(for: awaitOpcode)
        do {
            try await dispatch(throwing: [message])
        } catch {
            discardWaiter(ticket)
            throw error
        }
        return try await awaitReply(ticket, opcode: awaitOpcode, timeout: timeout)
    }

    /// Writes one message and returns once the bytes are on the wire.
    ///
    /// For commands the firmware does not answer — a cover fill slice is the
    /// only one so far. It throws, and that is the whole difference from the
    /// internal fire-and-forget dispatch: a slice that never left has to stop
    /// the push at that slice rather than nine chunks later.
    ///
    /// Neither this nor ``send(_:awaitOpcode:timeout:)`` checks
    /// ``requireSessionReady()`` or ``requireWritable()``. Both carry reads as
    /// well, and a per-frame gate on a 163-frame sequence is the wrong place for
    /// it — see those methods. Which is exactly why both are internal: an
    /// ungated frame pump is fine as a module-private primitive and is a hole in
    /// the write gate as public API.
    func send(_ message: OutgoingMessage) async throws {
        try await dispatch(throwing: [message])
    }

    /// How long ``send(_:awaitOpcode:timeout:)`` waits when the caller does not
    /// say. Named rather than inlined because callers that size a poll hold or a
    /// budget around a sequence of reads have to add this up, and a `6` copied
    /// into another file goes stale silently the day this changes.
    static let defaultReplyTimeout: Duration = .seconds(6)

    // MARK: - Waiting for a reply

    /// One in-flight ``send(_:awaitOpcode:timeout:)``.
    ///
    /// It holds *either* side of the handoff, because either can arrive first:
    /// normally the sender parks a continuation and the reply resumes it, but a
    /// reply that beats the sender back parks its result here instead and the
    /// sender collects it without ever suspending.
    private struct ReplyWaiter {
        let opcode: UInt16
        var continuation: CheckedContinuation<Payload, Error>?
        var result: Result<Payload, Error>?
    }

    private var waiters: [UUID: ReplyWaiter] = [:]
    /// Arrival order per opcode. A reply carries nothing that says which request
    /// it answers, so the oldest unsettled waiter takes it — the same rule the
    /// previous array of continuations used.
    private var waitOrder: [UInt16: [UUID]] = [:]

    private func registerWaiter(for opcode: UInt16) -> UUID {
        let id = UUID()
        waiters[id] = ReplyWaiter(opcode: opcode)
        waitOrder[opcode, default: []].append(id)
        return id
    }

    /// Hands a result to a waiter whether or not its sender has parked yet.
    /// First result wins; later ones (a timeout racing a reply) are dropped.
    private func settle(_ id: UUID, with result: Result<Payload, Error>) {
        guard var waiter = waiters[id], waiter.result == nil else { return }
        dequeue(id, opcode: waiter.opcode)
        if let continuation = waiter.continuation {
            waiters[id] = nil
            continuation.resume(with: result)
        } else {
            waiter.result = result
            waiters[id] = waiter
        }
    }

    /// Drops a waiter nobody will ever collect: its write never went out.
    private func discardWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        dequeue(id, opcode: waiter.opcode)
    }

    private func dequeue(_ id: UUID, opcode: UInt16) {
        waitOrder[opcode]?.removeAll { $0 == id }
        if waitOrder[opcode]?.isEmpty == true { waitOrder[opcode] = nil }
    }

    private func awaitReply(_ id: UUID, opcode: UInt16, timeout: Duration) async throws -> Payload {
        // Answered already, inside the write's own suspension. No continuation
        // is created on this path at all — that is the race being closed.
        if let result = waiters[id]?.result {
            waiters[id] = nil
            return try result.get()
        }
        // Started before parking but it cannot fire before then: creating a Task
        // is not a suspension point, so the actor stays ours until the
        // continuation below is installed.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timeOut(id, opcode: opcode)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            guard var waiter = waiters[id] else {
                // Only reachable if the slot was discarded under us; report it
                // as the torn-down link every other path calls it.
                continuation.resume(throwing: SessionError.notReady)
                return
            }
            if let result = waiter.result {
                waiters[id] = nil
                continuation.resume(with: result)
                return
            }
            waiter.continuation = continuation
            waiters[id] = waiter
        }
    }

    private func timeOut(_ id: UUID, opcode: UInt16) {
        settle(id, with: .failure(SessionError.timedOut(opcode)))
    }

    private func resume(opcode: UInt16, with payload: Payload) {
        guard let id = waitOrder[opcode]?.first else { return }
        settle(id, with: .success(payload))
    }

    private func failPending(_ error: Error) {
        // A copy, because `settle` mutates `waitOrder` as it goes.
        for id in waitOrder.values.flatMap({ $0 }) {
            settle(id, with: .failure(error))
        }
    }

    // MARK: - Holding the poll

    /// A live claim on the poll timer, handed out by
    /// ``suspendPolling(reason:timeout:)``.
    public struct PollHold: Sendable, Hashable {
        fileprivate let id = UUID()
        fileprivate init() {}
    }

    /// What a live hold knows about itself. The reason is kept so the watchdog
    /// can name the culprit: a hold that had to be taken back is a bug in its
    /// holder, and "polling resumed by itself after five minutes" with no name
    /// attached is not something anyone can act on.
    private struct PollHoldRecord {
        let reason: String
        var watchdog: Task<Void, Never>?
    }

    private var pollHolds: [PollHold: PollHoldRecord] = [:]
    /// Whether the session wants to poll at all — kept apart from whether a hold
    /// is up, so releasing a hold after a disconnect does not resurrect a timer
    /// for a session that no longer has a handshake behind it.
    private var pollingWanted = false

    /// Stops the safety-net poll until the returned hold is released.
    ///
    /// A cover push streams `0x0221` for ten-plus seconds. The 6-second poll
    /// would otherwise drop a `0x0200`/`0x020A` read into the middle of that
    /// stream, and the firmware's tolerance for an interleaved frame during a
    /// transfer is unmeasured — the upstream client does nothing else at all
    /// while it uploads. Getting it wrong fails in the expensive direction:
    /// every pixel written, every checkpoint acknowledged, nothing displayed,
    /// and no command that takes the bytes back out.
    ///
    /// Tokens rather than a depth counter, deliberately. A counter that receives
    /// one resume too many either goes negative and wedges the poll for the rest
    /// of the session, or clamps at zero and lets a still-running transfer be
    /// polled through. Releasing an unknown or already-released hold here is a
    /// no-op, and two overlapping holders cannot get it wrong. Take one hold
    /// around the whole push, not one per slice.
    ///
    /// Prefer ``withPollingHeld(reason:timeout:_:)`` — this pair is the primitive
    /// under it, and the manual form is only correct for callers that already run
    /// inside this actor. See that method for why.
    ///
    /// It cannot recall a poll that is already mid-flight: the tick that started
    /// before the hold went up finishes its write. Take the hold before the
    /// first cover command, and the settle pauses cover the gap.
    ///
    /// - Parameter timeout: This holder's own worst case — every retry, every
    ///   settle pause and every reply timeout in the work it is about to do,
    ///   added up, plus margin. It *replaces*
    ///   ``SessionConfiguration/pollHoldTimeout`` rather than adding to it, and
    ///   the watchdog is the only thing that reads it, so the number a holder
    ///   passes is a promise about itself and nothing else. Pass nil only when
    ///   the work genuinely has no computable ceiling; a holder whose ceiling
    ///   lives in a config struct somewhere else must derive it from that struct,
    ///   because a constant here and a budget there drift apart silently and the
    ///   drift only shows up as a poll landing in the middle of a transfer.
    public func suspendPolling(reason: String, timeout: Duration? = nil) -> PollHold {
        let hold = PollHold()
        // A non-positive ceiling would fire the watchdog on the next tick and
        // poll straight through the transfer this hold exists to protect. That
        // is a caller bug either way, but inheriting the backstop is the
        // survivable reading of it, so a bad number is treated as no number.
        let holdTimeout = timeout.flatMap { $0 > .zero ? $0 : nil } ?? config.pollHoldTimeout
        pollHolds[hold] = PollHoldRecord(reason: reason)
        // Armed after the record exists, because the watchdog looks the hold up
        // by key. Creating a `Task` is not a suspension point, so nothing can
        // observe the half-built record in between.
        pollHolds[hold]?.watchdog = Task { [weak self] in
            try? await Task.sleep(for: holdTimeout)
            guard !Task.isCancelled else { return }
            await self?.expirePollHold(hold)
        }
        pollTask?.cancel()
        pollTask = nil
        diagnostics.record("BLE", L10n.format("轮询已暂停：%@", reason, table: "Core"))
        return hold
    }

    /// Releases a hold, restarting the poll once the last one is gone.
    ///
    /// Releasing an unknown hold — one already released, or one left over from a
    /// previous run and cleared by ``start(preferred:)`` — is a no-op. In
    /// particular it must not resume polling: by then a *different* holder may
    /// own the poll, and honouring a stale token would poll straight through a
    /// live transfer.
    public func resumePolling(_ hold: PollHold) {
        releasePollHold(hold, expired: false)
    }

    /// Runs `body` with the poll held and releases the hold on every exit path,
    /// including a throw and a cancellation.
    ///
    /// This is the form external callers should use.
    /// ``suspendPolling(reason:timeout:)``
    /// hands back a token whose release is `await`-only from outside the actor,
    /// and a `defer` block cannot `await`; the best an outside caller can write
    /// is `defer { Task { await session.resumePolling(hold) } }`, an
    /// unstructured task with no ordering guarantee that a cancelled parent can
    /// drop outright. A leaked hold is not a small bug: only
    /// ``start(preferred:)`` clears the set, and a reconnect runs through the
    /// backoff ladder rather than `start`, so the poll stays dead for the rest
    /// of the session while `0x0300` reports keep arriving. The symptom is
    /// "telemetry is still flowing, the full `0x0200` read just never comes back
    /// again", which is close to undiagnosable from the outside — hence the
    /// watchdog in `suspendPolling` as a second line of defence.
    ///
    /// `body` may call straight back into this session: the hold is a token, not
    /// a lock, and the actor is free again the moment `body` is entered. The one
    /// thing it must not do is take a second hold and hand *that* token out to
    /// something with a longer life than this scope, which puts the leak back.
    ///
    /// - Parameter timeout: How long the watchdog gives `body` before deciding
    ///   nobody is coming back and taking the poll away from it — the holder's
    ///   own worst case, not a guess. Leaving it nil inherits
    ///   ``SessionConfiguration/pollHoldTimeout``, which is a fixed backstop that
    ///   knows nothing about `body`; a `body` whose own budget is configurable
    ///   must compute this from that budget, or the day someone raises the budget
    ///   the watchdog starts firing in the middle of live work. See
    ///   ``suspendPolling(reason:timeout:)``.
    public func withPollingHeld<T>(
        reason: String,
        timeout: Duration? = nil,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let hold = suspendPolling(reason: reason, timeout: timeout)
        // Legal here and only here: this method is already actor-isolated, so
        // `resumePolling` is a plain synchronous call rather than an `await`.
        defer { resumePolling(hold) }
        return try await body()
    }

    /// Whether anything is currently holding the poll.
    public var isPollingHeld: Bool { !pollHolds.isEmpty }

    /// The hold outlived any plausible holder. Take it back and say so.
    private func expirePollHold(_ hold: PollHold) {
        releasePollHold(hold, expired: true)
    }

    private func releasePollHold(_ hold: PollHold, expired: Bool) {
        guard let record = pollHolds.removeValue(forKey: hold) else { return }
        // Harmless when the watchdog is the caller: it is already past its sleep.
        record.watchdog?.cancel()
        if expired {
            diagnostics.record("WARN", L10n.format(
                "轮询暂停超时未解除，已强制作废：%@", record.reason, table: "Core"
            ))
        }
        // Another holder still owns the poll — nothing to restart, and saying
        // "resumed" here would be a lie in the log.
        guard pollHolds.isEmpty else { return }
        restartPollLoop()
        // Releasing the last hold is not the same as polling resuming: a push
        // that ended because the link dropped releases into a session with no
        // handshake behind it. The log says which happened, because "the poll
        // went quiet for two minutes" is otherwise unreadable after the fact.
        diagnostics.record(
            "BLE",
            pollTask == nil
                ? L10n.text("轮询暂停已解除，但会话不在，未重启轮询", table: "Core")
                : L10n.text("轮询已恢复", table: "Core")
        )
    }

    /// Drops every hold and its watchdog. Only ``start(preferred:)`` may do this:
    /// a fresh run has no holders, so any surviving token belongs to a caller
    /// that is already gone.
    private func clearPollHolds() {
        for record in pollHolds.values { record.watchdog?.cancel() }
        pollHolds.removeAll()
    }

    // MARK: - Timers

    private func armStageTimeout() {
        stageTimeoutTask?.cancel()
        guard let engine, engine.stage != .sessionReady else { return }
        let timeout = config.stageTimeout
        stageTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.stageDidTimeOut()
        }
    }

    private func stageDidTimeOut() async {
        guard var engine, engine.stage != .sessionReady, !stopped else { return }
        // `0x0022` and `0x0027` are documented as not always ACKing. Those two
        // stages may be nudged forward once; every other stall is a real failure.
        guard engine.canSkipCurrentStage, let next = try? engine.skipCurrentStage() else {
            fail(
                L10n.format(
                    "充电器在「%@」这一步没有回应，连接没能建立。可以再试一次；靠近一点，并确认官方 Anker App 没有占用它。",
                    engine.stage.label, table: "Core"
                ),
                detail: "stage timeout at \(engine.stage) after \(config.stageTimeout)"
            )
            return
        }
        diagnostics.record("BLE", "no ACK during \(engine.stage), continuing")
        self.engine = engine
        set(phase: engine.stage == .sessionReady ? .monitoring : .negotiating(engine.stage))
        await dispatch(next)
        if engine.stage == .sessionReady { startPolling() } else { armStageTimeout() }
    }

    private func startPolling() {
        stageTimeoutTask?.cancel()
        backoffAttempt = 0
        sessionReadyAt = Date()
        pollingWanted = true
        restartPollLoop()
    }

    /// The single place the poll timer is created.
    ///
    /// Both halves of the decision — the session wanting to poll, and nothing
    /// holding it — funnel through here so they cannot disagree. A reconnect
    /// that lands mid-transfer therefore comes back with the hold still honoured
    /// instead of quietly resuming the poll under the transfer's feet.
    private func restartPollLoop() {
        pollTask?.cancel()
        pollTask = nil
        guard pollingWanted, pollHolds.isEmpty, !stopped else { return }
        let interval = config.pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.poll()
            }
        }
    }

    /// The official app polls `0x020A` for live port data and `0x0200` for the full
    /// settings snapshot at half that rate. The device also pushes `0x0300` reports
    /// on its own, so this is a floor, not the only source of data.
    ///
    /// The hold is re-checked here, not just when the timer is armed: cancelling
    /// `pollTask` does not unwind a tick already inside this function.
    private func poll() async {
        guard engine?.stage == .sessionReady, pollHolds.isEmpty else { return }
        pollTick += 1
        var messages = [
            CommandEncoder.realtimeProbe(
                countryCode: config.countryCode, ownerUserID: config.ownerUserID
            )
        ]
        if pollTick % 2 == 0 { messages.append(CommandEncoder.readAll()) }
        await dispatch(messages)
    }

    private func startHousekeeping() {
        housekeepingTask?.cancel()
        housekeepingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                await self.checkStaleness()
            }
        }
    }

    private func checkStaleness() {
        checkSilentSession()
        checkFruitlessScan()
        guard let received = snapshot.telemetry?.receivedAt else { return }
        let stale = Date().timeIntervalSince(received) > config.staleAfter
        guard stale != snapshot.isStale else { return }
        snapshot.isStale = stale
        publish()
    }

    /// The charger can accept the encrypted session and then answer nothing at all.
    /// Saying "已连接" in that state would be a lie, so name what actually happened.
    private func checkSilentSession() {
        guard let readyAt = sessionReadyAt,
              snapshot.telemetry == nil,
              engine?.stage == .sessionReady,
              Date().timeIntervalSince(readyAt) > Self.silentSessionTimeout else { return }
        sessionReadyAt = nil
        let reason = snapshot.authRejected
            ? L10n.text(
                "充电器拒绝了这个账号身份，之后不再返回数据。请在「设备与连接」里填入绑定这台充电器的 Anker 账号 ID。",
                table: "Core"
            )
            : L10n.text("会话已建立，但充电器对读取命令没有任何应答。", table: "Core")
        diagnostics.record("ERR", reason)
        snapshot.warning = nil
        set(phase: .failed(reason))
    }

    private static let silentSessionTimeout: TimeInterval = 20

    /// A scan that finds plenty of Bluetooth devices but no charger usually means
    /// the charger is connected to something else — it stops advertising entirely
    /// while held — not that it is out of range.
    private func checkFruitlessScan() {
        // A browse started from the picker keeps scanning while a session is
        // already live — and the connected charger never advertises, so this
        // "no charger found" hint would fire right next to flowing data.
        guard !snapshot.phase.isLive else {
            if snapshot.scanHint != nil {
                snapshot.scanHint = nil
                publish()
            }
            return
        }
        guard let startedAt = scanStartedAt, snapshot.isScanning else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > Self.fruitlessScanTimeout else { return }
        let hint = snapshot.chargerCandidates.isEmpty
            ? (snapshot.nearbyDevices.isEmpty
                ? L10n.format(
                    "已扫描 %d 秒，附近没有任何蓝牙设备。请确认蓝牙已开启。",
                    Int(elapsed), table: "Core"
                )
                : scanHint(elapsed: elapsed, deviceCount: snapshot.nearbyDevices.count))
            : nil
        guard hint != snapshot.scanHint else { return }
        snapshot.scanHint = hint
        publish()
    }

    private static let fruitlessScanTimeout: TimeInterval = 15

    private func scanHint(elapsed: TimeInterval, deviceCount: Int) -> String {
        if deviceCount == 1 {
            return L10n.format(
                "已扫描 %d 秒，看到 1 台蓝牙设备但没有充电器。充电器被连接时会完全停止广播——请确认它已通电，且官方 Anker App 或另一台设备没有占用它。",
                Int(elapsed), table: "Core"
            )
        }
        return L10n.format(
            "已扫描 %d 秒，看到 %d 台蓝牙设备但没有充电器。充电器被连接时会完全停止广播——请确认它已通电，且官方 Anker App 或另一台设备没有占用它。",
            Int(elapsed), deviceCount, table: "Core"
        )
    }

    private func cancelTimers() {
        // Not just the timer, the intent behind it: polling starts again when a
        // fresh ladder reaches `sessionReady`, never because a hold happened to
        // be released while the link was down.
        pollingWanted = false
        pollTask?.cancel(); pollTask = nil
        stageTimeoutTask?.cancel(); stageTimeoutTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
    }

    /// A refusal at `0x0022`/`0x0027` is survivable: the AES session is already
    /// established by then, and the official app itself never waits for those two
    /// acknowledgements. Any other refusal is fatal, and the user is told either way.
    private func recover(from error: Error) async {
        guard var engine,
              case HandshakeError.deviceRejected(let stage, let status) = error,
              engine.canSkipCurrentStage,
              let next = try? engine.skipCurrentStage()
        else {
            let stage = engine?.stage ?? .idle
            fail(Self.describe(error, stage: stage), detail: Self.detail(error, stage: stage))
            return
        }
        // Two sentences about the same event, aimed at two different readers.
        // The user gets the consequence — reads still work, a control might be
        // refused — and the status byte that explains *which* refusal this was
        // goes where a bug report can find it.
        let note = L10n.format(
            "充电器没有接受「%@」。数据照常能读，但控制类操作可能会被拒绝。",
            stage.label, table: "Core"
        )
        diagnostics.record("WARN", note)
        diagnostics.record(
            "WARN", String(format: "stage %@ rejected status=0x%02X, continuing read-only",
                           String(describing: stage), Int(status))
        )
        snapshot.warning = note
        if stage == .userAuth { snapshot.authRejected = true }
        self.engine = engine
        set(phase: engine.stage == .sessionReady ? .monitoring : .negotiating(engine.stage))
        await dispatch(next)
        if engine.stage == .sessionReady { startPolling() } else { armStageTimeout() }
    }

    /// Turns a handshake failure into a sentence about what happened and what to
    /// try next.
    ///
    /// This string lands on the dashboard and inside the menu bar bubble, so it
    /// carries no status byte, no field id, no opcode and no `String(describing:)`
    /// dump of an enum. Those are worth keeping and they are kept — ``detail(_:stage:)``
    /// produces them for `diagnostics` on the very same failure — but the reader
    /// of this sentence asked "is my charger connected", not "which byte came
    /// back".
    ///
    /// The step name is the one piece of the machinery that stays, because
    /// ``HandshakeStage/label`` is already plain language (「身份认证」,
    /// 「交换公钥」) and which step stopped is the difference between "press
    /// retry" and "go fill in the account id".
    ///
    /// Where the real cause is unknown it says so. A connection that drops
    /// mid-ladder usually drops for a reason nothing on this end can see, and
    /// inventing one — distance, interference, the official app — would be a
    /// guess wearing a diagnosis's clothes. Unknown plus a next step beats a
    /// confident wrong answer.
    ///
    /// `deviceRejected` never reaches here from the user-auth step: that one is
    /// survivable and is handled by ``recover(from:)``, which keeps the link and
    /// says so. So this branch must not offer account-id advice — by the time it
    /// runs, the account is not what the charger objected to.
    static func describe(_ error: Error, stage: HandshakeStage) -> String {
        guard let handshake = error as? HandshakeError else {
            return L10n.format(
                "连接在「%@」这一步断了，原因不明。可以再试一次；靠近一点，并确认官方 Anker App 没有占用它。",
                stage.label, table: "Core"
            )
        }
        switch handshake {
        case .deviceRejected(let failedStage, _):
            return L10n.format(
                "充电器在「%@」这一步拒绝了连接。可以再试一次；如果每次都停在这里，把充电器断电重新通电再连。",
                failedStage.label, table: "Core"
            )
        case .missingField(let failedStage, _):
            return L10n.format(
                "充电器在「%@」这一步的回复不完整，连接没能建立。请再试一次。",
                failedStage.label, table: "Core"
            )
        case .crypto:
            return L10n.text(
                "没能和充电器协商出加密通道，连接没能建立。请再试一次；如果一直失败，把蓝牙关掉再打开。",
                table: "Core"
            )
        case .notStarted, .unexpectedStage:
            return L10n.format(
                "连接在「%@」这一步乱了次序，没能建立。请重新连接。", stage.label, table: "Core"
            )
        }
    }

    /// The same failure spelled out for the diagnostics log and a bug report:
    /// the step, the status byte, the missing field id, the raw error for
    /// anything that is not a ``HandshakeError``.
    ///
    /// Deliberately not localized and deliberately never shown in the UI. It is
    /// the other half of ``describe(_:stage:)`` — the evidence stays, it just
    /// stops being the thing the user reads.
    static func detail(_ error: Error, stage: HandshakeStage) -> String {
        guard let handshake = error as? HandshakeError else {
            return "handshake failed at \(stage): \(String(describing: error))"
        }
        switch handshake {
        case .deviceRejected(let failedStage, let status):
            return String(
                format: "handshake rejected at %@ status=0x%02X",
                String(describing: failedStage), Int(status)
            )
        case .missingField(let failedStage, let id):
            return String(
                format: "handshake reply at %@ is missing field 0x%02X",
                String(describing: failedStage), Int(id)
            )
        case .crypto(let error):
            return "handshake key agreement failed at \(stage): \(String(describing: error))"
        case .notStarted:
            return "handshake driven before start() at \(stage)"
        case .unexpectedStage(let unexpected):
            return "handshake out of order: engine at \(stage), reply for \(unexpected)"
        }
    }

    // MARK: - Snapshot plumbing

    /// - Parameters:
    ///   - reason: What the user is told. A consequence and a next step, never
    ///     an opcode or a status byte.
    ///   - detail: The same failure in the terms a bug report needs. Logged
    ///     beside `reason` and shown nowhere.
    private func fail(_ reason: String, detail: String? = nil) {
        diagnostics.record("ERR", reason)
        if let detail { diagnostics.record("ERR", detail) }
        snapshot.lastError = reason
        cancelTimers()
        engine = nil
        set(phase: .failed(reason))
        transport.disconnect()
    }

    private func set(phase: SessionPhase) {
        snapshot.phase = phase
        publish()
    }

    private func publish() {
        let value = snapshot
        for continuation in subscribers.values { continuation.yield(value) }
    }
}

/// Best-effort POSIX TZ rule for the charger's own clock display.
public enum PosixTimeZone {
    public static func current(_ zone: TimeZone = .current) -> String {
        let offset = zone.secondsFromGMT()
        guard offset != 0 else { return "UTC0" }
        // POSIX signs are inverted relative to UTC offsets.
        let inverted = -offset
        let hours = inverted / 3600
        let minutes = abs(inverted % 3600) / 60
        let abbreviation = zone.abbreviation()?.prefix(while: { $0.isLetter }) ?? ""
        let name = abbreviation.count >= 3 ? String(abbreviation) : "UTC"
        return minutes == 0 ? "\(name)\(hours)" : String(format: "%@%d:%02d", name, hours, minutes)
    }
}
