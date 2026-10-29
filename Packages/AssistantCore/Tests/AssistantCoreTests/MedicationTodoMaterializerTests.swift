import XCTest
@testable import AssistantCore

/// 服药待办物化规则的回归测试。
/// 核心风险：待办物化是「静默数据面」——规则错了不会报错，
/// 只会表现为「有推送提醒但首页待办不出现」或「同一天重复生成服药条目」。
final class MedicationTodoMaterializerTests: XCTestCase {

    /// 固定 UTC 公历，断言可写绝对时刻。
    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// 2026-10-28 00:00:00 UTC
    private let day = Date(timeIntervalSince1970: 1_793_145_600)

    // MARK: - 标题

    func testTodoTitleBindsTimePoint() {
        XCTAssertEqual(
            MedicationTodoMaterializer.todoTitle(medName: "布洛芬", timePoint: "08:00"),
            "服药：布洛芬（08:00）"
        )
    }

    func testTodoTitleDiffersByTimePoint() {
        let morning = MedicationTodoMaterializer.todoTitle(medName: "维生素C", timePoint: "08:00")
        let evening = MedicationTodoMaterializer.todoTitle(medName: "维生素C", timePoint: "20:00")
        XCTAssertNotEqual(morning, evening)
    }

    func testIsMaterializedTitle() {
        XCTAssertTrue(MedicationTodoMaterializer.isMaterializedTitle("服药：布洛芬（08:00）"))
        XCTAssertTrue(MedicationTodoMaterializer.isMaterializedTitle("服药：维生素C（20:30）"))
        XCTAssertFalse(MedicationTodoMaterializer.isMaterializedTitle("按时吃降压药"))
        XCTAssertFalse(MedicationTodoMaterializer.isMaterializedTitle("早晚复合维生素"))
        XCTAssertFalse(MedicationTodoMaterializer.isMaterializedTitle("服药：布洛芬（饭后）"))
        XCTAssertFalse(MedicationTodoMaterializer.isMaterializedTitle("服药：（08:00）"))
    }

    // MARK: - 时刻解析

    func testDueDateParsesHourMinuteOnGivenDay() throws {
        let due = try XCTUnwrap(
            MedicationTodoMaterializer.dueDate(timePoint: "08:30", on: day, calendar: utcCalendar)
        )
        var comps = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: due)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 10)
        XCTAssertEqual(comps.day, 28)
        XCTAssertEqual(comps.hour, 8)
        XCTAssertEqual(comps.minute, 30)
        XCTAssertEqual(comps.second, 0)
    }

    func testDueDateRejectsMalformedTimePoints() {
        XCTAssertNil(MedicationTodoMaterializer.dueDate(timePoint: "25:00", on: day, calendar: utcCalendar))
        XCTAssertNil(MedicationTodoMaterializer.dueDate(timePoint: "08:75", on: day, calendar: utcCalendar))
        XCTAssertNil(MedicationTodoMaterializer.dueDate(timePoint: "8点", on: day, calendar: utcCalendar))
        XCTAssertNil(MedicationTodoMaterializer.dueDate(timePoint: "", on: day, calendar: utcCalendar))
        XCTAssertNil(MedicationTodoMaterializer.dueDate(timePoint: "08", on: day, calendar: utcCalendar))
        XCTAssertNil(MedicationTodoMaterializer.dueDate(timePoint: "08:00:00", on: day, calendar: utcCalendar))
    }

    func testDueDateAcceptsMidnightAndEndOfDay() {
        XCTAssertNotNil(MedicationTodoMaterializer.dueDate(timePoint: "00:00", on: day, calendar: utcCalendar))
        XCTAssertNotNil(MedicationTodoMaterializer.dueDate(timePoint: "23:59", on: day, calendar: utcCalendar))
    }

    // MARK: - 槽位展开

    func testDaySlotsSkipsInvalidAndSortsAscending() {
        let slots = MedicationTodoMaterializer.daySlots(
            medName: "阿莫西林",
            dailyTimePoints: ["20:00", "坏时点", "08:00", "13:00"],
            on: day,
            calendar: utcCalendar
        )
        XCTAssertEqual(slots.map(\.title), [
            "服药：阿莫西林（08:00）",
            "服药：阿莫西林（13:00）",
            "服药：阿莫西林（20:00）"
        ])
        XCTAssertEqual(slots.map(\.dueAt).count, 3)
        XCTAssertTrue(slots[0].dueAt < slots[1].dueAt)
        XCTAssertTrue(slots[1].dueAt < slots[2].dueAt)
    }

    func testDaySlotsIncludesPastTimePoints() {
        // 晚间建档也应展开当天全部时点：漏服的要以逾期形态留在待办里供补打卡，
        // 否则「晚间才建档」时首页一条都看不到（本 bug 的直接成因之一）。
        let slots = MedicationTodoMaterializer.daySlots(
            medName: "布洛芬",
            dailyTimePoints: ["08:00", "20:00"],
            on: day,
            calendar: utcCalendar
        )
        XCTAssertEqual(slots.count, 2)
    }

    func testDaySlotsEmptyForEmptyTimePoints() {
        XCTAssertTrue(
            MedicationTodoMaterializer.daySlots(medName: "X", dailyTimePoints: [], on: day, calendar: utcCalendar).isEmpty
        )
    }

    // MARK: - 幂等判定

    func testShouldMaterializeOnlyWhenNeitherActiveNorCompletedToday() {
        // 无任何在途/今日完成记录 → 建
        XCTAssertTrue(MedicationTodoMaterializer.shouldMaterialize(hasActive: false, hasCompletedToday: false))
        // 已有未完成条目（含跨天遗留的逾期）→ 不建，避免堆积
        XCTAssertFalse(MedicationTodoMaterializer.shouldMaterialize(hasActive: true, hasCompletedToday: false))
        // 今日已打卡完成 → 不建，防止同一天重复生成
        XCTAssertFalse(MedicationTodoMaterializer.shouldMaterialize(hasActive: false, hasCompletedToday: true))
        // 两者并存 → 不建
        XCTAssertFalse(MedicationTodoMaterializer.shouldMaterialize(hasActive: true, hasCompletedToday: true))
    }
}
