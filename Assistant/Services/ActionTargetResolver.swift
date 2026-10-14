import AssistantCore
import Foundation
import SwiftData

/// 实体目标解析结果（目标解析走确定性代码，不交给小模型挑 ID）
enum TargetResolution<T> {
    case unique(T)
    case ambiguous([TargetCandidate<T>])
    case none
}

struct TargetCandidate<T>: Identifiable {
    let id: UUID
    let item: T
    let displayTitle: String
    let subtitle: String?
    let score: Double
}

/// 确定性实体目标解析器
@MainActor
final class ActionTargetResolver {

    /// 解析待办事项目标
    static func resolveTodo(
        mention: String,
        context: ModelContext
    ) -> TargetResolution<TodoItem> {
        let q = mention.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return .none }

        // 1. 若传进来的是 UUID 字符串，直接按主键唯一定位
        if let uuid = UUID(uuidString: q) {
            let desc = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == uuid })
            if let found = (try? context.fetch(desc))?.first {
                return .unique(found)
            }
        }

        // 2. 检索待办（活跃优先，同时也拉最近完成的历史）
        let allTodos = (try? context.fetch(FetchDescriptor<TodoItem>())) ?? []
        guard !allTodos.isEmpty else { return .none }

        var candidates: [TargetCandidate<TodoItem>] = []

        for todo in allTodos {
            let title = todo.title.lowercased()
            let detail = (todo.detail ?? "").lowercased()
            let isActive = todo.status == .active

            var matchScore: Double = 0

            if title == q {
                matchScore = 1.0
            } else if title.contains(q) {
                // 标题包含输入（如「开会」匹配「下午三点开会」）
                matchScore = 0.85
            } else if q.contains(title) && title.count >= 2 {
                // 输入包含标题（如「把下午开会完成」包含「下午开会」）
                matchScore = 0.8
            } else if detail.contains(q) {
                matchScore = 0.5
            } else {
                // 字符重合度计算（Jaccard / 共同字数）
                let qChars = Set(q)
                let titleChars = Set(title)
                let common = qChars.intersection(titleChars).count
                if common >= 2 {
                    matchScore = Double(common) / Double(max(qChars.count, titleChars.count)) * 0.7
                }
            }

            guard matchScore >= 0.4 else { continue }

            // 活跃状态加权：未完成待办优先于已完成
            let statusWeight = isActive ? 1.0 : 0.5
            var finalScore = matchScore * statusWeight

            // 时间接近度加权：今天/即将到期加分
            if let due = todo.dueAt {
                let cal = Calendar.current
                if cal.isDateInToday(due) {
                    finalScore += 0.15
                } else if due < .now && isActive {
                    finalScore += 0.1 // 逾期待办也加权
                }
            }

            var subtitleParts: [String] = []
            if let due = todo.dueAt {
                subtitleParts.append(due.formatted(date: .abbreviated, time: .shortened))
            }
            if !isActive {
                subtitleParts.append("已完成")
            }

            candidates.append(TargetCandidate(
                id: todo.id,
                item: todo,
                displayTitle: todo.title,
                subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · "),
                score: finalScore
            ))
        }

        candidates.sort { $0.score > $1.score }

        guard let best = candidates.first else {
            return .none
        }

        // 唯一高分匹配判断
        if candidates.count == 1 && best.score >= 0.5 {
            return .unique(best.item)
        }

        if let second = candidates.dropFirst().first {
            // 第一名显著高于第二名（分差 >= 0.25 且绝对分 >= 0.75）
            if best.score >= 0.75 && (best.score - second.score >= 0.25) {
                return .unique(best.item)
            }
            // 否则归为歧义候选集，最多返回前 4 项供用户点选
            return .ambiguous(Array(candidates.prefix(4)))
        }

        return best.score >= 0.5 ? .unique(best.item) : .none
    }

    /// 解析账目记录目标
    static func resolveExpense(
        mention: String,
        amount: Double? = nil,
        context: ModelContext
    ) -> TargetResolution<ExpenseRecord> {
        let q = mention.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 按 UUID 定位
        if let uuid = UUID(uuidString: q) {
            let desc = FetchDescriptor<ExpenseRecord>(predicate: #Predicate { $0.id == uuid })
            if let found = (try? context.fetch(desc))?.first {
                return .unique(found)
            }
        }

        // 取最近 30 天支出进行匹配
        let cal = Calendar.current
        let thirtyDaysAgo = cal.date(byAdding: .day, value: -30, to: .now) ?? .now
        var desc = FetchDescriptor<ExpenseRecord>(
            predicate: #Predicate { $0.date >= thirtyDaysAgo },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        desc.fetchLimit = 50

        let records = (try? context.fetch(desc)) ?? []
        guard !records.isEmpty else { return .none }

        var candidates: [TargetCandidate<ExpenseRecord>] = []
        for r in records {
            var score: Double = 0
            let title = r.title.lowercased()
            let cat = r.categoryRaw.lowercased()

            if !q.isEmpty {
                if title == q { score += 0.8 }
                else if title.contains(q) || q.contains(title) { score += 0.6 }
                else if cat.contains(q) { score += 0.4 }
            }

            if let targetAmt = amount, abs(r.amount - targetAmt) < 0.01 {
                score += 0.5
            }

            // 越接近今天的账单越加权
            let daysAgo = cal.dateComponents([.day], from: r.date, to: .now).day ?? 30
            score += max(0, Double(30 - daysAgo) / 30.0 * 0.2)

            guard score >= 0.5 else { continue }

            let sub = "\(r.date.formatted(date: .abbreviated, time: .omitted)) · \(r.categoryRaw) · ¥\(String(format: "%.2f", r.amount))"
            candidates.append(TargetCandidate(
                id: r.id,
                item: r,
                displayTitle: r.title.isEmpty ? r.categoryRaw : r.title,
                subtitle: sub,
                score: score
            ))
        }

        candidates.sort { $0.score > $1.score }

        guard let best = candidates.first else { return .none }
        if candidates.count == 1 || (candidates.count > 1 && best.score - candidates[1].score >= 0.25) {
            return .unique(best.item)
        }
        return .ambiguous(Array(candidates.prefix(4)))
    }
}
