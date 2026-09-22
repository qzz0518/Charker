import Foundation

/// A 160 W charger this Mac has monitored before.
///
/// Several can be saved — one at home, one at the office — and the session
/// reconnects to whichever of them is in range. Nothing here is secret: the
/// identifier is CoreBluetooth's per-Mac handle and the serial number is public
/// device metadata, the same class of value `a2345SelectedSerial` stores.
public struct SavedCharger: Codable, Sendable, Equatable, Identifiable {
    /// CoreBluetooth's per-Mac identifier, the key the transport reconnects by.
    public var id: UUID
    /// The user's name for this charger ("家里", "办公室"). Empty means unnamed.
    public var nickname: String
    /// From the handshake's base info. It lets a charger whose CoreBluetooth
    /// identifier changed (the system forgot it) rejoin its old entry, name and
    /// all, instead of appearing twice.
    public var serialNumber: String?
    public var lastConnectedAt: Date?

    /// Long enough for any real place name, short enough for the menu bar.
    public static let nicknameLimit = 24

    public init(
        id: UUID,
        nickname: String = "",
        serialNumber: String? = nil,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.nickname = Self.normalizedNickname(nickname)
        self.serialNumber = serialNumber
        self.lastConnectedAt = lastConnectedAt
    }

    /// Fields added later decode with defaults, so a newer build's list never
    /// empties an older one's.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        nickname = Self.normalizedNickname(
            try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        )
        serialNumber = try container.decodeIfPresent(String.self, forKey: .serialNumber)
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }

    /// What lists and menus call this charger: the user's name, else the
    /// product name plus the end of the serial, so two unnamed chargers of the
    /// same model still read differently.
    public var displayName: String {
        if !nickname.isEmpty { return nickname }
        let product = ChargerProduct.a2687.displayName
        guard let serialNumber, serialNumber.count >= 4 else { return product }
        return "\(product) · \(serialNumber.suffix(4))"
    }

    public static func normalizedNickname(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return String(trimmed.prefix(nicknameLimit))
    }
}

public extension Array where Element == SavedCharger {
    func charger(_ id: UUID?) -> SavedCharger? {
        guard let id else { return nil }
        return first { $0.id == id }
    }

    /// Most recently used first, so a reconnect tries the likeliest charger
    /// first and the list reads in the order the user actually moves between
    /// places. Never-connected entries keep their saved order at the end.
    var reconnectOrder: [UUID] {
        enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.lastConnectedAt, rhs.element.lastConnectedAt) {
                case let (l?, r?) where l != r: return l > r
                case (.some, nil): return true
                case (nil, .some): return false
                default: return lhs.offset < rhs.offset
                }
            }
            .map(\.element.id)
    }

    /// Adds a charger that just reached live monitoring, or refreshes the one
    /// already saved. A different identifier carrying a known serial is the same
    /// charger after the system forgot it: it takes over that entry and keeps
    /// the name the user gave it.
    mutating func recordConnection(id: UUID, serialNumber: String?, at date: Date) {
        let serial = serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownSerial = (serial?.isEmpty == false) ? serial : nil
        if let index = firstIndex(where: { $0.id == id }) {
            self[index].lastConnectedAt = date
            if let knownSerial { self[index].serialNumber = knownSerial }
            if let knownSerial,
               let twin = firstIndex(where: { $0.id != id && $0.serialNumber == knownSerial }) {
                if self[index].nickname.isEmpty { self[index].nickname = self[twin].nickname }
                remove(at: twin)
            }
            return
        }
        if let knownSerial, let twin = firstIndex(where: { $0.serialNumber == knownSerial }) {
            self[twin].id = id
            self[twin].lastConnectedAt = date
            return
        }
        append(SavedCharger(id: id, serialNumber: knownSerial, lastConnectedAt: date))
    }

    mutating func rename(_ id: UUID, to nickname: String) {
        guard let index = firstIndex(where: { $0.id == id }) else { return }
        self[index].nickname = SavedCharger.normalizedNickname(nickname)
    }

    mutating func forget(_ id: UUID) {
        removeAll { $0.id == id }
    }
}

public extension SavedCharger {
    static func encodeList(_ chargers: [SavedCharger]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(chargers) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Entry by entry: one damaged record is dropped, the rest survive. Nil only
    /// when the text is not a JSON array at all.
    static func decodeList(_ json: String) -> [SavedCharger]? {
        struct Lenient: Decodable {
            var charger: SavedCharger?
            init(from decoder: Decoder) throws {
                charger = try? SavedCharger(from: decoder)
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let entries = try? decoder.decode([Lenient].self, from: Data(json.utf8)) else {
            return nil
        }
        var seen = Set<UUID>()
        return entries.compactMap(\.charger).filter { seen.insert($0.id).inserted }
    }
}
