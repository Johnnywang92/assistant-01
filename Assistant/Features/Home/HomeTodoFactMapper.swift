import AssistantCore
import Foundation

// MARK: - 首页 · App 层映射边界
//
// 方案 C 的工程红线：**状态数据由 Core 输出结构化事实，视图只渲染、不自行计算**。
// 但「SwiftData 模型 → Core 纯值事实」这一步在 App 层，只有 App 层能测。
//
// 为什么单独抽成 mapper 而不是留在 View 的 private 属性里：
// - View 的 private 计算属性无法单测，改动只能靠人肉 review；
// - 这里把映射规则显式化，测试能钉住「今天口径」「无日期只算今天新建」
//   这类**静默失败高发**的筛选条件；
// - mapper 只做映射，不做判定：判定规则全在 Core（主任务、空闲时长、队列顺序）。
//
// 依赖约束：mapper 依赖 SwiftData 的 `TodoItem`，因此 App 层测试 target
// 需要 SwiftData 宏插件可用。纯逻辑部分（不碰 SwiftData）放在 Core，
// 由 `swift test` 覆盖，不受宏插件环境影响。

/// 一条待办在首页的**今日口径**筛选结果。
struct HomeTodoCandidate: Hashable, Sendable {
    /// 是否计入今日概览的环。
    let isIncluded: Bool
    /// 计入时的纯值事实；未计入时为 nil。
    let fact: HomeTodoFact?

    init(isIncluded: Bool, fact: HomeTodoFact?) {
        self.isIncluded = isIncluded
        self.fact = fact
    }
}

/// 首页「今日口径」的筛选规则。
///
/// 口径（与 `homeFacts` 保持一致，抽出来是为了能测）：
/// - **活跃**：今天到期（含逾期）或今天创建的。无日期的待办只统计今天新建的，
///   避免全库陈年待办把环的分母撑爆；
/// - **已完成**：今天完成的（`completedAt` 落在今天）。
enum HomeTodoFactMapper {

    /// 把一条待办映射为首页事实。`now` / `calendar` 必须由调用方注入，
    /// 禁止在这里读墙上时钟（否则测试不可复现）。
    static func map(
        id: UUID,
        isDone: Bool,
        dueAt: Date?,
        reminderOverrideAt: Date?,
        createdAt: Date,
        completedAt: Date?,
        now: Date,
        calendar: Calendar
    ) -> HomeTodoCandidate {
        // 有效时间：手动改过的提醒时间优先于原到期时间
        let effective = reminderOverrideAt ?? dueAt

        if isDone {
            // 已完成：只看完成时刻是否落在今天
            guard let completedAt, completedAt >= calendar.startOfDay(for: now) else {
                return HomeTodoCandidate(isIncluded: false, fact: nil)
            }
            return HomeTodoCandidate(
                isIncluded: true,
                fact: HomeTodoFact(
                    id: id,
                    isDone: true,
                    dueAt: effective,
                    createdAt: createdAt,
                    isOverdue: false
                )
            )
        }

        // 活跃：今天到期（含逾期）或今天创建
        if let effective {
            guard let startOfTomorrow = calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: now)
            ) else {
                return HomeTodoCandidate(isIncluded: false, fact: nil)
            }
            guard effective < startOfTomorrow else {
                return HomeTodoCandidate(isIncluded: false, fact: nil)
            }
        } else {
            guard createdAt >= calendar.startOfDay(for: now) else {
                return HomeTodoCandidate(isIncluded: false, fact: nil)
            }
        }

        return HomeTodoCandidate(
            isIncluded: true,
            fact: HomeTodoFact(
                id: id,
                isDone: false,
                dueAt: effective,
                createdAt: createdAt,
                isOverdue: (effective ?? .distantFuture) < now
            )
        )
    }
}
