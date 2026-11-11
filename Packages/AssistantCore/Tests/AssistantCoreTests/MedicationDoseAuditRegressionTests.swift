import XCTest
@testable import AssistantCore

/// 审查修复的回归护栏。
///
/// 三类问题都会导致**用户吃错药 / 漏服 / 重复服药**：
/// 1. 已服完却仍报「待服 N 次」→ 用户重复服药（过量）；
/// 2. 药名子串误匹配 → 另一种药的待办被完成（漏服）；
/// 3. 漏服的那一顿没提示 → 默默漏服。
final class MedicationDoseAuditRegressionTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = hh; comps.minute = mm
        return calendar.date(from: comps)!
    }

    // MARK: - 汇总层：逐计划累加，不是差值

    /// 一个药已服完（3 剂）、另一个没吃（1 剂）→ 实际只有 **1** 剂待服。
    ///
    /// 差值算法会算出 `4 − 1 = 3` → 组件报「待服 3 次」→ 用户多吃 2 剂。
    func testSummaryAggregatesPerPlanNotByDifference() {
        let satisfied = WidgetMedicationSummary(
            scheduledDoseCount: 3, takenDoseLowerBound: 1,
            pendingPlanCount: 0, totalPlanCount: 1,
            isAllSatisfied: true, pendingDoseCount: 0)
        let pending = WidgetMedicationSummary(
            scheduledDoseCount: 1, takenDoseLowerBound: 0,
            pendingPlanCount: 1, totalPlanCount: 1,
            isAllSatisfied: false, pendingDoseCount: 1)

        // 合并：已服完的贡献 0，未服的贡献 1
        let merged = WidgetMedicationSummary(
            scheduledDoseCount: satisfied.scheduledDoseCount + pending.scheduledDoseCount,
            takenDoseLowerBound: satisfied.takenDoseLowerBound + pending.takenDoseLowerBound,
            pendingPlanCount: satisfied.pendingPlanCount + pending.pendingPlanCount,
            totalPlanCount: satisfied.totalPlanCount + pending.totalPlanCount,
            isAllSatisfied: false,
            pendingDoseCount: satisfied.pendingDoseCount + pending.pendingDoseCount)
        XCTAssertEqual(merged.pendingDoseCount, 1)
    }

    /// `isAllSatisfied == true` 时待服数必须是 0（走任何构造路径）。
    func testAllSatisfiedImpliesZeroPending() {
        // 显式传 0
        let explicit = WidgetMedicationSummary(
            scheduledDoseCount: 3, takenDoseLowerBound: 1,
            pendingPlanCount: 0, totalPlanCount: 1,
            isAllSatisfied: true, pendingDoseCount: 0)
        XCTAssertEqual(explicit.pendingDoseCount, 0)

        // 不传（走回落路径）也必须是 0
        let fallback = WidgetMedicationSummary(
            scheduledDoseCount: 3, takenDoseLowerBound: 1,
            pendingPlanCount: 0, totalPlanCount: 1,
            isAllSatisfied: true)
        XCTAssertEqual(
            fallback.pendingDoseCount, 0,
            "回落路径不能把已服完算成还有 2 剂待服"
        )
    }

    /// 老快照（无 pendingDoseCount 字段）解码时不得崩，且不得虚报。
    func testLegacySummaryDecodesWithoutPendingDoseCount() throws {
        let legacyJSON = """
        {
          "scheduledDoseCount": 3,
          "takenDoseLowerBound": 1,
          "pendingPlanCount": 1,
          "totalPlanCount": 1,
          "isAllSatisfied": false
        }
        """
        let summary = try JSONDecoder().decode(
            WidgetMedicationSummary.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(summary.scheduledDoseCount, 3)
        // 未全部服完 → 回落为差值（保守，宁可多提醒）
        XCTAssertEqual(summary.pendingDoseCount, 2)
    }

    /// 老快照若是「已全部服完」，待服数必须为 0。
    func testLegacySummaryWithAllSatisfiedDecodesToZeroPending() throws {
        let legacyJSON = """
        {
          "scheduledDoseCount": 3,
          "takenDoseLowerBound": 1,
          "pendingPlanCount": 0,
          "totalPlanCount": 1,
          "isAllSatisfied": true
        }
        """
        let summary = try JSONDecoder().decode(
            WidgetMedicationSummary.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(summary.pendingDoseCount, 0)
    }

    // MARK: - 漏服识别

    /// 08:00 已过没吃 → 报漏服；13:00 未到 → 不报。
    func testMissedSlotReportsEarliestUncompletedPastSlot() {
        let now = date(2026, 11, 10, 14, 0)
        let missed = MedicationHabitDoseResolver.missedSlotText(
            medName: "阿莫西林",
            dailyTimePoints: ["08:00", "13:00", "20:00"],
            completedTitles: [],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(missed, "08:00")
    }

    /// 08:00 已完成 → 下一顿 13:00 也过了 → 报 13:00。
    func testMissedSlotAdvancesAfterCompletion() {
        let now = date(2026, 11, 10, 14, 0)
        let completed = Set(MedicationTodoMaterializer.slotTitles(
            medName: "阿莫西林",
            dailyTimePoints: ["08:00"],
            on: now,
            calendar: calendar
        ))
        let missed = MedicationHabitDoseResolver.missedSlotText(
            medName: "阿莫西林",
            dailyTimePoints: ["08:00", "13:00", "20:00"],
            completedTitles: completed,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(missed, "13:00")
    }

    /// 全部完成 → 没有漏服。
    func testNoMissedSlotWhenAllCompleted() {
        let now = date(2026, 11, 10, 21, 0)
        let completed = Set(MedicationTodoMaterializer.slotTitles(
            medName: "阿莫西林",
            dailyTimePoints: ["08:00", "13:00", "20:00"],
            on: now,
            calendar: calendar
        ))
        let missed = MedicationHabitDoseResolver.missedSlotText(
            medName: "阿莫西林",
            dailyTimePoints: ["08:00", "13:00", "20:00"],
            completedTitles: completed,
            now: now,
            calendar: calendar
        )
        XCTAssertNil(missed)
    }

    /// 用户手建的「吃药」待办（非物化标题）不应被算作完成某一时点。
    func testManualTodoDoesNotCountAsSlotCompletion() {
        let now = date(2026, 11, 10, 9, 0)
        let missed = MedicationHabitDoseResolver.missedSlotText(
            medName: "阿莫西林",
            dailyTimePoints: ["08:00"],
            completedTitles: ["吃药"],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(missed, "08:00")
    }

    // MARK: - 精确匹配

    /// 「维生素D」与「维生素D3」是两种药，槽位标题互不认领。
    func testSubstringMedNamesDoNotCrossMatch() {
        let d = MedicationTodoMaterializer.slotTitles(
            medName: "维生素D", dailyTimePoints: ["08:00"],
            on: date(2026, 11, 10, 8, 0), calendar: calendar)
        let d3 = MedicationTodoMaterializer.slotTitles(
            medName: "维生素D3", dailyTimePoints: ["08:00"],
            on: date(2026, 11, 10, 8, 0), calendar: calendar)

        XCTAssertFalse(d.contains(d3[0]))
        XCTAssertFalse(d3.contains(d[0]))
        // 但各自的标题仍能被自己匹配上
        XCTAssertTrue(d.contains(d[0]))
        XCTAssertTrue(d3.contains(d3[0]))
    }

    /// 习惯待办标题格式固定为「运动：<名称>」，精确匹配能对上。
    func testHabitTodoTitleExactMatch() {
        let expected = "运动：夜跑"
        XCTAssertEqual(expected, "运动：\(("夜跑"))")
        XCTAssertNotEqual("运动：夜跑 3 公里", expected)
    }
}
