import Foundation

/// GATT identifiers, logical opcodes and TLV ids used by the A2687.
///
/// All values are cross-checked between the pinned SolixBLE commit
/// `bb2d398` and the pinned WebBLE commit `ad4355d`.
public enum A2687 {
    /// Advertised 16-bit service. Shared across the Anker Solix/Prime family,
    /// so it is a discovery filter, not proof of model.
    public static let advertisedService = "FF09"
    public static let primaryService = "8C850001-0302-41C5-B46E-CF057C562025"
    public static let writeCharacteristic = "8C850002-0302-41C5-B46E-CF057C562025"
    public static let notifyCharacteristic = "8C850003-0302-41C5-B46E-CF057C562025"

    /// Observed advertised-name prefix. A candidate hint only.
    public static let namePrefix = "ASHDJW"

    public enum Opcode {
        // Negotiation (group 0x01)
        public static let initialConnect: UInt16 = 0x0001
        public static let capability: UInt16 = 0x0003
        public static let setCapability: UInt16 = 0x0005
        public static let publicKey: UInt16 = 0x0021
        public static let aesMetadata: UInt16 = 0x0022
        public static let userAuth: UInt16 = 0x0027
        public static let baseInfo: UInt16 = 0x0029

        // Session (group 0x0F)
        public static let readAll: UInt16 = 0x0200
        /// Display language (`A2 = typed u8`). Confirmed on firmware v0.0.5.2.
        public static let deviceLanguage: UInt16 = 0x0202
        /// Display auto-lock interval (`A2 = typed u8`). Confirmed on firmware v0.0.5.2.
        public static let screenTimeout: UInt16 = 0x0203
        /// Display brightness percent (`A2 = typed u8`). Confirmed on firmware v0.0.5.2.
        public static let screenBrightness: UInt16 = 0x0204
        public static let bindSuccess: UInt16 = 0x020A
        /// The enable that actually starts the ~1 Hz per-port stream. A plain
        /// `0x0200` subscribe is enough on some firmware; hardened builds stay
        /// silent until this is sent.
        public static let realtimeTrigger: UInt16 = 0x020B
        /// Manual display orientation. This intentionally shares `0x020B` with
        /// `realtimeTrigger`; the typed-u8 `A2` payload distinguishes the write
        /// from the trigger's typed byte block.
        public static let screenOrientation: UInt16 = 0x020B
        public static let portHistory: UInt16 = 0x020C
        /// Enables or disables gyroscope-driven display rotation.
        public static let gyroscope: UInt16 = 0x020D
        public static let realtimeReport: UInt16 = 0x0300

        /// Selects which screensaver the display shows. Also the command that
        /// names a custom cover by its cloud id — the pixels themselves go up
        /// separately through `coverTransferStart` / `coverTransferChunk`.
        public static let setScreensaver: UInt16 = 0x021F
        /// Announces a cover upload: id, hash, byte count, chunk geometry.
        public static let coverTransferStart: UInt16 = 0x0220
        /// One 156-byte slice of the JPEG.
        ///
        /// Evidence for this whole trio is weaker than for the rest of this file
        /// and is worth stating plainly: the byte layout was recovered by a third
        /// party (LYJW131/anker-prime-ble @ f23a07d) exploiting this firmware's
        /// reused GCM nonce to XOR against a known `0x021F` plaintext, on one
        /// machine and one firmware — not by decrypting a capture of our own. It
        /// is corroborated only indirectly here: the matching action names
        /// (`action_start_transfer_screen_saver_image`, `action_transfer_screen_saver_image`)
        /// and the `SmallChargingUrl` literal do appear in the official app's
        /// 3.23.0 binary, and the three plaintext lengths add up. That makes the
        /// shape credible, not confirmed.
        public static let coverTransferChunk: UInt16 = 0x0221

        // Writes. Implemented but gated; see `CommandEncoder`.
        public static let portOutput: UInt16 = 0x0207
        public static let portTimer: UInt16 = 0x0209
        public static let fixedAllocation: UInt16 = 0x0205
        public static let chargingMode: UInt16 = 0x0206
    }

    /// TLV identifiers. `A1` is the action/sequence slot in nearly every message.
    public enum Field {
        public static let a1: UInt8 = 0xA1
        public static let a2: UInt8 = 0xA2
        public static let a3: UInt8 = 0xA3
        public static let a4: UInt8 = 0xA4
        public static let a5: UInt8 = 0xA5
        public static let a6: UInt8 = 0xA6
        public static let a7: UInt8 = 0xA7
        /// Display auto-lock enum in the handshake settings snapshot.
        public static let a8: UInt8 = 0xA8
        /// Manual/current display orientation in the handshake settings snapshot.
        public static let af: UInt8 = 0xAF
        public static let ac: UInt8 = 0xAC
        public static let ad: UInt8 = 0xAD
        public static let ae: UInt8 = 0xAE
        /// Carries the screensaver's URL slot. Only ever seen holding the literal
        /// `SmallChargingUrl` — see `CoverCommands.urlPlaceholder`.
        public static let fd: UInt8 = 0xFD
        /// Replay-protection epoch appended to every session command.
        public static let timestamp: UInt8 = 0xFE
    }

    /// Session commands carry `A1 = 0x21` as their action selector.
    public static let sessionAction: UInt8 = 0x21

    public enum Port: Int, CaseIterable, Sendable {
        case c1 = 0, c2 = 1, c3 = 2

        public var label: String { "C\(rawValue + 1)" }
        /// TLV id holding this port's live `[status, mV, mA, cW]` struct.
        public var telemetryField: UInt8 { [Field.a5, Field.a6, Field.a7][rawValue] }
        /// TLV id holding this port's cable/protocol control struct.
        public var cableField: UInt8 { [Field.ac, Field.ad, Field.ae][rawValue] }
    }
}
