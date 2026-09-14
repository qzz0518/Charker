import Foundation
import XCTest
@testable import CharkerCore

final class EnergyHistoryTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        ))!
    }

    /// 从磁盘格式这一侧灌一个合成存档进来。
    ///
    /// `hourly` / `sessions` 都是 `private(set)`，而折叠必须在一份"还没被折过"
    /// 的跨年数据上验；靠 `record` 一帧帧喂出三年历史既慢，又会在途中自己触发
    /// 裁剪，于是根本量不到"折叠前"。日期策略跟 `EnergyHistoryStore` 一致。
    private func makeHistory(
        hourly: [EnergyPeriodRecord] = [],
        sessions: [EnergySessionRecord] = []
    ) throws -> EnergyHistory {
        struct Archive: Encodable {
            let hourly: [EnergyPeriodRecord]
            let sessions: [EnergySessionRecord]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(
            EnergyHistory.self,
            from: encoder.encode(Archive(hourly: hourly, sessions: sessions))
        )
    }

    /// 把一份已经有内部状态的历史按磁盘格式写出去，塞进 hourly/sessions 再读回来。
    ///
    /// 折叠水位线是私有字段，但它入档。要验"上次运行留下的坏水位线会不会拖累
    /// 这次"，就必须造出一份"带着那个水位线从磁盘回来"的存档——直接 setter 造不出，
    /// 也不该为测试开一个 setter。走一遍真正的编解码路径反而最接近现场。
    private func reload(
        _ history: EnergyHistory,
        hourly: [EnergyPeriodRecord] = [],
        sessions: [EnergySessionRecord] = []
    ) throws -> EnergyHistory {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        guard var object = try JSONSerialization.jsonObject(
            with: encoder.encode(history)
        ) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        object["hourly"] = try JSONSerialization.jsonObject(with: encoder.encode(hourly))
        object["sessions"] = try JSONSerialization.jsonObject(with: encoder.encode(sessions))
        return try decoder.decode(
            EnergyHistory.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    /// 两帧遥测，够触发一次 `compactIfNeeded`（第一帧只开段，不问裁剪）。
    private func feedTwoFrames(_ history: inout EnergyHistory, at start: Date) {
        for step in 0..<2 {
            history.record(EnergyMeasurement(
                at: start.addingTimeInterval(Double(step) * 60),
                totalWatts: 60,
                perPortWatts: [60, 0, 0]
            ), calendar: calendar)
        }
    }

    private func bucket(startingAt start: Date, energyWh: Double = 1.5) -> EnergyPeriodRecord {
        EnergyPeriodRecord(
            startedAt: start,
            endedAt: start.addingTimeInterval(900),
            energyWh: energyWh,
            activeSeconds: 900,
            peakWatts: 60 + energyWh,
            perPortWh: [energyWh * 0.6, energyWh * 0.3, energyWh * 0.1]
        )
    }

    func testPortValuesUseOneSixSlotShape() {
        XCTAssertEqual(EnergyHistory.portSlotCount, 6)

        let measurement = EnergyMeasurement(
            at: date(2026, 8, 27, 9, 0),
            totalWatts: 21,
            perPortWatts: [1, 2, 3, 4, 5, 6, 7]
        )
        XCTAssertEqual(measurement.perPortWatts, [1, 2, 3, 4, 5, 6])

        let session = EnergySessionRecord(
            startedAt: measurement.at,
            endedAt: measurement.at,
            perPortWh: [1, 2, 3]
        )
        let period = EnergyPeriodRecord(
            startedAt: measurement.at,
            endedAt: measurement.at,
            perPortWh: [1, 2, 3]
        )
        XCTAssertEqual(session.perPortWh, [1, 2, 3, 0, 0, 0])
        XCTAssertEqual(period.perPortWh, [1, 2, 3, 0, 0, 0])
        XCTAssertEqual(EnergyHistorySummary().perPortWh, [0, 0, 0, 0, 0, 0])
    }

    func testIntegratesAndAggregatesAllSixPorts() {
        var history = EnergyHistory()
        let start = date(2026, 8, 27, 10, 0)
        let watts = [60.0, 48, 36, 24, 12, 6]
        history.record(
            EnergyMeasurement(at: start, totalWatts: watts.reduce(0, +), perPortWatts: watts),
            calendar: calendar
        )
        history.record(
            EnergyMeasurement(
                at: start.addingTimeInterval(60),
                totalWatts: watts.reduce(0, +),
                perPortWatts: watts
            ),
            calendar: calendar
        )

        let expected = watts.map { $0 / 60 }
        let summary = history.summary(from: nil, to: start.addingTimeInterval(120))
        XCTAssertEqual(summary.perPortWh.count, EnergyHistory.portSlotCount)
        for index in 0..<EnergyHistory.portSlotCount {
            XCTAssertEqual(summary.perPortWh[index], expected[index], accuracy: 0.000_001)
        }

        let day = history.periods(
            from: calendar.startOfDay(for: start),
            to: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!,
            granularity: .day,
            calendar: calendar
        )
        XCTAssertEqual(day.count, 1)
        XCTAssertEqual(day[0].perPortWh.count, EnergyHistory.portSlotCount)
        for index in 0..<EnergyHistory.portSlotCount {
            XCTAssertEqual(day[0].perPortWh[index], expected[index], accuracy: 0.000_001)
        }
    }

    func testIntegratesEnergyAndPortSharesFromObservedTime() {
        var history = EnergyHistory()
        let start = date(2026, 8, 27, 10, 0)
        history.record(EnergyMeasurement(at: start, totalWatts: 60, perPortWatts: [40, 20, 0]), calendar: calendar)
        history.record(EnergyMeasurement(
            at: start.addingTimeInterval(60), totalWatts: 60, perPortWatts: [40, 20, 0]
        ), calendar: calendar)

        let summary = history.summary(from: nil, to: start.addingTimeInterval(120))
        XCTAssertEqual(summary.energyWh, 1, accuracy: 0.000_001)
        XCTAssertEqual(summary.activeSeconds, 60, accuracy: 0.000_001)
        XCTAssertEqual(summary.averageWatts, 60, accuracy: 0.000_001)
        XCTAssertEqual(summary.peakWatts, 60, accuracy: 0.000_001)
        XCTAssertEqual(summary.perPortWh[0], 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(summary.perPortWh[1], 1.0 / 3.0, accuracy: 0.000_001)
    }

    func testLongGapStartsANewSessionAndAddsNoImaginedEnergy() {
        var history = EnergyHistory()
        let start = date(2026, 8, 27, 10, 0)
        history.record(EnergyMeasurement(at: start, totalWatts: 60, perPortWatts: [60, 0, 0]), calendar: calendar)
        history.record(EnergyMeasurement(
            at: start.addingTimeInterval(60), totalWatts: 60, perPortWatts: [60, 0, 0]
        ), calendar: calendar)
        history.record(EnergyMeasurement(
            at: start.addingTimeInterval(180), totalWatts: 30, perPortWatts: [0, 30, 0]
        ), calendar: calendar)
        history.record(EnergyMeasurement(
            at: start.addingTimeInterval(240), totalWatts: 30, perPortWatts: [0, 30, 0]
        ), calendar: calendar)
        history.finishCurrentSession()

        let summary = history.summary(from: nil, to: start.addingTimeInterval(300))
        XCTAssertEqual(summary.sessionCount, 2)
        XCTAssertEqual(summary.activeSeconds, 120, accuracy: 0.000_001)
        XCTAssertEqual(summary.energyWh, 1.5, accuracy: 0.000_001)
    }

    func testManualCutStartsTheNextSampleAsAFreshSession() {
        var history = EnergyHistory()
        let start = date(2026, 8, 27, 10, 0)
        history.record(EnergyMeasurement(
            at: start,
            totalWatts: 60,
            perPortWatts: [60, 0, 0]
        ), calendar: calendar)
        history.record(EnergyMeasurement(
            at: start.addingTimeInterval(60),
            totalWatts: 60,
            perPortWatts: [60, 0, 0]
        ), calendar: calendar)

        history.finishCurrentSession()

        let nextStart = start.addingTimeInterval(70)
        history.record(EnergyMeasurement(
            at: nextStart,
            totalWatts: 30,
            perPortWatts: [0, 30, 0]
        ), calendar: calendar)
        history.record(EnergyMeasurement(
            at: nextStart.addingTimeInterval(60),
            totalWatts: 30,
            perPortWatts: [0, 30, 0]
        ), calendar: calendar)

        XCTAssertEqual(history.sessions.count, 1)
        XCTAssertEqual(history.sessions[0].energyWh, 1, accuracy: 0.000_001)
        XCTAssertEqual(history.currentSessionSummary.energyWh, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(history.currentSessionSummary.sessionCount, 1)

        let all = history.summary(from: nil, to: nextStart.addingTimeInterval(120))
        XCTAssertEqual(all.energyWh, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(all.activeSeconds, 120, accuracy: 0.000_001)
        XCTAssertEqual(all.sessionCount, 2)
    }

    func testCurrentSessionSummaryExcludesCompletedSessions() {
        var history = EnergyHistory()
        let first = date(2026, 8, 27, 9, 0)
        history.record(EnergyMeasurement(
            at: first,
            totalWatts: 90,
            perPortWatts: [90, 0, 0]
        ), calendar: calendar)
        history.record(EnergyMeasurement(
            at: first.addingTimeInterval(60),
            totalWatts: 90,
            perPortWatts: [90, 0, 0]
        ), calendar: calendar)
        history.finishCurrentSession()

        let second = date(2026, 8, 27, 10, 0)
        history.record(EnergyMeasurement(
            at: second,
            totalWatts: 30,
            perPortWatts: [0, 30, 0]
        ), calendar: calendar)
        history.record(EnergyMeasurement(
            at: second.addingTimeInterval(60),
            totalWatts: 30,
            perPortWatts: [0, 30, 0]
        ), calendar: calendar)

        let current = history.currentSessionSummary
        XCTAssertEqual(current.energyWh, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(current.activeSeconds, 60, accuracy: 0.000_001)
        XCTAssertEqual(current.peakWatts, 30, accuracy: 0.000_001)
        XCTAssertEqual(current.perPortWh, [0, 0.5, 0, 0, 0, 0])
        XCTAssertEqual(current.sessionCount, 1)
        XCTAssertEqual(history.currentSessionPeriod?.energyWh ?? -1, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(history.currentSessionPeriod?.startedAt, second)
    }

    func testIntervalCrossingAnHourIsSplitBetweenBuckets() {
        var history = EnergyHistory()
        let start = date(2026, 8, 27, 10, 59, 30)
        history.record(EnergyMeasurement(at: start, totalWatts: 60, perPortWatts: [60, 0, 0]), calendar: calendar)
        history.record(EnergyMeasurement(
            at: start.addingTimeInterval(60), totalWatts: 60, perPortWatts: [60, 0, 0]
        ), calendar: calendar)

        let periods = history.periods(
            from: calendar.startOfDay(for: start),
            to: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!,
            granularity: .hour,
            calendar: calendar
        )
        XCTAssertEqual(periods.count, 2)
        XCTAssertEqual(periods[0].energyWh, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(periods[1].energyWh, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(periods[0].activeSeconds, 30, accuracy: 0.000_001)
        XCTAssertEqual(periods[1].activeSeconds, 30, accuracy: 0.000_001)
    }

    func testDailyAggregationKeepsObservedDaysSeparate() {
        var history = EnergyHistory()
        let first = date(2026, 8, 26, 10, 0)
        let second = date(2026, 8, 27, 10, 0)
        for start in [first, second] {
            history.record(EnergyMeasurement(at: start, totalWatts: 60, perPortWatts: [60, 0, 0]), calendar: calendar)
            history.record(EnergyMeasurement(
                at: start.addingTimeInterval(60), totalWatts: 60, perPortWatts: [60, 0, 0]
            ), calendar: calendar)
        }

        let periods = history.periods(
            from: calendar.startOfDay(for: first),
            to: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: second))!,
            granularity: .day,
            calendar: calendar
        )
        XCTAssertEqual(periods.count, 2)
        XCTAssertEqual(periods.map(\.energyWh), [1, 1])
    }

    func testStoreRoundTripsAndPreservesCorruptArchive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = EnergyHistoryStore(url: url)

        var history = EnergyHistory()
        let start = date(2026, 8, 27, 10, 0)
        history.record(EnergyMeasurement(at: start, totalWatts: 60, perPortWatts: [60, 0, 0]), calendar: calendar)
        history.record(EnergyMeasurement(
            at: start.addingTimeInterval(60), totalWatts: 60, perPortWatts: [60, 0, 0]
        ), calendar: calendar)
        try store.save(history)

        let loaded = store.load()
        XCTAssertNil(loaded.warning)
        XCTAssertEqual(loaded.history.sessions.count, 1)
        XCTAssertNil(loaded.history.activeSession)
        XCTAssertEqual(
            loaded.history.summary(from: nil, to: start.addingTimeInterval(120)).energyWh,
            1,
            accuracy: 0.000_001
        )

        try Data("not-json".utf8).write(to: url, options: .atomic)
        let corrupt = store.load()
        XCTAssertNotNil(corrupt.warning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.deletingPathExtension().appendingPathExtension("corrupt.json").path
        ))
    }

    func testStoreClearResetsMemoryAndRemovesEveryArchiveCopy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        let store = EnergyHistoryStore(url: url)

        var history = EnergyHistory()
        let start = date(2026, 8, 27, 10, 0)
        history.record(
            EnergyMeasurement(at: start, totalWatts: 60, perPortWatts: [60, 0, 0]),
            calendar: calendar
        )
        history.record(
            EnergyMeasurement(
                at: start.addingTimeInterval(60),
                totalWatts: 60,
                perPortWatts: [60, 0, 0]
            ),
            calendar: calendar
        )
        try store.save(history)
        try Data("old-recovery-copy".utf8).write(to: backup, options: .atomic)

        try store.clear(&history)

        XCTAssertTrue(history.sessions.isEmpty)
        XCTAssertTrue(history.hourly.isEmpty)
        XCTAssertNil(history.activeSession)
        XCTAssertEqual(history.archivedSessionCount, 0)
        XCTAssertNil(history.archivedSessionsBefore)
        XCTAssertNil(history.skippedCompaction)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))

        let reloaded = store.load()
        XCTAssertNil(reloaded.warning)
        XCTAssertTrue(reloaded.history.sessions.isEmpty)
        XCTAssertTrue(reloaded.history.hourly.isEmpty)
        XCTAssertNil(reloaded.history.activeSession)

        // 清空也必须丢掉上一帧测量，否则新记录的第一帧会跨着清空点积分，
        // 凭空把已删除那一分钟的用电量带回来。
        history.record(
            EnergyMeasurement(
                at: start.addingTimeInterval(120),
                totalWatts: 60,
                perPortWatts: [60, 0, 0]
            ),
            calendar: calendar
        )
        XCTAssertEqual(history.currentSessionSummary.energyWh, 0, accuracy: 0.000_001)
        XCTAssertEqual(
            history.currentSessionSummary.perPortWh,
            Array(repeating: 0, count: EnergyHistory.portSlotCount)
        )
    }

    func testRemoveRecordsClearsOneCalendarRangeAndStartsFreshInsideIt() throws {
        var history = EnergyHistory()
        let previousDay = date(2026, 8, 29, 23, 0)
        history.record(
            EnergyMeasurement(at: previousDay, totalWatts: 60, perPortWatts: [60, 0, 0]),
            calendar: calendar
        )
        history.record(
            EnergyMeasurement(
                at: previousDay.addingTimeInterval(60),
                totalWatts: 60,
                perPortWatts: [60, 0, 0]
            ),
            calendar: calendar
        )
        history.finishCurrentSession()

        let today = date(2026, 8, 30, 0, 0)
        let todayRun = date(2026, 8, 30, 10, 0)
        history.record(
            EnergyMeasurement(at: todayRun, totalWatts: 120, perPortWatts: [0, 120, 0]),
            calendar: calendar
        )
        history.record(
            EnergyMeasurement(
                at: todayRun.addingTimeInterval(60),
                totalWatts: 120,
                perPortWatts: [0, 120, 0]
            ),
            calendar: calendar
        )

        XCTAssertTrue(history.removeRecords(from: today, to: date(2026, 8, 31, 0, 0)))
        XCTAssertEqual(
            history.summary(from: nil, to: today).energyWh,
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            history.summary(from: today, to: date(2026, 8, 31, 0, 0)).energyWh,
            0,
            accuracy: 0.000_001
        )
        XCTAssertNil(history.activeSession)
        XCTAssertFalse(history.removeRecords(from: today, to: date(2026, 8, 31, 0, 0)))

        history.record(
            EnergyMeasurement(
                at: todayRun.addingTimeInterval(120),
                totalWatts: 120,
                perPortWatts: [0, 120, 0]
            ),
            calendar: calendar
        )
        XCTAssertEqual(history.currentSessionSummary.energyWh, 0, accuracy: 0.000_001)
    }

    func testReplacingAfterRangeRemovalDeletesTheStaleRecoveryCopy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        let store = EnergyHistoryStore(url: url)

        var history = EnergyHistory()
        let firstDay = date(2026, 8, 29, 10, 0)
        let secondDay = date(2026, 8, 30, 10, 0)
        for start in [firstDay, secondDay] {
            history.record(
                EnergyMeasurement(at: start, totalWatts: 60, perPortWatts: [60, 0, 0]),
                calendar: calendar
            )
            history.record(
                EnergyMeasurement(
                    at: start.addingTimeInterval(60),
                    totalWatts: 60,
                    perPortWatts: [60, 0, 0]
                ),
                calendar: calendar
            )
            history.finishCurrentSession()
        }
        try store.save(history)
        try Data("stale-history".utf8).write(to: backup, options: .atomic)

        XCTAssertTrue(history.removeRecords(
            from: date(2026, 8, 30, 0, 0),
            to: date(2026, 8, 31, 0, 0)
        ))
        try store.replaceAfterRemoval(history)

        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        let reloaded = store.load()
        XCTAssertNil(reloaded.warning)
        XCTAssertEqual(
            reloaded.history.summary(from: nil, to: date(2026, 8, 31, 0, 0)).energyWh,
            1,
            accuracy: 0.000_001
        )
    }

    // MARK: - Retention
    //
    // 折叠是不可逆的有损变换，所以这几条测试守的是同一句话：可以降分辨率，
    // 不可以丢总量。

    func testFoldingPreservesTotals() throws {
        let today = date(2026, 8, 27, 0, 0)
        var buckets: [EnergyPeriodRecord] = []
        // 跨三年，每天三个小时桶：最老的一段要一路穿过日桶压到月桶。
        for dayOffset in (-1_000)...0 {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            for (slot, hour) in [9, 13, 21].enumerated() {
                let start = calendar.date(byAdding: .hour, value: hour, to: day)!
                buckets.append(bucket(
                    startingAt: start,
                    energyWh: 1 + Double((abs(dayOffset) + slot) % 7) * 0.25
                ))
            }
        }

        var history = try makeHistory(hourly: buckets)
        let end = date(2026, 8, 28, 0, 0)
        let before = history.summary(from: nil, to: end)
        XCTAssertEqual(
            before.energyWh,
            buckets.reduce(0) { $0 + $1.energyWh },
            accuracy: 0.000_001
        )

        let now = date(2026, 8, 27, 23, 0)
        history.recoverAfterLaunch(now: now, calendar: calendar)
        XCTAssertNil(history.skippedCompaction)
        XCTAssertLessThan(history.hourly.count, buckets.count)

        let after = history.summary(from: nil, to: end)
        XCTAssertEqual(after.energyWh, before.energyWh, accuracy: 0.000_001)
        XCTAssertEqual(after.activeSeconds, before.activeSeconds, accuracy: 0.000_001)
        XCTAssertEqual(after.peakWatts, before.peakWatts, accuracy: 0.000_001)
        for port in 0..<EnergyHistory.portSlotCount {
            XCTAssertEqual(after.perPortWh[port], before.perPortWh[port], accuracy: 0.000_001)
        }

        // 两年前的桶必须落在月首，否则下一次折叠会按月重新分组而错位。
        let dayCutoff = calendar.date(
            byAdding: .day, value: -EnergyHistory.dailyDetailDays, to: calendar.startOfDay(for: now)
        )!
        for record in history.hourly where record.startedAt < dayCutoff {
            XCTAssertEqual(
                record.startedAt,
                calendar.dateInterval(of: .month, for: record.startedAt)?.start
            )
        }

        // 再折一次不该再动任何东西：三级折叠必须是幂等的。
        let foldedCount = history.hourly.count
        history.recoverAfterLaunch(now: now, calendar: calendar)
        XCTAssertEqual(history.hourly.count, foldedCount)
        XCTAssertEqual(
            history.summary(from: nil, to: end).energyWh, before.energyWh, accuracy: 0.000_001
        )
    }

    func testSessionCapFoldsFromTheFront() throws {
        let start = date(2026, 8, 20, 0, 0)
        let overflow = 100
        let total = EnergyHistory.sessionDetailLimit + overflow
        // 全部落在明细保留期内，所以触发折叠的只能是数量上限这一条。
        let sessions = (0..<total).map { index -> EnergySessionRecord in
            let began = start.addingTimeInterval(Double(index) * 60)
            return EnergySessionRecord(
                startedAt: began,
                endedAt: began.addingTimeInterval(30),
                energyWh: 0.5,
                activeSeconds: 30,
                peakWatts: 60,
                perPortWh: [0.5, 0, 0],
                sampleCount: 2
            )
        }

        var history = try makeHistory(sessions: sessions)
        let now = start.addingTimeInterval(Double(total) * 60 + 3_600)
        history.recoverAfterLaunch(now: now, calendar: calendar)

        XCTAssertEqual(history.sessions.count, EnergyHistory.sessionDetailLimit)
        XCTAssertEqual(history.archivedSessionCount, overflow)
        // 削掉的是最旧的那批：留下来的第一段正是原来的第 overflow + 1 段。
        XCTAssertEqual(history.sessions.first?.startedAt, sessions[overflow].startedAt)
        XCTAssertEqual(history.sessions.last?.startedAt, sessions.last?.startedAt)
        XCTAssertEqual(history.archivedSessionsBefore, sessions[overflow - 1].endedAt)
        // "全部"里的段数不因裁剪而变小。
        XCTAssertEqual(history.summary(from: nil, to: now).sessionCount, total)
    }

    /// v1 存档里没有 archivedSessionCount / archivedSessionsBefore /
    /// nextCompactionAt 这三个键。合成的 `init(from:)` 遇到缺键会抛错，那会让
    /// 老用户的存档被当成损坏文件搬去 .corrupt.json——整份历史就此消失。
    func testLegacyArchiveDecodesWithoutNewKeys() throws {
        // 时间戳是毫秒：1787824800000 = 2026-08-27T10:00:00Z，1787828400000 = 11:00:00Z。
        let legacyHistory = """
        {
          "hourly": [
            {
              "startedAt": 1787824800000,
              "endedAt": 1787828400000,
              "energyWh": 12.5,
              "activeSeconds": 3600,
              "peakWatts": 96.5,
              "perPortWh": [10, 2.5, 0]
            }
          ],
          "sessions": [
            {
              "id": "5E1E2A2E-0F1B-4C6C-9C2B-2C7E6E1A0001",
              "startedAt": 1787824800000,
              "endedAt": 1787828400000,
              "energyWh": 12.5,
              "activeSeconds": 3600,
              "peakWatts": 96.5,
              "perPortWh": [10, 2.5, 0],
              "sampleCount": 3600
            }
          ]
        }
        """

        // 直接解码，不经 `recoverAfterLaunch`：这一段验的是缺键，不该被跑测试
        // 那天的挂钟决定裁剪掉多少。
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let history = try decoder.decode(EnergyHistory.self, from: Data(legacyHistory.utf8))
        XCTAssertEqual(history.hourly.first?.startedAt, date(2026, 8, 27, 10, 0))
        XCTAssertEqual(history.hourly.first?.endedAt, date(2026, 8, 27, 11, 0))
        XCTAssertEqual(history.sessions.count, 1)
        XCTAssertEqual(history.sessions.first?.sampleCount, 3600)
        XCTAssertEqual(history.hourly.first?.perPortWh, [10, 2.5, 0, 0, 0, 0])
        XCTAssertEqual(history.sessions.first?.perPortWh, [10, 2.5, 0, 0, 0, 0])
        XCTAssertNil(history.activeSession)
        // 缺席的新键取默认值，不是"更早还有 N 段"。
        XCTAssertEqual(history.archivedSessionCount, 0)
        XCTAssertNil(history.archivedSessionsBefore)
        XCTAssertEqual(
            history.summary(from: nil, to: date(2026, 8, 28, 0, 0)).energyWh,
            12.5,
            accuracy: 0.000_001
        )

        // 再走一遍真正的升级路径：老文件落在磁盘上，新二进制读它，不能被当成
        // 损坏文件搬去 .corrupt.json。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        try Data(#"{"version": 1, "history": \#(legacyHistory)}"#.utf8)
            .write(to: url, options: .atomic)

        let loaded = EnergyHistoryStore(url: url).load()
        XCTAssertNil(loaded.warning)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.deletingPathExtension().appendingPathExtension("corrupt.json").path
        ))
        // 加载会按当天的时钟裁剪，明细可能已折叠成日/月桶——总量一度都不能少。
        XCTAssertEqual(
            loaded.history.summary(from: nil, to: date(2036, 1, 1, 0, 0)).energyWh,
            12.5,
            accuracy: 0.000_001
        )
        XCTAssertTrue(loaded.history.hourly.allSatisfy {
            $0.perPortWh.count == EnergyHistory.portSlotCount
                && $0.perPortWh.suffix(3).allSatisfy { $0 == 0 }
        })
    }

    func testLegacyThreeSlotActiveMeasurementCanContinueWithSixPorts() throws {
        let legacyHistory = """
        {
          "hourly": [],
          "sessions": [],
          "activeSession": {
            "id": "5E1E2A2E-0F1B-4C6C-9C2B-2C7E6E1A0002",
            "startedAt": 1787824800000,
            "endedAt": 1787824800000,
            "energyWh": 0,
            "activeSeconds": 0,
            "peakWatts": 60,
            "perPortWh": [0, 0, 0],
            "sampleCount": 1
          },
          "lastMeasurement": {
            "at": 1787824800000,
            "totalWatts": 60,
            "perPortWatts": [40, 20, 0]
          }
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var history = try decoder.decode(EnergyHistory.self, from: Data(legacyHistory.utf8))
        XCTAssertEqual(history.activeSession?.perPortWh, [0, 0, 0, 0, 0, 0])

        history.record(
            EnergyMeasurement(
                at: date(2026, 8, 27, 10, 1),
                totalWatts: 120,
                perPortWatts: [40, 20, 0, 10, 20, 30]
            ),
            calendar: calendar
        )

        XCTAssertEqual(history.currentSessionSummary.perPortWh.count, EnergyHistory.portSlotCount)
        XCTAssertEqual(history.currentSessionSummary.perPortWh[3], 10.0 / 120, accuracy: 0.000_001)
        XCTAssertEqual(history.currentSessionSummary.perPortWh[4], 20.0 / 120, accuracy: 0.000_001)
        XCTAssertEqual(history.currentSessionSummary.perPortWh[5], 30.0 / 120, accuracy: 0.000_001)
    }

    func testCSVExportsSixStablePortColumns() {
        var history = EnergyHistory()
        let start = date(2026, 8, 27, 10, 0)
        let watts = [10.0, 20, 30, 40, 50, 60]
        history.record(
            EnergyMeasurement(at: start, totalWatts: 210, perPortWatts: watts),
            calendar: calendar
        )
        history.record(
            EnergyMeasurement(
                at: start.addingTimeInterval(60), totalWatts: 210, perPortWatts: watts
            ),
            calendar: calendar
        )
        history.finishCurrentSession()

        let rows = history.exportCSV(generatedAt: start)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("#") }
        XCTAssertEqual(
            rows.first,
            "kind,start,end,energy_wh,active_seconds,peak_w,average_w,c1_wh,c2_wh,c3_wh,c4_wh,a1_wh,a2_wh,samples"
        )
        XCTAssertEqual(rows.count, 3)
        for row in rows.dropFirst() {
            XCTAssertEqual(row.split(separator: ",", omittingEmptySubsequences: false).count, 14)
        }
        let bucket = rows[1].split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(bucket[7], "0.1667")
        XCTAssertEqual(bucket[10], "0.6667")
        XCTAssertEqual(bucket[12], "1.0000")
    }

    /// RTC 没电、虚拟机快照恢复、手动改日期：Mac 会在 NTP 把时钟拉回来之前的
    /// 几秒里报出一个遥远未来的 now。按那个 now 算保留期会把整个存档一次折光。
    func testFutureClockRefusesToCompact() throws {
        let today = date(2026, 8, 27, 0, 0)
        var buckets: [EnergyPeriodRecord] = []
        for dayOffset in (-240)...0 {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            for hour in [8, 9, 10] {
                buckets.append(bucket(
                    startingAt: calendar.date(byAdding: .hour, value: hour, to: day)!
                ))
            }
        }
        var history = try makeHistory(hourly: buckets)
        let untouched = history.hourly

        history.recoverAfterLaunch(now: date(2036, 1, 1, 8, 0), calendar: calendar)
        XCTAssertEqual(history.hourly, untouched)
        XCTAssertEqual(history.skippedCompaction?.latestRecordAt, buckets.last?.endedAt)
        XCTAssertEqual(history.skippedCompaction?.attemptedAt, date(2036, 1, 1, 8, 0))
        XCTAssertNotNil(history.skippedCompactionNotice)

        // 时钟纠正回来之后，该折的照折，总量仍然一字不差。
        history.recoverAfterLaunch(now: date(2026, 8, 27, 23, 0), calendar: calendar)
        XCTAssertNil(history.skippedCompaction)
        XCTAssertNil(history.skippedCompactionNotice)
        XCTAssertLessThan(history.hourly.count, untouched.count)
        XCTAssertEqual(
            history.summary(from: nil, to: date(2036, 1, 1, 0, 0)).energyWh,
            buckets.reduce(0) { $0 + $1.energyWh },
            accuracy: 0.000_001
        )
    }

    /// 跑飞的时钟不只在启动那一下危险：连上充电器之后，每一帧遥测都会带着
    /// 未来的时间戳再问一次裁剪。参照物必须停在跑飞之前的那条记录上。
    func testFutureClockRefusesToCompactWhileTelemetryFlows() throws {
        let today = date(2026, 8, 27, 0, 0)
        var buckets: [EnergyPeriodRecord] = []
        for dayOffset in (-240)...0 {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            for hour in [8, 9, 10] {
                buckets.append(bucket(
                    startingAt: calendar.date(byAdding: .hour, value: hour, to: day)!
                ))
            }
        }
        var history = try makeHistory(hourly: buckets)
        let archived = Set(history.hourly.map(\.startedAt))

        let runaway = date(2036, 1, 1, 8, 0)
        for step in 0..<6 {
            history.record(EnergyMeasurement(
                at: runaway.addingTimeInterval(Double(step) * 60),
                totalWatts: 60,
                perPortWatts: [60, 0, 0]
            ), calendar: calendar)
        }

        XCTAssertNotNil(history.skippedCompaction)
        XCTAssertEqual(history.skippedCompaction?.latestRecordAt, buckets.last?.endedAt)
        // 老桶一个不少，只是多了跑飞时段自己的那几个。
        XCTAssertTrue(archived.isSubset(of: Set(history.hourly.map(\.startedAt))))
    }

    /// 时钟防线只挡住了折叠，没挡住折叠水位线：`nextCompactionAt` 照样由那块
    /// 可疑的 `now` 算出来并入档。时钟被 NTP 纠正回来之后，早退判断永久成立，
    /// 裁剪再也不跑——保留期本来要治的病，反倒被这条水位线锁死。
    ///
    /// 两条路都能中毒，所以两条都验：
    /// (a) 存档是空的，防线找不到参照物，根本不触发；
    /// (b) 时钟只超前一百天，没越过两年的阈值，折叠照做、水位线照推。
    func testPoisonedCompactionWatermarkStillCompactsOnceTheClockIsCorrected() throws {
        let today = date(2026, 8, 27, 0, 0)
        // 跨三年多，每天一个小时桶：日桶保留期和月桶折叠都要被越过。
        let buckets = ((-1_200)...0).map { dayOffset -> EnergyPeriodRecord in
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            return bucket(startingAt: calendar.date(byAdding: .hour, value: 9, to: day)!)
        }
        let telemetryStart = date(2026, 8, 27, 12, 0)

        var control = try makeHistory(hourly: buckets)
        feedTwoFrames(&control, at: telemetryStart)
        let expected = control.hourly.count
        XCTAssertLessThan(expected, buckets.count, "对照组本身就得折过，否则这条测试没有对照")

        // (a) 一台空存档的 Mac 在时钟跑飞时启动。没有任何记录可当参照物，防线
        //     直接跳过，跑飞的 now 把水位线写成了 2065 年。
        var blankLaunch = EnergyHistory()
        blankLaunch.recoverAfterLaunch(now: date(2065, 1, 1, 8, 0), calendar: calendar)
        XCTAssertNil(blankLaunch.skippedCompaction)
        var afterBlankLaunch = try reload(blankLaunch, hourly: buckets)
        feedTwoFrames(&afterBlankLaunch, at: telemetryStart)
        XCTAssertEqual(afterBlankLaunch.hourly.count, expected)

        // (b) 时钟只超前一百天：没越过两年阈值，防线判定"正常"，折叠照做，
        //     水位线被推到一百天之后。
        var mildlyAhead = try makeHistory(hourly: [bucket(startingAt: date(2026, 8, 26, 9, 0))])
        mildlyAhead.recoverAfterLaunch(
            now: calendar.date(byAdding: .day, value: 100, to: today)!, calendar: calendar
        )
        XCTAssertNil(mildlyAhead.skippedCompaction)
        var afterMildLead = try reload(mildlyAhead, hourly: buckets)
        feedTwoFrames(&afterMildLead, at: telemetryStart)
        XCTAssertEqual(afterMildLead.hourly.count, expected)

        // 折叠可以降分辨率，但两条路上的总量都不能少。
        let end = date(2026, 8, 28, 0, 0)
        let total = buckets.reduce(0) { $0 + $1.energyWh }
        for history in [control, afterBlankLaunch, afterMildLead] {
            XCTAssertEqual(
                history.summary(from: nil, to: end).energyWh,
                total + history.currentSessionSummary.energyWh,
                accuracy: 0.000_001
            )
        }
    }
}
