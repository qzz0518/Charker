import A2687Protocol
import CoreBluetooth
import Foundation

/// CoreBluetooth link to one Anker Prime charger.
///
/// Discovery scans with `withServices: nil` and matches in code. A filtered scan
/// only matches the advertisement's *Service UUIDs* fields; a charger that
/// publishes `FF09` as service data — or that advertises nothing but a name —
/// is invisible to it. Scanning everything and deciding here costs a little more
/// radio work and finds devices the filter silently misses, which is also what
/// lets the UI offer a manual picker when auto-detection comes up empty.
///
/// All CoreBluetooth work happens on a private serial queue; events leave through
/// an `AsyncStream` so the session actor never touches a delegate callback thread.
public final class CoreBluetoothTransport: NSObject, ChargerTransport, @unchecked Sendable {
    public let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let queue = DispatchQueue(label: "dev.charker.bluetooth", qos: .utility)
    private let fileLog: FileLog?

    private var central: CBCentralManager?
    /// The one charger this transport is linked to, from `didConnect` until
    /// teardown. GATT discovery, notifications and writes only ever act on it.
    private var peripheral: CBPeripheral?
    /// `connect` requests still outstanding. Several at once when more than one
    /// saved charger can be retrieved: CoreBluetooth waits for each in the
    /// background, the first to connect becomes `peripheral` and the rest are
    /// cancelled. Retained here because CoreBluetooth does not retain them.
    private var pending: [UUID: CBPeripheral] = [:]
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    /// The chargers the caller asked for, most preferred first.
    private var targets: [UUID] = []
    /// `connect(to:)` wants its one target and nothing else, even from a scan.
    private var exclusive = false
    /// None of `targets` could be retrieved — the system forgot them, which
    /// also changes their identifiers. Only then may a scan attach any charger
    /// it recognises, as a single remembered charger always could.
    private var targetsForgotten = false
    /// Bumped whenever the set of outstanding requests is replaced or torn
    /// down. A delayed retry belongs to the wait it was scheduled in and is
    /// dropped once that wait is over.
    private var waitGeneration = 0
    private var pendingWrites: [CheckedContinuation<Void, Error>] = []
    private var isScanning = false
    /// No transport instance may attach before its caller explicitly chooses a
    /// connection path. `connect` turns this on; picker browsing keeps it off.
    /// Starting at `true` let the first CoreBluetooth state callback race ahead
    /// of the queued browse request and attach a system-connected charger.
    private var autoConnect = false
    /// Peripherals must be retained or CoreBluetooth drops them before we connect.
    private var seen: [UUID: CBPeripheral] = [:]
    private var announced: [UUID: (rssi: Int, at: Date)] = [:]
    private var notificationCount = 0

    private let serviceUUID = CBUUID(string: A2687.primaryService)
    private let advertisedUUID = CBUUID(string: A2687.advertisedService)
    private let writeUUID = CBUUID(string: A2687.writeCharacteristic)
    private let notifyUUID = CBUUID(string: A2687.notifyCharacteristic)

    /// Advertised-name fragments seen on Anker Prime hardware, lowercased.
    private let nameHints = ["ashdjw", "ashd", "anker", "prime", "a2687", "solix"]

    /// Product type `B405`, the official device-table entry for the A2687.
    private static let productTypeA2687: [UInt8] = [0xB4, 0x05]

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            Array(haystack[start..<(start + needle.count)]) == needle
        }
    }

    public init(fileLog: FileLog? = FileLog()) {
        self.fileLog = fileLog
        var sink: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { sink = $0 }
        continuation = sink
        super.init()
    }

    public func start() {
        queue.async {
            guard self.central == nil else { return }
            self.fileLog?.write("=== transport start === authorization=\(CBManager.authorization.rawValue)")
            // A central manager stays silent while the permission sheet is up, so
            // report the wait explicitly rather than looking hung.
            if CBManager.authorization == .notDetermined {
                self.continuation.yield(.bluetoothState(.notDetermined))
            }
            self.central = CBCentralManager(delegate: self, queue: self.queue, options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
            ])
        }
    }

    public func connect(preferred: [UUID]) {
        queue.async {
            self.retarget(preferred, exclusive: false)
            self.autoConnect = true
            self.beginConnect()
        }
    }

    public func connect(to identifier: UUID) {
        queue.async {
            self.retarget([identifier], exclusive: true)
            self.autoConnect = true
            if self.central?.state == .poweredOn, self.peripheral == nil, self.pending.isEmpty,
               let known = self.seen[identifier] {
                self.attach(known, reason: "user picked")
            } else {
                self.beginConnect()
            }
        }
    }

    public func startScanning() {
        queue.async {
            // CoreBluetooth permits scanning beside an existing connection, but
            // this picker uses an unfiltered duplicate scan. Running that firehose
            // while telemetry is live needlessly wakes the app and churns the UI.
            // Outstanding connects are no reason to refuse: nothing is linked,
            // and a saved charger that turns up still connects on its own.
            guard self.peripheral == nil else {
                self.stopScanLocked()
                return
            }
            self.autoConnect = false
            self.announced.removeAll()
            self.scan()
        }
    }

    public func stopScanning() {
        queue.async { self.stopScanLocked() }
    }

    public func disconnect() {
        queue.async {
            self.stopScanLocked()
            if let peripheral = self.peripheral {
                self.central?.cancelPeripheralConnection(peripheral)
            }
            // Also withdraws every outstanding connect.
            self.teardownLocked(reason: nil, notify: false)
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let peripheral = self.peripheral, let characteristic = self.writeCharacteristic else {
                    continuation.resume(throwing: TransportError.notConnected)
                    return
                }
                let withResponse = characteristic.properties.contains(.write)
                let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
                let limit = peripheral.maximumWriteValueLength(for: type)
                guard bytes.count <= limit else {
                    continuation.resume(throwing: TransportError.valueTooLong(bytes.count, max: limit))
                    return
                }
                if withResponse {
                    self.pendingWrites.append(continuation)
                    peripheral.writeValue(Data(bytes), for: characteristic, type: .withResponse)
                } else {
                    // Without-response writes have no ACK; respect the radio's backpressure.
                    guard peripheral.canSendWriteWithoutResponse else {
                        continuation.resume(throwing: TransportError.writeFailed("radio busy"))
                        return
                    }
                    peripheral.writeValue(Data(bytes), for: characteristic, type: .withoutResponse)
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Private, queue-confined

    /// Points the transport at a new set of chargers. An outstanding connect
    /// for a charger that is no longer wanted is withdrawn; one still wanted is
    /// left alone, because cancelling and re-issuing it only invites a stale
    /// callback from the first request.
    private func retarget(_ identifiers: [UUID], exclusive: Bool) {
        targets = identifiers
        self.exclusive = exclusive
        targetsForgotten = false
        waitGeneration += 1
        for (id, candidate) in pending where !identifiers.contains(id) {
            pending[id] = nil
            fileLog?.write("withdrawing connect to \(id)")
            cancelLocked(candidate)
        }
    }

    /// Whether an automatic path may attach this charger without being told to.
    private func wants(_ identifier: UUID) -> Bool {
        targets.isEmpty || targets.contains(identifier)
    }

    private func beginConnect() {
        guard let central, central.state == .poweredOn, peripheral == nil else { return }

        // The charger stops advertising completely while any client holds it — a
        // phone app, or a stale copy of this one. Scanning then finds nothing, and
        // retrieval by primary service is the only way back to it. The 16-bit FF09
        // is not accepted here (it returns an empty array), so ask by the 128-bit
        // service only.
        for candidate in central.retrieveConnectedPeripherals(withServices: [serviceUUID]) {
            seen[candidate.identifier] = candidate
            announce(candidate, rssi: 0, advertisement: [:], extra: [.systemConnected])
            // Only a charger the caller wants: straight after a switch, the one
            // just let go can still be held at system level for a moment.
            if autoConnect, wants(candidate.identifier), pending[candidate.identifier] == nil {
                fileLog?.write("retrieveConnectedPeripherals matched \(candidate.identifier)")
                attach(candidate, reason: "already connected at system level")
                return
            }
        }

        // A picker browse attaches nothing; it only keeps the list coming.
        guard autoConnect else {
            scan()
            return
        }

        if !targets.isEmpty {
            // `connect` never times out, so each saved charger simply waits for
            // its turn to come into range. That is the whole of automatic
            // switching: home and office are both requested, whichever is here
            // answers.
            let missing = targets.filter { pending[$0] == nil }
            let known = missing.isEmpty
                ? []
                : central.retrievePeripherals(withIdentifiers: missing)
            for candidate in known.sorted(by: { lhs, rhs in
                (targets.firstIndex(of: lhs.identifier) ?? .max)
                    < (targets.firstIndex(of: rhs.identifier) ?? .max)
            }) {
                seen[candidate.identifier] = candidate
                fileLog?.write("retrievePeripherals matched remembered \(candidate.identifier)")
                attach(candidate, reason: "remembered peripheral")
            }
            if !pending.isEmpty { return }
            targetsForgotten = true
        }
        scan()
    }

    private func scan() {
        guard let central, central.state == .poweredOn,
              peripheral == nil, !isScanning else { return }
        isScanning = true
        continuation.yield(.scanning(true))
        fileLog?.write("scanning (unfiltered)")
        // Unfiltered: see the reasoning on the type. Duplicates are on so RSSI
        // stays fresh in the picker and a late-appearing name is not missed.
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true,
        ])
    }

    private func attach(_ found: CBPeripheral, reason: String) {
        // A connect issued while the radio is off is dropped by CoreBluetooth
        // with no callback. Recorded as pending it would block every later
        // request; left out, the power-on callback asks again for the targets.
        guard central?.state == .poweredOn else { return }
        // A picker browse keeps its scan: a saved charger re-requested behind
        // it must not freeze the list the user is reading.
        if autoConnect { stopScanLocked() }
        pending[found.identifier] = found
        fileLog?.write("connecting to \(found.identifier) (\(reason))")
        // Connect with no options at all. macOS 15.7.7 rejects
        // CBConnectPeripheralOptionEnableAutoReconnect outright: connect() fails
        // with CBError.invalidParameters (code 1) whenever the key is present, set
        // to true OR false, and for any peripheral — measured against this charger
        // and against a bonded Logitech mouse. The symbol is macOS 14+, so this is
        // a runtime rejection rather than an availability problem. Recovery is
        // owned by the session state machine and its backoff regardless.
        central?.connect(found, options: nil)
    }

    private func stopScanLocked() {
        if isScanning {
            central?.stopScan()
            isScanning = false
            continuation.yield(.scanning(false))
        }
    }

    private static let failedConnectRetryDelay: DispatchTimeInterval = .seconds(2)

    /// Withdraws a request or drops a link. CoreBluetooth treats a cancel while
    /// it is not powered on as API misuse; its own reset already dropped them.
    private func cancelLocked(_ target: CBPeripheral) {
        guard let central, central.state == .poweredOn else { return }
        central.cancelPeripheralConnection(target)
    }

    private func teardownLocked(reason: String?, notify: Bool) {
        waitGeneration += 1
        let hadPeripheral = peripheral != nil || !pending.isEmpty
        for candidate in pending.values { cancelLocked(candidate) }
        pending.removeAll()
        peripheral?.delegate = nil
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        let waiting = pendingWrites
        pendingWrites.removeAll()
        for continuation in waiting { continuation.resume(throwing: TransportError.notConnected) }
        if notify && hadPeripheral {
            fileLog?.write("disconnected: \(reason ?? "clean")")
            continuation.yield(.disconnected(reason: reason))
        }
    }

    /// Decides whether an advertisement looks like an Anker Prime charger, and why.
    private func match(_ peripheral: CBPeripheral, _ advertisement: [String: Any]) -> [MatchReason] {
        var reasons: [MatchReason] = []

        let advertised = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if advertised.contains(advertisedUUID) || advertised.contains(serviceUUID) {
            reasons.append(.advertisedService)
        }
        let serviceData = advertisement[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        if serviceData.keys.contains(advertisedUUID) || serviceData.keys.contains(serviceUUID) {
            reasons.append(.serviceData)
        }
        let overflow = advertisement[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        if overflow.contains(advertisedUUID) || overflow.contains(serviceUUID) {
            reasons.append(.overflowService)
        }
        let name = ((advertisement[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "")
            .lowercased()
        if !name.isEmpty, nameHints.contains(where: name.contains) {
            reasons.append(.namePrefix)
        }
        // The manufacturer payload embeds the official product type for this model
        // (`A2687` -> `B405` in Anker's own device table), which is a far more
        // specific signal than the family-wide FF09.
        if let manufacturer = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data,
           Self.contains(Array(manufacturer), Self.productTypeA2687) {
            reasons.append(.productType)
        }
        if targets.contains(peripheral.identifier) {
            reasons.append(.remembered)
        }
        return reasons
    }

    private func announce(
        _ peripheral: CBPeripheral, rssi: Int, advertisement: [String: Any], extra: [MatchReason] = []
    ) {
        // Unfiltered scanning with duplicates on produces a firehose. Only forward
        // an advertisement when it actually tells the UI something new, otherwise
        // the session actor spends its time on RSSI jitter. Decide that before
        // building the DiscoveredCharger — most callbacks are dropped here, and
        // the value's array allocations were being thrown away with them.
        let previous = announced[peripheral.identifier]
        let isNew = previous == nil
        let moved = abs((previous?.rssi ?? 0) - rssi) > 6
        let aged = Date().timeIntervalSince(previous?.at ?? .distantPast) > 3
        guard isNew || moved || aged || !extra.isEmpty else { return }
        announced[peripheral.identifier] = (rssi, Date())

        let advertised = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceData = advertisement[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let name = (advertisement[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name

        var reasons = match(peripheral, advertisement)
        for reason in extra where !reasons.contains(reason) { reasons.append(reason) }

        let charger = DiscoveredCharger(
            id: peripheral.identifier,
            name: name,
            rssi: rssi,
            serviceUUIDs: advertised.map(\.uuidString) + (peripheral.services ?? []).map(\.uuid.uuidString),
            serviceDataKeys: serviceData.keys.map(\.uuidString),
            hasManufacturerData: advertisement[CBAdvertisementDataManufacturerDataKey] != nil,
            isConnectable: (advertisement[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true,
            matchReasons: reasons
        )
        continuation.yield(.discovered(charger))

        if isNew || moved {
            fileLog?.write(
                "seen \(peripheral.identifier) name=\(Redact.identifier(name)) rssi=\(rssi) "
                + "svc=[\(advertised.map(\.uuidString).joined(separator: ","))] "
                + "svcData=[\(serviceData.keys.map(\.uuidString).joined(separator: ","))] "
                + "mfg=\(advertisement[CBAdvertisementDataManufacturerDataKey] != nil) "
                + "match=[\(reasons.map(\.rawValue).joined(separator: ","))]"
            )
        }
    }
}

extension CoreBluetoothTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state: BluetoothState
        switch central.state {
        case .poweredOn: state = .poweredOn
        case .poweredOff: state = .poweredOff
        case .unauthorized:
            state = CBManager.authorization == .notDetermined ? .notDetermined : .unauthorized
        case .unsupported: state = .unsupported
        default: state = .unknown
        }
        fileLog?.write("central state -> \(state)")
        continuation.yield(.bluetoothState(state))
        if state == .poweredOn {
            beginConnect()
        } else {
            // The radio stopped the scan itself; say so, or the picker keeps
            // showing a scan that is not running and its button stays disabled.
            if isScanning {
                isScanning = false
                continuation.yield(.scanning(false))
            }
            teardownLocked(reason: nil, notify: true)
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        seen[peripheral.identifier] = peripheral
        announce(peripheral, rssi: RSSI.intValue, advertisement: advertisementData)

        guard autoConnect, self.peripheral == nil,
              pending[peripheral.identifier] == nil else { return }
        if targets.contains(peripheral.identifier) {
            attach(peripheral, reason: "remembered, advertising")
            return
        }
        // Any charger only when nothing specific was asked for, or when every
        // saved identifier has been forgotten by the system. Otherwise a room
        // with a colleague's charger in it would hand the user theirs.
        guard !exclusive, targets.isEmpty || targetsForgotten else { return }
        let reasons = match(peripheral, advertisementData)
        guard !reasons.isEmpty else { return }
        attach(peripheral, reason: reasons.map(\.rawValue).joined(separator: "+"))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard self.peripheral == nil, pending[id] != nil else {
            // A request this transport already withdrew — a race loser that
            // completed before its cancel landed, or the charger just switched
            // away from. Holding it would keep that charger silent: it stops
            // advertising while any client holds it.
            if self.peripheral?.identifier != id {
                fileLog?.write("dropping unrequested connection \(id)")
                central.cancelPeripheralConnection(peripheral)
            }
            return
        }
        pending[id] = nil
        for (other, candidate) in pending {
            fileLog?.write("\(id) answered first; withdrawing \(other)")
            central.cancelPeripheralConnection(candidate)
        }
        pending.removeAll()
        self.peripheral = peripheral
        peripheral.delegate = self
        fileLog?.write("connected \(id)")
        continuation.yield(.connected(DiscoveredCharger(
            id: peripheral.identifier, name: peripheral.name, matchReasons: [.remembered]
        )))
        peripheral.discoverServices([serviceUUID])
    }

    public func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        // Only a request still outstanding can fail; anything else is a stale
        // answer to one already withdrawn.
        guard pending.removeValue(forKey: peripheral.identifier) != nil else { return }
        let id = peripheral.identifier
        let reason = error?.localizedDescription ?? L10n.text("连接失败", table: "Core")
        fileLog?.write("connect to \(id) failed: \(reason)")
        guard self.peripheral == nil, pending.isEmpty else {
            // Another saved charger is still being waited for, so the session
            // hears nothing and runs no backoff. Ask for this one again here, or
            // the charger right beside the Mac is dropped from the wait for good.
            let generation = waitGeneration
            queue.asyncAfter(deadline: .now() + Self.failedConnectRetryDelay) { [weak self] in
                guard let self, self.waitGeneration == generation, self.peripheral == nil,
                      self.pending[id] == nil, self.targets.contains(id),
                      // Resolved again: a Bluetooth reset in between invalidates
                      // the object the failure was reported on.
                      let fresh = self.central?.retrievePeripherals(withIdentifiers: [id]).first
                else { return }
                self.attach(fresh, reason: "retry after failed connect")
            }
            return
        }
        continuation.yield(.disconnected(reason: reason))
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        // A link dropped on purpose (a switch, a same-charger reconnect) reports
        // its disconnect late, often after the next request went out. Only the
        // current link may tear anything down.
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        teardownLocked(reason: error?.localizedDescription, notify: true)
    }
}

extension CoreBluetoothTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        let found = (peripheral.services ?? []).map(\.uuid.uuidString).joined(separator: ",")
        fileLog?.write("services on \(peripheral.identifier): [\(found)]")
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            teardownLocked(
                reason: L10n.text("这台设备不是受支持的充电器", table: "Core"),
                notify: true
            )
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == writeUUID { writeCharacteristic = characteristic }
            if characteristic.uuid == notifyUUID { notifyCharacteristic = characteristic }
        }
        guard let notifyCharacteristic, writeCharacteristic != nil else {
            teardownLocked(reason: L10n.text("缺少读写特征", table: "Core"), notify: true)
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral.identifier == self.peripheral?.identifier,
              characteristic.uuid == notifyUUID, characteristic.isNotifying, error == nil else { return }
        let withResponse = writeCharacteristic?.properties.contains(.write) ?? false
        let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
        let limit = peripheral.maximumWriteValueLength(for: type)
        fileLog?.write("notifications live, maxWrite=\(limit) withResponse=\(withResponse)")
        continuation.yield(.ready(maxWriteLength: limit, withResponse: withResponse))
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        guard characteristic.uuid == notifyUUID, let value = characteristic.value else {
            if let error { fileLog?.write("notify error: \(error.localizedDescription)") }
            return
        }
        // Log the arrival itself, not just what survives parsing: "nothing came
        // back" and "something came back that we could not read" need very
        // different fixes, and without this they look identical.
        notificationCount += 1
        fileLog?.write("notify #\(notificationCount) \(value.count) B")
        continuation.yield(.notification([UInt8](value)))
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard peripheral.identifier == self.peripheral?.identifier,
              !pendingWrites.isEmpty else { return }
        let continuation = pendingWrites.removeFirst()
        if let error {
            continuation.resume(throwing: TransportError.writeFailed(error.localizedDescription))
        } else {
            continuation.resume()
        }
    }
}
