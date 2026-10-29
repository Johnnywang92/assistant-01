import XCTest

@testable import AssistantCore

/// SleepPlanCopy 的纪律回归：分钟数必须来自 plan 的真实字段，禁止手写概数。
final class SleepPlanCopyTests: XCTestCase {

    /// 2026-10-28 12:00:00 UTC
    private let day = Date(timeIntervalSince1970: 1_793_183_200)
    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func sample(_ onset: Int, asleep: Int = 420, daysAgo: Int = 1) -> SleepNightSample {
        SleepNightSample(
            nightKey: utcCalendar.date(byAdding: .day, value: -daysAgo, to: day)!,
            onsetOffset: onset,
            asleepMinutes: asleep
        )
    }

    /// 目标夜 10-28（周三夜）。习惯样本：7 个夜的 onset。
    private func plan(
        samples: [SleepNightSample],
        desired: Int? = nil,
        goal: Int = 420,
        now: Date? = nil
    ) -> SleepPlan {
        SleepReminderPlanner.plan(.init(
            now: now ?? utcCalendar.date(byAdding: .hour, value: -2, to: day)!,
            calendar: utcCalendar,
            nightKey: day,
            samples: samples,
            desiredBedtimeOffset: desired,
            sleepGoalMinutes: goal
        ))
    }

    /// 行2 类场景：欠 48 分钟 → 线性 −25。明细行必须写真实数字 48 与 25。
    func testReasonLinesCarryRealDebtNumbers() throws {
        // 7 夜均睡 372min = 6.2h，goal 420 → debt 48
        let p = plan(samples: (1...7).map { sample(705, asleep: 372, daysAgo: $0) })
        let lines = SleepPlanCopy.reasonLines(for: p)
        let debtLine = try XCTUnwrap(lines.first { $0.contains("总睡眠比目标") })
        XCTAssertTrue(debtLine.contains("48"), "欠账分钟数必须来自真实计算：\(debtLine)")
        XCTAssertTrue(debtLine.contains("25"), "提前分钟数必须来自真实 adjustment：\(debtLine)")
        // 概数禁用
        XCTAssertFalse(debtLine.contains("半小时"))
        XCTAssertFalse(debtLine.contains("大约"))
    }

    /// 文案的「提前 N 分钟」= shiftMinutes 真实值（body 与 reasonLines 不得矛盾）。
    func testBodyShiftMatchesShiftMinutes() throws {
        let p = plan(samples: (1...7).map { sample(705, asleep: 372, daysAgo: $0) })
        XCTAssertEqual(p.shiftMinutes, 25)
        let body = SleepPlanCopy.body(for: p)
        XCTAssertTrue(body.contains("提前 25 分钟"), body)
    }

    /// 混合锚点（w<1）时参照物是「作息基准」，不是「你的习惯」（审查 D）。
    func testBaselineLabelBlendedSaysBaselineNotHabit() {
        // n=3 → w=3/7，habit 与 desired 不同 → blended
        let p = plan(samples: (1...3).map { sample(720, daysAgo: $0) }, desired: 660)
        XCTAssertEqual(SleepPlanCopy.baselineLabel(for: p), "作息基准")
        let lines = SleepPlanCopy.reasonLines(for: p)
        XCTAssertTrue(lines.contains { $0.contains("加权") })
        XCTAssertTrue(lines.contains { $0.contains("习惯占 43%") }, "\(lines)")
    }

    /// 越界跳过：明细必须说明范围，且 outcome=skipped。
    func testOutOfRangeReasonLineMentionsRange() throws {
        let p = plan(samples: (1...7).map { sample(840, daysAgo: $0) }) // 习惯 02:00 越界
        XCTAssertEqual(p.outcome, .skipped)
        let lines = SleepPlanCopy.reasonLines(for: p)
        XCTAssertTrue(lines.contains { $0.contains("21:30") && $0.contains("01:30") })
    }

    /// 默认降级：明细必须注明「暂按默认」，不得声称智能计算。
    func testDefaultFallbackReasonLineIsHonest() {
        let p = plan(samples: [])
        XCTAssertEqual(p.confidence, .defaultFallback)
        let lines = SleepPlanCopy.reasonLines(for: p)
        XCTAssertTrue(lines.contains { $0.contains("暂无入睡记录") })
        XCTAssertTrue(SleepPlanCopy.body(for: p).contains("暂按默认时间"))
    }
}
