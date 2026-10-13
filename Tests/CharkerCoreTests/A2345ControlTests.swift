import A2345Protocol
@testable import CharkerCore
import XCTest

final class A2345ControlStateTests: XCTestCase {
    func testWriteKeysMatchEchoedGroupAndSlot() {
        let c1 = A2345WriteKey(A2345Command.setPortOutput(.c1, on: true))
        let c2 = A2345WriteKey(A2345Command.setPortOutput(.c2, on: false))
        let ack = A2345WriteAcknowledgement(messageType: 0x0A07, status: 0, group: .c2)
        XCTAssertFalse(c1.matches(ack))
        XCTAssertTrue(c2.matches(ack))

        let powerOn = A2345WriteKey(A2345Command.setPortSchedule(
            .c3, .powerOn, A2345PortSchedule(isEnabled: true, hour: 7, minute: 0, weekdays: 0)
        ))
        XCTAssertTrue(powerOn.matches(A2345WriteAcknowledgement(messageType: 0x0A08, status: 0, slot: .powerOn)))
        XCTAssertFalse(powerOn.matches(A2345WriteAcknowledgement(messageType: 0x0A08, status: 0, slot: .powerOff)))
        XCTAssertFalse(powerOn.matches(A2345WriteAcknowledgement(messageType: 0x0A08, status: 0, group: .c2, slot: .powerOn)))
        // Acknowledgements that echo nothing match by type alone.
        XCTAssertTrue(powerOn.matches(A2345WriteAcknowledgement(messageType: 0x0A08, status: 0)))

        let brightness = A2345WriteKey(A2345Command.setBrightness(60))
        XCTAssertTrue(brightness.matches(A2345WriteAcknowledgement(messageType: 0x0A04, status: 0)))
        XCTAssertFalse(brightness.matches(A2345WriteAcknowledgement(messageType: 0x0A03, status: 0)))
    }

    func testOptimisticStateFollowsTheCommand() {
        var settings = A2345DeviceSettings.demo
        settings = settings.applying(.setPortCountdown(.c1, enabled: true, seconds: 3_600))
        XCTAssertEqual(settings.portControls[.c1]?.countdownRemaining, 3_600)
        settings = settings.applying(.setPortOutput(.c1, on: false))
        XCTAssertEqual(settings.portControls[.c1]?.isOn, false)
        XCTAssertEqual(settings.portControls[.c1]?.countdownEnabled, false)

        settings = settings.applying(.setChargingMode(.portPriority))
        settings = settings.applying(.setPortPriority(0b1001))
        XCTAssertEqual(settings.priorityBitmap, 0b1001)
        settings = settings.applying(.setChargingMode(.dualLaptop))
        XCTAssertEqual(settings.priorityBitmap, 0)

        let theme = A2345ClockThemeRequest(
            clockOn: false, kind: .style3, themeID: nil, imageCRC: 0,
            url: A2345ClockThemeRequest.builtInStyleURL(.style3)
        )
        settings = settings.applying(.setClockTheme(theme))
        XCTAssertEqual(settings.clock?.isOn, false)
        XCTAssertEqual(settings.clock?.themeCode, 2)
    }

    func testSnapshotKeepsThemeDetailsOnlyTheThemeMessageCarries() {
        var previous = A2345DeviceSettings.demo
        previous.clock = A2345ClockState(
            isOn: true, holidayEnabled: false, themeCode: 3, themeID: 9,
            themeURL: "https://example.com/t.jpg", isShowingHoliday: false
        )
        previous.customImageTimeDisplay = true

        var incoming = A2345DeviceSettings.demo
        incoming.clock = A2345ClockState(isOn: true, holidayEnabled: true, themeCode: 3, themeID: 9)
        incoming.customImageTimeDisplay = nil
        let merged = previous.mergingSnapshot(incoming)
        XCTAssertEqual(merged.clock?.themeURL, "https://example.com/t.jpg")
        XCTAssertEqual(merged.clock?.holidayEnabled, true)
        XCTAssertEqual(merged.customImageTimeDisplay, true)

        incoming.clock = A2345ClockState(isOn: true, holidayEnabled: false, themeCode: 3, themeID: 10)
        XCTAssertNil(previous.mergingSnapshot(incoming).clock?.themeURL)
    }

    func testCountdownRunsDownBetweenReports() {
        var snapshot = A2345ConnectionSnapshot()
        var settings = A2345DeviceSettings.demo
        settings.apply(.portCountdown(.c2, enabled: true, total: 600, remaining: 300))
        snapshot.settings = settings
        let reported = Date(timeIntervalSince1970: 1_000)
        snapshot.countdownReportedAt[.c2] = reported
        XCTAssertEqual(snapshot.countdownRemaining(.c2, at: reported.addingTimeInterval(100)), 200)
        XCTAssertEqual(snapshot.countdownRemaining(.c2, at: reported.addingTimeInterval(400)), 0)
        XCTAssertNil(snapshot.countdownRemaining(.c1, at: reported))
    }
}
