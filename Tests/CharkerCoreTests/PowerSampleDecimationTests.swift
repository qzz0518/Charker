import XCTest
@testable import CharkerCore

/// The overview chart plots at most a couple of hundred marks instead of the
/// full 600-reading history. These lock the properties the curve depends on:
/// the shape must not shift as the window slides, peaks must survive, and the
/// trailing point marker must stay welded to the real last reading.
final class PowerSampleDecimationTests: XCTestCase {
    private func series(_ totals: [Double], step: TimeInterval = 2) -> [PowerSample] {
        let origin = Date(timeIntervalSinceReferenceDate: 0)
        return totals.enumerated().map { index, total in
            PowerSample(
                at: origin.addingTimeInterval(Double(index) * step),
                total: total,
                perPort: [total, 0, 0]
            )
        }
    }

    func testShortSeriesIsReturnedUntouched() {
        let input = series((0..<50).map(Double.init))
        XCTAssertEqual(PowerSample.decimated(input, budget: 180), input)
    }

    func testStaysWithinBudget() {
        let input = series((0..<600).map { Double($0 % 97) })
        let output = PowerSample.decimated(input, budget: 180)
        XCTAssertLessThan(output.count, input.count)
        XCTAssertLessThanOrEqual(output.count, 180 + 1)
    }

    func testIsOrderedInTime() {
        let input = series((0..<600).map { Double(($0 * 37) % 160) })
        let output = PowerSample.decimated(input, budget: 180)
        XCTAssertEqual(output, output.sorted { $0.at < $1.at })
    }

    func testKeepsTheExactLastReading() {
        let input = series((0..<600).map { Double($0 % 97) })
        let output = PowerSample.decimated(input, budget: 180)
        XCTAssertEqual(output.last, input.last)
    }

    /// A single spike inside one bucket must not be averaged away — it is the
    /// peak the user is looking for.
    func testPreservesAnIsolatedPeak() {
        var totals = [Double](repeating: 20, count: 600)
        totals[301] = 158
        let output = PowerSample.decimated(series(totals), budget: 180)
        XCTAssertEqual(output.map(\.total).max(), 158)
    }

    /// And a trough: keeping only per-bucket maxima would draw an upper
    /// envelope and lift the whole curve off its real floor.
    func testPreservesAnIsolatedTrough() {
        var totals = [Double](repeating: 120, count: 600)
        totals[177] = 3
        let output = PowerSample.decimated(series(totals), budget: 180)
        XCTAssertEqual(output.map(\.total).min(), 3)
    }

    /// The reason for bucketing on absolute time: appending one reading must
    /// not re-elect every retained point, or the curve shimmers under itself.
    func testSlidingTheWindowKeepsMostOfTheCurveStable() {
        let totals = (0..<601).map { Double(($0 * 13) % 160) }
        let before = PowerSample.decimated(Array(series(totals).prefix(600)), budget: 180)
        let after = PowerSample.decimated(Array(series(totals).dropFirst(1)), budget: 180)
        let shared = Set(before.map(\.at)).intersection(after.map(\.at))
        XCTAssertGreaterThan(
            Double(shared.count) / Double(before.count), 0.9,
            "a one-sample slide re-elected points well beyond the two edge buckets"
        )
    }

    func testDegenerateZeroSpanIsReturnedUntouched() {
        let origin = Date(timeIntervalSinceReferenceDate: 0)
        let input = (0..<600).map { _ in
            PowerSample(at: origin, total: 10, perPort: [10, 0, 0])
        }
        XCTAssertEqual(PowerSample.decimated(input, budget: 180), input)
    }
}
