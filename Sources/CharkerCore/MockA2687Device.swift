import A2687Protocol
import CryptoKit
import Foundation

/// A software A2687 that speaks the real wire protocol.
///
/// It exists for three reasons: end-to-end tests without hardware, the app's demo
/// mode, and a reviewable build for anyone who does not own the charger. Its
/// canned responses are the plaintexts recovered from the pinned SolixBLE
/// negotiation fixtures, so the client is exercised against real device shapes.
public final class MockA2687Device: @unchecked Sendable {
    public struct PortState: Sendable {
        public var isOn: Bool
        public var voltage: Double
        public var current: Double
        public var cableCode: UInt8
        public var profileCode: UInt8

        public init(
            isOn: Bool, voltage: Double, current: Double,
            cableCode: UInt8 = 0x01, profileCode: UInt8 = 0x00
        ) {
            self.isOn = isOn
            self.voltage = voltage
            self.current = current
            self.cableCode = cableCode
            self.profileCode = profileCode
        }

        public var power: Double { isOn ? voltage * current : 0 }

        static let idle = PortState(isOn: false, voltage: 0, current: 0, cableCode: 0x03)
    }

    public var ports: [PortState] = [
        PortState(isOn: true, voltage: 20.0, current: 3.25, cableCode: 0x01, profileCode: 0x01),
        PortState(isOn: true, voltage: 9.0, current: 2.0, cableCode: 0x00, profileCode: 0x02),
        .idle,
    ]
    public var serialNumber = "ASHDMOCK00000000"
    public var firmwareVersion = "v0.0.5.0"
    public var productName = "Charging"
    public var macBytes: [UInt8] = [0x02, 0x00, 0x5E, 0x10, 0x00, 0x01]
    /// Persistent display settings. Nil keeps legacy demo/test snapshots free of
    /// settings until a test or a write opts into them.
    public var deviceLanguage: DeviceLanguage?
    public var screenTimeout: ScreenTimeout?
    public var screenBrightness: UInt8?
    public var screenOrientation: ScreenOrientation?
    public var gyroscopeEnabled: Bool?

    private let privateKey = P256.KeyAgreement.PrivateKey()
    private var sessionKeys: A2687Crypto.Keys?
    private var reassembler = FrameReassembler()
    /// Set once the client has authenticated; port writes are refused before that.
    public private(set) var sessionOpen = false

    public init() {}

    public func reset() {
        sessionKeys = nil
        sessionOpen = false
        reassembler.reset()
    }

    /// Feeds client bytes in, returns the frames the device would notify back.
    public func receive(_ chunk: [UInt8]) -> [[UInt8]] {
        reassembler.append(chunk).flatMap { respond(to: $0) }
    }

    /// One asynchronous realtime report, the `0x4300` app-mode stream.
    public func realtimeReport() -> [UInt8]? {
        guard let sessionKeys, sessionOpen else { return nil }
        return seal(group: Frame.sessionGroup, opcode: A2687.Opcode.realtimeReport,
                    response: false, plaintext: telemetryPayload(), keys: sessionKeys)
    }

    // MARK: - Protocol

    private func respond(to frame: Frame) -> [[UInt8]] {
        let negotiationKeys = A2687Crypto.Keys.negotiation
        let keys = frame.opcode >= A2687.Opcode.aesMetadata && sessionKeys != nil
            ? sessionKeys! : negotiationKeys
        guard let plaintext = try? A2687Crypto.open(frame.payload, with: keys),
              let request = try? Payload.parse(plaintext) else { return [] }

        switch frame.opcode {
        case A2687.Opcode.initialConnect:
            return [ack(frame, [TLV(id: A2687.Field.a1, value: [0x01])], keys: negotiationKeys)]

        case A2687.Opcode.capability:
            return [ack(frame, [
                TLV(id: A2687.Field.a1, value: [0x02]),
                TLV(id: A2687.Field.a2, value: [0x29, 0x01]),
                TLV(id: A2687.Field.a3, value: [0x44]),
                TLV(id: A2687.Field.a4, value: [0x01]),
                TLV(id: A2687.Field.a5, value: [0x02]),
            ], keys: negotiationKeys)]

        case A2687.Opcode.baseInfo:
            let serial = Array(serialNumber.utf8)
            return [ack(frame, [
                TLV(id: A2687.Field.a1, value: [0x03]),
                TLV(id: A2687.Field.a2, value: Array(productName.utf8)),
                TLV(id: A2687.Field.a3, value: Array(firmwareVersion.utf8)),
                TLV(id: A2687.Field.a4, value: serial),
                TLV(id: A2687.Field.a5, value: macBytes + serial.suffix(11)),
            ], keys: negotiationKeys)]

        case A2687.Opcode.setCapability:
            return [ack(frame, [], keys: negotiationKeys)]

        case A2687.Opcode.publicKey:
            guard let point = request[A2687.Field.a1], point.count == 64,
                  let secret = try? A2687Crypto.sharedSecret(privateKey: privateKey, devicePoint: point),
                  let derived = try? A2687Crypto.Keys(secretPrefix: secret) else { return [] }
            sessionKeys = derived
            return [ack(frame, [
                TLV(id: A2687.Field.a1, value: A2687Crypto.rawPublicKey(privateKey)),
            ], keys: negotiationKeys)]

        case A2687.Opcode.aesMetadata:
            guard let sessionKeys else { return [] }
            return [ack(frame, [], keys: sessionKeys)]

        case A2687.Opcode.userAuth:
            guard let sessionKeys else { return [] }
            sessionOpen = true
            return [ack(frame, [], keys: sessionKeys)]

        case A2687.Opcode.readAll:
            guard let sessionKeys, sessionOpen else { return [] }
            return [seal(group: Frame.sessionGroup, opcode: A2687.Opcode.realtimeReport,
                         response: false, plaintext: telemetryPayload(), keys: sessionKeys)]

        case A2687.Opcode.portOutput:
            guard let sessionKeys, sessionOpen,
                  case .u8(let index)? = request.typed(A2687.Field.a2),
                  case .u8(let on)? = request.typed(A2687.Field.a3),
                  ports.indices.contains(Int(index)) else { return [] }
            ports[Int(index)].isOn = on != 0
            return [
                ack(frame, [TLV(id: A2687.Field.a1, value: TypedValue.u8(0).encoded)], keys: sessionKeys),
                seal(group: Frame.sessionGroup, opcode: A2687.Opcode.realtimeReport,
                     response: false, plaintext: telemetryPayload(), keys: sessionKeys),
            ]

        case A2687.Opcode.portTimer:
            guard let sessionKeys, sessionOpen,
                  case .u8(let index)? = request.typed(A2687.Field.a2),
                  case .bytes(let duration)? = request.typed(A2687.Field.a3),
                  duration.count == 4,
                  ports.indices.contains(Int(index)) else { return [] }
            let seconds = UInt32(duration[0])
                | UInt32(duration[1]) << 8
                | UInt32(duration[2]) << 16
                | UInt32(duration[3]) << 24
            guard seconds > 0 else { return [] }
            // The production UI owns the local projected deadline. The simulator
            // only needs to reproduce the real protocol's accepted ACK so demo
            // mode exercises the same AppModel path without touching hardware.
            return [ack(frame, [], keys: sessionKeys)]

        case A2687.Opcode.deviceLanguage:
            guard let sessionKeys, sessionOpen,
                  case .u8(let value)? = request.typed(A2687.Field.a2),
                  let language = DeviceLanguage(rawValue: value) else { return [] }
            deviceLanguage = language
            return [ack(frame, [], keys: sessionKeys)]

        case A2687.Opcode.screenTimeout:
            guard let sessionKeys, sessionOpen,
                  case .u8(let value)? = request.typed(A2687.Field.a2),
                  let timeout = ScreenTimeout(rawValue: value) else { return [] }
            screenTimeout = timeout
            return [ack(frame, [], keys: sessionKeys)]

        case A2687.Opcode.screenBrightness:
            guard let sessionKeys, sessionOpen,
                  case .u8(let value)? = request.typed(A2687.Field.a2), value <= 100 else { return [] }
            screenBrightness = max(25, value)
            return [ack(frame, [], keys: sessionKeys)]

        case A2687.Opcode.screenOrientation:
            guard let sessionKeys, sessionOpen else { return [] }
            // `0x020B` is also the realtime trigger. Only the scalar-u8 shape is
            // the orientation write; the trigger carries a nine-byte block.
            guard case .u8(let value)? = request.typed(A2687.Field.a2) else {
                return [ack(frame, [], keys: sessionKeys)]
            }
            guard let orientation = ScreenOrientation(rawValue: value) else { return [] }
            screenOrientation = orientation
            return [ack(frame, [], keys: sessionKeys)]

        case A2687.Opcode.gyroscope:
            guard let sessionKeys, sessionOpen,
                  case .u8(let value)? = request.typed(A2687.Field.a2), value <= 1 else { return [] }
            gyroscopeEnabled = value == 1
            return [ack(frame, [], keys: sessionKeys)]

        default:
            return []
        }
    }

    private func telemetryPayload() -> [UInt8] {
        var fields: [TLV] = [TLV(id: A2687.Field.a1, value: [A2687.sessionAction])]
        for port in A2687.Port.allCases {
            let state = ports[port.rawValue]
            let mV = UInt16(clamping: Int((state.isOn ? state.voltage : 0) * 1000))
            let mA = UInt16(clamping: Int((state.isOn ? state.current : 0) * 1000))
            let cW = UInt16(clamping: Int(state.power * 100))
            let bytes: [UInt8] = [
                state.isOn ? 0x01 : 0x00,
                UInt8(mV & 0xFF), UInt8(mV >> 8),
                UInt8(mA & 0xFF), UInt8(mA >> 8),
                UInt8(cW & 0xFF), UInt8(cW >> 8),
            ]
            fields.append(TLV(id: port.telemetryField, value: TypedValue.bytes(bytes).encoded))
            // Twelve bytes, the CPowerControl shape real firmware sends. It used
            // to be four (`00 00 cable profile`), which decoded only because the
            // reader took the last two bytes of any length; against the fixed
            // offsets that short struct now yields no cable at all, which emptied
            // the cable chip throughout demo mode.
            fields.append(TLV(
                id: port.cableField,
                value: TypedValue.bytes(
                    PortControl.idleDefaultPrefix + [state.cableCode, state.profileCode]
                ).encoded
            ))
        }
        if let screenTimeout {
            fields.append(TLV(id: A2687.Field.a8, value: TypedValue.u8(screenTimeout.rawValue).encoded))
        }
        if let screenBrightness {
            fields.append(TLV(id: A2687.Field.a9, value: TypedValue.u8(screenBrightness).encoded))
        }
        if let screenOrientation {
            fields.append(TLV(id: A2687.Field.af, value: TypedValue.u8(screenOrientation.rawValue).encoded))
        }
        if let gyroscopeEnabled {
            fields.append(TLV(id: A2687.Field.b2, value: TypedValue.u8(gyroscopeEnabled ? 1 : 0).encoded))
        }
        return [0x00] + TLVCodec.encode(fields)
    }

    private func ack(_ frame: Frame, _ fields: [TLV], keys: A2687Crypto.Keys) -> [UInt8] {
        seal(group: frame.group, opcode: frame.opcode, response: true,
             plaintext: [0x00] + TLVCodec.encode(fields), keys: keys)
    }

    private func seal(
        group: UInt8, opcode: UInt16, response: Bool, plaintext: [UInt8], keys: A2687Crypto.Keys
    ) -> [UInt8] {
        let sealed = (try? A2687Crypto.seal(plaintext, with: keys)) ?? []
        return PacketCodec.encode(
            Frame(group: group, opcode: opcode, encrypted: true, response: response, payload: sealed)
        )
    }
}
