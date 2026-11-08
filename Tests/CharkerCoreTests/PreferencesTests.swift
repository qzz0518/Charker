import Foundation
import XCTest
@testable import CharkerCore

final class LightweightPreferencesTests: XCTestCase {
    func testLightweightModeIsOnByDefault() {
        let prefs = PreferencesStore(defaults: MemoryDefaults()).load()
        XCTAssertTrue(prefs.lightweightModeEnabled)
    }

    func testLightweightModeRoundTrips() {
        let defaults = MemoryDefaults()
        let store = PreferencesStore(defaults: defaults)
        var prefs = store.load()
        prefs.lightweightModeEnabled = false
        store.save(prefs)

        XCTAssertFalse(PreferencesStore(defaults: defaults).load().lightweightModeEnabled)
    }
}
