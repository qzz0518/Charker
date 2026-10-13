import Foundation

public enum A2345 {
    public enum MessageType {
        public static let realtime: UInt16 = 0x0303
        public static let versionInfo: UInt16 = 0x0830
        public static let statusSnapshot: UInt16 = 0x0A00
        public static let realtimeAcknowledgement: UInt16 = 0x0A0B
        public static let relatedAcknowledgements: Set<UInt16> = [0x0A0A, 0x0A0B, 0x0A14]
    }

    public enum Field {
        public static let a1: UInt8 = 0xA1
        public static let a2: UInt8 = 0xA2
        public static let a3: UInt8 = 0xA3
        public static let a4: UInt8 = 0xA4
        public static let a5: UInt8 = 0xA5
        public static let a6: UInt8 = 0xA6
        public static let a7: UInt8 = 0xA7
        public static let a8: UInt8 = 0xA8
        public static let a9: UInt8 = 0xA9
        public static let timestamp: UInt8 = 0xFE
    }

    public enum ValueType {
        public static let string: UInt8 = 0x00
        public static let variable: UInt8 = 0x03
        public static let binary: UInt8 = 0x04
    }
}

public enum A2345Port: Int, CaseIterable, Sendable, Hashable {
    case c1 = 0
    case c2
    case c3
    case c4
    case a1
    case a2

    public var label: String {
        switch self {
        case .c1: "C1"
        case .c2: "C2"
        case .c3: "C3"
        case .c4: "C4"
        case .a1: "A1"
        case .a2: "A2"
        }
    }

    public var telemetryField: UInt8 { UInt8(Int(A2345.Field.a2) + rawValue) }

    public static let usbC: [A2345Port] = [.c1, .c2, .c3, .c4]
}

public struct A2345PortReading: Sendable, Equatable {
    /// Raw byte; only 0 = inactive and 1 = active are currently established.
    public var status: UInt8
    public var millivolts: UInt16
    public var milliamps: UInt16
    public var centiwatts: UInt16
    /// Mainland firmware tail, as the official app 3.24.0 reads it. Nil when
    /// the field was too short to carry the byte.
    /// Cable: 0 = 3 A, 1 = 5 A, 2 = EPR, 3 = Huawei, 4 = Xiaomi.
    public var cable: UInt8?
    /// Private fast-charge protocol: 0 = none, 1 = Huawei SCP, 2 = Xiaomi
    /// HyperCharge.
    public var fastCharge: UInt8?
    /// Recognised device brand: 0 = unknown, 1 = Huawei/Honor, 2 = Xiaomi.
    public var deviceBrand: UInt8?

    public init(
        status: UInt8,
        millivolts: UInt16,
        milliamps: UInt16,
        centiwatts: UInt16,
        cable: UInt8? = nil,
        fastCharge: UInt8? = nil,
        deviceBrand: UInt8? = nil
    ) {
        self.status = status
        self.millivolts = millivolts
        self.milliamps = milliamps
        self.centiwatts = centiwatts
        self.cable = cable
        self.fastCharge = fastCharge
        self.deviceBrand = deviceBrand
    }

    public var isActive: Bool { status == 1 }
    public var voltage: Double { Double(millivolts) * 0.001 }
    public var current: Double { Double(milliamps) * 0.001 }
    public var power: Double { Double(centiwatts) * 0.01 }
}

/// One of the four C1...C4 raw metadata slots in field A8.
///
/// A single-device capture made `word0` match Apple's USB vendor id, but the
/// second word and the general field semantics still need another known-device
/// differential test. Keep both words deliberately unnamed so unverified
/// identity semantics cannot leak into the product UI.
public struct A2345A8Slot: Sendable, Equatable {
    public var port: A2345Port
    public var rawBytes: [UInt8]
    public var word0: UInt16
    public var word1: UInt16

    public init(port: A2345Port, rawBytes: [UInt8], word0: UInt16, word1: UInt16) {
        self.port = port
        self.rawBytes = rawBytes
        self.word0 = word0
        self.word1 = word1
    }

    public var isAllOnesSentinel: Bool { rawBytes.allSatisfy { $0 == 0xFF } }
    public var isUnidentified: Bool { rawBytes.allSatisfy { $0 == 0x00 } }
}

/// One provisional four-byte C-port metadata slot from optional field A9.
/// Semantics are intentionally not named until a single-variable device test
/// separates protocol state from advertised charging capability.
public struct A2345ProvisionalSlot: Sendable, Equatable {
    public var port: A2345Port
    public var rawBytes: [UInt8]
    public var word0: UInt16
    public var word1: UInt16

    public init(port: A2345Port, rawBytes: [UInt8], word0: UInt16, word1: UInt16) {
        self.port = port
        self.rawBytes = rawBytes
        self.word0 = word0
        self.word1 = word1
    }

    public var isAllOnesSentinel: Bool { rawBytes.allSatisfy { $0 == 0xFF } }
    public var isUnidentified: Bool { rawBytes.allSatisfy { $0 == 0x00 } }
}

public struct A2345RealtimeTelemetry: Sendable, Equatable {
    public var responseMarker: UInt8?
    public var ports: [A2345Port: A2345PortReading]
    public var a8Slots: [A2345A8Slot]
    /// Nil on firmware that predates A9. Present sentinels remain in the array.
    public var provisionalSlots: [A2345ProvisionalSlot]?
    public var timestamp: UInt32?
    public var unknownFields: [A2345TLV]

    public init(
        responseMarker: UInt8?,
        ports: [A2345Port: A2345PortReading],
        a8Slots: [A2345A8Slot],
        provisionalSlots: [A2345ProvisionalSlot]?,
        timestamp: UInt32?,
        unknownFields: [A2345TLV]
    ) {
        self.responseMarker = responseMarker
        self.ports = ports
        self.a8Slots = a8Slots
        self.provisionalSlots = provisionalSlots
        self.timestamp = timestamp
        self.unknownFields = unknownFields
    }
}

public struct A2345VersionInfo: Sendable, Equatable {
    public var hardwareVersion: String
    public var softwareVersion: String
    public var productCode: String?
    public var mcuComponent: String?
    public var esp32Component: String?
    public var unknownFields: [A2345TLV]

    public init(
        hardwareVersion: String,
        softwareVersion: String,
        productCode: String?,
        mcuComponent: String?,
        esp32Component: String?,
        unknownFields: [A2345TLV]
    ) {
        self.hardwareVersion = hardwareVersion
        self.softwareVersion = softwareVersion
        self.productCode = productCode
        self.mcuComponent = mcuComponent
        self.esp32Component = esp32Component
        self.unknownFields = unknownFields
    }
}

/// The `0A00` full-device response. A4...A9 reuse the seven-byte port shape
/// and map to C1, C2, C3, C4, A1 and A2; every other field is decoded into
/// `settings` the way the official app 3.24.0 reads it. `unknownFields` keeps
/// all non-port fields in wire form.
public struct A2345StatusSnapshot: Sendable, Equatable {
    public var ports: [A2345Port: A2345PortReading]
    public var settings: A2345DeviceSettings
    public var unknownFields: [A2345TLV]

    public init(
        ports: [A2345Port: A2345PortReading],
        settings: A2345DeviceSettings = A2345DeviceSettings(),
        unknownFields: [A2345TLV]
    ) {
        self.ports = ports
        self.settings = settings
        self.unknownFields = unknownFields
    }
}

public struct A2345Acknowledgement: Sendable, Equatable {
    public var messageType: UInt16
    public var increment: UInt8?
    /// Captured value `0x34` is kept as a marker, not labelled success/error.
    public var marker: UInt8

    public init(messageType: UInt16, increment: UInt8?, marker: UInt8) {
        self.messageType = messageType
        self.increment = increment
        self.marker = marker
    }
}

public enum A2345DecodedMessage: Sendable, Equatable {
    case realtime(A2345RealtimeTelemetry)
    case statusSnapshot(A2345StatusSnapshot)
    case versionInfo(A2345VersionInfo)
    case settingsUpdate([A2345SettingsUpdate])
    case acknowledgement(A2345WriteAcknowledgement)
    case unknown(A2345Frame)
}

public enum A2345MessageError: Error, Sendable, Equatable {
    case missingField(UInt8)
    case duplicateField(UInt8)
    case invalidFieldLength(id: UInt8, expected: Int, actual: Int)
    case unexpectedFieldType(id: UInt8, expected: UInt8, actual: UInt8?)
    case invalidUTF8(UInt8)
    case invalidAcknowledgementLength(Int)
    case unexpectedMessageType(expected: UInt16, actual: UInt16)
}

public enum A2345MessageDecoder {
    public static func decode(_ frame: A2345Frame) throws -> A2345DecodedMessage {
        switch frame.messageType {
        case A2345.MessageType.realtime:
            return .realtime(try decodeRealtime(frame))
        case A2345.MessageType.statusSnapshot:
            return .statusSnapshot(try decodeStatusSnapshot(frame))
        case A2345.MessageType.versionInfo:
            return .versionInfo(try decodeVersionInfo(frame))
        default:
            if let updates = A2345SettingsDecoder.updates(from: frame) {
                return .settingsUpdate(updates)
            }
            if let acknowledgement = A2345SettingsDecoder.acknowledgement(from: frame) {
                return .acknowledgement(acknowledgement)
            }
            return .unknown(frame)
        }
    }

    public static func decodeRealtime(_ frame: A2345Frame) throws -> A2345RealtimeTelemetry {
        guard frame.messageType == A2345.MessageType.realtime else {
            throw A2345MessageError.unexpectedMessageType(
                expected: A2345.MessageType.realtime,
                actual: frame.messageType
            )
        }

        var ports: [A2345Port: A2345PortReading] = [:]
        for port in A2345Port.allCases {
            let field = try requiredField(port.telemetryField, in: frame)
            ports[port] = try decodePortReading(field)
        }

        // A8/A9 are metadata, not electrical readings. Firmware already ships
        // both with and without A9, so a new type/length (or a duplicate field)
        // must not discard otherwise valid six-port telemetry. A successfully
        // decoded optional field is marked consumed; anything else stays in
        // `unknownFields` with its raw bytes intact for later differential work.
        var consumedOptionalIndexes = Set<Int>()

        let a8Slots: [A2345A8Slot]
        if let decoded = decodeOptionalFixedSlotBytes(
            id: A2345.Field.a8,
            in: frame,
            consumedIndexes: &consumedOptionalIndexes
        ) {
            a8Slots = A2345Port.usbC.enumerated().map { index, port in
                let raw = Array(decoded[(index * 4)..<(index * 4 + 4)])
                return A2345A8Slot(
                    port: port,
                    rawBytes: raw,
                    word0: littleEndianUInt16(raw, at: 0),
                    word1: littleEndianUInt16(raw, at: 2)
                )
            }
        } else {
            a8Slots = []
        }

        let provisionalSlots: [A2345ProvisionalSlot]?
        if let decoded = decodeOptionalFixedSlotBytes(
            id: A2345.Field.a9,
            in: frame,
            consumedIndexes: &consumedOptionalIndexes
        ) {
            provisionalSlots = A2345Port.usbC.enumerated().map { index, port in
                let raw = Array(decoded[(index * 4)..<(index * 4 + 4)])
                return A2345ProvisionalSlot(
                    port: port,
                    rawBytes: raw,
                    word0: littleEndianUInt16(raw, at: 0),
                    word1: littleEndianUInt16(raw, at: 2)
                )
            }
        } else {
            provisionalSlots = nil
        }

        let responseMarker: UInt8?
        let markerMatches = frame.fields.enumerated().filter { $0.element.id == A2345.Field.a1 }
        if markerMatches.count == 1, markerMatches[0].element.rawValue.count == 1 {
            consumedOptionalIndexes.insert(markerMatches[0].offset)
            responseMarker = markerMatches[0].element.rawValue[0]
        } else {
            responseMarker = nil
        }

        let timestamp: UInt32?
        let timestampMatches = frame.fields.enumerated().filter {
            $0.element.id == A2345.Field.timestamp
        }
        if timestampMatches.count == 1,
           timestampMatches[0].element.rawValue.count == 5,
           timestampMatches[0].element.rawValue[0] == A2345.ValueType.variable {
            consumedOptionalIndexes.insert(timestampMatches[0].offset)
            timestamp = littleEndianUInt32(
                Array(timestampMatches[0].element.rawValue.dropFirst()),
                at: 0
            )
        } else {
            timestamp = nil
        }

        let coreFields = Set(A2345Port.allCases.map(\.telemetryField))

        return A2345RealtimeTelemetry(
            responseMarker: responseMarker,
            ports: ports,
            a8Slots: a8Slots,
            provisionalSlots: provisionalSlots,
            timestamp: timestamp,
            unknownFields: frame.fields.enumerated().compactMap { index, field in
                guard !coreFields.contains(field.id),
                      !consumedOptionalIndexes.contains(index) else { return nil }
                return field
            }
        )
    }

    public static func decodeStatusSnapshot(_ frame: A2345Frame) throws -> A2345StatusSnapshot {
        guard frame.messageType == A2345.MessageType.statusSnapshot else {
            throw A2345MessageError.unexpectedMessageType(
                expected: A2345.MessageType.statusSnapshot,
                actual: frame.messageType
            )
        }

        var ports: [A2345Port: A2345PortReading] = [:]
        var known = Set<UInt8>()
        for (offset, port) in A2345Port.allCases.enumerated() {
            let id = UInt8(Int(A2345.Field.a4) + offset)
            ports[port] = try decodePortReading(try requiredField(id, in: frame))
            known.insert(id)
        }
        return A2345StatusSnapshot(
            ports: ports,
            settings: A2345SettingsDecoder.settings(from: frame),
            unknownFields: frame.fields.filter { !known.contains($0.id) }
        )
    }

    private static func decodeOptionalFixedSlotBytes(
        id: UInt8,
        in frame: A2345Frame,
        consumedIndexes: inout Set<Int>
    ) -> [UInt8]? {
        let matches = frame.fields.enumerated().filter { $0.element.id == id }
        guard matches.count == 1 else { return nil }
        let match = matches[0]
        guard match.element.rawValue.count == 17,
              match.element.rawValue.first == A2345.ValueType.binary else { return nil }
        consumedIndexes.insert(match.offset)
        return Array(match.element.rawValue.dropFirst())
    }

    /// Mainland firmware 1.4.0.2 appends three bytes to every port field
    /// (cable rating, private fast-charge protocol, recognised device brand).
    /// The official app 3.24.0 reads both shapes by length alone, with the
    /// same first seven bytes, so a longer field must not drop the frame.
    private static func decodePortReading(_ field: A2345TLV) throws -> A2345PortReading {
        let value = try typedPayload(
            field,
            type: A2345.ValueType.binary,
            minimumPayloadLength: 7
        )
        // Same length gates as the official parser: the cable and protocol
        // bytes need a payload longer than 8, the brand one longer than 9.
        return A2345PortReading(
            status: value[0],
            millivolts: littleEndianUInt16(value, at: 1),
            milliamps: littleEndianUInt16(value, at: 3),
            centiwatts: littleEndianUInt16(value, at: 5),
            cable: value.count > 8 ? value[7] : nil,
            fastCharge: value.count > 8 ? value[8] : nil,
            deviceBrand: value.count > 9 ? value[9] : nil
        )
    }

    public static func decodeVersionInfo(_ frame: A2345Frame) throws -> A2345VersionInfo {
        guard frame.messageType == A2345.MessageType.versionInfo else {
            throw A2345MessageError.unexpectedMessageType(
                expected: A2345.MessageType.versionInfo,
                actual: frame.messageType
            )
        }

        let hardware = try string(try requiredField(A2345.Field.a1, in: frame))
        var software = try string(try requiredField(A2345.Field.a2, in: frame))
        if software.hasPrefix("v") { software.removeFirst() }
        let product = try optionalField(A2345.Field.a3, in: frame).map(string)
        let mcu = try optionalField(A2345.Field.a4, in: frame).map(string)
        let esp32 = try optionalField(A2345.Field.a5, in: frame).map(string)
        let known = Set([A2345.Field.a1, A2345.Field.a2, A2345.Field.a3, A2345.Field.a4, A2345.Field.a5])

        return A2345VersionInfo(
            hardwareVersion: hardware,
            softwareVersion: software,
            productCode: product,
            mcuComponent: mcu,
            esp32Component: esp32,
            unknownFields: frame.fields.filter { !known.contains($0.id) }
        )
    }

    public static func decodeAcknowledgement(_ frame: A2345Frame) throws -> A2345Acknowledgement {
        guard A2345.MessageType.relatedAcknowledgements.contains(frame.messageType) else {
            throw A2345MessageError.unexpectedMessageType(
                expected: A2345.MessageType.realtimeAcknowledgement,
                actual: frame.messageType
            )
        }
        guard frame.encodedLength == 14 else {
            throw A2345MessageError.invalidAcknowledgementLength(frame.encodedLength)
        }
        let field = try requiredField(A2345.Field.a1, in: frame)
        guard field.rawValue.count == 1 else {
            throw A2345MessageError.invalidFieldLength(
                id: field.id,
                expected: 1,
                actual: field.rawValue.count
            )
        }
        return A2345Acknowledgement(
            messageType: frame.messageType,
            increment: frame.increment,
            marker: field.rawValue[0]
        )
    }

    private static func requiredField(_ id: UInt8, in frame: A2345Frame) throws -> A2345TLV {
        guard let field = try optionalField(id, in: frame) else {
            throw A2345MessageError.missingField(id)
        }
        return field
    }

    private static func optionalField(_ id: UInt8, in frame: A2345Frame) throws -> A2345TLV? {
        let matches = frame.fields.filter { $0.id == id }
        guard matches.count <= 1 else { throw A2345MessageError.duplicateField(id) }
        return matches.first
    }

    private static func typedPayload(
        _ field: A2345TLV,
        type: UInt8,
        minimumPayloadLength: Int
    ) throws -> [UInt8] {
        guard field.rawValue.first == type else {
            throw A2345MessageError.unexpectedFieldType(
                id: field.id,
                expected: type,
                actual: field.rawValue.first
            )
        }
        guard field.rawValue.count >= minimumPayloadLength + 1 else {
            throw A2345MessageError.invalidFieldLength(
                id: field.id,
                expected: minimumPayloadLength + 1,
                actual: field.rawValue.count
            )
        }
        return Array(field.rawValue.dropFirst())
    }

    /// Version strings arrive both with a leading 0x00 type byte and without
    /// one (`a1 08 76 30 2e 32 …` in a capture of the official app); printable
    /// first bytes are kept.
    private static func string(_ field: A2345TLV) throws -> String {
        guard let first = field.rawValue.first,
              first == A2345.ValueType.string || first >= 0x20 else {
            throw A2345MessageError.unexpectedFieldType(
                id: field.id,
                expected: A2345.ValueType.string,
                actual: field.rawValue.first
            )
        }
        var bytes = first == A2345.ValueType.string
            ? Array(field.rawValue.dropFirst())
            : field.rawValue
        while bytes.last == 0 { bytes.removeLast() }
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw A2345MessageError.invalidUTF8(field.id)
        }
        return value
    }

    private static func littleEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
