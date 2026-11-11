import AssistantCore
import SwiftData
import XCTest

@testable import Assistant

/// 支出「今日」唯一口径的 App 层回归测试。
///
/// 曾经 App 头部「今日支出」排除待结算账，而小组件/语音播报的今日合计却计入，
/// 同一笔报销待到账让两处「今日支出」给出两个数字。口径统一到
/// `ExpenseRecord.countsAsTodayExpense`：非收入、非待结算、归属日为今天。
final class ExpenseTodayCaliberTests: XCTestCase {

    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    /// 2026-11-10 14:00 +08:00
    private let now: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 14, minute: 0))!
    }()

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: ExpenseRecord.self,
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

    private func record(
        amount: Double,
        isIncome: Bool = false,
        isPending: Bool = false,
        date: Date
    ) -> ExpenseRecord {
        let record = ExpenseRecord(
            amount: amount, isIncome: isIncome, title: "测试账目", date: date, isPending: isPending
        )
        context.insert(record)
        return record
    }

    // MARK: - 计入规则

    func testTodayOrdinaryExpenseCounts() {
        let r = record(amount: 30, date: date(2026, 11, 10, 9, 0))
        XCTAssertTrue(r.countsAsTodayExpense(now: now, calendar: calendar))
    }

    /// 待结算（报销待到账等）尚未真正花出，不计入今日支出。这是两套口径的分歧点。
    func testPendingExpenseExcluded() {
        let r = record(amount: 50, isPending: true, date: date(2026, 11, 10, 9, 0))
        XCTAssertFalse(r.countsAsTodayExpense(now: now, calendar: calendar))
    }

    func testIncomeExcluded() {
        let r = record(amount: 100, isIncome: true, date: date(2026, 11, 10, 9, 0))
        XCTAssertFalse(r.countsAsTodayExpense(now: now, calendar: calendar))
    }

    func testYesterdayExpenseExcluded() {
        let r = record(amount: 20, date: date(2026, 11, 9, 9, 0))
        XCTAssertFalse(r.countsAsTodayExpense(now: now, calendar: calendar))
    }

    func testTomorrowExpenseExcluded() {
        let r = record(amount: 20, date: date(2026, 11, 11, 9, 0))
        XCTAssertFalse(r.countsAsTodayExpense(now: now, calendar: calendar))
    }

    // MARK: - 合计口径

    /// 混合账本下「今日支出」只算今日普通支出：待结算与收入都不计。
    /// App 头部汇总与小组件取数共用此判定，结果必须一致。
    func testTodayTotalExcludesPendingAndIncome() {
        let records = [
            record(amount: 30, date: date(2026, 11, 10, 9, 0)),
            record(amount: 50, isPending: true, date: date(2026, 11, 10, 10, 0)),
            record(amount: 100, isIncome: true, date: date(2026, 11, 10, 11, 0)),
            record(amount: 20, date: date(2026, 11, 9, 9, 0))
        ]

        let total = records
            .filter { $0.countsAsTodayExpense(now: now, calendar: calendar) }
            .reduce(0.0) { $0 + $1.amount }

        XCTAssertEqual(total, 30, accuracy: 0.001)
    }
}