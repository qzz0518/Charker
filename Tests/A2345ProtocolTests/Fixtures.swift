import Foundation

/// De-identified byte-exact fixtures shaped from the verified A2345 captures.
/// Values intentionally contain no serial number, account, token or MQTT topic.
enum A2345Fixtures {
    /// Firmware without optional field A9.
    static let realtimeOldFirmware =
        "ff09640003010f030301a10134a2080401883a60065009a3080400000000000000a4080401881314000a00a5080400000000000000a6080400000000000000a7080400000000000000a81104ac05a8120000000000000000fffffffffe0503785634125d"

    /// Same snapshot shape with the newer optional four-slot A9 field.
    static let realtimeNewFirmware =
        "ff09770003010f030302a10134a2080401883a60065009a3080400000000000000a4080401881314000a00a5080400000000000000a6080400000000000000a7080400000000000000a81104ac05a8120000000000000000ffffffffa9110401001f00ffffffff00000000fffffffffe050378563412ef"

    /// Captured 62-byte 0830 shape: versions plus product/MCU/ESP32 labels.
    static let versionInfo =
        "ff093e0003010f0830a10600312e302e30a20800322e312e312e36a306004132333435a40a0041323334355f6d6375a50c0041323334355f657370333214"

    /// Captured 14-byte 0A0B shape. Marker 0x34 has no success/error label.
    static let realtimeAcknowledgement = "ff090e0003010f0a0b00a1013460"
}

extension String {
    var a2345HexBytes: [UInt8] {
        var bytes: [UInt8] = []
        var index = startIndex
        while index < endIndex,
              let next = self.index(index, offsetBy: 2, limitedBy: endIndex) {
            guard let byte = UInt8(self[index..<next], radix: 16) else {
                preconditionFailure("invalid fixture hex")
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
