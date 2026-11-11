import XCTest
@testable import AssistantCore

/// 乐观更新时**汇总数字必须同步**的回归测试。
///
/// 场景：用户在桌面组件点「服药打卡」→ 手表 / 组件本地立刻更新 → 但主 App
/// 还没落库落库前，桌面若仍显示「待服 2 次」，用户会以为没点上而重复点击。
/// 这类「点了没反应」的体感问题，比显示不准更伤信任。
final class WidgetOptimisticSummaryTests: XCTestCase {

    private func makeSnapshot() -> WidgetSnapshot {
        WidgetSnapshot(
            topTodos: [],
            parcels: [],
            todayExpense: 0,
            medications: [
                WatchMedicationEntry(
                    id: UUID(), medName: "维生素 D", dosage: "1 粒",
                    mealRelationText: "餐后", timePointsText: "08:00 / 20:00",
                    isTakenToday: false, scheduledCount: 2, takenCount: 0)
            ],
            habits: [
                WatchHabitEntry(
                    id: UUID(), title: "夜跑", recurrenceText: "每周",
                    isDueToday: true)
            ],
            medicationSummary: WidgetMedicationSummary(
                scheduledDoseCount: 2, takenDoseLowerBound: 0,
                pendingPlanCount: 1, totalPlanCount: 1, isAllSatisfied: false),
            habitSummary: WidgetHabitSummary(dueCount: 1, totalCount: 1),
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    func testMarkMedicationTakenSyncsEntryAndSummary() {
        var snapshot = makeSnapshot()
        let planID = snapshot.medications[0].id
        WatchSyncReconciler.applyOptimistically(
            .markMedicationTaken(planID: planID, todoID: nil), to: &snapshot)

        XCTAssertTrue(snapshot.medications[0].isTakenToday)
        XCTAssertNil(snapshot.medications[0].activeTodoID)
        XCTAssertEqual(snapshot.medications[0].takenCount, 1)
        // 汇总同步
        XCTAssertEqual(snapshot.medicationSummary?.takenDoseLowerBound, 1)
        XCTAssertEqual(snapshot.medicationSummary?.pendingPlanCount, 0)
        XCTAssertTrue(snapshot.medicationSummary?.isAllSatisfied ?? false)
        XCTAssertEqual(snapshot.medicationSummary?.pendingDoseCount, 1)
    }

    func testCompleteHabitSyncsSummary() {
        var snapshot = makeSnapshot()
        let habitID = snapshot.habits[0].id
        WatchSyncReconciler.applyOptimistically(
            .completeHabit(habitID: habitID), to: &snapshot)

        XCTAssertFalse(snapshot.habits[0].isDueToday)
        XCTAssertEqual(snapshot.habitSummary?.dueCount, 0)
        XCTAssertTrue(snapshot.habitSummary?.isAllDone ?? false)
    }

    /// 连续打卡两次不能把已服数推超过应服时点数。
    func testRepeatedTakesDoNotExceedScheduledCount() {
        var snapshot = makeSnapshot()
        let planID = snapshot.medications[0].id
        for _ in 0..<5 {
            WatchSyncReconciler.applyOptimistically(
                .markMedicationTaken(planID: planID, todoID: nil), to: &snapshot)
        }
        XCTAssertEqual(snapshot.medications[0].takenCount, 2)
        XCTAssertEqual(snapshot.medicationSummary?.takenDoseLowerBound, 2)
        XCTAssertEqual(snapshot.medicationSummary?.pendingDoseCount, 0)
    }

    /// 汇总数字不能减到负数。
    func testCountsNeverGoNegative() {
        var snapshot = makeSnapshot()
        let habitID = snapshot.habits[0].id
        for _ in 0..<3 {
            WatchSyncReconciler.applyOptimistically(
                .completeHabit(habitID: habitID), to: &snapshot)
        }
        XCTAssertEqual(snapshot.habitSummary?.dueCount, 0)
        XCTAssertGreaterThanOrEqual(snapshot.habitSummary?.dueCount ?? -1, 0)
    }

    /// 通过「完成服药待办」这条路径（点顶部的待办而不是点药丸图标）也要同步汇总。
    func testCompleteTodoPathAlsoSyncsSummary() {
        var snapshot = makeSnapshot()
        let todoID = UUID()
        snapshot.medications[0].activeTodoID = todoID
        snapshot.topTodos = [WidgetTodoEntry(id: todoID, title: "服药：维生素 D（08:00）", typeRaw: "medication")]

        WatchSyncReconciler.applyOptimistically(.completeTodo(todoID), to: &snapshot)

        XCTAssertTrue(snapshot.medications[0].isTakenToday)
        XCTAssertEqual(snapshot.medications[0].takenCount, 1)
        XCTAssertEqual(snapshot.medicationSummary?.takenDoseLowerBound, 1)
        XCTAssertEqual(snapshot.medicationSummary?.pendingPlanCount, 0)
    }
}
