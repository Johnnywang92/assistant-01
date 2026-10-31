import AssistantCore
import Foundation
import SwiftData

/// 财务账本块：今日/昨日/前天/本周/本月汇总、主要分类与近期逐笔明细。
struct FinancePromptBlock: PromptBlockProvider {
    let id: PromptBlockID = .finance

    func makeBlock(context: ModelContext, query: String) -> PromptBlock {
        let calendar = Calendar.current
        let currentMonth = calendar.component(.month, from: .now)
        let currentYear = calendar.component(.year, from: .now)
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: .now) ?? .now
        var todayExpense: Double = 0
        var yesterdayExpense: Double = 0
        var dayBeforeYesterdayExpense: Double = 0
        var weekExpense: Double = 0
        var monthExpense: Double = 0
        var monthIncome: Double = 0
        var categoryTotals: [String: Double] = [:]
        let windowStart = min(
            calendar.date(from: DateComponents(year: currentYear, month: currentMonth, day: 1)) ?? .now,
            calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now,
            calendar.startOfDay(for: twoDaysAgo)
        )
        let records = ((try? context.fetch(FetchDescriptor<ExpenseRecord>(
            predicate: #Predicate { $0.date >= windowStart },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        ))) ?? [])

        var recentExpenseDescriptor = FetchDescriptor<ExpenseRecord>(
            predicate: #Predicate { !$0.isIncome },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        recentExpenseDescriptor.fetchLimit = 5
        let recentExpenseRecords = (try? context.fetch(recentExpenseDescriptor)) ?? []

        let formatAmt: (Double) -> String = { val in
            if val.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0f", val)
            } else if (val * 10).truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.1f", val)
            } else {
                return String(format: "%.2f", val)
            }
        }
        let relDayLabel: (Date) -> String = { d in
            if calendar.isDateInToday(d) { return "今天" }
            if calendar.isDateInYesterday(d) { return "昨天" }
            if calendar.isDate(d, inSameDayAs: twoDaysAgo) { return "前天" }
            return "\(calendar.component(.month, from: d))月\(calendar.component(.day, from: d))日"
        }

        for r in records {
            let isThisMonth = calendar.component(.year, from: r.date) == currentYear &&
                calendar.component(.month, from: r.date) == currentMonth
            if r.isIncome {
                if isThisMonth { monthIncome += r.amount }
            } else {
                if calendar.isDateInToday(r.date) { todayExpense += r.amount }
                if calendar.isDateInYesterday(r.date) { yesterdayExpense += r.amount }
                if calendar.isDate(r.date, inSameDayAs: twoDaysAgo) { dayBeforeYesterdayExpense += r.amount }
                if calendar.isDate(r.date, equalTo: .now, toGranularity: .weekOfYear) { weekExpense += r.amount }
                if isThisMonth {
                    monthExpense += r.amount
                    categoryTotals[r.categoryRaw, default: 0] += r.amount
                }
            }
        }
        let topCatText = categoryTotals.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.key) ¥\(formatAmt($0.value))" }
            .joined(separator: "、")
        let recentExpenseText = recentExpenseRecords
            .map { "[\(relDayLabel($0.date))·\($0.categoryRaw)] \($0.title.isEmpty ? $0.categoryRaw : $0.title) ¥\(formatAmt($0.amount))" }
            .joined(separator: "、")

        let financeOverview: String = {
            var parts: [String] = []
            if todayExpense > 0 {
                parts.append("今天已消费 ¥\(formatAmt(todayExpense))")
            } else if yesterdayExpense > 0 {
                parts.append("今天暂未产生消费，昨天消费了 ¥\(formatAmt(yesterdayExpense))")
            } else {
                parts.append("今天与昨天暂未记账")
            }
            if todayExpense > 0 && yesterdayExpense > 0 {
                parts.append("昨天消费 ¥\(formatAmt(yesterdayExpense))")
            }
            if dayBeforeYesterdayExpense > 0 {
                parts.append("前天消费 ¥\(formatAmt(dayBeforeYesterdayExpense))")
            }
            parts.append("本周累计消费 ¥\(formatAmt(weekExpense))")
            parts.append("本月累计消费 ¥\(formatAmt(monthExpense))（收入 ¥\(formatAmt(monthIncome))）")
            return parts.joined(separator: "，")
        }()
        let financeDetails = "\(financeOverview)\(topCatText.isEmpty ? "" : "；主要分类：\(topCatText)")\(recentExpenseText.isEmpty ? "" : "；近期逐笔明细：\(recentExpenseText)")"
        return PromptBlock(id: id, text: "• 财务账本：\(financeDetails)")
    }
}
