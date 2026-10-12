import A2345Protocol
import A2687Protocol
import Foundation

public extension ChargerReading {
    init(a2345 telemetry: A2345RealtimeTelemetry, receivedAt: Date = Date()) {
        let ports = A2345Port.allCases.compactMap { source -> ChargerPortReading? in
            guard let value = telemetry.ports[source],
                  let port = ChargerPortID(rawValue: source.rawValue) else { return nil }
            return ChargerPortReading(
                port: port,
                // Only 0 and 1 have been established on wire. The shared
                // model treats any non-zero status as on, so normalize an
                // unknown future status to off instead of inventing output.
                statusCode: value.isActive ? 1 : 0,
                voltage: value.voltage,
                current: value.current,
                power: value.power,
                // A8's two words are still only a high-confidence identity
                // candidate. Do not expose them through the confirmed USB
                // VID/PID surface until a second known-brand differential test.
                usbVendorID: nil,
                usbProductID: nil,
                cable: Self.cable(value, on: source),
                fastCharge: Self.fastCharge(value),
                deviceBrand: Self.deviceBrand(value)
            )
        }
        self.init(product: .a2345, ports: ports, receivedAt: receivedAt)
    }

    init(a2345 snapshot: A2345StatusSnapshot, receivedAt: Date = Date()) {
        let ports = A2345Port.allCases.compactMap { source -> ChargerPortReading? in
            guard let value = snapshot.ports[source],
                  let port = ChargerPortID(rawValue: source.rawValue) else { return nil }
            return ChargerPortReading(
                port: port,
                statusCode: value.isActive ? 1 : 0,
                voltage: value.voltage,
                current: value.current,
                power: value.power,
                cable: Self.cable(value, on: source),
                fastCharge: Self.fastCharge(value),
                deviceBrand: Self.deviceBrand(value)
            )
        }
        self.init(product: .a2345, ports: ports, receivedAt: receivedAt)
    }

    // The official app only shows the cable for C1...C4, and an idle port
    // reports zeros, which would otherwise read as a 3 A cable.
    private static func cable(_ value: A2345PortReading, on port: A2345Port) -> PortCable? {
        guard value.isActive, A2345Port.usbC.contains(port) else { return nil }
        return value.cable.flatMap(PortCable.init(rawValue:))
    }

    private static func fastCharge(_ value: A2345PortReading) -> PortFastCharge? {
        guard value.isActive else { return nil }
        return value.fastCharge.flatMap(PortFastCharge.init(rawValue:))
    }

    private static func deviceBrand(_ value: A2345PortReading) -> PortDeviceBrand? {
        guard value.isActive else { return nil }
        return value.deviceBrand.flatMap(PortDeviceBrand.init(rawValue:))
    }

    init(a2687 telemetry: ChargerTelemetry) {
        let ports = A2687.Port.allCases.compactMap { source -> ChargerPortReading? in
            guard let value = telemetry.port(source),
                  let port = ChargerPortID(rawValue: source.rawValue) else { return nil }
            let identity = value.connectedDevice
            let hasNamedIdentity = identity.map {
                !$0.isNoIdentity && !$0.isUnidentified
            } ?? false
            return ChargerPortReading(
                port: port,
                statusCode: value.statusCode,
                voltage: value.voltage,
                current: value.current,
                power: value.power,
                usbVendorID: hasNamedIdentity ? identity?.vendorID : nil,
                usbProductID: hasNamedIdentity ? identity?.productID : nil
            )
        }
        self.init(product: .a2687, ports: ports, receivedAt: telemetry.receivedAt)
    }
}
