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
                usbProductID: nil
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
                power: value.power
            )
        }
        self.init(product: .a2345, ports: ports, receivedAt: receivedAt)
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
