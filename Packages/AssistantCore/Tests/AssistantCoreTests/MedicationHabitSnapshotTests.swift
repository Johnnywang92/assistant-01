import XCTest
@testable import AssistantCore

/// 小组件用药 / 打卡快照的编码与汇总口径回归测试。
///
/// 覆盖两类最容易出事的点：
/// 1. **老快照兼容** —— 快照存在 App Group 且跨版本，解码失败会被 `try?` 吞掉，
///    组件静默变空白且无任何日志；
/// 2. **截断失真** —— 快照里的 `medications` / `habits` 是 `prefix(6)` 截断的，
///    汇总数字必须由主 App 侧算好，不能让组件自己 sum。
final class MedicationHabitSnapshotTests: XCTestCase {

    private func date(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = hh; comps.minute = mm
        return cal.date(from: comps)!
    }

    // MARK: - 老快照兼容

    /// 老版本快照没有 medicationSummary / habitSummary，必须仍能解码。
    func testLegacySnapshotWithoutSummaryDecodes() throws {
        let legacyJSON = """
        {
          "topTodos": [],
          "parcels": [],
          "todayExpense": 0,
          "generatedAt": "2026-11-10T08:00:00Z"
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: data)
        XCTAssertNil(snapshot.medicationSummary)
        XCTAssertNil(snapshot.habitSummary)
        XCTAssertTrue(snapshot.medications.isEmpty)
        XCTAssertTrue(snapshot.habits.isEmpty)
    }

    /// 老版本的服药条目没有 scheduledCount / takenCount / nextDueText。
    func testLegacyMedicationEntryDecodesWithDefaults() throws {
        let legacyJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "medName": "维生素 D",
          "dosage": "1 粒",
          "mealRelationText": "餐后 30 分钟",
          "timePointsText": "08:00",
          "isTakenToday": false
        }
        """
        let data = Data(legacyJSON.utf8)
        let entry = try JSONDecoder().decode(WatchMedicationEntry.self, from: data)
        XCTAssertEqual(entry.medName, "维生素 D")
        XCTAssertFalse(entry.isTakenToday)
        XCTAssertEqual(entry.scheduledCount, 0)
        XCTAssertEqual(entry.takenCount, 0)
        XCTAssertNil(entry.nextDueText)
        XCTAssertNil(entry.activeTodoID)
    }

    /// 老版本的习惯条目没有 nextDueText。
    func testLegacyHabitEntryDecodesWithDefaults() throws {
        let legacyJSON = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "title": "夜跑 3 公里",
          "recurrenceText": "每隔一天",
          "isDueToday": true
        }
        """
        let data = Data(legacyJSON.utf8)
        let entry = try JSONDecoder().decode(WatchHabitEntry.self, from: data)
        XCTAssertEqual(entry.title, "夜跑 3 公里")
        XCTAssertTrue(entry.isDueToday)
        XCTAssertNil(entry.nextDueText)
    }

    // MARK: - 新字段往返

    func testSummaryRoundTrip() throws {
        let snapshot = WidgetSnapshot(
            topTodos: [],
            parcels: [],
            todayExpense: 0,
            medicationSummary: WidgetMedicationSummary(
                scheduledDoseCount: 6,
                takenDoseLowerBound: 2,
                pendingPlanCount: 2,
                totalPlanCount: 3,
                isAllSatisfied: false
            ),
            habitSummary: WidgetHabitSummary(dueCount: 2, totalCount: 4),
            generatedAt: date(2026, 11, 10, 15, 0)
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(decoded.medicationSummary?.scheduledDoseCount, 6)
        XCTAssertEqual(decoded.medicationSummary?.takenDoseLowerBound, 2)
        XCTAssertEqual(decoded.medicationSummary?.pendingPlanCount, 2)
        XCTAssertEqual(decoded.medicationSummary?.totalPlanCount, 3)
        XCTAssertFalse(decoded.medicationSummary?.isAllSatisfied ?? true)
        XCTAssertEqual(decoded.habitSummary?.dueCount, 2)
        XCTAssertEqual(decoded.habitSummary?.totalCount, 4)
    }

    // MARK: - 汇总口径

    func testPendingDoseCountNeverNegative() {
        let summary = WidgetMedicationSummary(
            scheduledDoseCount: 2, takenDoseLowerBound: 3,
            pendingPlanCount: 0, totalPlanCount: 1, isAllSatisfied: true)
        // 已服数不可能超过应服数；即便数据异常也不能显示负数
        XCTAssertEqual(summary.pendingDoseCount, 0)
    }

    /// 汇总数字与截断的条目列表**无关** —— 汇总由主 App 侧基于全量算。
    ///
    /// 这条用例钉住「组件不能自己 sum」：哪怕快照里只有 1 条服药条目，
    /// 汇总里的 scheduledDoseCount 也可以是 6（因为主 App 看了全部计划）。
    func testSummaryIsIndependentOfTruncatedEntryList() {
        let snapshot = WidgetSnapshot(
            topTodos: [],
            parcels: [],
            todayExpense: 0,
            medications: [
                WatchMedicationEntry(
                    id: UUID(), medName: "药 A", dosage: "1",
                    mealRelationText: "", timePointsText: "08:00",
                    isTakenToday: true, scheduledCount: 3, takenCount: 1)
            ],
            medicationSummary: WidgetMedicationSummary(
                scheduledDoseCount: 6, takenDoseLowerBound: 1,
                pendingPlanCount: 1, totalPlanCount: 2, isAllSatisfied: false),
            generatedAt: date(2026, 11, 10, 15, 0)
        )
        XCTAssertEqual(snapshot.medications.count, 1)
        XCTAssertEqual(snapshot.medicationSummary?.scheduledDoseCount, 6)
        XCTAssertEqual(snapshot.medicationSummary?.totalPlanCount, 2)
    }

    func testHabitSummaryIsAllDoneWhenNoDueItems() {
        XCTAssertTrue(WidgetHabitSummary(dueCount: 0, totalCount: 3).isAllDone)
        XCTAssertFalse(WidgetHabitSummary(dueCount: 1, totalCount: 3).isAllDone)
    }

    // MARK: - 下一时点

    func testNextScheduledSlotTextPicksFutureSlot() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = date(2026, 11, 10, 9, 0)
        let text = MedicationHabitDoseResolver.nextScheduledSlotText(
            dailyTimePoints: ["08:00", "13:00", "20:00"],
            now: now, calendar: cal)
        // 08:00 已过 → 下一个是 13:00
        XCTAssertEqual(text, "13:00")
    }

    func testNextScheduledSlotTextNilWhenAllSlotsPassed() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = date(2026, 11, 10, 21, 0)
        let text = MedicationHabitDoseResolver.nextScheduledSlotText(
            dailyTimePoints: ["08:00", "13:00", "20:00"],
            now: now, calendar: cal)
        XCTAssertNil(text)
    }

    func testNextScheduledSlotIgnoresInvalidTimePoints() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = date(2026, 11, 10, 9, 0)
        let text = MedicationHabitDoseResolver.nextScheduledSlotText(
            dailyTimePoints: ["不是时间", "13:00"],
            now: now, calendar: cal)
        XCTAssertEqual(text, "13:00")
    }
}
