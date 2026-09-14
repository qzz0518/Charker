import XCTest
@testable import CharkerCore

final class A2345ConnectionStateTests: XCTestCase {
    func testFreshTelemetryRequiresMonitoringReadingAndFreshness() {
        var snapshot = A2345ConnectionSnapshot()
        XCTAssertFalse(snapshot.hasFreshTelemetry)

        snapshot.phase = .waitingForTelemetry
        snapshot.reading = ChargerReading(product: .a2345, ports: [], receivedAt: Date())
        XCTAssertFalse(snapshot.hasFreshTelemetry)

        snapshot.phase = .monitoring
        XCTAssertTrue(snapshot.hasFreshTelemetry)

        snapshot.isStale = true
        XCTAssertFalse(snapshot.hasFreshTelemetry)

        snapshot.isStale = false
        snapshot.reading = nil
        XCTAssertFalse(snapshot.hasFreshTelemetry)

        snapshot.reading = ChargerReading(product: .a2345, ports: [], receivedAt: Date())
        snapshot.phase = .reconnecting(attempt: 1)
        XCTAssertFalse(snapshot.hasFreshTelemetry)

        snapshot.phase = .failed("offline")
        XCTAssertFalse(snapshot.hasFreshTelemetry)
    }

    func testReconnectBudgetStopsAfterFiveConsecutiveFailures() {
        var budget = A2345ReconnectBudget()

        XCTAssertTrue(budget.recordFailure())
        XCTAssertEqual(budget.retryDelaySeconds, 1)
        XCTAssertTrue(budget.recordFailure())
        XCTAssertEqual(budget.retryDelaySeconds, 2)
        XCTAssertTrue(budget.recordFailure())
        XCTAssertEqual(budget.retryDelaySeconds, 4)
        XCTAssertTrue(budget.recordFailure())
        XCTAssertEqual(budget.retryDelaySeconds, 8)
        XCTAssertFalse(budget.recordFailure())
        XCTAssertEqual(budget.consecutiveFailures, 5)
    }

    func testValidTelemetryResetsConsecutiveFailureStreak() {
        var budget = A2345ReconnectBudget()

        XCTAssertTrue(budget.recordFailure())
        XCTAssertTrue(budget.recordFailure())
        budget.recordValidTelemetry()

        XCTAssertEqual(budget.consecutiveFailures, 0)
        XCTAssertTrue(budget.recordFailure())
        XCTAssertEqual(budget.consecutiveFailures, 1)
        XCTAssertEqual(budget.retryDelaySeconds, 1)
    }
}
