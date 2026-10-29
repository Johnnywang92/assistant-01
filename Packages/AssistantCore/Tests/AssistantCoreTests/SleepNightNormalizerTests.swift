import XCTest
@testable import AssistantCore

/// 睡眠夜归一化的回归测试。
/// 核心风险：睡眠数据是「静默数据面」——归一化错了不报错，
/// 只会表现为提醒时刻持续偏离、或把傍晚小睡当成入睡时间。
final class SleepNightNormalizerTests: XCTestCase {

    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// 2026-10-28 00:00:00 UTC（周三）
    private let day = Date(timeIntervalSince1970: 1_793_145_600)

    private func make(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = day
        comps.hour = hour; comps.minute = minute
        return utcCalendar.date(from: comps)!
    }

    // MARK: 夜归属

    func testNightKeyEveningBelongsToSameDay() {
        let t = make(28, 23, 30)
        XCTAssertEqual(SleepNightNormalizer.nightKey(for: t, calendar: utcCalendar), utcCalendar.startOfDay(for: make(28, 0, 0)))
    }

    func testNightKeyAfterMidnightBelongsToPreviousDay() {
        let t = make(29, 0, 30)
        XCTAssertEqual(SleepNightNormalizer.nightKey(for: t, calendar: utcCalendar), utcCalendar.startOfDay(for: make(28, 0, 0)))
    }

    func testNightKeyNoonBoundary() {
        XCTAssertEqual(
            SleepNightNormalizer.nightKey(for: make(28, 12, 0), calendar: utcCalendar),
            utcCalendar.startOfDay(for: make(28, 0, 0))
        )
        XCTAssertEqual(
            SleepNightNormalizer.nightKey(for: make(28, 11, 59), calendar: utcCalendar),
            utcCalendar.startOfDay(for: make(27, 0, 0))
        )
    }

    // MARK: offset ↔ Date

    func testOffsetMapsClockFaceToMinutesSinceNoon() {
        // 跨 0 点的内部表示：23:45→705、00:00→720、00:30→750
        XCTAssertEqual(SleepNightNormalizer.offset(of: make(28, 23, 45), nightKey: make(28, 0, 0), calendar: utcCalendar), 705)
        XCTAssertEqual(SleepNightNormalizer.offset(of: make(29, 0, 0), nightKey: make(28, 0, 0), calendar: utcCalendar), 720)
        XCTAssertEqual(SleepNightNormalizer.offset(of: make(29, 0, 30), nightKey: make(28, 0, 0), calendar: utcCalendar), 750)
    }

    func testMedianAcrossMidnightIsNotNoon() {
        // 23:50 与 00:10 的中位必须是 00:00（offset 720），钟面直取中位会错算到 12:00 附近
        let offsets = [710, 730]
        let mid = SleepReminderPlanner.round5(SleepReminderPlanner.median(offsets))
        XCTAssertEqual(mid, 720)
        let (h, m) = SleepNightNormalizer.wallClock(of: mid)
        XCTAssertEqual(h, 0)
        XCTAssertEqual(m, 0)
    }

    func testDateConversionRoundTripsAcrossMidnight() throws {
        let key = make(28, 0, 0)
        let d = try XCTUnwrap(SleepNightNormalizer.date(nightKey: key, offset: 750, calendar: utcCalendar))
        XCTAssertEqual(utcCalendar.component(.day, from: d), 29)
        XCTAssertEqual(utcCalendar.component(.hour, from: d), 0)
        XCTAssertEqual(utcCalendar.component(.minute, from: d), 30)
        XCTAssertEqual(SleepNightNormalizer.offset(of: d, nightKey: key, calendar: utcCalendar), 750)
    }

    func testDateConversionIsWallClockOnDSTTransition() throws {
        // 2026-03-08 美东春季拨快：组件换算必须仍得墙上 00:30，
        // 「12:00 + offset×60 秒」的绝对时间加法在这里会偏一小时。
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 7; comps.hour = 0; comps.minute = 0
        let key = try XCTUnwrap(ny.date(from: comps))
        let d = try XCTUnwrap(SleepNightNormalizer.date(nightKey: key, offset: 750, calendar: ny))
        XCTAssertEqual(ny.component(.day, from: d), 8)
        XCTAssertEqual(ny.component(.hour, from: d), 0)
        XCTAssertEqual(ny.component(.minute, from: d), 30)
        XCTAssertEqual(SleepNightNormalizer.offset(of: d, nightKey: key, calendar: ny), 750)
    }

    func testHourMinuteHelpersRoundTrip() {
        XCTAssertEqual(SleepNightNormalizer.offset(hourMinute: "23:30"), 690)
        XCTAssertEqual(SleepNightNormalizer.offset(hourMinute: "00:30"), 750)
        XCTAssertEqual(SleepNightNormalizer.offset(hourMinute: "21:30"), 570)
        XCTAssertEqual(SleepNightNormalizer.hourMinute(offset: 750), "00:30")
        XCTAssertEqual(SleepNightNormalizer.hourMinute(offset: 705), "23:45")
        XCTAssertNil(SleepNightNormalizer.offset(hourMinute: "25:00"))
    }

    // MARK: 样本归一化

    func testSampleTakesLongestSegmentStartAsOnsetNotEarliest() throws {
        // 傍晚沙发小睡 20:00–20:30，主睡眠 23:30–07:00
        // onset 必须是 23:30（最长段），不是 20:00（最早 start）
        let key = make(28, 0, 0)
        let sample = try XCTUnwrap(SleepNightNormalizer.sample(
            nightKey: key,
            segments: [
                (make(28, 20, 0), make(28, 20, 30)),
                (make(28, 23, 30), make(29, 7, 0))
            ],
            calendar: utcCalendar
        ))
        XCTAssertEqual(sample.onsetOffset, 690) // 23:30
        XCTAssertEqual(sample.asleepMinutes, 30 + 450)
    }

    func testSampleTotalAsleepSumsFragmentsNotLongestSegment() throws {
        // 夜醒多：23:00–02:00（3h）+ 02:30–06:00（3.5h）
        // 最长段 3.5h，但总睡眠必须是 6.5h（390min）——睡眠债口径用总数
        let key = make(28, 0, 0)
        let sample = try XCTUnwrap(SleepNightNormalizer.sample(
            nightKey: key,
            segments: [
                (make(28, 23, 0), make(29, 2, 0)),
                (make(29, 2, 30), make(29, 6, 0))
            ],
            calendar: utcCalendar
        ))
        XCTAssertEqual(sample.asleepMinutes, 390)
        XCTAssertEqual(sample.onsetOffset, 870) // 最长段 02:30 起
    }

    func testSampleMergesOverlappingMultiSourceIntervals() throws {
        // 手表 + 第三方 App 重叠：合并后总时长不是两段之和
        let key = make(28, 0, 0)
        let sample = try XCTUnwrap(SleepNightNormalizer.sample(
            nightKey: key,
            segments: [
                (make(28, 23, 0), make(29, 5, 0)),
                (make(28, 23, 30), make(29, 5, 30))
            ],
            calendar: utcCalendar
        ))
        XCTAssertEqual(sample.asleepMinutes, 390) // 23:00–05:30 合并
        XCTAssertEqual(sample.onsetOffset, 660)   // 23:00
    }

    func testSampleClipsSegmentsToNightWindow() throws {
        // 11:00–13:00 跨夜窗口起点（12:00）：只计 12:00–13:00 的 60 分钟
        let key = make(28, 0, 0)
        let sample = try XCTUnwrap(SleepNightNormalizer.sample(
            nightKey: key,
            segments: [(make(28, 11, 0), make(28, 13, 0))],
            calendar: utcCalendar
        ))
        XCTAssertEqual(sample.asleepMinutes, 60)
    }

    func testSampleReturnsNilForEmptyNight() {
        XCTAssertNil(SleepNightNormalizer.sample(nightKey: make(28, 0, 0), segments: [], calendar: utcCalendar))
        XCTAssertNil(SleepNightNormalizer.sample(
            nightKey: make(28, 0, 0),
            segments: [(make(30, 8, 0), make(30, 9, 0))], // 不在窗口内
            calendar: utcCalendar
        ))
    }

    // MARK: 分桶（已知限制：不识别调休/法定假日）

    func testWeekendNightBucketUsesNightOwnership() {
        // 2026-10-28 周三 → 工作日桶；10-30 周五夜、10-31 周六夜 → 周末桶
        XCTAssertFalse(SleepReminderPlanner.isWeekendNight(make(28, 0, 0), calendar: utcCalendar))
        XCTAssertTrue(SleepReminderPlanner.isWeekendNight(make(30, 0, 0), calendar: utcCalendar))
        XCTAssertTrue(SleepReminderPlanner.isWeekendNight(make(31, 0, 0), calendar: utcCalendar))
        XCTAssertFalse(SleepReminderPlanner.isWeekendNight(make(29, 0, 0), calendar: utcCalendar))
    }
}
