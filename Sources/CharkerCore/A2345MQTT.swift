import Foundation
import Network
import Security

enum A2345MQTTCodecError: Error, Equatable {
    case malformedPacket
    case unsupportedQoS(UInt8)
    case stringTooLong
}

enum A2345MQTTInboundPacket: Equatable {
    case connack(sessionPresent: Bool, returnCode: UInt8)
    case suback(packetIdentifier: UInt16, returnCodes: [UInt8])
    case publish(topic: String, payload: Data, qos: UInt8, packetIdentifier: UInt16?)
    case pingResponse
    case disconnect
    case other(type: UInt8, body: Data)
}

/// MQTT 3.1.1 framing kept independent from Network.framework so every byte of
/// CONNECT/SUBSCRIBE/PUBLISH/PUBACK and every fragmented inbound packet can be
/// pinned by unit tests. Outbound PUBLISH is deliberately fixed to QoS 0; the
/// only caller is the closed A2345 read-request builder below.
enum A2345MQTTCodec {
    /// Cloud payload decoding accepts at most 256 KiB. Reserve 4 KiB for the
    /// MQTT topic and framing, then reject the length before waiting for or
    /// allocating an attacker-controlled multi-megabyte packet.
    static let maximumPacketBytes = A2345CloudPayloadDecoder.maximumInputBytes + 4_096

    static func connect(clientID: String, keepAlive: UInt16) throws -> Data {
        var body = Data([0x00, 0x04])
        body.append(contentsOf: "MQTT".utf8)
        body.append(0x04) // MQTT 3.1.1
        body.append(0x02) // clean session; no username/password/will
        body.append(UInt8(keepAlive >> 8))
        body.append(UInt8(keepAlive & 0xFF))
        body.append(try mqttString(clientID))
        return packet(typeAndFlags: 0x10, body: body)
    }

    static func subscribe(
        topic: String,
        packetIdentifier: UInt16,
        qos: UInt8 = 0
    ) throws -> Data {
        guard packetIdentifier != 0, qos <= 1 else {
            throw A2345MQTTCodecError.malformedPacket
        }
        var body = Data([
            UInt8(packetIdentifier >> 8),
            UInt8(packetIdentifier & 0xFF),
        ])
        body.append(try mqttString(topic))
        body.append(qos)
        return packet(typeAndFlags: 0x82, body: body)
    }

    /// Encodes the sole outbound PUBLISH shape used by this read-only client.
    /// No QoS/retain/duplicate switches are accepted by design.
    static func publishQoSZero(topic: String, payload: Data) throws -> Data {
        guard !topic.isEmpty,
              !topic.contains("+"),
              !topic.contains("#"),
              payload.count <= maximumPacketBytes
        else {
            throw A2345MQTTCodecError.malformedPacket
        }
        var body = try mqttString(topic)
        body.append(payload)
        guard body.count <= maximumPacketBytes else {
            throw A2345MQTTCodecError.malformedPacket
        }
        return packet(typeAndFlags: 0x30, body: body)
    }

    static func pingRequest() -> Data { Data([0xC0, 0x00]) }

    static func pubAck(packetIdentifier: UInt16) throws -> Data {
        guard packetIdentifier != 0 else { throw A2345MQTTCodecError.malformedPacket }
        return Data([
            0x40, 0x02,
            UInt8(packetIdentifier >> 8), UInt8(packetIdentifier & 0xFF),
        ])
    }

    static func disconnect() -> Data { Data([0xE0, 0x00]) }

    static func decodeNext(from buffer: inout Data) throws -> A2345MQTTInboundPacket? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        guard let remaining = try remainingLength(bytes, start: 1) else { return nil }
        let headerLength = 1 + remaining.encodedBytes
        guard remaining.value <= maximumPacketBytes else {
            throw A2345MQTTCodecError.malformedPacket
        }
        let totalLength = headerLength + remaining.value
        guard totalLength <= bytes.count else { return nil }

        let first = bytes[0]
        let type = first >> 4
        let flags = first & 0x0F
        let body = Data(bytes[headerLength..<totalLength])
        buffer.removeFirst(totalLength)

        switch type {
        case 2:
            guard flags == 0, body.count == 2 else {
                throw A2345MQTTCodecError.malformedPacket
            }
            return .connack(
                sessionPresent: body[body.startIndex] & 0x01 == 1,
                returnCode: body[body.startIndex + 1]
            )

        case 3:
            return try decodePublish(firstByte: first, body: body)

        case 9:
            guard flags == 0, body.count >= 3 else {
                throw A2345MQTTCodecError.malformedPacket
            }
            let packetIdentifier = uint16(body, at: 0)
            guard packetIdentifier != 0 else {
                throw A2345MQTTCodecError.malformedPacket
            }
            return .suback(
                packetIdentifier: packetIdentifier,
                returnCodes: Array(body.dropFirst(2))
            )

        case 13:
            guard flags == 0, body.isEmpty else {
                throw A2345MQTTCodecError.malformedPacket
            }
            return .pingResponse

        case 14:
            guard flags == 0, body.isEmpty else {
                throw A2345MQTTCodecError.malformedPacket
            }
            return .disconnect

        default:
            return .other(type: type, body: body)
        }
    }

    private static func decodePublish(
        firstByte: UInt8,
        body: Data
    ) throws -> A2345MQTTInboundPacket {
        let qos = (firstByte >> 1) & 0x03
        guard qos <= 1 else { throw A2345MQTTCodecError.unsupportedQoS(qos) }
        guard body.count >= 2 else { throw A2345MQTTCodecError.malformedPacket }
        let topicLength = Int(uint16(body, at: 0))
        guard topicLength > 0, body.count >= 2 + topicLength else {
            throw A2345MQTTCodecError.malformedPacket
        }
        let topicRange = 2..<(2 + topicLength)
        guard let topic = String(data: body.subdata(in: topicRange), encoding: .utf8),
              !topic.contains("\0")
        else {
            throw A2345MQTTCodecError.malformedPacket
        }

        var payloadOffset = 2 + topicLength
        var packetIdentifier: UInt16?
        if qos == 1 {
            guard body.count >= payloadOffset + 2 else {
                throw A2345MQTTCodecError.malformedPacket
            }
            let identifier = uint16(body, at: payloadOffset)
            guard identifier != 0 else { throw A2345MQTTCodecError.malformedPacket }
            packetIdentifier = identifier
            payloadOffset += 2
        }

        return .publish(
            topic: topic,
            payload: body.subdata(in: payloadOffset..<body.count),
            qos: qos,
            packetIdentifier: packetIdentifier
        )
    }

    private static func packet(typeAndFlags: UInt8, body: Data) -> Data {
        var data = Data([typeAndFlags])
        data.append(contentsOf: encodeRemainingLength(body.count))
        data.append(body)
        return data
    }

    private static func mqttString(_ value: String) throws -> Data {
        let bytes = Data(value.utf8)
        guard !value.contains("\0"), bytes.count <= Int(UInt16.max) else {
            throw A2345MQTTCodecError.stringTooLong
        }
        var output = Data([
            UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF),
        ])
        output.append(bytes)
        return output
    }

    private static func encodeRemainingLength(_ length: Int) -> [UInt8] {
        var value = length
        var bytes: [UInt8] = []
        repeat {
            var encoded = UInt8(value % 128)
            value /= 128
            if value > 0 { encoded |= 0x80 }
            bytes.append(encoded)
        } while value > 0
        return bytes
    }

    private static func remainingLength(
        _ bytes: [UInt8],
        start: Int
    ) throws -> (value: Int, encodedBytes: Int)? {
        var multiplier = 1
        var value = 0
        for offset in 0..<4 {
            let index = start + offset
            guard index < bytes.count else { return nil }
            let encoded = bytes[index]
            value += Int(encoded & 0x7F) * multiplier
            if encoded & 0x80 == 0 {
                return (value, offset + 1)
            }
            multiplier *= 128
        }
        throw A2345MQTTCodecError.malformedPacket
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        let start = data.startIndex + offset
        return UInt16(data[start]) << 8 | UInt16(data[start + 1])
    }
}

public enum A2345MQTTError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidClientIdentity(OSStatus)
    case connectionFailed
    case connectionRejected(UInt8)
    case subscriptionRejected(UInt8)
    case protocolViolation
    case handshakeTimedOut
    case keepAliveTimedOut

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return L10n.text("MQTT 连接参数无效。", table: "Core")
        case .invalidClientIdentity(let status):
            return L10n.format("MQTT 客户端证书与私钥无法组成身份（%d）。", status, table: "Core")
        case .connectionFailed:
            return L10n.text("无法连接 Anker MQTT 服务。", table: "Core")
        case .connectionRejected(let code):
            return L10n.format("Anker MQTT 拒绝了连接（%d）。", code, table: "Core")
        case .subscriptionRejected(let code):
            return L10n.format("Anker MQTT 拒绝了订阅（%d）。", code, table: "Core")
        case .protocolViolation:
            return L10n.text("Anker MQTT 返回了无效数据。", table: "Core")
        case .handshakeTimedOut:
            return L10n.text("Anker MQTT 连接或订阅握手超时。", table: "Core")
        case .keepAliveTimedOut:
            return L10n.text("Anker MQTT 心跳超时。", table: "Core")
        }
    }
}

public struct A2345MQTTConfiguration: Sendable {
    public var credentials: AnkerMQTTCredentials
    public var device: AnkerBoundDevice
    public var topic: String
    public var clientID: String
    public var port: UInt16
    public var keepAlive: UInt16

    public init(
        credentials: AnkerMQTTCredentials,
        device: AnkerBoundDevice,
        topic: String,
        clientID: String,
        port: UInt16 = 8883,
        keepAlive: UInt16 = 60
    ) {
        self.credentials = credentials
        self.device = device
        self.topic = topic
        self.clientID = clientID
        self.port = port
        self.keepAlive = keepAlive
    }

    func readCommandBuilder() throws -> A2345MQTTReadCommandBuilder {
        try A2345MQTTReadCommandBuilder(
            credentials: credentials,
            device: device,
            subscriptionTopic: topic
        )
    }
}

public enum A2345MQTTEvent: Sendable, Equatable {
    case connected
    case subscribed
    case message(topic: String, payload: Data)
    case disconnected
    case failed(A2345MQTTError)
}

enum A2345MQTTSubscriberState: Equatable, Sendable {
    case idle
    case connecting
    case awaitingConnack
    case awaitingSuback(UInt16)
    case subscribed
    case stopped

    var requiresHandshakeWatchdog: Bool {
        switch self {
        case .connecting, .awaitingConnack, .awaitingSuback:
            return true
        case .idle, .subscribed, .stopped:
            return false
        }
    }
}

/// A deliberately read-only MQTT 3.1.1 client. Its public surface can connect,
/// subscribe and stop; the only outbound device messages are the two typed read
/// requests issued internally. QoS-1 messages are acknowledged because PUBACK is
/// transport housekeeping, not a device write.
public final class A2345MQTTSubscriber: @unchecked Sendable {
    public let events: AsyncStream<A2345MQTTEvent>

    /// One bounded budget covers network establishment, CONNACK and SUBACK.
    /// Without it, NWConnection.waiting or a silent broker could pin one retry
    /// attempt forever before the post-subscription telemetry watchdog exists.
    static let handshakeTimeout: TimeInterval = 20

    /// A2345's realtime trigger has a fixed 10-second device-side window. Renew
    /// two seconds early so scheduler jitter cannot create a telemetry gap.
    static let realtimeRefreshInterval: TimeInterval = 8

    /// The server returns an ordinary PEM certificate and RSA key. Security's
    /// in-memory `SecIdentityCreate` path has existed since macOS 10.12, so the
    /// app's macOS 14 deployment target can use the cloud reader without ever
    /// importing temporary key material into a persistent Keychain.
    public static let supportsMemoryOnlyClientIdentity = true

    private let configuration: A2345MQTTConfiguration
    private let continuation: AsyncStream<A2345MQTTEvent>.Continuation
    private let queue = DispatchQueue(label: "dev.charker.a2345.mqtt", qos: .utility)
    private var connection: NWConnection?
    private var importedIdentity: SecIdentity?
    private var receiveBuffer = Data()
    private var state = A2345MQTTSubscriberState.idle
    private var handshakeTimer: DispatchSourceTimer?
    private var handshakeGeneration: UInt64 = 0
    private var pingTimer: DispatchSourceTimer?
    private var realtimeRefreshTimer: DispatchSourceTimer?
    private var readCommandBuilder: A2345MQTTReadCommandBuilder?
    private var lastInboundAt = Date()
    private var terminalEventSent = false

    public init(configuration: A2345MQTTConfiguration) {
        self.configuration = configuration
        var sink: AsyncStream<A2345MQTTEvent>.Continuation!
        // The UI only needs the newest few state changes and telemetry frames.
        // A bounded stream prevents wake/resume from replaying an unbounded
        // broker backlog while QoS-1 acknowledgement remains transport-local.
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { sink = $0 }
        self.continuation = sink
    }

    deinit {
        handshakeTimer?.cancel()
        pingTimer?.cancel()
        realtimeRefreshTimer?.cancel()
        connection?.cancel()
        continuation.finish()
    }

    public func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopLocked(sendDisconnect: true) }
    }

    private func startLocked() {
        guard case .idle = state else { return }
        guard !configuration.credentials.endpoint.isEmpty,
              !configuration.clientID.isEmpty,
              !configuration.topic.isEmpty,
              configuration.port > 0,
              configuration.keepAlive > 0,
              let port = NWEndpoint.Port(rawValue: configuration.port)
        else {
            fail(.invalidConfiguration)
            return
        }

        do {
            readCommandBuilder = try configuration.readCommandBuilder()
            let identity = try importIdentity()
            importedIdentity = identity
            guard let networkIdentity = sec_identity_create(identity) else {
                fail(.invalidClientIdentity(errSecDecode))
                return
            }

            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(
                tls.securityProtocolOptions,
                .TLSv12
            )
            sec_protocol_options_set_local_identity(
                tls.securityProtocolOptions,
                networkIdentity
            )
            let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            let connection = NWConnection(
                host: NWEndpoint.Host(configuration.credentials.endpoint),
                port: port,
                using: parameters
            )
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] newState in
                self?.handleConnectionState(newState)
            }
            state = .connecting
            armHandshakeWatchdog()
            connection.start(queue: queue)
        } catch let error as A2345MQTTError {
            fail(error)
        } catch {
            fail(.invalidClientIdentity(errSecDecode))
        }
    }

    private func handleConnectionState(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            guard case .connecting = state else { return }
            do {
                state = .awaitingConnack
                receiveNext()
                try send(A2345MQTTCodec.connect(
                    clientID: configuration.clientID,
                    keepAlive: configuration.keepAlive
                ))
            } catch {
                fail(.protocolViolation)
            }
        case .failed:
            fail(.connectionFailed)
        case .cancelled:
            stopLocked(sendDisconnect: false)
        default:
            break
        }
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lastInboundAt = Date()
                self.receiveBuffer.append(data)
                guard self.receiveBuffer.count <= A2345MQTTCodec.maximumPacketBytes + 5 else {
                    self.fail(.protocolViolation)
                    return
                }
                do {
                    while let packet = try A2345MQTTCodec.decodeNext(from: &self.receiveBuffer) {
                        try self.handle(packet)
                    }
                } catch {
                    self.fail(.protocolViolation)
                    return
                }
            }
            if error != nil {
                self.fail(.connectionFailed)
                return
            }
            if isComplete {
                self.stopLocked(sendDisconnect: false)
                return
            }
            self.receiveNext()
        }
    }

    private func handle(_ packet: A2345MQTTInboundPacket) throws {
        switch packet {
        case .connack(_, let returnCode):
            guard case .awaitingConnack = state else {
                throw A2345MQTTCodecError.malformedPacket
            }
            guard returnCode == 0 else {
                fail(.connectionRejected(returnCode))
                return
            }
            continuation.yield(.connected)
            let identifier: UInt16 = 1
            state = .awaitingSuback(identifier)
            try send(A2345MQTTCodec.subscribe(
                topic: configuration.topic,
                packetIdentifier: identifier
            ))

        case .suback(let packetIdentifier, let returnCodes):
            let transition: A2345MQTTSubscriptionTransition
            do {
                transition = try A2345MQTTSubscriptionTransition.accept(
                    state: state,
                    packetIdentifier: packetIdentifier,
                    returnCodes: returnCodes
                )
            } catch let error as A2345MQTTError {
                fail(error)
                return
            }
            state = transition.nextState
            cancelHandshakeWatchdog()
            guard let readCommandBuilder else {
                throw A2345MQTTCodecError.malformedPacket
            }
            let requestDate = Date()
            for request in transition.initialReadRequests {
                try send(readCommandBuilder.mqttPacket(
                    for: request,
                    at: requestDate
                ))
            }
            startRealtimeRefreshTimer()
            startPingTimer()
            continuation.yield(.subscribed)

        case .publish(let topic, let payload, let qos, let packetIdentifier):
            guard case .subscribed = state else {
                throw A2345MQTTCodecError.malformedPacket
            }
            guard let readCommandBuilder,
                  readCommandBuilder.acceptsInboundTopic(topic)
            else {
                throw A2345MQTTCodecError.malformedPacket
            }
            continuation.yield(.message(topic: topic, payload: payload))
            if qos == 1 {
                guard let packetIdentifier else {
                    throw A2345MQTTCodecError.malformedPacket
                }
                try send(A2345MQTTCodec.pubAck(packetIdentifier: packetIdentifier))
            }

        case .pingResponse:
            break

        case .disconnect:
            stopLocked(sendDisconnect: false)

        case .other:
            // The two read requests use QoS 0, so PUBACK and other outbound
            // command-response packet types have no valid role in this session.
            break
        }
    }

    private func send(_ data: Data) throws {
        guard let connection else { throw A2345MQTTError.connectionFailed }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.fail(.connectionFailed) }
        })
    }

    private func startPingTimer() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(5, Double(configuration.keepAlive) / 2)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, case .subscribed = self.state else { return }
            if Date().timeIntervalSince(self.lastInboundAt) > Double(self.configuration.keepAlive) * 2 {
                self.fail(.keepAliveTimedOut)
                return
            }
            do {
                try self.send(A2345MQTTCodec.pingRequest())
            } catch {
                self.fail(.connectionFailed)
            }
        }
        pingTimer = timer
        timer.resume()
    }

    private func startRealtimeRefreshTimer() {
        realtimeRefreshTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.realtimeRefreshInterval,
            repeating: Self.realtimeRefreshInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self,
                  case .subscribed = self.state,
                  let readCommandBuilder = self.readCommandBuilder
            else { return }
            do {
                try self.send(readCommandBuilder.mqttPacket(
                    for: .realtimeTrigger,
                    at: Date()
                ))
            } catch {
                self.fail(.protocolViolation)
            }
        }
        realtimeRefreshTimer = timer
        timer.resume()
    }

    private func armHandshakeWatchdog() {
        cancelHandshakeWatchdog()
        handshakeGeneration &+= 1
        let generation = handshakeGeneration
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.handshakeTimeout)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.handshakeGeneration == generation,
                  self.state.requiresHandshakeWatchdog
            else { return }
            self.fail(.handshakeTimedOut)
        }
        handshakeTimer = timer
        timer.resume()
    }

    private func cancelHandshakeWatchdog() {
        handshakeGeneration &+= 1
        handshakeTimer?.cancel()
        handshakeTimer = nil
    }

    private func importIdentity() throws -> SecIdentity {
        guard let certificate = SecCertificateCreateWithData(
            nil,
            configuration.credentials.certificateDER as CFData
        ) else {
            throw A2345MQTTError.invalidClientIdentity(errSecDecode)
        }

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrIsPermanent: false,
        ]
        var keyError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(
            configuration.credentials.privateKeyDER as CFData,
            attributes as CFDictionary,
            &keyError
        ), let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw A2345MQTTError.invalidClientIdentity(errSecDecode)
        }
        return identity
    }

    private func stopLocked(sendDisconnect: Bool) {
        guard !terminalEventSent else { return }
        if sendDisconnect, case .subscribed = state {
            try? send(A2345MQTTCodec.disconnect())
        }
        state = .stopped
        cancelHandshakeWatchdog()
        pingTimer?.cancel()
        pingTimer = nil
        realtimeRefreshTimer?.cancel()
        realtimeRefreshTimer = nil
        readCommandBuilder = nil
        importedIdentity = nil
        connection?.cancel()
        connection = nil
        terminalEventSent = true
        continuation.yield(.disconnected)
        continuation.finish()
    }

    private func fail(_ error: A2345MQTTError) {
        guard !terminalEventSent else { return }
        state = .stopped
        cancelHandshakeWatchdog()
        pingTimer?.cancel()
        pingTimer = nil
        realtimeRefreshTimer?.cancel()
        realtimeRefreshTimer = nil
        readCommandBuilder = nil
        importedIdentity = nil
        connection?.cancel()
        connection = nil
        terminalEventSent = true
        continuation.yield(.failed(error))
        continuation.finish()
    }
}
