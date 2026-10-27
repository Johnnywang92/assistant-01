import AssistantCore
import Foundation
import SwiftData

// MARK: - 查询执行服务（App 侧）
//
// 把 `QueryInsightEngine` 解析出的结构化意图落地为一句话回答：
// 数字与文案规则在 AssistantCore（`QueryAnswerBuilder` / `TrendAnalytics`），
// 本层只负责按时间窗取数与领域派发。
//
// 取数一律走谓词 + fetchLimit 下推 SQLite，不做全表 fetch 后内存过滤
//（原 executeLookup 的四表全扫正是要消掉的）。

@MainActor
enum LifeQueryService {

    /// 统一入口：结构化意图 → 应答文案
    static func answer(_ insight: QueryInsight, context: ModelContext) -> String {
        switch (insight.domain, insight.kind) {
        case (.expense, .trend):
            return expenseTrend(insight, context: context)
        case (.expense, .aggregate):
            return expenseAggregate(insight, context: context)
        case (.diet, .trend), (.diet, .aggregate):
            return dietTrend(insight, context: context)
        case (.health, .trend), (.health, .aggregate):
            return health(insight, context: context)
        case (.todo, .agenda):
            return agenda(insight, context: context)
        default:
            return lookup(insight: insight, context: context)
        }
    }

    /// 关键词查找（收纳/药品/证件/纪念日/人生大事/待办），找不到给出兜底文案
    static func lookup(insight: QueryInsight, context: ModelContext) -> String {
        let keyword = (insight.keyword ?? insight.rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            return QueryAnswerBuilder.lookupMiss(keyword: "空关键词", searchedKinds: [])
        }

        if let hit = searchEntities(keyword: keyword, context: context) {
            return hit
        }
        return QueryAnswerBuilder.lookupMiss(
            keyword: keyword,
            searchedKinds: ["收纳", "药品", "证件", "纪念日", "人生大事", "待办"]
        )
    }

    // MARK: - 消费汇总

    private static func expenseAggregate(_ insight: QueryInsight, context: ModelContext) -> String {
        let interval = insight.timeRange.interval()
        let lines = expenseLines(from: interval.start, to: interval.end, context: context)

        // 对照窗口：等长的前一周期（用于环比）
        let span = interval.end.timeIntervalSince(interval.start)
        let prevStart = interval.start.addingTimeInterval(-span)
        let prevEnd = interval.start
        let previousTotal: Double? = {
            guard span > 0, span < 366 * 24 * 3600 else { return nil }
            return expenseLines(from: prevStart, to: prevEnd, context: context)
                .filter { !$0.isIncome }
                .reduce(0.0) { $0 + $1.amount }
        }()

        return QueryAnswerBuilder.expenseSummary(
            rangeLabel: insight.timeRange.displayLabel,
            lines: lines,
            previousTotal: previousTotal
        )
    }

    // MARK: - 消费趋势

    private static func expenseTrend(_ insight: QueryInsight, context: ModelContext) -> String {
        let monthCount: Int = {
            if case .lastNMonths(let n) = insight.timeRange { return max(2, n) }
            return 6
        }()
        // 取窗口外多一个月，保证环比基线有数据
        let fetchStart = Calendar.current.date(byAdding: .month, value: -(monthCount + 1), to: .now) ?? .now
        let records = (try? context.fetch(FetchDescriptor<ExpenseRecord>(
            predicate: #Predicate { $0.date >= fetchStart },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        ))) ?? []
        let trend = TrendAnalytics.expenseTrend(
            entries: records.map {
                TrendAnalytics.ExpenseEntry(
                    date: $0.date,
                    amount: $0.amount,
                    isIncome: $0.isIncome,
                    categoryRaw: $0.categoryRaw
                )
            },
            monthCount: monthCount
        )
        return QueryAnswerBuilder.expenseTrendNarrative(trend)
    }

    // MARK: - 饮食趋势

    private static func dietTrend(_ insight: QueryInsight, context: ModelContext) -> String {
        let dayCount: Int = {
            switch insight.timeRange {
            case .lastNDays(let n): return max(2, n)
            case .today, .yesterday, .dayBeforeYesterday: return 7
            default: return 30
            }
        }()
        let fetchStart = Calendar.current.date(byAdding: .day, value: -(dayCount + 1), to: .now) ?? .now
        let records = (try? context.fetch(FetchDescriptor<FoodIntakeRecord>(
            predicate: #Predicate { $0.date >= fetchStart }
        ))) ?? []
        let trend = TrendAnalytics.dietTrend(
            entries: records.map {
                TrendAnalytics.DietEntry(date: $0.date, calories: $0.consumedCalories)
            },
            dayCount: dayCount
        )
        return QueryAnswerBuilder.dietTrendNarrative(trend)
    }

    // MARK: - 健康趋势 / 汇总（数据源：每日健康快照落库）

    private static func health(_ insight: QueryInsight, context: ModelContext) -> String {
        let calendar = Calendar.current

        // 单日汇总（「昨天睡了多少」）→ 点查当日快照
        let interval = insight.timeRange.interval()
        let daySpan = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: interval.start),
            to: calendar.startOfDay(for: interval.end)
        ).day ?? 1

        if insight.kind == .aggregate && daySpan <= 1 {
            let records = (try? context.fetch(FetchDescriptor<HealthDaySnapshotRecord>(
                predicate: #Predicate { $0.day >= interval.start && $0.day < interval.end },
                sortBy: [SortDescriptor(\.day, order: .forward)]
            ))) ?? []
            guard let latest = records.last else {
                return QueryAnswerBuilder.healthSummary(rangeLabel: insight.timeRange.displayLabel)
            }
            let snapshot = latest.toSnapshot()
            let score = VitalityEvaluator.evaluate(
                snapshot: snapshot,
                foodIntakeCalories: foodCaloriesByDay(from: interval.start, to: interval.end, calendar: calendar, context: context)[calendar.startOfDay(for: latest.day)]
            ).score
            return QueryAnswerBuilder.healthSummary(
                rangeLabel: insight.timeRange.displayLabel,
                sleepHours: snapshot.sleepHours,
                stepCount: snapshot.stepCount,
                vitalityScore: Double(score)
            )
        }

        // 趋势 / 多日汇总（「最近睡得怎么样」「本月睡眠如何」）→ 日序列
        let dayCount: Int = {
            switch insight.timeRange {
            case .lastNDays(let n): return max(2, n)
            case .today, .tomorrow, .yesterday, .dayBeforeYesterday, .thisWeek, .lastWeek: return 7
            case .thisMonth, .lastMonth: return 30
            case .lastNMonths(let n): return min(90, max(7, n * 30))
            case .allTime: return 30
            }
        }()
        let fetchStart = calendar.date(byAdding: .day, value: -(dayCount + 1), to: .now) ?? .now
        let records = (try? context.fetch(FetchDescriptor<HealthDaySnapshotRecord>(
            predicate: #Predicate { $0.day >= fetchStart },
            sortBy: [SortDescriptor(\.day, order: .forward)]
        ))) ?? []
        let calories = foodCaloriesByDay(from: fetchStart, to: .distantFuture, calendar: calendar, context: context)

        // 健康分数不在库里存——依赖当日饮食摄入，读趋势时用同一套公式现算，保证跨天可比
        let entries = records.map { record -> TrendAnalytics.HealthEntry in
            let day = calendar.startOfDay(for: record.day)
            let snapshot = record.toSnapshot()
            let score = VitalityEvaluator.evaluate(
                snapshot: snapshot,
                foodIntakeCalories: calories[day]
            ).score
            return TrendAnalytics.HealthEntry(
                date: record.day,
                sleepHours: snapshot.sleepHours,
                vitalityScore: Double(score)
            )
        }
        let trend = TrendAnalytics.healthTrend(entries: entries, dayCount: dayCount)
        return QueryAnswerBuilder.healthTrendNarrative(trend)
    }

    /// 当日饮食摄入热量按天求和。与健康页 `todayFoodCalories` 同口径（`consumedCalories`），
    /// 活力分的能量收支维度靠它——不落健康快照库，避免双份漂移。
    private static func foodCaloriesByDay(
        from start: Date,
        to end: Date,
        calendar: Calendar,
        context: ModelContext
    ) -> [Date: Double] {
        let foods = (try? context.fetch(FetchDescriptor<FoodIntakeRecord>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        ))) ?? []
        var result: [Date: Double] = [:]
        for food in foods {
            let day = calendar.startOfDay(for: food.date)
            result[day, default: 0] += food.consumedCalories
        }
        return result
    }

    // MARK: - 日程

    private static func agenda(_ insight: QueryInsight, context: ModelContext) -> String {
        let interval = insight.timeRange.interval()
        let active = TodoStatus.active.rawValue
        // 窗口内到期 + 已逾期（今天问「有什么安排」时逾期件也该出现）
        let overdueCutoff = interval.end
        let items = (try? context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate {
                $0.statusRaw == active && $0.dueAt != nil && $0.dueAt! < overdueCutoff
            },
            sortBy: [SortDescriptor(\.dueAt, order: .forward)]
        ))) ?? []

        let now = Date.now
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let lines = items.map { item -> QueryAnswerBuilder.AgendaLine in
            let due = item.dueAt ?? now
            let timeText = Calendar.current.isDate(due, inSameDayAs: now) ? formatter.string(from: due) : nil
            return QueryAnswerBuilder.AgendaLine(
                title: item.title,
                timeText: timeText,
                isOverdue: due < now && insight.timeRange == .today
            )
        }
        let overflow = max(0, lines.count - 6)
        return QueryAnswerBuilder.agendaSummary(
            rangeLabel: insight.timeRange.displayLabel,
            lines: Array(lines.prefix(8)),
            overflowCount: overflow
        )
    }

    // MARK: - 实体查找（谓词下推 + fetchLimit）

    private static func searchEntities(keyword: String, context: ModelContext) -> String? {
        // 1. 物品收纳
        var storageDesc = FetchDescriptor<StoredItem>(
            predicate: #Predicate { $0.name.localizedStandardContains(keyword) },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        storageDesc.fetchLimit = 3
        if let stored = (try? context.fetch(storageDesc))?.first {
            return QueryAnswerBuilder.lookupHit(
                kind: "收纳",
                name: stored.name,
                detail: "\(stored.roomArea) · \(stored.location)"
            )
        }

        // 2. 家庭常备药
        var medDesc = FetchDescriptor<MedicineItem>(
            predicate: #Predicate { $0.name.localizedStandardContains(keyword) },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        medDesc.fetchLimit = 3
        if let med = (try? context.fetch(medDesc))?.first {
            return QueryAnswerBuilder.lookupHit(
                kind: "常备药",
                name: med.name,
                detail: "\(med.roomArea) · \(med.storageLocation)"
            )
        }

        // 3. 证件卡包
        var docDesc = FetchDescriptor<IDDocumentItem>(
            predicate: #Predicate { $0.title.localizedStandardContains(keyword) },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        docDesc.fetchLimit = 3
        if let doc = (try? context.fetch(docDesc))?.first {
            let num = doc.documentNumber.map { "号码 \($0)" } ?? doc.type.displayName
            return QueryAnswerBuilder.lookupHit(kind: "证件", name: doc.title, detail: num)
        }

        // 4. 纪念日（无 createdAt/updatedAt 字段，按目标日期排序）
        var annivDesc = FetchDescriptor<AnniversaryItem>(
            predicate: #Predicate { $0.title.localizedStandardContains(keyword) },
            sortBy: [SortDescriptor(\.targetDate, order: .forward)]
        )
        annivDesc.fetchLimit = 3
        if let anniv = (try? context.fetch(annivDesc))?.first {
            return QueryAnswerBuilder.lookupHit(
                kind: "纪念日",
                name: anniv.title,
                detail: "还有 \(anniv.daysUntilNext) 天"
            )
        }

        // 5. 人生大事项目
        var lifeDesc = FetchDescriptor<LifeEventProject>(
            predicate: #Predicate { $0.title.localizedStandardContains(keyword) },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        lifeDesc.fetchLimit = 3
        if let project = (try? context.fetch(lifeDesc))?.first {
            return QueryAnswerBuilder.lookupHit(
                kind: "人生大事",
                name: project.title,
                detail: L10n.tr(project.statusRaw)
            )
        }

        // 6. 待办
        let active = TodoStatus.active.rawValue
        var todoDesc = FetchDescriptor<TodoItem>(
            predicate: #Predicate {
                $0.statusRaw == active && $0.title.localizedStandardContains(keyword)
            },
            sortBy: [SortDescriptor(\.dueAt, order: .forward)]
        )
        todoDesc.fetchLimit = 3
        if let todo = (try? context.fetch(todoDesc))?.first {
            let due = todo.dueAt.map {
                "截止 \($0.formatted(date: .abbreviated, time: .shortened))"
            } ?? "未设截止"
            return QueryAnswerBuilder.lookupHit(kind: "待办", name: todo.title, detail: due)
        }

        return nil
    }

    // MARK: - 取数辅助

    private static func expenseLines(from start: Date, to end: Date, context: ModelContext) -> [QueryAnswerBuilder.ExpenseLine] {
        let records = (try? context.fetch(FetchDescriptor<ExpenseRecord>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        ))) ?? []
        return records.map {
            QueryAnswerBuilder.ExpenseLine(
                title: $0.title,
                amount: $0.amount,
                isIncome: $0.isIncome,
                categoryRaw: $0.categoryRaw
            )
        }
    }
}
