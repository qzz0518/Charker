import Foundation

/// Byte-exact captures from the pinned reference commits.
///
/// The frames come from `flip-dots/SolixBLE@bb2d398` `tests/const.py`
/// (`NEGOTIATION_RESPONSES_PRIME`, recorded from a real Anker Prime 160W). The
/// plaintexts are what those frames decrypt to under the firmware's static
/// negotiation key — they are the ground truth this client is written against.
///
/// Note that the base-info capture embeds the serial number and Bluetooth address
/// of *that project author's* charger, not of any unit belonging to this project.
/// Those bytes are already public under MIT in the source linked above, and they
/// cannot be altered here: the frame checksum and the AES-GCM tag are computed
/// over them, so editing a byte would destroy the vector's whole purpose.
enum Fixtures {
    static let clientInitialConnect =
        "ff09200003000140010a82d0ab535303e3aa9f0c2f9c868465bc8476f556fb7d"
    static let clientCapability =
        "ff09270003000140030a82d0ab53538ab3de100ac9bb87a0b8e36c1dd8167a9c25a9839d9a14d5"
    static let clientBaseInfo =
        "ff09200003000140290a82d0ab535303e3aa9f0c2f9c868465bc8476f556fb55"

    static let deviceInitialConnect = "ff091e000300014801ab273ed3e27270c3f4d676ac7d69a00572793732a6"
    static let deviceCapability =
        "ff092b000300014803ab273ed0443800b35db54c6d4a6ec3d48171a04ea7ebce8bf749e5e48c5d991a5e67"
    static let deviceBaseInfo =
        "ff0958000300014829ab273ed144326ada9fc66fa02508c5ddf549ade014d1eeb252fea1057c15b00985ab8a724fa3830e8e5b27acbaa1224fd2172c0439d27aaf9e62a66bda5c41c424f23c5c8d7df8d3b89422ddff2266"
    static let deviceSetCapability = "ff091b000300014805abab709a595a803dd04246b78a927453cf65"
    static let devicePublicKey =
        "ff095d000300014821ab277fc01de436d341de628c79c1384d0aea25ce030622fa3ca0808ce5d1b7365ec1b1753a11ab78fba3ca07dda95cd57c93d1267b1222bef9908f7633a758ab924eba63ee01e715be5b9c3b082e6d81c2204241"

    // Decrypted payloads, verified against the frames above.
    static let plainClientInitialConnect = "a104ef79b569"
    static let plainClientCapability = "a104ef79b569a30120a40200f0"
    static let plainDeviceInitialConnect = "00a10101"
    static let plainDeviceCapability = "00a10102a2022901a30144a40101a50102"
    static let plainDeviceBaseInfo =
        "00a10103a2084368617267696e67a30876302e302e352e30a411415348444b375531463531353031373731a5117ce9138146025531463531353031373731"
    static let plainDeviceSetCapability = "00"
    static let plainDevicePublicKey =
        "00a14012fbde1f61bf6a6a4532ae5e988993a61e39e2e278ca4f60dad1804c088e5b7d324487184742cfdc0e767497892fc2ff7773866d2052c2182adecad4e29e3dd4"
}

extension String {
    var hexBytes: [UInt8] {
        var out: [UInt8] = []
        var index = startIndex
        while index < endIndex, let next = self.index(index, offsetBy: 2, limitedBy: endIndex) {
            out.append(UInt8(self[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }
}

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
