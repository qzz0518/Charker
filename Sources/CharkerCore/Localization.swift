import Foundation

/// Shared localization lookup for text produced outside SwiftUI.
///
/// Product bundles use `Bundle.main`; tests and previews may inject a fixture
/// bundle. Missing entries deliberately fall back to the key itself, which lets
/// the existing Simplified Chinese source copy remain the no-resource fallback.
public enum L10n {
    /// `Bundle.localizedString` takes a lock and walks a per-table string map on
    /// every call, and view bodies call it dozens of times each — the power
    /// chart alone asks for six labels per plotted sample. A sampled run spent
    /// roughly a sixth of the main thread inside these two functions, so main
    /// bundle lookups are memoised for the life of the process.
    ///
    /// Only `Bundle.main` is cached. The app has no in-app language switch, so
    /// its tables cannot change while it runs; an injected fixture bundle stays
    /// uncached so tests keep seeing live lookups.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: String] = [:]
    nonisolated(unsafe) private static var mainLocale: Locale?

    private struct Key: Hashable {
        let table: String
        let key: String
    }

    /// The app can have a per-app language that differs from the Mac's region.
    /// Bundle preference therefore wins; `Locale.current` remains the fallback
    /// for test bundles without localization metadata.
    public static func locale(for bundle: Bundle = .main) -> Locale {
        guard bundle === Bundle.main else { return resolveLocale(bundle) }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let mainLocale { return mainLocale }
        let resolved = resolveLocale(bundle)
        mainLocale = resolved
        return resolved
    }

    private static func resolveLocale(_ bundle: Bundle) -> Locale {
        guard let identifier = bundle.preferredLocalizations.first, !identifier.isEmpty else {
            return .current
        }
        return Locale(identifier: identifier)
    }

    public static func text(
        _ key: String,
        table: String = "Localizable",
        bundle: Bundle = .main
    ) -> String {
        guard bundle === Bundle.main else {
            return bundle.localizedString(forKey: key, value: key, table: table)
        }
        let cacheKey = Key(table: table, key: key)
        cacheLock.lock()
        if let hit = cache[cacheKey] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        // Resolved outside the lock: the bundle takes its own, and holding both
        // would put a UI-thread lookup behind a background one.
        let resolved = bundle.localizedString(forKey: key, value: key, table: table)
        cacheLock.lock()
        cache[cacheKey] = resolved
        cacheLock.unlock()
        return resolved
    }

    public static func format(
        _ key: String,
        _ arguments: CVarArg...,
        table: String = "Localizable",
        bundle: Bundle = .main
    ) -> String {
        String(
            format: text(key, table: table, bundle: bundle),
            locale: locale(for: bundle),
            arguments: arguments
        )
    }
}
