import A2687Protocol
import Foundation
import XCTest
@testable import CharkerCore

final class PortShutdownScheduleTests: XCTestCase {
    func testScheduleFormatsItsRemainingStateFromTheAcceptedDeadline() throws {
        let armedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let schedule = PortShutdownSchedule(
            peripheralID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            port: .c2,
            durationSeconds: 3_600,
            armedAt: armedAt
        )

        XCTAssertEqual(schedule.port, .c2)
        XCTAssertEqual(schedule.deadline, armedAt.addingTimeInterval(3_600))
        XCTAssertEqual(schedule.remainingSeconds(at: armedAt.addingTimeInterval(600)), 3_000)
        XCTAssertEqual(
            schedule.remainingFraction(at: armedAt.addingTimeInterval(600)),
            5.0 / 6.0,
            accuracy: 0.000_001
        )
        XCTAssertFalse(schedule.isActive(at: schedule.deadline))
    }

    func testStoreRoundTripsActiveSchedulesAndDropsExpiredOnes() throws {
        let defaults = MemoryDefaults()
        let store = PortShutdownScheduleStore(defaults: defaults, key: "testSchedules")
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let device = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let expired = PortShutdownSchedule(
            peripheralID: device, port: .c1, durationSeconds: 60,
            armedAt: now.addingTimeInterval(-120)
        )
        let active = PortShutdownSchedule(
            peripheralID: device, port: .c3, durationSeconds: 3_600,
            armedAt: now.addingTimeInterval(-120)
        )

        store.save([expired, active], activeAt: now)

        XCTAssertEqual(store.load(activeAt: now), [active])
    }

    func testStoreKeepsOnlyTheNewestCountdownForOneDevicePort() throws {
        let defaults = MemoryDefaults()
        let store = PortShutdownScheduleStore(defaults: defaults, key: "testSchedules")
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let device = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let old = PortShutdownSchedule(
            peripheralID: device, port: .c2, durationSeconds: 3_600,
            armedAt: now.addingTimeInterval(-120)
        )
        let replacement = PortShutdownSchedule(
            peripheralID: device, port: .c2, durationSeconds: 7_200,
            armedAt: now.addingTimeInterval(-30)
        )

        store.save([replacement, old], activeAt: now)

        XCTAssertEqual(store.load(activeAt: now), [replacement])
    }
}
