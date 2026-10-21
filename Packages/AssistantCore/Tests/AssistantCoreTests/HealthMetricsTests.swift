import XCTest
@testable import AssistantCore

/// Apple 健康只读接入的纯逻辑回归测试。
///
/// 核心风险（按危害排序）：
/// 1. **把「读不到」误判成「已达标」**——HealthKit 不允许查询读权限状态，
///    拒绝读取与无数据表现一致，判定一旦乐观化就会凭空造出「今天已完成运动」。
/// 2. 累计型指标被重复求和（步数/饮水算成两倍）。
/// 3. 睡眠时长被当成累计量求和（同一晚变两倍）。
/// 4. 无数据时被填成 0，UI 展示「0 步」这类看似精确的假数据。
final class HealthMetricsTests: XCTestCase {

    /// 固定一天：2026-06-01 00:00:00 UTC
    private let day = Date(timeIntervalSince1970: 1_780_300_800)

    private func value(_ kind: HealthMetricKind, _ v: Double) -> HealthMetricValue {
        HealthMetricValue(kind: kind, value: v, day: day)
    }

    // MARK: - 目标达成判定

    func testAchievedWhenValueMeetsTarget() {
        let p = HealthGoalProgress(goal: HealthGoal(kind: .stepCount, target: 8000), actual: 8000)
        XCTAssertEqual(p.status, .achieved)
        XCTAssertTrue(p.isAchieved)
        XCTAssertEqual(p.ratio, 1.0, accuracy: 0.0001)
    }

    func testNotAchievedWhenValueBelowTarget() {
        let p = HealthGoalProgress(goal: HealthGoal(kind: .stepCount, target: 8000), actual: 3200)
        XCTAssertEqual(p.status, .notAchieved)
        XCTAssertFalse(p.isAchieved)
        XCTAssertEqual(p.ratio, 0.4, accuracy: 0.0001)
    }

    /// 核心风险 1：无数据绝不能被判成已达成。
    func testNoDataNeverCountsAsAchieved() {
        let p = HealthGoalProgress(goal: HealthGoal(kind: .stepCount, target: 8000), actual: nil)
        XCTAssertEqual(p.status, .noData)
        XCTAssertFalse(p.isAchieved, "读不到数据时不能报「已达标」——那会凭空造出完成记录")
        XCTAssertEqual(p.ratio, 0)
    }

    /// 核心风险 4：无数据不能被折算成 0 值参与展示。
    func testNoDataSummaryDoesNotFabricateZero() {
        let p = HealthGoalProgress(goal: HealthGoal(kind: .dietaryWater, target: 2000), actual: nil)
        let summary = HealthMetrics.summary(for: p)
        XCTAssertFalse(summary.contains("0 毫升"), "无数据时不得展示成「0 毫升」这种精确假值")
        XCTAssertTrue(summary.contains("暂无"))
    }

    func testRatioIsClampedToOneWhenOverTarget() {
        let p = HealthGoalProgress(goal: HealthGoal(kind: .stepCount, target: 8000), actual: 20000)
        XCTAssertEqual(p.ratio, 1.0, accuracy: 0.0001, "超额完成时进度条不能溢出")
        XCTAssertTrue(p.isAchieved)
    }

    /// 目标值非法（非正数）时，达成判定必须失效而不是恒真或恒假。
    func testInvalidTargetNeverAchieves() {
        let p = HealthGoalProgress(goal: HealthGoal(kind: .stepCount, target: 0), actual: 5000)
        XCTAssertFalse(p.isAchieved)
        XCTAssertEqual(p.status, .noData)
        XCTAssertEqual(p.ratio, 0)
    }

    // MARK: - 读状态

    /// 核心风险 1 的直接体现：无法区分「拒绝读取」与「无数据」，因此状态只有三态。
    func testReadStateDistinguishesOnlyWhatCanBeKnown() {
        XCTAssertEqual(HealthReadState.notDetermined.hasRequested, false)
        XCTAssertEqual(HealthReadState.requestedNoData.hasRequested, true)
        XCTAssertEqual(HealthReadState.requestedNoData.hasData, false)
        XCTAssertEqual(HealthReadState.hasData.hasData, true)
    }

    func testEmptySnapshotIsRequestedNoData() {
        let snapshot = HealthDaySnapshot.empty(day: day)
        XCTAssertEqual(snapshot.readState, .requestedNoData)
    }

    func testSnapshotWithAnyValueIsHasData() {
        let snapshot = HealthDaySnapshot(day: day, values: [.stepCount: value(.stepCount, 100)])
        XCTAssertEqual(snapshot.readState, .hasData)
    }

    // MARK: - 聚合

    /// 核心风险 2：同一天多次上报的累计型指标要相加（分两次读到的步数应合并为总量）。
    func testAggregateSumsCumulativeMetrics() {
        let snapshot = HealthMetrics.aggregate([
            value(.stepCount, 3000),
            value(.stepCount, 5000)
        ], day: day)
        XCTAssertEqual(snapshot.value(for: .stepCount)?.value, 8000)
    }

    func testAggregateKeepsDistinctKinds() {
        let snapshot = HealthMetrics.aggregate([
            value(.stepCount, 3000),
            value(.dietaryWater, 1200)
        ], day: day)
        XCTAssertEqual(snapshot.value(for: .stepCount)?.value, 3000)
        XCTAssertEqual(snapshot.value(for: .dietaryWater)?.value, 1200)
    }

    func testAggregateEmptyInputProducesEmptySnapshot() {
        let snapshot = HealthMetrics.aggregate([], day: day)
        XCTAssertTrue(snapshot.values.isEmpty)
        XCTAssertEqual(snapshot.readState, .requestedNoData)
    }

    // MARK: - 合并快照

    /// 核心风险 2 的另一面：后台与前台各拉一次，步数应累加而不是互相覆盖。
    func testMergeSnapshotSumsCumulativeMetrics() {
        let lhs = HealthDaySnapshot(day: day, values: [.stepCount: value(.stepCount, 3000)])
        let rhs = HealthDaySnapshot(day: day, values: [.stepCount: value(.stepCount, 5000)])
        let merged = HealthMetrics.mergeSnapshot(lhs, rhs)
        XCTAssertEqual(merged.value(for: .stepCount)?.value, 8000)
    }

    /// 核心风险 3：同一晚的睡眠被读两次时不能翻倍。
    func testMergeSnapshotTakesMaxForSleep() {
        let lhs = HealthDaySnapshot(day: day, values: [.sleep: value(.sleep, 7.5)])
        let rhs = HealthDaySnapshot(day: day, values: [.sleep: value(.sleep, 7.5)])
        let merged = HealthMetrics.mergeSnapshot(lhs, rhs)
        XCTAssertEqual(merged.value(for: .sleep)?.value, 7.5, "睡眠是区间量而非累计量，重复上报应取较大值")
    }

    func testMergeSnapshotKeepsKindsMissingFromEitherSide() {
        let lhs = HealthDaySnapshot(day: day, values: [.stepCount: value(.stepCount, 3000)])
        let rhs = HealthDaySnapshot(day: day, values: [.dietaryWater: value(.dietaryWater, 800)])
        let merged = HealthMetrics.mergeSnapshot(lhs, rhs)
        XCTAssertEqual(merged.value(for: .stepCount)?.value, 3000)
        XCTAssertEqual(merged.value(for: .dietaryWater)?.value, 800)
    }

    // MARK: - 目标与待办的关联

    func testEachMetricMapsToRelatedTodoType() {
        XCTAssertEqual(HealthMetricKind.stepCount.relatedTodoType, .exercise)
        XCTAssertEqual(HealthMetricKind.activeEnergy.relatedTodoType, .exercise)
        XCTAssertEqual(HealthMetricKind.dietaryWater.relatedTodoType, .hydration)
        XCTAssertEqual(HealthMetricKind.sleep.relatedTodoType, .medication)
    }

    func testProgressForTodoTypePicksMatchingGoal() {
        let snapshot = HealthDaySnapshot(day: day, values: [.dietaryWater: value(.dietaryWater, 2500)])
        let p = HealthMetrics.progress(for: .hydration, snapshot: snapshot)
        XCTAssertEqual(p?.goal.kind, .dietaryWater)
        XCTAssertEqual(p?.status, .achieved)
    }

    /// 未观测到的指标即使目标存在，也必须是 noData 而非 notAchieved。
    func testProgressForTodoTypeWithoutDataIsNoData() {
        let snapshot = HealthDaySnapshot.empty(day: day)
        let p = HealthMetrics.progress(for: .exercise, snapshot: snapshot)
        XCTAssertEqual(p?.status, .noData)
    }

    func testProgressForAllGoalsCoversEveryDefaultGoal() {
        let snapshot = HealthDaySnapshot(day: day, values: [.stepCount: value(.stepCount, 1000)])
        let progresses = HealthMetrics.progress(for: snapshot)
        XCTAssertEqual(progresses.count, HealthGoal.defaults.count)
        // 只有步数有数据，其余三项必须是 noData
        XCTAssertEqual(progresses.first { $0.goal.kind == .stepCount }?.status, .notAchieved)
        XCTAssertEqual(progresses.first { $0.goal.kind == .dietaryWater }?.status, .noData)
        XCTAssertEqual(progresses.first { $0.goal.kind == .sleep }?.status, .noData)
    }

    // MARK: - 格式化

    func testFormatUsesKindSpecificUnits() {
        XCTAssertEqual(HealthMetrics.format(8234, for: .stepCount), "8234 步")
        XCTAssertEqual(HealthMetrics.format(420, for: .activeEnergy), "420 千卡")
        XCTAssertEqual(HealthMetrics.format(1850, for: .dietaryWater), "1850 毫升")
        XCTAssertEqual(HealthMetrics.format(7.5, for: .sleep), "7.5 小时")
        XCTAssertEqual(HealthMetrics.format(7.4, for: .sleep), "7.4 小时")
    }

    func testSummaryReportsRemainingAmount() {
        let p = HealthGoalProgress(goal: HealthGoal(kind: .stepCount, target: 8000), actual: 3000)
        XCTAssertEqual(HealthMetrics.summary(for: p), "步数还差 5000 步")
    }

    func testSummaryReportsAchieved() {
        let p = HealthGoalProgress(goal: HealthGoal(kind: .stepCount, target: 8000), actual: 9000)
        XCTAssertEqual(HealthMetrics.summary(for: p), "步数已达标（9000 步）")
    }
}
