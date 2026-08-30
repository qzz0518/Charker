import Foundation

/// Redaction helpers for anything that may reach a log file or a diagnostics export.
///
/// Session keys, nonces, shared secrets and ECDH private keys are never passed
/// through here — they simply never leave ``A2687Crypto``.
public enum Redact {
    /// `ASHDEXAMPLE000001` -> `ASHD…0001`
    public static func identifier(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        guard value.count > 8 else { return String(repeating: "•", count: value.count) }
        return "\(value.prefix(4))…\(value.suffix(4))"
    }

    /// `AA:BB:CC:DD:EE:FF` -> `AA:BB:••:••:••:FF`
    public static func mac(_ value: String?) -> String {
        guard let value else { return "—" }
        let parts = value.split(separator: ":")
        guard parts.count == 6 else { return identifier(value) }
        return "\(parts[0]):\(parts[1]):••:••:••:\(parts[5])"
    }

    /// Payload bytes are summarised, never dumped, unless raw capture is explicitly enabled.
    public static func payload(_ bytes: [UInt8], rawAllowed: Bool) -> String {
        guard rawAllowed else { return "\(bytes.count) B" }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func opcode(_ value: UInt16) -> String {
        String(format: "0x%04X", value)
    }
}
