import Foundation

/// One trustworthy point from the live telemetry stream. History is integrated
/// from pairs of these points; gaps are never guessed as consumed energy.
public struct EnergyMeasurement: Codable, Equatable, Sendable {
    public var at: Date
    public var totalWatts: Double
    public var perPortWatts: [Double]

    public init(at: Date, totalWatts: Double, perPortWatts: [Double]) {
        self.at = at
        self.totalWatts = Self.clean(totalWatts)
        self.perPortWatts = EnergyHistory.normalizedPortValues(perPortWatts.map(Self.clean))
    }

    private enum CodingKeys: String, CodingKey {
        case at, totalWatts, perPortWatts
    }

    /// Synthesised `Decodable` bypasses the public initializer. Decode through
    /// it explicitly so v1 archives with three entries are padded to the
    /// current six-slot shape before any integration code indexes the array.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            at: try container.decode(Date.self, forKey: .at),
            totalWatts: try container.decode(Double.self, forKey: .totalWatts),
            perPortWatts: try container.decodeIfPresent([Double].self, forKey: .perPortWatts) ?? []
        )
    }

    private static func clean(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}

/// A continuous stretch of observed telemetry, analogous to one trip in an EV
/// mileage log. `activeSeconds` is observed time, not wall time across gaps.
public struct EnergySessionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var energyWh: Double
    public var activeSeconds: TimeInterval
    public var peakWatts: Double
    public var perPortWh: [Double]
    public var sampleCount: Int

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        energyWh: Double = 0,
        activeSeconds: TimeInterval = 0,
        peakWatts: Double = 0,
        perPortWh: [Double] = [],
        sampleCount: Int = 1
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.energyWh = energyWh
        self.activeSeconds = activeSeconds
        self.peakWatts = peakWatts
        self.perPortWh = EnergyHistory.normalizedPortValues(perPortWh)
        self.sampleCount = sampleCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, energyWh, activeSeconds, peakWatts, perPortWh, sampleCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            endedAt: try container.decode(Date.self, forKey: .endedAt),
            energyWh: try container.decode(Double.self, forKey: .energyWh),
            activeSeconds: try container.decode(TimeInterval.self, forKey: .activeSeconds),
            peakWatts: try container.decode(Double.self, forKey: .peakWatts),
            perPortWh: try container.decodeIfPresent([Double].self, forKey: .perPortWh) ?? [],
            sampleCount: try container.decode(Int.self, forKey: .sampleCount)
        )
    }

    public var averageWatts: Double {
        activeSeconds > 0 ? energyWh * 3600 / activeSeconds : 0
    }
}

/// Compact one-hour storage bucket. Long-term charts aggregate these into days
/// or months, so history remains small without inventing missing raw samples.
public struct EnergyPeriodRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { startedAt }
    public var startedAt: Date
    public var endedAt: Date
    public var energyWh: Double
    public var activeSeconds: TimeInterval
    public var peakWatts: Double
    public var perPortWh: [Double]

    public init(
        startedAt: Date,
        endedAt: Date,
        energyWh: Double = 0,
        activeSeconds: TimeInterval = 0,
        peakWatts: Double = 0,
        perPortWh: [Double] = []
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.energyWh = energyWh
        self.activeSeconds = activeSeconds
        self.peakWatts = peakWatts
        self.perPortWh = EnergyHistory.normalizedPortValues(perPortWh)
    }

    private enum CodingKeys: String, CodingKey {
        case startedAt, endedAt, energyWh, activeSeconds, peakWatts, perPortWh
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            endedAt: try container.decode(Date.self, forKey: .endedAt),
            energyWh: try container.decode(Double.self, forKey: .energyWh),
            activeSeconds: try container.decode(TimeInterval.self, forKey: .activeSeconds),
            peakWatts: try container.decode(Double.self, forKey: .peakWatts),
            perPortWh: try container.decodeIfPresent([Double].self, forKey: .perPortWh) ?? []
        )
    }

    public var averageWatts: Double {
        activeSeconds > 0 ? energyWh * 3600 / activeSeconds : 0
    }
}

public struct EnergyHistorySummary: Equatable, Sendable {
    public var energyWh: Double
    public var activeSeconds: TimeInterval
    public var peakWatts: Double
    public var perPortWh: [Double]
    public var sessionCount: Int

    public init(
        energyWh: Double = 0,
        activeSeconds: TimeInterval = 0,
        peakWatts: Double = 0,
        perPortWh: [Double] = [],
        sessionCount: Int = 0
    ) {
        self.energyWh = energyWh
        self.activeSeconds = activeSeconds
        self.peakWatts = peakWatts
        self.perPortWh = EnergyHistory.normalizedPortValues(perPortWh)
        self.sessionCount = sessionCount
    }

    public var averageWatts: Double {
        activeSeconds > 0 ? energyWh * 3600 / activeSeconds : 0
    }
}

public enum EnergyHistoryGranularity: Sendable {
    case hour
    case day
    case month
}

/// Local, observation-only energy ledger. The A2687 does not expose a reliable
/// lifetime-energy counter, so this type deliberately says only what Charker saw.
public struct EnergyHistory: Codable, Equatable, Sendable {
    /// Stable storage width shared by measurements, sessions, buckets,
    /// summaries and exports. Shorter legacy arrays are zero-padded; input
    /// beyond this width is deliberately ignored.
    public static let portSlotCount = 6
    public static let maximumIntegrableGap: TimeInterval = 120

    fileprivate static func normalizedPortValues(_ values: [Double]) -> [Double] {
        (0..<portSlotCount).map { index in
            index < values.count ? values[index] : 0
        }
    }

    /// 小时桶的原始分辨率保留期。三个月覆盖 UI 上所有会按小时看的范围（今天）
    /// 并给"回头看看那天几点在充"留足余量；更早的时间里没人再按小时看，存档
    /// 却要为它每天付 24 条记录。越线的小时桶折叠成日桶——折叠只做求和与取
    /// 最大，"全部"这一档的总能量、总时长一字不差。
    public static let hourlyDetailDays = 90
    /// 日桶再保留两年，之后压成月桶。月桶是终点：一年只长 12 条，十年 120 条，
    /// 不必再往下折。
    public static let dailyDetailDays = 730
    /// 明细段与小时桶同期：能看到那天几点在充，就该能看到那天插拔了几次。
    public static let sessionDetailDays = hourlyDetailDays
    /// 数量兜底。哪怕全落在保留期内，也不让明细段无限长——每段约 230 字节，
    /// 四千段是四分之一兆，已经比任何人会翻的行数多一个量级。
    public static let sessionDetailLimit = 4000
    /// `now` 领先存档里最新一条记录多久之后，就该怀疑是时钟而不是时间出了问题。
    ///
    /// 取日桶保留期这一档：再短会误伤一台真的睡了半年的 Mac——那种情况下折叠
    /// 正是对的；再长就等于没有防线，因为一旦越过两年，一次折叠会把所有小时桶
    /// 一路压成月桶。折叠不可逆，边界因此宁可靠"宽"这一侧。
    public static let implausibleClockLead = TimeInterval(dailyDetailDays) * 86_400
    /// 折叠水位线合法能领先"当下"多久。水位线只会被排到"今天零点 + 1 天"，
    /// 夏令时把一天拉成 25 小时、`now` 又恰好落在零点时最多领先 25 小时，
    /// 所以两天已经宽出一截；再宽就该怀疑它是拿一块跑飞的时钟算出来的。
    public static let implausibleCompactionLead: TimeInterval = 2 * 86_400

    public private(set) var sessions: [EnergySessionRecord] = []
    public private(set) var hourly: [EnergyPeriodRecord] = []
    public private(set) var activeSession: EnergySessionRecord?
    /// 折叠掉明细的段数。段数只在这里续着数，所以裁剪之后"全部"里的
    /// "连接旅程 N 段"不会突然变小。
    public private(set) var archivedSessionCount: Int = 0
    /// 折叠水位线：所有被折叠的段都结束于此刻之前。范围统计靠它判断该不该
    /// 把这些段算进来。
    public private(set) var archivedSessionsBefore: Date?
    /// 最近一次因为时钟不可信而放弃的裁剪。存在即警告：只要它非 nil，存档就是
    /// 完整的、没被这次的 `now` 动过。
    public private(set) var skippedCompaction: SkippedCompaction?
    private var lastMeasurement: EnergyMeasurement?
    /// 下一次裁剪最早值得做的时刻。保留期的切点按天走，一天压一次就够。
    ///
    /// 没有这条水位线时曾经踩过一个坑：早退判断问的是"最老的一条是不是超期"，
    /// 而折叠出来的月桶本来就来自两年前，于是每一帧遥测都判定超期、每一帧都
    /// 全表扫一遍——裁剪要治的正是这个病，不能反过来自己犯。
    private var nextCompactionAt: Date?

    /// `startedAt → hourly` 下标。每秒一帧遥测都要找到当前小时的桶，原来是
    /// `firstIndex(where:)` 线性扫全表——存档越长扫得越慢，偏偏是长期运行时
    /// 最不该退化的那一步。索引不入档：它完全由 `hourly` 推导，磁盘上留一份
    /// 陈旧副本只会在下次启动时把两个小时悄悄并成一个。
    private var hourIndex: [Date: Int] = [:]

    /// 一次被拒绝的裁剪。不入档：它描述的是本次运行看到的时钟，下次启动要重新问。
    public struct SkippedCompaction: Equatable, Sendable {
        /// 被拒绝的那个 `now`。
        public var attemptedAt: Date
        /// 存档里最新一条记录的时刻，也就是判断的参照物。
        public var latestRecordAt: Date

        public init(attemptedAt: Date, latestRecordAt: Date) {
            self.attemptedAt = attemptedAt
            self.latestRecordAt = latestRecordAt
        }
    }

    public init() {}

    /// An app launch is a new observation run. If a prior process was killed,
    /// preserve its last session as completed instead of pretending it is live.
    ///
    /// 也是长期休眠后唯一确定会执行的裁剪点：一台几个月没开的 Mac 再启动时，
    /// 存档在第一帧遥测到达之前就已经压好。
    public mutating func recoverAfterLaunch(
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let watermark = latestObservation
        finishCurrentSession()
        compact(now: now, calendar: calendar, latestRecord: watermark)
    }

    /// 清空全部本机记录。折叠计数一并归零——"清空"必须是真的清空，不能留下
    /// 一个说"更早还有 N 段"的孤儿计数。
    public mutating func removeAll() {
        self = EnergyHistory()
    }

    /// 删除一个日历范围内的本机记录。小时桶是范围能量的权威来源，所以只移除
    /// 与范围相交的桶；连接旅程若跨过边界也整段移除，避免列表继续暴露一条包含
    /// 已删除时段的记录。范围外的能量桶不受影响。
    ///
    /// 返回值表示是否真的移除了内容，方便界面禁用空范围并避免无意义写盘。
    @discardableResult
    public mutating func removeRecords(from start: Date, to end: Date) -> Bool {
        guard start < end else { return false }

        let originalHourlyCount = hourly.count
        let originalSessionCount = sessions.count
        let removedActive = activeSession.map {
            $0.startedAt < end && $0.endedAt >= start
        } ?? false
        let removedLastMeasurement = lastMeasurement.map {
            $0.at >= start && $0.at < end
        } ?? false

        hourly.removeAll { $0.startedAt < end && $0.endedAt > start }
        sessions.removeAll { $0.startedAt < end && $0.endedAt >= start }
        if removedActive { activeSession = nil }
        if removedActive || removedLastMeasurement { lastMeasurement = nil }

        let changed = hourly.count != originalHourlyCount
            || sessions.count != originalSessionCount
            || removedActive
            || removedLastMeasurement
        if changed { rebuildHourIndex() }
        return changed
    }

    /// 手写而不用合成：`hourIndex` 是派生量不能入档，而三个裁剪相关的新字段
    /// 必须在老存档里缺席时也能解出来——合成的 `init(from:)` 遇到缺键会直接
    /// 抛错，那会让 v1 存档被当成损坏文件搬去 .corrupt.json。存档版本号因此
    /// 保持 1：字段是往后兼容地加进去的，不是换了一套格式。
    private enum CodingKeys: String, CodingKey {
        case sessions
        case hourly
        case activeSession
        case lastMeasurement
        case archivedSessionCount
        case archivedSessionsBefore
        case nextCompactionAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent([EnergySessionRecord].self, forKey: .sessions) ?? []
        hourly = try container.decodeIfPresent([EnergyPeriodRecord].self, forKey: .hourly) ?? []
        activeSession = try container.decodeIfPresent(EnergySessionRecord.self, forKey: .activeSession)
        lastMeasurement = try container.decodeIfPresent(EnergyMeasurement.self, forKey: .lastMeasurement)
        archivedSessionCount = try container.decodeIfPresent(Int.self, forKey: .archivedSessionCount) ?? 0
        archivedSessionsBefore = try container.decodeIfPresent(Date.self, forKey: .archivedSessionsBefore)
        nextCompactionAt = try container.decodeIfPresent(Date.self, forKey: .nextCompactionAt)
        // 裁剪、导出和折叠都指望这两个数组按时间有序，而磁盘上的顺序只是
        // 上一次写入时的顺序，不能当作保证。
        hourly.sort { $0.startedAt < $1.startedAt }
        sessions.sort { $0.startedAt < $1.startedAt }
        rebuildHourIndex()
    }

    public mutating func record(
        _ measurement: EnergyMeasurement,
        calendar: Calendar = .current
    ) {
        guard let previous = lastMeasurement else {
            beginSession(with: measurement)
            return
        }

        let elapsed = measurement.at.timeIntervalSince(previous.at)
        guard elapsed > 0 else { return }
        guard elapsed < Self.maximumIntegrableGap else {
            finishCurrentSession()
            beginSession(with: measurement)
            return
        }

        if activeSession == nil { beginSession(with: previous) }
        integrateSession(from: previous, to: measurement, seconds: elapsed)
        // 下一行就会往 hourly 里写一个 `measurement.at` 所在的桶，所以时钟的
        // 合理性必须拿"记录之前"的水位线来问：否则一台时钟跑到未来的 Mac 只要
        // 连上充电器，第一帧就把参照物抬到了未来，裁剪照样会把整个存档折光。
        let watermark = latestObservation
        integrateHourly(from: previous, to: measurement, calendar: calendar)
        lastMeasurement = measurement
        compactIfNeeded(now: measurement.at, calendar: calendar, latestRecord: watermark)
    }

    public mutating func finishCurrentSession() {
        if let activeSession { sessions.append(activeSession) }
        activeSession = nil
        lastMeasurement = nil
    }

    /// The currently open observation run only. This is deliberately derived
    /// from the live session instead of a clock range, so a manual cut resets
    /// "本次" immediately even when the next run begins in the same minute.
    public var currentSessionSummary: EnergyHistorySummary {
        guard let activeSession else { return EnergyHistorySummary() }
        return EnergyHistorySummary(
            energyWh: activeSession.energyWh,
            activeSeconds: activeSession.activeSeconds,
            peakWatts: activeSession.peakWatts,
            perPortWh: activeSession.perPortWh,
            sessionCount: 1
        )
    }

    /// A chart-ready record for the open run. Hourly storage intentionally
    /// combines every run in an hour, so it cannot represent “本次” after a
    /// manual cut; this projection keeps the current run isolated.
    public var currentSessionPeriod: EnergyPeriodRecord? {
        guard let activeSession else { return nil }
        return EnergyPeriodRecord(
            startedAt: activeSession.startedAt,
            endedAt: activeSession.endedAt,
            energyWh: activeSession.energyWh,
            activeSeconds: activeSession.activeSeconds,
            peakWatts: activeSession.peakWatts,
            perPortWh: activeSession.perPortWh
        )
    }

    public func summary(from start: Date?, to end: Date) -> EnergyHistorySummary {
        let periods = hourly.filter { period in
            period.startedAt < end && (start == nil || period.endedAt > start!)
        }
        let records = sessionRecords(from: start, to: end)
        return EnergyHistorySummary(
            energyWh: periods.reduce(0) { $0 + $1.energyWh },
            activeSeconds: periods.reduce(0) { $0 + $1.activeSeconds },
            peakWatts: periods.map(\.peakWatts).max() ?? 0,
            perPortWh: (0..<Self.portSlotCount).map { index in
                periods.reduce(0) { $0 + $1.perPortWh[index] }
            },
            sessionCount: records.count + archivedSessions(reachedFrom: start)
        )
    }

    /// 折叠掉的段只剩一个计数，没有各自的时间戳，所以只有当范围一路回溯到
    /// 水位线之前时才把它们算进来。"今天 / 本周 / 本月"因此不会凭空多出几百段，
    /// 而"全部"里的段数不会因为裁剪而变小。
    private func archivedSessions(reachedFrom start: Date?) -> Int {
        guard archivedSessionCount > 0 else { return 0 }
        guard let start else { return archivedSessionCount }
        guard let watermark = archivedSessionsBefore else { return 0 }
        return start < watermark ? archivedSessionCount : 0
    }

    public func sessionRecords(from start: Date?, to end: Date) -> [EnergySessionRecord] {
        var records = sessions
        if let activeSession { records.append(activeSession) }
        return records
            .filter { $0.startedAt < end && (start == nil || $0.endedAt >= start!) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func periods(
        from start: Date?,
        to end: Date,
        granularity: EnergyHistoryGranularity,
        calendar: Calendar = .current
    ) -> [EnergyPeriodRecord] {
        let source = hourly.filter { period in
            period.startedAt < end && (start == nil || period.endedAt > start!)
        }
        return Self.aggregate(source, granularity: granularity, calendar: calendar)
    }

    /// 同一段代码既服务于图表的按天/按月分组，也服务于保留期折叠——两处必须
    /// 用同一套口径，否则"折叠前后总量相同"就只是句口号。求和的求和、取最大的
    /// 取最大，没有平均值被再平均。
    private static func aggregate(
        _ source: [EnergyPeriodRecord],
        granularity: EnergyHistoryGranularity,
        calendar: Calendar
    ) -> [EnergyPeriodRecord] {
        var grouped: [Date: EnergyPeriodRecord] = [:]
        for period in source {
            let key: Date
            switch granularity {
            case .hour:
                key = calendar.dateInterval(of: .hour, for: period.startedAt)?.start ?? period.startedAt
            case .day:
                key = calendar.startOfDay(for: period.startedAt)
            case .month:
                key = calendar.dateInterval(of: .month, for: period.startedAt)?.start ?? period.startedAt
            }
            var aggregate = grouped[key] ?? EnergyPeriodRecord(startedAt: key, endedAt: period.endedAt)
            aggregate.endedAt = max(aggregate.endedAt, period.endedAt)
            aggregate.energyWh += period.energyWh
            aggregate.activeSeconds += period.activeSeconds
            aggregate.peakWatts = max(aggregate.peakWatts, period.peakWatts)
            for index in 0..<Self.portSlotCount {
                aggregate.perPortWh[index] += period.perPortWh[index]
            }
            grouped[key] = aggregate
        }
        return grouped.values.sorted { $0.startedAt < $1.startedAt }
    }

    private mutating func beginSession(with measurement: EnergyMeasurement) {
        activeSession = EnergySessionRecord(
            startedAt: measurement.at,
            endedAt: measurement.at,
            peakWatts: measurement.totalWatts
        )
        lastMeasurement = measurement
    }

    private mutating func integrateSession(
        from previous: EnergyMeasurement,
        to current: EnergyMeasurement,
        seconds: TimeInterval
    ) {
        guard var active = activeSession else { return }
        active.endedAt = current.at
        active.activeSeconds += seconds
        active.energyWh += Self.wattHours(previous.totalWatts, current.totalWatts, seconds)
        active.peakWatts = max(active.peakWatts, previous.totalWatts, current.totalWatts)
        active.sampleCount += 1
        for index in 0..<Self.portSlotCount {
            active.perPortWh[index] += Self.wattHours(
                previous.perPortWatts[index], current.perPortWatts[index], seconds
            )
        }
        activeSession = active
    }

    private mutating func integrateHourly(
        from previous: EnergyMeasurement,
        to current: EnergyMeasurement,
        calendar: Calendar
    ) {
        let totalSeconds = current.at.timeIntervalSince(previous.at)
        var segmentStart = previous.at
        while segmentStart < current.at {
            let hour = calendar.dateInterval(of: .hour, for: segmentStart)
            let periodStart = hour?.start ?? segmentStart
            let segmentEnd = min(hour?.end ?? current.at, current.at)
            guard segmentEnd > segmentStart else { break }

            let startFraction = segmentStart.timeIntervalSince(previous.at) / totalSeconds
            let endFraction = segmentEnd.timeIntervalSince(previous.at) / totalSeconds
            let startTotal = Self.interpolate(previous.totalWatts, current.totalWatts, startFraction)
            let endTotal = Self.interpolate(previous.totalWatts, current.totalWatts, endFraction)
            let seconds = segmentEnd.timeIntervalSince(segmentStart)
            let startPorts = (0..<Self.portSlotCount).map {
                Self.interpolate(previous.perPortWatts[$0], current.perPortWatts[$0], startFraction)
            }
            let endPorts = (0..<Self.portSlotCount).map {
                Self.interpolate(previous.perPortWatts[$0], current.perPortWatts[$0], endFraction)
            }

            accumulateHour(
                starting: periodStart,
                ending: segmentEnd,
                seconds: seconds,
                startTotal: startTotal,
                endTotal: endTotal,
                startPorts: startPorts,
                endPorts: endPorts
            )
            segmentStart = segmentEnd
        }
    }

    private mutating func accumulateHour(
        starting start: Date,
        ending end: Date,
        seconds: TimeInterval,
        startTotal: Double,
        endTotal: Double,
        startPorts: [Double],
        endPorts: [Double]
    ) {
        var index = hourIndex[start]
        if index == nil {
            hourly.append(EnergyPeriodRecord(startedAt: start, endedAt: end))
            hourIndex[start] = hourly.count - 1
            // 时钟回拨（手动改时间、NTP 大幅校正）会让新桶落在旧桶之前，而裁剪、
            // 导出和 compactIfNeeded 的早退判断都指望这个数组按时间有序。发现
            // 失序就当场排好重建索引；正常运行永远不会走到这里。
            if hourly.count > 1, hourly[hourly.count - 2].startedAt > start {
                hourly.sort { $0.startedAt < $1.startedAt }
                rebuildHourIndex()
            }
            index = hourIndex[start]
        }
        guard let index else { return }
        hourly[index].endedAt = max(hourly[index].endedAt, end)
        hourly[index].activeSeconds += seconds
        hourly[index].energyWh += Self.wattHours(startTotal, endTotal, seconds)
        hourly[index].peakWatts = max(hourly[index].peakWatts, startTotal, endTotal)
        for port in 0..<Self.portSlotCount {
            hourly[index].perPortWh[port] += Self.wattHours(startPorts[port], endPorts[port], seconds)
        }
    }

    private mutating func rebuildHourIndex() {
        hourIndex.removeAll(keepingCapacity: true)
        for (offset, record) in hourly.enumerated() { hourIndex[record.startedAt] = offset }
    }

    // MARK: - Retention
    //
    // 存档只增不减是这里最早的形状，跑一年之后它会变成每次保存都要重写的
    // 几兆 JSON。裁剪的规矩只有一条：可以降分辨率，不可以丢总量——折叠后
    // "全部"这一档的能量、时长、段数都必须和折叠前一模一样。

    /// 每帧遥测都会走一趟，所以早退只做一次可选解包加一次 Date 比较。段数上限
    /// 是唯一能在一天之内被突破的红线，它单独判一次。
    private mutating func compactIfNeeded(now: Date, calendar: Calendar, latestRecord: Date?) {
        // 时钟防线只拦住了折叠，拦不住水位线：水位线是拿上一次的 `now` 算的，
        // 而那个 `now` 可能来自一块跑飞的时钟。NTP 把时钟拉回来之后，档里就留着
        // 一个几十年后的"下次裁剪时间"，下面的早退于是永久成立——保留期要治的病
        // 反倒被这条水位线锁死了。时间往回走过就说明它是坏值，丢掉重算。
        if let scheduled = nextCompactionAt,
           scheduled.timeIntervalSince(now) > Self.implausibleCompactionLead {
            nextCompactionAt = nil
        }
        if let nextCompactionAt, now < nextCompactionAt,
           sessions.count <= Self.sessionDetailLimit { return }
        compact(now: now, calendar: calendar, latestRecord: latestRecord)
    }

    /// 裁剪的切点全部由 `now` 推出来，而 `now` 是挂钟——RTC 没电、虚拟机快照
    /// 恢复、用户手动改日期，都会让一台 Mac 在 NTP 纠正回来之前的几秒里报出
    /// 一个遥远未来的时间。按那个时间算保留期，整个 hourly 存档会被一次折光，
    /// 而折叠是不可逆的有损变换：几秒后时钟对了，小时明细也回不来了。
    ///
    /// 所以宁可这次不裁剪。跳过几乎没有代价：时钟纠正后的下一帧遥测就会再试
    /// 一次；而真正睡了三年的那台 Mac 这一轮不折，下次启动时存档里已经有了
    /// 新鲜的桶，参照物回到当下，该折的照折——只是晚了一程，没有丢东西。
    private mutating func compact(now: Date, calendar: Calendar, latestRecord: Date?) {
        // 参照物一旦定下就粘住：时钟跑飞之后每一帧遥测都会往 hourly 里写一个
        // 未来的桶，若每次都重新取"最新一条记录"，第二帧就会拿跑飞后的桶当参照，
        // 判定一切正常，防线只挡得住一秒钟。时钟被纠正回来后判断自然通过，
        // 参照物也随之清掉。
        let reference = skippedCompaction?.latestRecordAt ?? latestRecord
        if let reference, now.timeIntervalSince(reference) > Self.implausibleClockLead {
            skippedCompaction = SkippedCompaction(attemptedAt: now, latestRecordAt: reference)
            return
        }
        skippedCompaction = nil
        compactHourly(now: now, calendar: calendar)
        compactSessions(now: now, calendar: calendar)
        // 空存档里没有任何东西可折，排期却完全由 `now` 决定——一台开机时时钟就
        // 跑飞的 Mac（防线此时找不到参照物，压根不触发）会因此把早退锁到几十年后。
        // 没有参照物就不排期：第一帧遥测自己会带来一个。
        guard latestObservation != nil else {
            nextCompactionAt = nil
            return
        }
        let today = calendar.startOfDay(for: now)
        nextCompactionAt = calendar.date(byAdding: .day, value: 1, to: today)
    }

    /// 跳过裁剪的原因，给诊断导出和设置页用。说清楚两件事：什么都没被删，以及
    /// 该去查的是系统时间。
    public var skippedCompactionNotice: String? {
        guard let skippedCompaction else { return nil }
        return L10n.format(
            "系统时间（%@）远超存档里最新一条记录（%@），已跳过本次历史裁剪，未删除任何数据。请检查 Mac 的日期与时间。",
            Self.isoText(skippedCompaction.attemptedAt),
            Self.isoText(skippedCompaction.latestRecordAt),
            table: "Core"
        )
    }

    /// 存档里最新一条落盘记录的时刻。两个数组都按 `startedAt` 有序，所以只看
    /// 末尾——这条每帧都要算，不能是一次全表扫描。
    ///
    /// 只问 `hourly` 和 `sessions`：进行中的那一段和 `lastMeasurement` 的时刻
    /// 直接来自当前这块可疑的时钟，拿它们当参照等于让被告自证清白。
    private var latestObservation: Date? {
        guard let bucket = hourly.last?.endedAt else { return sessions.last?.endedAt }
        guard let session = sessions.last?.endedAt else { return bucket }
        return max(bucket, session)
    }

    /// 小时桶 → 日桶 → 月桶。已经折叠过的日桶起点就是当天零点，再被折进月桶
    /// 时按月分组仍然落在同一格，所以三级可以反复叠加而不会错位。
    private mutating func compactHourly(now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        guard
            let hourCutoff = calendar.date(byAdding: .day, value: -Self.hourlyDetailDays, to: today),
            let dayCutoff = calendar.date(byAdding: .day, value: -Self.dailyDetailDays, to: today)
        else { return }

        var kept: [EnergyPeriodRecord] = []
        var toDays: [EnergyPeriodRecord] = []
        var toMonths: [EnergyPeriodRecord] = []
        for record in hourly {
            if record.startedAt < dayCutoff {
                toMonths.append(record)
            } else if record.startedAt < hourCutoff {
                toDays.append(record)
            } else {
                kept.append(record)
            }
        }
        guard !toDays.isEmpty || !toMonths.isEmpty else { return }

        hourly = Self.aggregate(toMonths, granularity: .month, calendar: calendar)
            + Self.aggregate(toDays, granularity: .day, calendar: calendar)
            + kept
        rebuildHourIndex()
    }

    /// 段落明细里只有起止时刻和样本数是折叠时真正丢掉的东西：能量与时长本来
    /// 就从 `hourly` 汇总，不经过这里。段数交给 `archivedSessionCount` 续着数。
    private mutating func compactSessions(now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(
            byAdding: .day, value: -Self.sessionDetailDays, to: today
        ) else { return }

        var kept = sessions.drop { $0.startedAt < cutoff }
        var folded = sessions.count - kept.count
        if kept.count > Self.sessionDetailLimit {
            folded += kept.count - Self.sessionDetailLimit
            kept = kept.suffix(Self.sessionDetailLimit)
        }
        guard folded > 0 else { return }

        // 两条规则都只从头部削，所以被折叠的恰好是最前面的 folded 条。
        let watermark = sessions.prefix(folded).map(\.endedAt).max()
        sessions = Array(kept)
        archivedSessionCount += folded
        archivedSessionsBefore = [archivedSessionsBefore, watermark].compactMap { $0 }.max()
    }

    private static func interpolate(_ start: Double, _ end: Double, _ fraction: Double) -> Double {
        start + (end - start) * max(0, min(1, fraction))
    }

    private static func wattHours(_ start: Double, _ end: Double, _ seconds: TimeInterval) -> Double {
        seconds * (start + end) / 2 / 3600
    }
}

// MARK: - Export
//
// 导出留在这一层而不是视图里，是为了让 CSV 与 JSON 共用同一份口径声明和同一套
// 取数逻辑：视图只负责挑文件位置和写盘。两种格式都不含序列号、MAC 或账号信息
// ——这里本来就没有这些字段，声明里也照直说明，免得导出文件被当成设备日志转发。

extension EnergyHistory {
    /// 导出文件顶部的口径声明。四句话回答四个"这数字能不能信"的问题：
    /// 谁算的、设备给不给账本、断档怎么处理、里面有没有身份信息。
    public static var exportNotice: [String] {
        [
            L10n.text("Charker 能耗导出：数值由 Charker 在本机对 BLE 遥测做时间积分推算。", table: "Core"),
            L10n.text("充电器不提供能量账本，这些是观测推算值，不是设备读数。", table: "Core"),
            L10n.text("Charker 未运行或未连接的时间是空洞，不计入，也不补值。", table: "Core"),
            L10n.text("文件只含时间与功率/能量聚合值，不含序列号、MAC 或账号信息。", table: "Core"),
        ]
    }

    /// 本地时区的 ISO 8601。刻意不用 UTC：文件里的时刻要和用户在界面上看到的
    /// 同一个数字对上，导出才好和别的记录对照。
    private static let isoStyle = Date.ISO8601FormatStyle(timeZone: .current)

    private static func isoText(_ date: Date) -> String { date.formatted(isoStyle) }

    /// `String(format:)` 不带 locale 参数时按 POSIX 走，小数点永远是点号——
    /// CSV 的数字列不能跟着系统区域变成逗号，否则整行的分隔就废了。
    private static func number(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    /// 表结构故意扁平：一张表、一列 `kind` 区分小时桶与连接段，所有字段都是
    /// 数字或 ISO 时间，没有需要转义的逗号和引号。
    public func exportCSV(generatedAt: Date = Date()) -> String {
        var lines = Self.exportNotice.map { "# " + $0 }
        lines.append("# generated_at: \(Self.isoText(generatedAt))")
        if archivedSessionCount > 0, let before = archivedSessionsBefore {
            lines.append("# " + L10n.format(
                "%@ 之前的 %d 段连接旅程已折叠为汇总，能量与时长仍计入小时/日/月桶，但不再单独成行。",
                Self.isoText(before), archivedSessionCount,
                table: "Core"
            ))
        }
        let portColumns = ["c1_wh", "c2_wh", "c3_wh", "c4_wh", "a1_wh", "a2_wh"]
        lines.append(([
            "kind", "start", "end", "energy_wh", "active_seconds", "peak_w", "average_w",
        ] + portColumns + ["samples"]).joined(separator: ","))

        for period in hourly {
            lines.append(([
                "bucket",
                Self.isoText(period.startedAt),
                Self.isoText(period.endedAt),
                Self.number(period.energyWh, 4),
                Self.number(period.activeSeconds, 0),
                Self.number(period.peakWatts, 2),
                Self.number(period.averageWatts, 2),
            ] + (0..<Self.portSlotCount).map {
                Self.number(period.perPortWh[$0], 4)
            } + [""]).joined(separator: ","))
        }

        for record in exportableSessions() {
            lines.append(([
                "session",
                Self.isoText(record.startedAt),
                Self.isoText(record.endedAt),
                Self.number(record.energyWh, 4),
                Self.number(record.activeSeconds, 0),
                Self.number(record.peakWatts, 2),
                Self.number(record.averageWatts, 2),
            ] + (0..<Self.portSlotCount).map {
                Self.number(record.perPortWh[$0], 4)
            } + ["\(record.sampleCount)"]).joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public func exportJSON(generatedAt: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.isoText(date))
        }
        return try encoder.encode(ExportDocument(
            schema: "charker.energy-history.1",
            generatedAt: generatedAt,
            notice: Self.exportNotice,
            archivedSessionCount: archivedSessionCount,
            archivedSessionsBefore: archivedSessionsBefore,
            buckets: hourly,
            sessions: exportableSessions()
        ))
    }

    /// 进行中的那一段也要出现在导出里，否则"刚充完就导出"会少掉最有用的一段。
    private func exportableSessions() -> [EnergySessionRecord] {
        guard let activeSession else { return sessions }
        return (sessions + [activeSession]).sorted { $0.startedAt < $1.startedAt }
    }

    private struct ExportDocument: Encodable {
        let schema: String
        let generatedAt: Date
        let notice: [String]
        let archivedSessionCount: Int
        let archivedSessionsBefore: Date?
        let buckets: [EnergyPeriodRecord]
        let sessions: [EnergySessionRecord]
    }
}

public struct EnergyHistoryLoadResult: Sendable {
    public var history: EnergyHistory
    public var warning: String?

    public init(history: EnergyHistory, warning: String? = nil) {
        self.history = history
        self.warning = warning
    }
}

/// Versioned JSON persistence in the app's own Application Support container.
/// The archive stores aggregated observations only—no device identifiers.
public final class EnergyHistoryStore: @unchecked Sendable {
    private struct Archive: Codable {
        var version: Int
        var history: EnergyHistory
    }

    private let url: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let version = 1

    public init(url: URL? = EnergyHistoryStore.defaultURL()) {
        self.url = url
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public static func defaultURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let directory = support.appendingPathComponent("Charker", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("energy-history-v1.json")
    }

    public var path: String { url?.path ?? "—" }

    public func load() -> EnergyHistoryLoadResult {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return EnergyHistoryLoadResult(history: EnergyHistory())
        }
        do {
            let data = try Data(contentsOf: url)
            let archive = try decoder.decode(Archive.self, from: data)
            guard archive.version == Self.version else {
                let backup = preserveCorruptArchive(at: url)
                let recovery = backup == nil
                    ? L10n.text("原文件不会在本次加载中被覆盖。", table: "Core")
                    : L10n.format(
                        "原数据已复制为 %@。", backup!.lastPathComponent,
                        table: "Core"
                    )
                return EnergyHistoryLoadResult(
                    history: EnergyHistory(),
                    warning: L10n.format(
                        "能耗历史来自不受支持的版本，%@", recovery,
                        table: "Core"
                    )
                )
            }
            var history = archive.history
            history.recoverAfterLaunch()
            return EnergyHistoryLoadResult(history: history)
        } catch {
            let backup = preserveCorruptArchive(at: url)
            let recovery = backup == nil
                ? L10n.text("原文件未被覆盖。", table: "Core")
                : L10n.format(
                    "原数据已复制为 %@。", backup!.lastPathComponent,
                    table: "Core"
                )
            return EnergyHistoryLoadResult(
                history: EnergyHistory(),
                warning: L10n.format(
                    "能耗历史无法读取，%@ %@", recovery, error.localizedDescription,
                    table: "Core"
                )
            )
        }
    }

    public func save(_ history: EnergyHistory) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try encoder.encode(Archive(version: Self.version, history: history))
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 把磁盘副本和调用方手里的历史当成一次清空操作。先删文件、后改内存：
    /// 任一磁盘删除失败时，调用方仍握着完整历史，可以选择把主存档写回来，
    /// 而不会出现“页面已经空了，但旧文件下次启动又回来”的半清空状态。
    public func clear(_ history: inout EnergyHistory) throws {
        try removeArchive()
        history.removeAll()
    }

    /// 范围删除后原子替换主存档，并移除可能含有已删除数据的恢复副本。若删除
    /// 恢复副本失败则抛错；调用方仍可用修改前的内存副本把主存档恢复回来。
    public func replaceAfterRemoval(_ history: EnergyHistory) throws {
        try save(history)
        try removeRecoveryArchive()
    }

    /// 删除磁盘存档，连同 .corrupt.json 备份一起——"清空历史"必须把用户能想到
    /// 的每一份副本都带走，只删主文件会留下一个下次损坏时又被翻出来的旧影子。
    ///
    /// 调用方必须在同一步把内存里的 `EnergyHistory` 换成空的，否则下一次
    /// `save(_:)` 会把刚删掉的东西原样写回来。
    public func removeArchive() throws {
        guard let url else { return }
        let backup = recoveryArchiveURL(for: url)
        for candidate in [url, backup] where FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.removeItem(at: candidate)
        }
    }

    private func removeRecoveryArchive() throws {
        guard let url else { return }
        let backup = recoveryArchiveURL(for: url)
        guard FileManager.default.fileExists(atPath: backup.path) else { return }
        try FileManager.default.removeItem(at: backup)
    }

    private func recoveryArchiveURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("corrupt.json")
    }

    private func preserveCorruptArchive(at url: URL) -> URL? {
        let backup = recoveryArchiveURL(for: url)
        if FileManager.default.fileExists(atPath: backup.path) { return backup }
        do {
            try FileManager.default.copyItem(at: url, to: backup)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            return backup
        } catch {
            return nil
        }
    }
}
