import XCTest
@testable import AssistantCore

/// 睡前提醒计算规则的回归测试。
/// 核心风险：提醒时刻是「静默体验面」——算错不报错，只会表现为
/// 提醒持续偏早/偏晚、文案与实际时刻不符、或同一夜收到多条提醒。
/// 示例表（方案第 4 节）逐行作为用例落地。
final class SleepReminderPlannerTests: XCTestCase {

    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// 2026-10-28 00:00:00 UTC（周三）
    private let day = Date(timeIntervalSince1970: 1_793_145_600)
    private var nightKey: Date { day }

    /// 构造 now：10-28 20:00 UTC（晚间，落在多数 T_fire 之前）
    private var eveningNow: Date {
        utcCalendar.date(byAdding: .hour, value: 20, to: day)!
    }

    private func sample(_ onsetOffset: Int, asleep: Int = 420, daysAgo: Int = 1) -> SleepNightSample {
        let key = utcCalendar.date(byAdding: .day, value: -daysAgo, to: day)!
        return SleepNightSample(nightKey: key, onsetOffset: onsetOffset, asleepMinutes: asleep)
    }

    /// 连续 7 个工作日桶的夜样本（10-19..10-27 间的 周一~四/日 夜；目标夜 10-28 周三同桶）
    private func habitSamples(onset: Int, asleep: Int = 420) -> [SleepNightSample] {
        [1, 2, 3, 6, 7, 8, 9].map { sample(onset, asleep: asleep, daysAgo: $0) }
    }

    private func plan(
        samples: [SleepNightSample],
        desired: Int? = nil,
        now: Date? = nil,
        goal: Int = 420,
        windDown: Int = 30
    ) -> SleepPlan {
        SleepReminderPlanner.plan(.init(
            now: now ?? eveningNow,
            calendar: utcCalendar,
            nightKey: nightKey,
            samples: samples,
            desiredBedtimeOffset: desired,
            sleepGoalMinutes: goal,
            windDownMinutes: windDown
        ))
    }

    // MARK: - 第 4 节示例表

    /// 行1：晚睡型、状态正常｜习惯 00:15(735)｜无修正｜00:15 / 23:45
    func testExample1NightOwlNormalState() {
        let p = plan(samples: habitSamples(onset: 735))
        XCTAssertEqual(p.bedtimeOffset, 735)
        XCTAssertEqual(p.fireOffset, 705)
        XCTAssertEqual(p.outcome, .scheduled)
        XCTAssertEqual(p.shiftMinutes, 0)
    }

    /// 行2：早睡型、周均欠 48min｜习惯 22:50(650)｜−25｜22:25 / 21:55
    /// 同时钉死线性口径：48×0.5=24→round5=25，阶梯口径会错算成 −15
    func testExample2SleepDebtLinearNotStepped() {
        let p = plan(samples: habitSamples(onset: 650, asleep: 372))
        XCTAssertEqual(p.bedtimeOffset, 625)  // 22:25
        XCTAssertEqual(p.fireOffset, 595)    // 21:55
        XCTAssertEqual(p.shiftMinutes, 25)
        XCTAssertTrue(p.reasons.contains(.sleepDebt(debtMinutes: 48, adjustment: -25)))
    }

    /// 行3：晚睡型、白天活力 48｜P1 energyAdj 恒 0（校准任务未完成，见 energyAdjustment）
    /// 时刻 = 习惯本身；活力分不产生任何偏移
    func testExample3DaytimeEnergyIgnoredInP1() {
        XCTAssertEqual(SleepReminderPlanner.energyAdjustment(daytimeEnergyScore: 48), 0)
        XCTAssertEqual(SleepReminderPlanner.energyAdjustment(daytimeEnergyScore: nil), 0) // nil 也是 0
        let p = plan(samples: habitSamples(onset: 730)) // 00:10
        XCTAssertEqual(p.bedtimeOffset, 730)
        XCTAssertEqual(p.fireOffset, 700) // 23:40
    }

    /// 行4：真封顶｜习惯 23:00(660)｜债 100min → −45 触顶｜22:15 / 21:45
    func testExample4DebtCapsAt45() {
        XCTAssertEqual(SleepReminderPlanner.debtAdjustment(debtMinutes: 100), -45)
        let p = plan(samples: habitSamples(onset: 660, asleep: 320)) // 420-320=100
        XCTAssertEqual(p.bedtimeOffset, 615) // 22:15
        XCTAssertEqual(p.fireOffset, 585)   // 21:45
        XCTAssertEqual(p.shiftMinutes, 45)
    }

    /// 行5：冷启动｜无样本、期望 23:00(660)｜23:00 / 22:30
    func testExample5ColdStartDesiredOnly() {
        let p = plan(samples: [], desired: 660)
        XCTAssertEqual(p.bedtimeOffset, 660)
        XCTAssertEqual(p.fireOffset, 630)
        XCTAssertEqual(p.confidence, .weakPrior)
        XCTAssertTrue(p.reasons.contains(.desiredAnchor(offset: 660)))
    }

    /// 行6：弱样本 n=3｜习惯 00:00(720)、期望 23:30(690)｜w=3/7 → anchor=round5(703)=705
    func testExample6WeakPriorBlendNOver7() {
        let samples = (1...3).map { sample(720, daysAgo: $0) }
        let p = plan(samples: samples, desired: 690)
        // 3/7·720 + 4/7·690 = 308.57+394.29 = 702.86 → round5 = 705
        XCTAssertEqual(p.baselineOffset, 705)
        XCTAssertEqual(p.bedtimeOffset, 705)
        XCTAssertEqual(p.fireOffset, 675) // 23:15
        XCTAssertEqual(p.confidence, .weakPrior)
        XCTAssertTrue(p.reasons.contains(.blendedAnchor(habitOffset: 720, desiredOffset: 690, habitWeight: 3.0 / 7.0)))
    }

    /// 行7：跨午夜归属｜习惯 00:40(760)｜T_fire 00:10 → nightKey 仍是本夜、identifier 不换日
    func testExample7CrossMidnightNightKeyAttribution() throws {
        let p = plan(samples: habitSamples(onset: 760))
        XCTAssertEqual(p.bedtimeOffset, 760)  // 00:40
        XCTAssertEqual(p.fireOffset, 730)    // 00:10（墙钟已是 10-29）
        let fireDate = try XCTUnwrap(p.fireAt)
        XCTAssertEqual(utcCalendar.component(.day, from: fireDate), 29)
        // identifier 归属夜（10-28），不随墙钟日期走
        XCTAssertEqual(
            SleepReminderPlanner.notificationID(nightKey: p.nightKey, calendar: utcCalendar),
            "sleep-bedtime-20261028"
        )
    }

    // MARK: - 修正与封顶

    func testDebtAdjustmentLinearWithRound5() {
        XCTAssertEqual(SleepReminderPlanner.debtAdjustment(debtMinutes: 48), -25)  // 24→25
        XCTAssertEqual(SleepReminderPlanner.debtAdjustment(debtMinutes: 30), -15)
        XCTAssertEqual(SleepReminderPlanner.debtAdjustment(debtMinutes: 10), -5)   // 5→5
        XCTAssertEqual(SleepReminderPlanner.debtAdjustment(debtMinutes: 0), 0)
        XCTAssertEqual(SleepReminderPlanner.debtAdjustment(debtMinutes: 1000), -45) // 封顶
    }

    /// 夜醒多的样本：债必须用**总睡眠**，不是最长段（normalizer 侧同名用例的 Planner 对照）
    func testDebtUsesTotalAsleepNotLongestSegment() {
        // 总睡眠 390（碎片夜），最长段仅 210；欠债按 420-390=30 → −15
        // 若误用最长段：420-210=210 → −45，时刻会大幅偏离
        let p = plan(samples: habitSamples(onset: 660, asleep: 390))
        XCTAssertTrue(p.reasons.contains(.sleepDebt(debtMinutes: 30, adjustment: -15)))
        XCTAssertEqual(p.bedtimeOffset, 645)
    }

    func testDebtRequiresAtLeastThreeValidNights() {
        let sparse = (1...2).map { sample(660, asleep: 200, daysAgo: $0) } // 欠 220min 但只有 2 夜
        let p = plan(samples: sparse)
        XCTAssertFalse(p.reasons.contains { if case .sleepDebt = $0 { return true }; return false })
        XCTAssertEqual(p.bedtimeOffset, 660) // 无修正
    }

    func testTotalAdjNeverPositive() {
        // 超额睡眠不产生延后修正（单向只提前）
        let p = plan(samples: habitSamples(onset: 660, asleep: 500))
        XCTAssertGreaterThanOrEqual(p.bedtimeOffset ?? 0, 660)
    }

    // MARK: - clamp 与越界（审查 D）

    func testClampedByDesiredAppearsInReasons() {
        // 习惯 01:30(810)、期望 23:00(660)：w=1 时 anchor=810，被期望±60 压到 720(00:00)
        let p = plan(samples: habitSamples(onset: 810), desired: 660)
        XCTAssertEqual(p.bedtimeOffset, 720)
        XCTAssertTrue(p.reasons.contains(.clampedByDesired))
        // 文案参照物是习惯（w=1），shift 取真实差值 90
        XCTAssertEqual(p.shiftMinutes, 90)
    }

    func testClampedByRangeAppearsInReasons() {
        // 习惯 21:40(580) 近边界，债 100min 把时刻压到 535(21:15) → 被 [570,810] 夹回 570
        let p = plan(samples: habitSamples(onset: 580, asleep: 320))
        XCTAssertEqual(p.bedtimeOffset, 570)
        XCTAssertTrue(p.reasons.contains(.clampedByRange))
    }

    func testHabitOutOfRangeIsSkippedNotRewritten() {
        // 夜班族习惯 02:30(870)：即使期望 23:00 能把混合锚点拉回区间内，
        // 也不允许悄悄改成「与习惯无关的时刻」——直接跳过并说明
        let p = plan(samples: habitSamples(onset: 870), desired: 660)
        XCTAssertEqual(p.outcome, .skipped)
        XCTAssertNil(p.bedtimeOffset)
        XCTAssertTrue(p.reasons.contains(.outOfRange(baselineOffset: 870)))
    }

    // MARK: - 迟到策略（审查 #1/A）

    func testImmediateWhenFirePassedButBeforeBedtime() {
        // T_fire=23:15、T_bed=23:45（habit 705）；now=23:20 → .immediate（走卡片不发通知）
        let p = plan(samples: habitSamples(onset: 705), now: utcCalendar.date(byAdding: .minute, value: 23 * 60 + 20, to: day)!)
        XCTAssertEqual(p.outcome, .immediate)
        XCTAssertNil(p.fireAt) // 不注册通知
        XCTAssertTrue(p.reasons.contains(.immediateNow))
    }

    func testSkippedWhenPastBedtime() {
        // now=23:55 > T_bed=23:45 → 跳过，不发「该睡了」的过期提醒
        let p = plan(samples: habitSamples(onset: 705), now: utcCalendar.date(byAdding: .minute, value: 23 * 60 + 55, to: day)!)
        XCTAssertEqual(p.outcome, .skipped)
        XCTAssertTrue(p.reasons.contains(.pastBedtime))
    }

    func testScheduledWhenBeforeFire() {
        let p = plan(samples: habitSamples(onset: 705), now: utcCalendar.date(byAdding: .minute, value: 22 * 60, to: day)!)
        XCTAssertEqual(p.outcome, .scheduled)
        XCTAssertNotNil(p.fireAt)
    }

    // MARK: - 锚点 / 分桶 / n_effective

    func testWeightIsNOver7Gradient() {
        // n_eff=7 → w=1（纯习惯）；n_eff=3 → w=3/7；n=0 → 纯期望
        let seven = plan(samples: habitSamples(onset: 720), desired: 660)
        XCTAssertEqual(seven.baselineOffset, 720)
        XCTAssertTrue(seven.reasons.contains(.habitAnchor(offset: 720)))
        XCTAssertFalse(seven.reasons.contains { if case .blendedAnchor = $0 { return true }; return false })

        let three = plan(samples: (1...3).map { sample(720, daysAgo: $0) }, desired: 660)
        // 3/7·720 + 4/7·660 = 308.57 + 377.14 = 685.71 → round5 = 685
        XCTAssertEqual(three.baselineOffset, 685)

        let zero = plan(samples: [], desired: 660)
        XCTAssertEqual(zero.baselineOffset, 660)
        XCTAssertTrue(zero.reasons.contains(.desiredAnchor(offset: 660)))
    }

    func testBucketFallbackToMixedCountsEffectiveSamples() {
        // 目标夜 10-28 周三（工作日桶）。工作日桶样本 3 夜（onset 700/710/720）≥3 → 只用该组
        var samples: [SleepNightSample] = []
        for (offset, daysAgo) in [(700, 7), (710, 6), (720, 3)] { // 10-21 三、10-22 四、10-25 日
            samples.append(sample(offset, daysAgo: daysAgo))
        }
        for daysAgo in [4, 5, 11, 12, 18] { // 周五/周六夜（周末桶），不参与
            samples.append(sample(800, asleep: 300, daysAgo: daysAgo))
        }
        let p = plan(samples: samples)
        XCTAssertEqual(p.effectiveSampleCount, 3)
        XCTAssertEqual(p.habitOffset, 710) // 700/710/720 中位
    }

    func testMedianAcrossMidnightInPlanner() {
        // 跨 0 点习惯：23:50(710) 与 00:10(730) 的中位 = 00:00(720)，绝不是 12:00 附近
        let samples = [sample(710, daysAgo: 1), sample(730, daysAgo: 2), sample(720, daysAgo: 3)]
        let p = plan(samples: samples)
        XCTAssertEqual(p.habitOffset, 720)
    }

    // MARK: - 降级与诚实性（审查 #6）

    func testDefaultFallbackWithNoData() {
        let p = plan(samples: [], desired: nil)
        XCTAssertEqual(p.outcome, .scheduled) // 默认 23:00 仍提醒
        XCTAssertEqual(p.bedtimeOffset, 660)
        XCTAssertEqual(p.confidence, .defaultFallback)
        XCTAssertTrue(p.reasons.contains(.defaultAnchor))
    }

    func testPseudoDesiredFreezeRule() {
        XCTAssertTrue(SleepReminderPlanner.shouldFreezePseudoDesired(hasDesired: false, sampleCount: 14))
        XCTAssertFalse(SleepReminderPlanner.shouldFreezePseudoDesired(hasDesired: false, sampleCount: 13))
        XCTAssertFalse(SleepReminderPlanner.shouldFreezePseudoDesired(hasDesired: true, sampleCount: 30))
    }

    // MARK: - 文案纪律（审查 #3/D：分钟数只能来自 shiftMinutes）

    func testCopyUsesRealShiftMinutesNotHandwritten() {
        let p = plan(samples: habitSamples(onset: 650, asleep: 372)) // shift 25
        let body = SleepPlanCopy.body(for: p)
        XCTAssertTrue(body.contains("提前 25 分钟"))
        XCTAssertTrue(body.contains("22:50")) // 基准时刻
        XCTAssertFalse(body.contains("半小时"))
    }

    func testCopyLabelsBaselineAsHabitWhenPureHabit() {
        let p = plan(samples: habitSamples(onset: 735))
        XCTAssertTrue(SleepPlanCopy.body(for: p).contains("你的习惯"))
    }

    func testCopyLabelsBaselineAsBlendedWhenWeakPrior() {
        let p = plan(samples: (1...3).map { sample(720, daysAgo: $0) }, desired: 690)
        XCTAssertTrue(SleepPlanCopy.body(for: p).contains("作息基准"))
    }

    func testCopyOutOfRangeAndDeniedTexts() {
        let p = plan(samples: habitSamples(onset: 870), desired: 660)
        XCTAssertTrue(SleepPlanCopy.body(for: p).contains("超出提醒范围"))
        XCTAssertTrue(SleepPlanCopy.notificationDeniedText().contains("系统设置"))
    }

    func testCopyMentionsDebtMinutes() {
        let p = plan(samples: habitSamples(onset: 650, asleep: 372))
        XCTAssertTrue(SleepPlanCopy.body(for: p).contains("少 48 分钟"))
    }
}
