import XCTest
@testable import CharkerCore

final class PowerChartScaleTests: XCTestCase {
    func testAutomaticRangeMakesEverydayA2345LoadReadable() {
        XCTAssertEqual(
            PowerChartScale.effectiveMaximum(
                preference: .zero,
                product: .a2345,
                observedPeak: 40
            ),
            50
        )
    }

    func testAutomaticRangeUsesStableDiscreteSteps() {
        XCTAssertEqual(
            PowerChartScale.effectiveMaximum(
                preference: .zero,
                product: .a2345,
                observedPeak: 45
            ),
            100
        )
        XCTAssertEqual(
            PowerChartScale.effectiveMaximum(
                preference: .zero,
                product: .a2687,
                observedPeak: 120
            ),
            160
        )
    }

    func testManualRangePromotesInsteadOfClippingARealReading() {
        XCTAssertEqual(
            PowerChartScale.effectiveMaximum(
                preference: 50,
                product: .a2345,
                observedPeak: 72
            ),
            100
        )
    }

    func testInvalidStoredRangeFallsBackToAutomatic() {
        XCTAssertEqual(PowerChartScale.normalizedPreference(75, for: .a2345), .zero)
        XCTAssertEqual(PowerChartScale.normalizedPreference(250, for: .a2687), .zero)
    }

    func testAxisTicksIncludeZeroAndTheDisplayedMaximum() {
        XCTAssertEqual(PowerChartScale.axisValues(maximum: 50), [0, 10, 20, 30, 40, 50])
        XCTAssertEqual(PowerChartScale.axisValues(maximum: 160), [0, 40, 80, 120, 160])
        XCTAssertEqual(PowerChartScale.axisValues(maximum: 250), [0, 50, 100, 150, 200, 250])
    }
}
