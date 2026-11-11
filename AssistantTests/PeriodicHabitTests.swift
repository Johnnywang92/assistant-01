import AssistantCore
import SwiftData
import XCTest

@testable import Assistant

/// 周期性习惯打卡推进的 App 层回归测试。
///
/// `PeriodicHabit` 是 SwiftData `@Model`，Core 单测覆盖不到。这里盯住一个静默 bug：
/// 「每月」曾用固定 30 天推进，大小月交替时到期日逐月漂移（1/31 加 30 天落到 3/2）。
/// 正确口径是日历加一个月，目标月天数不足时收敛到月末。
final class PeriodicHabitTests: XCTestCase {

    /// 固定时区，测试完全可复现（禁止读墙上时钟）。
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: PeriodicHabit.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func makeHabit(_ recurrence: RecurrenceInterval, hour: Int = 9, minute: Int = 0) -> PeriodicHabit {
        let habit = PeriodicHabit(
            title: "测试习惯", recurrence: recurrence, preferredHour: hour, preferredMinute: minute
        )
        context.insert(habit)
        return habit
    }

    // MARK: - 每月：跨月不漂移

    /// 每月打卡推进一个日历月，提醒时刻回填为偏好时间（而非打卡时刻）。
    func testMonthlyAdvancesOneCalendarMonth() {
        let habit = makeHabit(.monthly, hour: 9)
        habit.completeOnce(now: date(2026, 1, 15, 14, 0), calendar: calendar)

        XCTAssertEqual(habit.nextDueAt, date(2026, 2, 15, 9, 0))
        XCTAssertEqual(habit.lastCompletedAt, date(2026, 1, 15, 14, 0))
    }

    /// 关键回归：连续每月打卡，到期日始终停在 15 号。
    /// 旧实现每次 +30 天：1/15 → 2/14 → 3/16 …逐月漂离锚点日。
    func testMonthlyDoesNotDriftAcrossMonths() {
        let habit = makeHabit(.monthly, hour: 9)

        habit.completeOnce(now: date(2026, 1, 15, 9, 0), calendar: calendar)
        XCTAssertEqual(habit.nextDueAt, date(2026, 2, 15, 9, 0))

        habit.completeOnce(now: date(2026, 2, 15, 9, 0), calendar: calendar)
        XCTAssertEqual(habit.nextDueAt, date(2026, 3, 15, 9, 0))

        habit.completeOnce(now: date(2026, 3, 15, 9, 0), calendar: calendar)
        XCTAssertEqual(habit.nextDueAt, date(2026, 4, 15, 9, 0))
    }

    /// 月末打卡收敛到短月月末：2026 非闰年，1/31 → 2/28（旧实现 +30 天会漂到 3/2）。
    func testMonthlyMonthEndClampsToShortMonth() {
        let habit = makeHabit(.monthly, hour: 9)
        habit.completeOnce(now: date(2026, 1, 31, 9, 0), calendar: calendar)

        XCTAssertEqual(habit.nextDueAt, date(2026, 2, 28, 9, 0))
    }

    /// 跨年每月：12/15 → 次年 1/15。
    func testMonthlyRollsOverYear() {
        let habit = makeHabit(.monthly, hour: 9)
        habit.completeOnce(now: date(2026, 12, 15, 9, 0), calendar: calendar)

        XCTAssertEqual(habit.nextDueAt, date(2027, 1, 15, 9, 0))
    }

    // MARK: - 其余周期按日历天间隔

    func testDailyAdvancesOneDay() {
        let habit = makeHabit(.daily, hour: 8, minute: 30)
        habit.completeOnce(now: date(2026, 11, 10, 20, 0), calendar: calendar)

        XCTAssertEqual(habit.nextDueAt, date(2026, 11, 11, 8, 30))
    }

    func testEveryOtherDayAdvancesTwoDays() {
        let habit = makeHabit(.everyOtherDay, hour: 9)
        habit.completeOnce(now: date(2026, 11, 10, 20, 0), calendar: calendar)

        XCTAssertEqual(habit.nextDueAt, date(2026, 11, 12, 9, 0))
    }

    func testWeeklyAdvancesSevenDays() {
        let habit = makeHabit(.weekly, hour: 9)
        habit.completeOnce(now: date(2026, 11, 10, 20, 0), calendar: calendar)

        XCTAssertEqual(habit.nextDueAt, date(2026, 11, 17, 9, 0))
    }

    func testBiweeklyAdvancesFourteenDays() {
        let habit = makeHabit(.biweekly, hour: 9)
        habit.completeOnce(now: date(2026, 11, 10, 20, 0), calendar: calendar)

        XCTAssertEqual(habit.nextDueAt, date(2026, 11, 24, 9, 0))
    }

    // MARK: - 同日守卫

    /// 同一天重复打卡只推进一次，且不刷新完成时刻（提醒中心与待办完成两条路径共用）。
    func testSameDaySecondCheckInDoesNotAdvance() {
        let habit = makeHabit(.weekly, hour: 9)
        habit.completeOnce(now: date(2026, 11, 10, 8, 0), calendar: calendar)
        let firstDue = habit.nextDueAt

        habit.completeOnce(now: date(2026, 11, 10, 21, 0), calendar: calendar)

        XCTAssertEqual(habit.nextDueAt, firstDue, "同日重复打卡不能把周期再推一格")
        XCTAssertEqual(habit.lastCompletedAt, date(2026, 11, 10, 8, 0))
    }
}