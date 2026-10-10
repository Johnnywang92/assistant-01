import AssistantCore
import Foundation
import SwiftData

/// 离线语音意图与问答路由处理器
@MainActor
struct VoiceIntentProcessor {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    init() {
        self.context = Persistence.shared.mainContext
    }

    /// 评估用户语音输入，并返回助手回复
    public func process(query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "我没有听清，请再说一次。"
        }

        // 1. 意图：查快递 / 问取件码
        if trimmed.contains("快递") || trimmed.contains("取件") || trimmed.contains("包裹") {
            return queryParcels()
        }

        // 2. 意图：查流量
        if trimmed.contains("流量") || trimmed.contains("话费") {
            return queryDataUsage()
        }

        // 3. 意图：查地点 / 我在哪里
        if trimmed.contains("哪里") || trimmed.contains("地点") || trimmed.contains("家") || trimmed.contains("公司") {
            return queryLearnedPlaces()
        }

        // 4. 意图：查账 / 查开销
        if trimmed.contains("花了多少") || trimmed.contains("今天开销") || trimmed.contains("本月支出") || trimmed == "查账" {
            return queryExpenses()
        }

        // 5. 意图：一句话记账（如 "中午吃麦当劳花了 38 块"、"打车 25 元"）
        if let expense = ExpenseNaturalLanguageParser.parse(trimmed),
           (trimmed.contains("花") || trimmed.contains("元") || trimmed.contains("块") || trimmed.contains("支出") || trimmed.contains("收入") || trimmed.contains("买") || trimmed.contains("付") || trimmed.contains("记账") || trimmed.contains("记一笔")) {
            return recordExpense(expense, raw: trimmed)
        }

        // 6. 意图：添加新待办 / 备忘
        if trimmed.hasPrefix("记一下") || trimmed.hasPrefix("添加待办") || trimmed.hasPrefix("提醒我") {
            return createTodoFromVoice(trimmed)
        }

        // 7. 意图：查纪念日 / 倒数日 / 生日
        if trimmed.contains("纪念日") || trimmed.contains("生日") || trimmed.contains("倒数") || trimmed.contains("多少天") {
            return queryAnniversaries()
        }

        // 8. 意图：全部待办总览
        if trimmed.contains("待办") || trimmed.contains("要做") || trimmed.contains("安排") {
            return queryActiveTodos()
        }

        // 9. 意图：出门防丢 / 随身装备检查
        if trimmed.contains("出门") || trimmed.contains("防丢") || trimmed.contains("忘带") || trimmed.contains("随身") || trimmed.contains("要走了") {
            return queryDepartureChecklist()
        }

        // 10. 默认将未明确意图当成待办直接收录
        let item = TodoItem(type: .general, status: .active, title: trimmed, sourceText: trimmed)
        context.insert(item)
        try? context.save()
        return "已为你记下待办：\(trimmed)"
    }

    private func queryParcels() -> String {
        let active = TodoStatus.active.rawValue
        let parcel = TodoType.parcel.rawValue
        let items = (try? context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.typeRaw == parcel && $0.statusRaw == active }
        ))) ?? []

        if items.isEmpty {
            return "目前没有待取的快递。"
        }

        let desc = items.map { item in
            let code = item.pickupCode ?? "无取件码"
            let loc = item.location ?? item.station ?? ""
            return "\(item.courier ?? "快递")取件码 \(code)，在 \(loc)"
        }.joined(separator: "；")

        return "你当前有 \(items.count) 个待取包裹：\(desc)"
    }

    private func queryDataUsage() -> String {
        let records = (try? context.fetch(FetchDescriptor<DataUsageRecord>(
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
        ))) ?? []

        guard let latest = records.first else {
            return "暂未收到最近的运营商流量短信记录。"
        }

        let remainStr = latest.remainingMB.map { TodoFormatter.formatMB($0) } ?? "未知"
        let op = latest.operatorName ?? "运营商"
        return "根据最新的短信记录，你的 \(op) 剩余通用流量约为 \(remainStr)。"
    }

    private func queryLearnedPlaces() -> String {
        let places = (try? context.fetch(FetchDescriptor<LearnedPlace>())) ?? []
        let name = AppSettings.assistantName
        if places.isEmpty {
            return "\(name)还在自主学习你的常驻习惯，暂未聚类出常驻地点。"
        }
        let names = places.map { "\($0.name)（\($0.category.rawValue)）" }.joined(separator: "、")
        return "\(name)已学习到的常用地点包括：\(names)。"
    }

    private func createTodoFromVoice(_ text: String) -> String {
        var clean = text
        for prefix in ["记一下", "添加待办", "提醒我", "记住"] {
            if clean.hasPrefix(prefix) {
                clean = String(clean.dropFirst(prefix.count))
                break
            }
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { clean = text }

        let item = TodoItem(type: .general, status: .active, title: clean, sourceText: text)
        context.insert(item)
        try? context.save()
        return "好的，已为你记下待办事项：\(clean)。"
    }

    private func queryActiveTodos() -> String {
        let active = TodoStatus.active.rawValue
        let items = (try? context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.statusRaw == active }
        ))) ?? []

        if items.isEmpty {
            return "你目前没有任何未完成的待办事项，轻松一下吧！"
        }

        let titles = items.prefix(5).map(\.title).joined(separator: "；")
        return "你共有 \(items.count) 项待办，前几项是：\(titles)。"
    }

    private func queryAnniversaries() -> String {
        let items = (try? context.fetch(FetchDescriptor<AnniversaryItem>())) ?? []
        if items.isEmpty {
            return "你目前还没有记录任何纪念日或重要日子。"
        }

        let sorted = items.sorted { $0.daysUntilNext < $1.daysUntilNext }
        let descs = sorted.prefix(3).map { item in
            let days = item.daysUntilNext
            let desc = days == 0 ? "就在今天" : "还有 \(days) 天"
            return "\(item.title)\(desc)（第 \(item.nextYearsCount) 年）"
        }.joined(separator: "；")

        return "最近的纪念日有：\(descs)。"
    }

    private func recordExpense(_ parsed: ExpenseParseResult, raw: String) -> String {
        let record = ExpenseRecord(
            amount: parsed.amount,
            isIncome: parsed.isIncome,
            category: parsed.category,
            title: parsed.title,
            rawText: raw,
            date: parsed.date
        )
        context.insert(record)
        try? context.save()

        let amountText = String(format: parsed.amount.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", parsed.amount)
        if parsed.isIncome {
            return "已为你记入一笔【\(parsed.category.rawValue)】入账 \(amountText) 元（\(parsed.title)）。"
        } else {
            return "已为你记录一笔【\(parsed.category.rawValue)】支出 \(amountText) 元（\(parsed.title)）。"
        }
    }

    private func queryExpenses() -> String {
        let cal = Calendar.current
        let records = (try? context.fetch(FetchDescriptor<ExpenseRecord>())) ?? []

        let todayExpenses = records.filter { !($0.isIncome) && cal.isDateInToday($0.date) }
        let todayTotal = todayExpenses.reduce(0.0) { $0 + $1.amount }

        let currentMonth = cal.component(.month, from: .now)
        let currentYear = cal.component(.year, from: .now)
        let monthExpenses = records.filter {
            !($0.isIncome) &&
            cal.component(.month, from: $0.date) == currentMonth &&
            cal.component(.year, from: $0.date) == currentYear
        }
        let monthTotal = monthExpenses.reduce(0.0) { $0 + $1.amount }

        let todayStr = String(format: "%.1f", todayTotal)
        let monthStr = String(format: "%.1f", monthTotal)
        return "今日已支出 \(todayStr) 元（\(todayExpenses.count) 笔），本月累计支出 \(monthStr) 元。"
    }

    private func queryDepartureChecklist() -> String {
        let items = (try? context.fetch(FetchDescriptor<DepartureCheckItem>())) ?? []
        if items.isEmpty {
            return "出门前请确认随身四字诀：身（工卡证件）、手（手机）、钥（钥匙）、耳（耳机或雨伞）。目前清单暂未登记个性化装备。"
        }

        let uncheckEssentials = items.filter { $0.isEssential && !$0.isChecked }
        if !uncheckEssentials.isEmpty {
            let names = uncheckEssentials.prefix(3).map { $0.title }.joined(separator: "、")
            return "出发请留步！你还有 \(uncheckEssentials.count) 件核心装备尚未清点：如【\(names)】。出门前请确认指差四字：身、手、钥、耳！"
        }

        let uncheckedTotal = items.filter { !$0.isChecked }.count
        if uncheckedTotal == 0 {
            return "核心装备与随身物品已全部清点齐全，可以安心出发！祝你一路顺风！"
        } else {
            return "核心必带装备已就绪，还有 \(uncheckedTotal) 件非关键随身物品未打勾。请默念「身手钥耳」指差确认后出发。"
        }
    }
}
