import XCTest
@testable import AssistantCore

/// 「先排后截」的排序规则回归测试。
///
/// ## 为什么这条规则值得单独钉
///
/// 小组件快照里的药品 / 习惯是 `prefix(6)` 截断的。若按数据库原始顺序截断，
/// 可能截到的全是已服完的，而真正待服的那条排在第 7 位进不来 →
/// 组件显示「今日用药已服完」→ **用户漏服**。
///
/// 这类问题不报错、只是「显示得让人漏服」，是最难被发现的一类。
final class MedicationHabitSortingTests: XCTestCase {

    private struct Item {
        let name: String
        let pending: Bool
        let dueAt: Date
    }

    private func item(_ name: String, pending: Bool, dueHours: Int = 0) -> Item {
        Item(
            name: name,
            pending: pending,
            dueAt: Date(timeIntervalSince1970: TimeInterval(dueHours * 3600))
        )
    }

    // MARK: - 药品排序

    /// 待服的必须排在已服的前面。
    func testPendingMedicationsComeFirst() {
        let items = [
            item("A药", pending: false),
            item("B药", pending: false),
            item("C药", pending: true)
        ]
        let sorted = MedicationHabitDoseResolver.sortMedicationsPendingFirst(
            items, isPending: { $0.pending }, nameOf: { $0.name })
        XCTAssertEqual(sorted.map(\.name), ["C药", "A药", "B药"])
    }

    /// **核心场景**：前 6 个都服完了，第 7 个待服 → 截断后必须还能看到它。
    func testPendingMedicationIsNotTruncatedAway() {
        let items = (1...6).map { item("已服\($0)", pending: false) }
            + [item("待服药", pending: true)]
        let sorted = MedicationHabitDoseResolver.sortMedicationsPendingFirst(
            items, isPending: { $0.pending }, nameOf: { $0.name })
        let truncated = Array(sorted.prefix(6))
        XCTAssertEqual(
            truncated.first?.name, "待服药",
            "待服的药被截断掉 → 组件显示已服完 → 漏服"
        )
    }

    /// 同组内按名称排序 → 顺序稳定可复现（不依赖数据库返回顺序）。
    func testMedicationOrderingIsStableWithinGroup() {
        let items = [
            item("Z药", pending: true),
            item("A药", pending: true),
            item("M药", pending: true)
        ]
        let sorted = MedicationHabitDoseResolver.sortMedicationsPendingFirst(
            items, isPending: { $0.pending }, nameOf: { $0.name })
        XCTAssertEqual(sorted.map(\.name), ["A药", "M药", "Z药"])
    }

    /// 全部已服 → 顺序仍稳定（按名称）。
    func testAllTakenMedicationsStillOrderedDeterministically() {
        let items = [item("B药", pending: false), item("A药", pending: false)]
        let sorted = MedicationHabitDoseResolver.sortMedicationsPendingFirst(
            items, isPending: { $0.pending }, nameOf: { $0.name })
        XCTAssertEqual(sorted.map(\.name), ["A药", "B药"])
    }

    // MARK: - 习惯排序

    /// 待打卡的排前面。
    func testDueHabitsComeFirst() {
        let items = [
            item("已完成", pending: false, dueHours: 1),
            item("待打卡", pending: true, dueHours: 9)
        ]
        let sorted = MedicationHabitDoseResolver.sortHabitsDueFirst(
            items,
            isDue: { $0.pending },
            dueAt: { $0.dueAt },
            titleOf: { $0.name }
        )
        XCTAssertEqual(sorted.map(\.name), ["待打卡", "已完成"])
    }

    /// 同组内按到期时间升序（最该打的在前）。
    func testDueHabitsOrderedByDueTime() {
        let items = [
            item("晚", pending: true, dueHours: 21),
            item("早", pending: true, dueHours: 8),
            item("中", pending: true, dueHours: 13)
        ]
        let sorted = MedicationHabitDoseResolver.sortHabitsDueFirst(
            items,
            isDue: { $0.pending },
            dueAt: { $0.dueAt },
            titleOf: { $0.name }
        )
        XCTAssertEqual(sorted.map(\.name), ["早", "中", "晚"])
    }

    /// 到期时间相同时按标题兜底 → 完全确定的顺序。
    func testHabitsWithSameDueTimeFallBackToTitle() {
        let items = [
            item("B", pending: true, dueHours: 8),
            item("A", pending: true, dueHours: 8)
        ]
        let sorted = MedicationHabitDoseResolver.sortHabitsDueFirst(
            items,
            isDue: { $0.pending },
            dueAt: { $0.dueAt },
            titleOf: { $0.name }
        )
        XCTAssertEqual(sorted.map(\.name), ["A", "B"])
    }

    /// 空数组不崩。
    func testEmptyInputReturnsEmpty() {
        let meds = MedicationHabitDoseResolver.sortMedicationsPendingFirst(
            [Item](),
            isPending: { $0.pending },
            nameOf: { $0.name }
        )
        XCTAssertTrue(meds.isEmpty)
        let habits = MedicationHabitDoseResolver.sortHabitsDueFirst(
            [Item](),
            isDue: { $0.pending },
            dueAt: { $0.dueAt },
            titleOf: { $0.name }
        )
        XCTAssertTrue(habits.isEmpty)
    }
}
