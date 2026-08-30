import Foundation

/// A `UserDefaults` that lives entirely in memory.
///
/// The obvious test double — `UserDefaults(suiteName: UUID().uuidString)` —
/// looks disposable but is not: `removePersistentDomain(forName:)` empties the
/// domain without removing the file cfprefsd already wrote for it, so every run
/// of the suite left one more empty plist in ~/Library/Preferences. Several
/// hundred had accumulated there.
///
/// Every accessor `PreferencesStore` and its tests reach for is overridden, so
/// no read or write ever descends to the inherited domain. `testIsolation`
/// guards that: add a store call that is not overridden here and it fails
/// rather than quietly writing into the real defaults.
final class MemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

    override func string(forKey defaultName: String) -> String? {
        storage[defaultName] as? String
    }

    override func integer(forKey defaultName: String) -> Int {
        // Matches UserDefaults: a string that reads as a number counts, and
        // anything else is 0. Launch arguments arrive as strings, and the poll
        // interval floor is exercised through exactly that path.
        switch storage[defaultName] {
        case let value as Int: return value
        case let value as Double: return Int(value)
        case let value as Bool: return value ? 1 : 0
        case let value as String: return Int(value) ?? 0
        default: return 0
        }
    }

    override func bool(forKey defaultName: String) -> Bool {
        switch storage[defaultName] {
        case let value as Bool: return value
        case let value as Int: return value != 0
        case let value as String: return (value as NSString).boolValue
        default: return false
        }
    }

    override func stringArray(forKey defaultName: String) -> [String]? {
        storage[defaultName] as? [String]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func set(_ value: Int, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func set(_ value: Double, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }
}
