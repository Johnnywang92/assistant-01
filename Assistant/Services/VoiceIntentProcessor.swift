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

    /// 评估用户语音输入并返回意图结果（支持气泡动作选项卡片与手动设置中断）
    public func processIntent(query: String) async -> VoiceIntentResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return VoiceIntentResult(reply: L10n.tr("我没有听清，请再说一次。"))
        }

        // 优先检查是否命中对话式设置意图
        if ConversationSettingsEngine.shared.isSettingsQuery(trimmed),
           let settingResult = ConversationSettingsEngine.shared.processSettingsCommand(trimmed) {
            return settingResult
        }

        // 学习某项技能：走学习路径拆解（必须先于通用规划，否则会被平铺清单模板吃掉）
        if SkillPathPlanner.isLearningQuery(trimmed),
           let draft = SkillPathPlanner.build(query: trimmed) {
            return VoiceIntentResult(
                reply: L10n.tr(draft.summaryText),
                skillPlan: draft
            )
        }

        // 检查是否命中任务规划与待办拆解意图
        if TaskPlanningEngine.shared.isPlanningQuery(trimmed),
           let plan = TaskPlanningEngine.shared.decomposeTask(query: trimmed) {
            return VoiceIntentResult(
                reply: L10n.choose(
                    "\(plan.summary)\n我已将为你规划拆解好的具体待办整理在下方卡片中，你可以预览调整，确认后点击「一键加入待办」即可写入你的待办列表。",
                    "\(plan.summary)\nI've broken this down into actionable to-dos in the card below. Preview and adjust them, then tap 'Add All to To-Dos'."
                ),
                planningPlan: plan
            )
        }

        // 默认常规业务问答与意图收录
        let reply = await processCore(trimmed: trimmed)
        return VoiceIntentResult(reply: reply)
    }

    /// 评估用户语音输入，并返回助手回复纯文本
    public func process(query: String) async -> String {
        let res = await processIntent(query: query)
        return res.reply
    }

    private func processCore(trimmed: String) async -> String {
        let lower = trimmed.lowercased()
        // 0. 意图：查日报 / 周报 / 月报 / 今日复盘
        if trimmed.contains("日报") || trimmed.contains("周报") || trimmed.contains("月报") || trimmed.contains("年报") || trimmed.contains("年度总结") || trimmed.contains("本年总结") || trimmed.contains("复盘") || trimmed.contains("今天总结") || trimmed.contains("今日总结") || trimmed.contains("本周总结") || trimmed.contains("本月总结")
            || lower.contains("daily report") || lower.contains("weekly report") || lower.contains("monthly report") || lower.contains("annual report") || lower.contains("yearly report") || lower.contains("today's summary") {
            let period: ReportPeriodType = {
                if trimmed.contains("年报") || trimmed.contains("年度") || trimmed.contains("本年") || lower.contains("annual") || lower.contains("yearly") {
                    return .yearly
                } else if trimmed.contains("月报") || trimmed.contains("本月") || lower.contains("monthly") {
                    return .monthly
                } else if trimmed.contains("周报") || trimmed.contains("本周") || lower.contains("weekly") {
                    return .weekly
                } else {
                    return .daily
                }
            }()
            let report = PeriodicReportManager.shared.generateReport(period: period, for: .now, context: context)
            return L10n.choose(
                "【\(report.title)】\(report.smartSummary)（已搞定 \(report.completedTodos.count) 件事项，总支出 ¥\(String(format: "%.2f", report.totalExpense))）。可在「更多」菜单中打开图表查看详情。",
                "[\(report.title)] \(report.smartSummary) (\(report.completedTodos.count) completed, total spending ¥\(String(format: "%.2f", report.totalExpense))). Open Reports in More for charts."
            )
        }

        // 1. 意图：查快递 / 问取件码
        if trimmed.contains("快递") || trimmed.contains("取件") || trimmed.contains("包裹")
            || lower.contains("parcel") || lower.contains("package") || lower.contains("pickup code") || lower.contains("delivery") {
            return queryParcels()
        }

        // 2. 意图：查流量
        if trimmed.contains("流量") || trimmed.contains("话费") || lower.contains("data usage") || lower.contains("mobile data") {
            return queryDataUsage()
        }

        // 3. 意图：查地点 / 我在哪里
        if trimmed.contains("哪里") || trimmed.contains("地点") || trimmed.contains("家") || trimmed.contains("公司")
            || lower.contains("where am i") || lower.contains("learned place") || lower.contains("my places") {
            return queryLearnedPlaces()
        }

        // 4. 意图：查账 / 查开销（优先于记账识别，防止包含“花了多少”等疑问句误入记账）
        let isQuestionTone = trimmed.contains("多少") || trimmed.contains("几笔") || trimmed.contains("吗") ||
            trimmed.contains("？") || trimmed.contains("?") || trimmed.contains("是不是") || trimmed.contains("有没有") ||
            trimmed.contains("哪些") || trimmed.contains("什么") || trimmed.contains("查") || trimmed.contains("看") ||
            lower.contains("how much") || lower.hasPrefix("show ") || lower.hasPrefix("check ") || lower.hasPrefix("what ")
        let hasExpenseKeyword = trimmed.contains("开销") || trimmed.contains("支出") || trimmed.contains("消费") ||
            trimmed.contains("花销") || trimmed.contains("账单") || trimmed.contains("账本") || trimmed.contains("记账") ||
            trimmed.contains("花了") || trimmed.contains("花钱") ||
            lower.contains("spend") || lower.contains("spent") || lower.contains("expense") || lower.contains("bill")
        if trimmed == "查账" || trimmed.contains("花了多少") || trimmed.contains("消费了多少") ||
            trimmed.contains("今天开销") || trimmed.contains("昨天开销") || trimmed.contains("本月支出") ||
            lower.contains("how much did i spend") || lower.contains("my expenses") ||
            (isQuestionTone && hasExpenseKeyword) {
            return queryExpenses(query: trimmed)
        }

        // 5. 意图：一句话记账（如 "中午吃麦当劳花了 38 块"、"昨天花了 69.9"、"打车 25 元"、"spent 38 on lunch"）
        if !isQuestionTone,
           let expense = ExpenseNaturalLanguageParser.parse(trimmed),
           (trimmed.contains("花") || trimmed.contains("元") || trimmed.contains("块") || trimmed.contains("支出") || trimmed.contains("收入") || trimmed.contains("买") || trimmed.contains("付") || trimmed.contains("记账") || trimmed.contains("记一笔") || trimmed.contains("消费") || lower.contains("spent") || lower.contains("paid") || lower.contains("$") || lower.contains("usd") || lower.contains("yuan") || lower.contains("bucks") || lower.contains("dollars") || lower.contains("salary")) {
            return recordExpense(expense, raw: trimmed)
        }

        // 6. 意图：添加新待办 / 周期提醒（如 "记一下每周五下午5点写周报"、"每天晚上8点提醒我吃钙片"）
        let isTodoIntent = trimmed.hasPrefix("记一下") || trimmed.hasPrefix("添加待办") || trimmed.hasPrefix("提醒我")
            || trimmed.hasPrefix("帮我记") || trimmed.hasPrefix("帮我建") || trimmed.hasPrefix("建立待办")
            || trimmed.contains("提醒我") || lower.hasPrefix("remind me") || lower.hasPrefix("add todo") || lower.hasPrefix("add a todo")
            || (trimmed.contains("每") && (trimmed.contains("天") || trimmed.contains("周") || trimmed.contains("月") || trimmed.contains("星期")))
            || (lower.contains("every ") && (lower.contains("day") || lower.contains("week") || lower.contains("month")))
        if isTodoIntent {
            return createTodoFromVoice(trimmed)
        }

        // 7. 意图：查纪念日 / 倒数日 / 生日
        if trimmed.contains("纪念日") || trimmed.contains("生日") || trimmed.contains("倒数") || trimmed.contains("多少天")
            || lower.contains("anniversary") || lower.contains("anniversaries") || lower.contains("birthday") || lower.contains("countdown") {
            return queryAnniversaries()
        }

        // 8. 意图：全部待办总览
        if trimmed.contains("待办") || trimmed.contains("要做") || trimmed.contains("安排")
            || lower.contains("to-do") || lower.contains("todos") || lower.contains("my tasks") || lower.contains("what to do") {
            return queryActiveTodos()
        }

        // 9. 意图：出门防丢 / 随身装备检查
        if trimmed.contains("出门") || trimmed.contains("防丢") || trimmed.contains("忘带") || trimmed.contains("随身") || trimmed.contains("要走了")
            || lower.contains("departure") || lower.contains("checklist") || lower.contains("leaving home") {
            return queryDepartureChecklist()
        }

        // 10. 默认将未明确意图当成待办直接收录（智能解析提取时间或周期）
        return createTodoFromVoice(trimmed)
    }

    private func queryParcels() -> String {
        let active = TodoStatus.active.rawValue
        let parcel = TodoType.parcel.rawValue
        let items = (try? context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.typeRaw == parcel && $0.statusRaw == active }
        ))) ?? []

        if items.isEmpty {
            return L10n.tr("目前没有待取的快递。")
        }

        let desc = items.map { item in
            let code = item.pickupCode ?? L10n.tr("无取件码")
            let loc = item.location ?? item.station ?? ""
            return L10n.choose(
                "\(item.courier ?? "快递")取件码 \(code)，在 \(loc)",
                "\(item.courier ?? "Parcel") code \(code) at \(loc)"
            )
        }.joined(separator: L10n.choose("；", "; "))

        return L10n.choose(
            "你当前有 \(items.count) 个待取包裹：\(desc)",
            "You have \(items.count) parcel\(items.count == 1 ? "" : "s") to pick up: \(desc)"
        )
    }

    private func queryDataUsage() -> String {
        let records = (try? context.fetch(FetchDescriptor<DataUsageRecord>(
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
        ))) ?? []

        guard let latest = records.first else {
            return L10n.tr("暂未收到最近的运营商流量短信记录。")
        }

        let remainStr = latest.remainingMB.map { TodoFormatter.formatMB($0) } ?? L10n.tr("未知")
        let op = latest.operatorName ?? L10n.tr("运营商")
        return L10n.choose(
            "根据最新的短信记录，你的 \(op) 剩余通用流量约为 \(remainStr)。",
            "Based on the latest SMS record, your remaining \(op) mobile data is about \(remainStr)."
        )
    }

    private func queryLearnedPlaces() -> String {
        let places = (try? context.fetch(FetchDescriptor<LearnedPlace>())) ?? []
        let name = AppSettings.assistantName
        if places.isEmpty {
            return L10n.choose(
                "\(name)还在自主学习你的常驻习惯，暂未聚类出常驻地点。",
                "\(name) is still learning your frequent locations; none have been clustered yet."
            )
        }
        let names = places.map { "\($0.name)（\(L10n.tr($0.category.rawValue))）" }.joined(separator: L10n.choose("、", ", "))
        return L10n.choose(
            "\(name)已学习到的常用地点包括：\(names)。",
            "\(name)'s learned frequent places include: \(names)."
        )
    }

    private func createTodoFromVoice(_ text: String) -> String {
        let parsed = TodoNaturalLanguageParser.parse(text)

        let minOrder = (try? context.fetch(FetchDescriptor<TodoItem>()))?.map(\.sortOrder).min() ?? 0

        let item = TodoItem(
            type: parsed.type,
            status: .active,
            title: parsed.title,
            dueAt: parsed.dueAt,
            sourceText: text,
            sortOrder: minOrder - 1,
            recurrenceRuleRaw: parsed.recurrenceRule == .none ? nil : parsed.recurrenceRule.rawValue,
            recurrenceIntervalDays: parsed.customIntervalDays
        )

        context.insert(item)
        TodoNotificationManager.shared.scheduleNotification(for: item)
        try? context.save()

        if L10n.isEnglish {
            var feedback = "Got it! Added to-do \"\(parsed.title)\""
            if parsed.recurrenceRule != .none {
                feedback += " (\(parsed.recurrenceRule.displayLabel(customDays: parsed.customIntervalDays)))"
            }
            if let due = parsed.dueAt {
                feedback += ", reminder at \(due.formatted(date: .numeric, time: .shortened))"
            }
            feedback += "."
            return feedback
        } else {
            var feedback = "好的，已为你记下待办「\(parsed.title)」"
            if parsed.recurrenceRule != .none {
                feedback += "（\(parsed.recurrenceRule.displayLabel(customDays: parsed.customIntervalDays))）"
            }
            if let due = parsed.dueAt {
                feedback += "，提醒时间：\(due.formatted(date: .numeric, time: .shortened))"
            }
            feedback += "。"
            return feedback
        }
    }

    private func queryActiveTodos() -> String {
        let active = TodoStatus.active.rawValue
        let items = (try? context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.statusRaw == active }
        ))) ?? []

        if items.isEmpty {
            return L10n.tr("你目前没有任何未完成的待办事项，轻松一下吧！")
        }

        let titles = items.prefix(5).map(\.title).joined(separator: L10n.choose("；", "; "))
        return L10n.choose(
            "你共有 \(items.count) 项待办，前几项是：\(titles)。",
            "You have \(items.count) active to-do\(items.count == 1 ? "" : "s"). Top items: \(titles)."
        )
    }

    private func queryAnniversaries() -> String {
        let items = (try? context.fetch(FetchDescriptor<AnniversaryItem>())) ?? []
        if items.isEmpty {
            return L10n.tr("你目前还没有记录任何纪念日或重要日子。")
        }

        let sorted = items.sorted { $0.daysUntilNext < $1.daysUntilNext }
        let descs = sorted.prefix(3).map { item in
            let days = item.daysUntilNext
            if L10n.isEnglish {
                let desc = days == 0 ? "is today" : "in \(days) day\(days == 1 ? "" : "s")"
                return "\(item.title) \(desc) (Year \(item.nextYearsCount))"
            } else {
                let desc = days == 0 ? "就在今天" : "还有 \(days) 天"
                return "\(item.title)\(desc)（第 \(item.nextYearsCount) 年）"
            }
        }.joined(separator: L10n.choose("；", "; "))

        return L10n.choose("最近的纪念日有：\(descs)。", "Upcoming anniversaries: \(descs).")
    }

    private func formatAmount(_ amount: Double) -> String {
        if amount.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", amount)
        } else if (amount * 10).truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.1f", amount)
        } else {
            return String(format: "%.2f", amount)
        }
    }

    private func relativeDayLabel(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return L10n.tr("今天") }
        if calendar.isDateInYesterday(date) { return L10n.tr("昨天") }
        if let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: .now),
           calendar.isDate(date, inSameDayAs: twoDaysAgo) {
            return L10n.tr("前天")
        }
        let m = calendar.component(.month, from: date)
        let d = calendar.component(.day, from: date)
        return L10n.choose("\(m)月\(d)日", "\(m)/\(d)")
    }

    private func recordExpense(_ parsed: ExpenseParseResult, raw: String) -> String {
        let cal = Calendar.current
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

        let dayLabel = relativeDayLabel(for: parsed.date, calendar: cal)
        let amountText = formatAmount(parsed.amount)
        let records = (try? context.fetch(FetchDescriptor<ExpenseRecord>())) ?? []
        let sameDayTotal = records
            .filter { !$0.isIncome && cal.isDate($0.date, inSameDayAs: parsed.date) }
            .reduce(0.0) { $0 + $1.amount }
        let currentMonth = cal.component(.month, from: .now)
        let currentYear = cal.component(.year, from: .now)
        let monthTotal = records
            .filter { !$0.isIncome && cal.component(.year, from: $0.date) == currentYear && cal.component(.month, from: $0.date) == currentMonth }
            .reduce(0.0) { $0 + $1.amount }

        if parsed.isIncome {
            return L10n.choose(
                "已为你记入\(dayLabel)的一笔【\(parsed.category.rawValue)】入账 \(amountText) 元（\(parsed.title)）。",
                "Recorded \(dayLabel)'s [\(L10n.tr(parsed.category.rawValue))] income of ¥\(amountText) (\(parsed.title))."
            )
        } else {
            if L10n.isEnglish {
                return "Recorded \(dayLabel)'s [\(L10n.tr(parsed.category.rawValue))] expense of ¥\(amountText) (\(parsed.title)). \(dayLabel) total: ¥\(formatAmount(sameDayTotal)); this month: ¥\(formatAmount(monthTotal))."
            } else {
                let prefix = dayLabel == "今天" ? "已为你记录今天" : "已为你补记\(dayLabel)"
                return "\(prefix)一笔【\(parsed.category.rawValue)】支出 \(amountText) 元（\(parsed.title)）。\(dayLabel)累计消费 \(formatAmount(sameDayTotal)) 元，本月累计支出 \(formatAmount(monthTotal)) 元。"
            }
        }
    }

    public func queryExpenses(query: String = "") -> String {
        let cal = Calendar.current
        let lower = query.lowercased()
        let records = ((try? context.fetch(FetchDescriptor<ExpenseRecord>())) ?? []).sorted { $0.date > $1.date }
        let expenseRecords = records.filter { !$0.isIncome }

        if expenseRecords.isEmpty {
            return L10n.tr("你目前还没有记录任何消费支出。随时对我说「中午吃饭花了35」或「昨天买了69.9」即可快速记账。")
        }

        let todayExpenses = expenseRecords.filter { cal.isDateInToday($0.date) }
        let todayTotal = todayExpenses.reduce(0.0) { $0 + $1.amount }

        let yesterdayExpenses = expenseRecords.filter { cal.isDateInYesterday($0.date) }
        let yesterdayTotal = yesterdayExpenses.reduce(0.0) { $0 + $1.amount }

        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: .now) ?? .now
        let dayBeforeYesterdayExpenses = expenseRecords.filter { cal.isDate($0.date, inSameDayAs: twoDaysAgo) }
        let dayBeforeYesterdayTotal = dayBeforeYesterdayExpenses.reduce(0.0) { $0 + $1.amount }

        let weekExpenses = expenseRecords.filter { cal.isDate($0.date, equalTo: .now, toGranularity: .weekOfYear) }
        let weekTotal = weekExpenses.reduce(0.0) { $0 + $1.amount }

        let currentMonth = cal.component(.month, from: .now)
        let currentYear = cal.component(.year, from: .now)
        let monthExpenses = expenseRecords.filter {
            cal.component(.month, from: $0.date) == currentMonth &&
            cal.component(.year, from: $0.date) == currentYear
        }
        let monthTotal = monthExpenses.reduce(0.0) { $0 + $1.amount }

        let formatItems: ([ExpenseRecord]) -> String = { list in
            list.prefix(3).map { item in
                let label = item.title.isEmpty ? L10n.tr(item.category.rawValue) : item.title
                return L10n.choose("\(label) \(self.formatAmount(item.amount))元", "\(label) ¥\(self.formatAmount(item.amount))")
            }.joined(separator: L10n.choose("、", ", "))
        }

        // 1. 明确询问「昨天 / 昨日」
        if query.contains("昨天") || query.contains("昨日") || lower.contains("yesterday") {
            if yesterdayExpenses.isEmpty {
                if L10n.isEnglish {
                    let todayPart = todayTotal > 0 ? "today's spending is ¥\(formatAmount(todayTotal))" : "no expenses recorded today"
                    return "No expenses recorded yesterday; \(todayPart), and this month's total is ¥\(formatAmount(monthTotal))."
                } else {
                    let todayPart = todayTotal > 0 ? "今天已消费 \(formatAmount(todayTotal)) 元" : "今天暂未记账"
                    return "你昨天没有记录任何消费支出；\(todayPart)，本月累计消费 \(formatAmount(monthTotal)) 元。"
                }
            } else {
                let details = formatItems(yesterdayExpenses)
                if L10n.isEnglish {
                    let todayPart = todayTotal > 0 ? "Today: ¥\(formatAmount(todayTotal))" : "No expenses today yet"
                    return "Yesterday you spent ¥\(formatAmount(yesterdayTotal)) (\(yesterdayExpenses.count) item\(yesterdayExpenses.count == 1 ? "" : "s"): \(details)). \(todayPart), month total: ¥\(formatAmount(monthTotal))."
                } else {
                    let todayPart = todayTotal > 0 ? "今天已消费 \(formatAmount(todayTotal)) 元" : "今天暂未消费"
                    return "你昨天共消费了 \(formatAmount(yesterdayTotal)) 元（共 \(yesterdayExpenses.count) 笔：\(details)）。\(todayPart)，本月累计消费 \(formatAmount(monthTotal)) 元。"
                }
            }
        }

        // 2. 明确询问「前天」
        if query.contains("前天") || lower.contains("two days ago") {
            if dayBeforeYesterdayExpenses.isEmpty {
                return L10n.choose(
                    "你前天没有记录消费支出；本月累计消费 \(formatAmount(monthTotal)) 元。",
                    "No expenses recorded two days ago; this month's total is ¥\(formatAmount(monthTotal))."
                )
            } else {
                let details = formatItems(dayBeforeYesterdayExpenses)
                return L10n.choose(
                    "你前天共消费了 \(formatAmount(dayBeforeYesterdayTotal)) 元（\(details)），本月累计消费 \(formatAmount(monthTotal)) 元。",
                    "Two days ago you spent ¥\(formatAmount(dayBeforeYesterdayTotal)) (\(details)), month total: ¥\(formatAmount(monthTotal))."
                )
            }
        }

        // 3. 明确询问「本周 / 这周 / 最近 / 近期」
        if query.contains("本周") || query.contains("这周") || query.contains("最近") || query.contains("近期") || lower.contains("this week") || lower.contains("recent") {
            let recentDetails = expenseRecords.prefix(3).map { item in
                let dLabel = relativeDayLabel(for: item.date, calendar: cal)
                let title = item.title.isEmpty ? L10n.tr(item.category.rawValue) : item.title
                return L10n.choose("\(dLabel)\(title) \(formatAmount(item.amount))元", "\(dLabel) \(title) ¥\(formatAmount(item.amount))")
            }.joined(separator: L10n.choose("、", ", "))
            return L10n.choose(
                "你本周累计消费 \(formatAmount(weekTotal)) 元（今天 \(formatAmount(todayTotal)) 元，昨天 \(formatAmount(yesterdayTotal)) 元），最近明细：\(recentDetails)；本月累计消费 \(formatAmount(monthTotal)) 元。",
                "This week you spent ¥\(formatAmount(weekTotal)) (today ¥\(formatAmount(todayTotal)), yesterday ¥\(formatAmount(yesterdayTotal))). Recent: \(recentDetails). Month total: ¥\(formatAmount(monthTotal))."
            )
        }

        // 4. 常规查账 / 询问今天或总体消费
        if todayTotal == 0 {
            if yesterdayTotal > 0 {
                let yesterdayDetails = formatItems(yesterdayExpenses)
                return L10n.choose(
                    "你今天还没有消费记录；昨天消费了 \(formatAmount(yesterdayTotal)) 元（\(yesterdayDetails)），本月累计消费 \(formatAmount(monthTotal)) 元。",
                    "No expenses recorded today yet; yesterday you spent ¥\(formatAmount(yesterdayTotal)) (\(yesterdayDetails)), month total: ¥\(formatAmount(monthTotal))."
                )
            } else if let latest = expenseRecords.first {
                let latestDay = relativeDayLabel(for: latest.date, calendar: cal)
                let latestTitle = latest.title.isEmpty ? L10n.tr(latest.category.rawValue) : latest.title
                return L10n.choose(
                    "你今天和昨天暂未记账；最近一笔是\(latestDay)的「\(latestTitle)」\(formatAmount(latest.amount)) 元，本月累计消费 \(formatAmount(monthTotal)) 元。",
                    "No expenses today or yesterday; latest was \"\(latestTitle)\" ¥\(formatAmount(latest.amount)) on \(latestDay). Month total: ¥\(formatAmount(monthTotal))."
                )
            }
        }

        let todayDetails = formatItems(todayExpenses)
        if L10n.isEnglish {
            let yesterdaySuffix = yesterdayTotal > 0 ? ", yesterday ¥\(formatAmount(yesterdayTotal))" : ""
            return "Today you spent ¥\(formatAmount(todayTotal)) (\(todayExpenses.count) item\(todayExpenses.count == 1 ? "" : "s"): \(todayDetails))\(yesterdaySuffix). Month total: ¥\(formatAmount(monthTotal))."
        } else {
            let yesterdaySuffix = yesterdayTotal > 0 ? "，昨天消费 \(formatAmount(yesterdayTotal)) 元" : ""
            return "你今天已消费 \(formatAmount(todayTotal)) 元（\(todayExpenses.count) 笔：\(todayDetails)）\(yesterdaySuffix)，本月累计消费 \(formatAmount(monthTotal)) 元。"
        }
    }

    private func queryDepartureChecklist() -> String {
        let items = (try? context.fetch(FetchDescriptor<DepartureCheckItem>())) ?? []
        if items.isEmpty {
            return L10n.tr("出门前请确认随身四字诀：身（工卡证件）、手（手机）、钥（钥匙）、耳（耳机或雨伞）。目前清单暂未登记个性化装备。")
        }

        let uncheckEssentials = items.filter { $0.isEssential && !$0.isChecked }
        if !uncheckEssentials.isEmpty {
            let names = uncheckEssentials.prefix(3).map { L10n.tr($0.title) }.joined(separator: L10n.choose("、", ", "))
            return L10n.choose(
                "出发请留步！你还有 \(uncheckEssentials.count) 件核心装备尚未清点：如【\(names)】。出门前请确认指差四字：身、手、钥、耳！",
                "Hold on! You still have \(uncheckEssentials.count) essential item\(uncheckEssentials.count == 1 ? "" : "s") unchecked: [\(names)]. Remember: ID, Phone, Keys, Earbuds!"
            )
        }

        let uncheckedTotal = items.filter { !$0.isChecked }.count
        if uncheckedTotal == 0 {
            return L10n.tr("核心装备与随身物品已全部清点齐全，可以安心出发！祝你一路顺风！")
        } else {
            return L10n.choose(
                "核心必带装备已就绪，还有 \(uncheckedTotal) 件非关键随身物品未打勾。请默念「身手钥耳」指差确认后出发。",
                "All essential items are packed! \(uncheckedTotal) optional item\(uncheckedTotal == 1 ? "" : "s") unchecked. Double-check ID, Phone, Keys, and Earbuds before heading out."
            )
        }
    }
}

// MARK: - 待办与周期重复自然语言解析引擎

/// 待办自然语言意图解析结果
struct TodoVoiceParseResult {
    var title: String
    var type: TodoType
    var dueAt: Date?
    var recurrenceRule: TodoRecurrenceRule
    var customIntervalDays: Int
}

enum TodoNaturalLanguageParser {
    static func parse(_ input: String) -> TodoVoiceParseResult {
        var text = input
        let original = input
        let lower = input.lowercased()

        // 1. 去除常见语音唤醒/指令前缀
        let prefixes = [
            "帮我记一个", "帮我建一个", "帮我添加一个", "帮我设置一个",
            "帮我记一下", "帮我记", "帮我建", "帮我设",
            "添加待办", "建立待办", "创建待办", "新增待办",
            "设置提醒", "提醒我", "记一下", "记住", "备忘",
            "remind me to ", "remind me ", "add a todo to ", "add todo ", "remember to "
        ]
        for p in prefixes {
            if let range = text.range(of: p, options: [.caseInsensitive]) {
                text.removeSubrange(range)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. 解析重复周期
        var recurrenceRule: TodoRecurrenceRule = .none
        var customDays: Int = 0
        var targetWeekday: Int? = nil // 1: Sunday, 2: Monday, ..., 7: Saturday

        if text.contains("每天") || text.contains("天天") || text.contains("每日") || lower.contains("every day") || lower.contains("daily") {
            recurrenceRule = .daily
            customDays = 1
        } else if text.contains("每隔一天") || text.contains("隔天") || text.contains("每两天") || text.contains("每2天") || lower.contains("every other day") || lower.contains("every 2 days") {
            recurrenceRule = .everyOtherDay
            customDays = 2
        } else if text.contains("每三天") || text.contains("每3天") || lower.contains("every 3 days") {
            recurrenceRule = .everyThreeDays
            customDays = 3
        } else if text.contains("每两周") || text.contains("每2周") || text.contains("隔周") || lower.contains("every two weeks") || lower.contains("biweekly") {
            recurrenceRule = .biweekly
            customDays = 14
        } else if text.contains("每月") || text.contains("每个月") || lower.contains("every month") || lower.contains("monthly") {
            recurrenceRule = .monthly
            customDays = 30
        } else if let regex = try? NSRegularExpression(pattern: "(?:每|every\\s+)([0-9]{1,3})\\s*(?:天|days?)", options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
                  let r = Range(match.range(at: 1), in: text),
                  let d = Int(text[r]) {
            recurrenceRule = .custom
            customDays = max(1, d)
        } else if text.contains("每周") || text.contains("每个星期") || text.contains("每礼拜") || lower.contains("every week") || lower.contains("weekly") {
            recurrenceRule = .weekly
            customDays = 7
        }

        // 检查星期几（例如 每周五、周六、星期天）
        if text.contains("周一") || text.contains("星期一") || text.contains("礼拜一") {
            targetWeekday = 2
            if recurrenceRule == .none && (text.contains("每") || text.contains("下周")) { recurrenceRule = text.contains("每") ? .weekly : .none }
        } else if text.contains("周二") || text.contains("星期二") || text.contains("礼拜二") {
            targetWeekday = 3
            if recurrenceRule == .none && (text.contains("每") || text.contains("下周")) { recurrenceRule = text.contains("每") ? .weekly : .none }
        } else if text.contains("周三") || text.contains("星期三") || text.contains("礼拜三") {
            targetWeekday = 4
            if recurrenceRule == .none && (text.contains("每") || text.contains("下周")) { recurrenceRule = text.contains("每") ? .weekly : .none }
        } else if text.contains("周四") || text.contains("星期四") || text.contains("礼拜四") {
            targetWeekday = 5
            if recurrenceRule == .none && (text.contains("每") || text.contains("下周")) { recurrenceRule = text.contains("每") ? .weekly : .none }
        } else if text.contains("周五") || text.contains("星期五") || text.contains("礼拜五") {
            targetWeekday = 6
            if recurrenceRule == .none && (text.contains("每") || text.contains("下周")) { recurrenceRule = text.contains("每") ? .weekly : .none }
        } else if text.contains("周六") || text.contains("星期六") || text.contains("礼拜六") {
            targetWeekday = 7
            if recurrenceRule == .none && (text.contains("每") || text.contains("下周")) { recurrenceRule = text.contains("每") ? .weekly : .none }
        } else if text.contains("周日") || text.contains("周天") || text.contains("星期日") || text.contains("星期天") || text.contains("礼拜天") || text.contains("礼拜日") {
            targetWeekday = 1
            if recurrenceRule == .none && (text.contains("每") || text.contains("下周")) { recurrenceRule = text.contains("每") ? .weekly : .none }
        }

        // 3. 解析时间点（几点、几分）
        var targetHour: Int? = nil
        var targetMinute: Int = 0

        let hourRegex = try? NSRegularExpression(pattern: "([0-9]{1,2})(?:点|:|：)([0-9]{1,2})?")
        if let match = hourRegex?.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
            if let hrRange = Range(match.range(at: 1), in: text), let h = Int(text[hrRange]) {
                targetHour = h
                if match.range(at: 2).location != NSNotFound,
                   let minRange = Range(match.range(at: 2), in: text),
                   let m = Int(text[minRange]) {
                    targetMinute = m
                } else if text.contains("半") {
                    targetMinute = 30
                }
            }
        }

        let isPM = text.contains("下午") || text.contains("晚上") || text.contains("今晚") || text.contains("明晚") || text.contains("傍晚")
        let isAM = text.contains("早上") || text.contains("早晨") || text.contains("上午") || text.contains("清晨")
        let isNoon = text.contains("中午")

        if let h = targetHour {
            if isPM && h < 12 {
                targetHour = h + 12
            } else if isAM && h == 12 {
                targetHour = 0
            }
        } else {
            if isPM {
                targetHour = text.contains("晚") ? 20 : 17
            } else if isAM {
                targetHour = 9
            } else if isNoon {
                targetHour = 12
            }
        }

        // 4. 计算首次截止时间 dueAt
        var calculatedDue: Date? = nil
        let calendar = Calendar.current
        let now = Date.now

        if let hour = targetHour {
            var baseDate = now
            if text.contains("大后天") {
                baseDate = calendar.date(byAdding: .day, value: 3, to: now) ?? now
            } else if text.contains("后天") {
                baseDate = calendar.date(byAdding: .day, value: 2, to: now) ?? now
            } else if text.contains("明天") || text.contains("明早") || text.contains("明晚") {
                baseDate = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            } else if let weekday = targetWeekday {
                let currentWeekday = calendar.component(.weekday, from: now)
                var diff = (weekday - currentWeekday + 7) % 7
                if diff == 0 {
                    let todayTarget = calendar.date(bySettingHour: hour, minute: targetMinute, second: 0, of: now) ?? now
                    if todayTarget <= now {
                        diff = 7
                    }
                }
                baseDate = calendar.date(byAdding: .day, value: diff, to: now) ?? now
            }

            if let targetDate = calendar.date(bySettingHour: hour, minute: targetMinute, second: 0, of: baseDate) {
                if targetDate > now {
                    calculatedDue = targetDate
                } else if recurrenceRule == .daily {
                    calculatedDue = calendar.date(byAdding: .day, value: 1, to: targetDate)
                } else {
                    calculatedDue = targetDate
                }
            }
        } else if recurrenceRule != .none {
            let tomorrowNine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
            calculatedDue = tomorrowNine
        }

        // 5. 判断待办类型
        let type: TodoType
        if original.contains("药") || original.contains("维他命") || original.contains("钙片") || original.contains("滴眼液") {
            type = .medication
        } else if original.contains("扫地") || original.contains("拖地") || original.contains("洗床单") || original.contains("浇花") || original.contains("家务") || original.contains("垃圾") {
            type = .housework
        } else if original.contains("充电") {
            type = .charging
        } else if original.contains("喝水") {
            type = .hydration
        } else if original.contains("还款") || original.contains("账单") || original.contains("房租") || original.contains("水电费") {
            type = .bill
        } else if original.contains("退货") || original.contains("寄件") {
            type = .returnParcel
        } else if original.contains("取件") || original.contains("快递") || original.contains("包裹") {
            type = .parcel
        } else {
            type = .general
        }

        // 6. 清理标题，保留核心动作
        let cleanWords = [
            "每天", "天天", "每日", "每隔一天", "隔天", "每两天", "每2天", "每三天", "每3天",
            "每周一", "每周二", "每周三", "每周四", "每周五", "每周六", "每周日", "每周天",
            "每周", "每个月", "每月", "每两周",
            "明天", "后天", "大后天", "下午", "上午", "早上", "晚上", "中午", "早晨", "傍晚",
            "记得", "去", "做", "一下"
        ]
        var cleanTitle = text
        for w in cleanWords {
            cleanTitle = cleanTitle.replacingOccurrences(of: w, with: "")
        }
        if let hourRegex {
            cleanTitle = hourRegex.stringByReplacingMatches(in: cleanTitle, range: NSRange(location: 0, length: cleanTitle.utf16.count), withTemplate: "")
        }
        cleanTitle = cleanTitle.replacingOccurrences(of: "点半", with: "")
        cleanTitle = cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty || cleanTitle.count < 2 {
            cleanTitle = text.isEmpty ? original : text
        }

        return TodoVoiceParseResult(
            title: cleanTitle,
            type: type,
            dueAt: calculatedDue,
            recurrenceRule: recurrenceRule,
            customIntervalDays: customDays
        )
    }
}
