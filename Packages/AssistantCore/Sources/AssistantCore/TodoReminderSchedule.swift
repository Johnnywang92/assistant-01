import Foundation

/// 临期提醒的提前量计算与批量重排选择的纯逻辑。
/// 下沉自 Assistant/Services/TodoNotificationManager.swift，通知系统调用留在 app 侧。
public enum TodoReminderSchedule {
    /// 到期后仍未完成时的补提醒偏移（1 小时、3 小时、24 小时）。
    public static let overdueOffsets: [TimeInterval] = [3600, 3 * 3600, 24 * 3600]

    /// 批量重排时最多排期多少项。
    /// 每个待办最多占用 4 个系统通知名额（主提醒 + 3 次逾期提醒），iOS 对挂起通知数量有限制。
    /// 注意：文档曾写 50，代码事实为 15，以此处为准（回归测试会钉住该值）。
    public static let maxScheduledItems = 15

    /// 参与重排计算的待办快照。
    public struct Item: Hashable, Sendable {
        public var id: UUID
        public var dueAt: Date?
        /// 通知「稍后提醒」写入的下次提醒时间；只影响提醒，不改截止时间。
        public var reminderOverrideAt: Date?
        public var remindBeforeMinutes: Int

        public init(id: UUID, dueAt: Date?, reminderOverrideAt: Date?, remindBeforeMinutes: Int) {
            self.id = id
            self.dueAt = dueAt
            self.reminderOverrideAt = reminderOverrideAt
            self.remindBeforeMinutes = remindBeforeMinutes
        }
    }

    /// 主提醒时间：dueAt 提前 remindBeforeMinutes 分钟；提前量已过点则回落到 dueAt。
    /// 返回值可能不晚于 now（事项已到期但仍有未来逾期补提醒时，原实现按 1 秒立即触发），
    /// 因此 app 侧仍需 `max(1, timeIntervalSinceNow)` 兜底。
    /// 返回 nil 表示完全不该排期：主提醒、截止时间、三次逾期补提醒全部落在过去。
    /// override 存在时无条件优先于提前量（与「稍后」语义一致：用户选了时间就按它）。
    public static func mainReminderDate(
        dueAt: Date,
        remindBeforeMinutes: Int,
        reminderOverrideAt: Date?,
        now: Date
    ) -> Date? {
        let earlyReminder = dueAt.addingTimeInterval(-TimeInterval(max(0, remindBeforeMinutes) * 60))
        let planned = reminderOverrideAt ?? (earlyReminder > now ? earlyReminder : dueAt)
        guard planned > now || dueAt > now || !futureOverdueOffsets(dueAt: dueAt, now: now).isEmpty else {
            return nil
        }
        return planned
    }

    /// 仍晚于 now 的逾期补提醒偏移，按由近到远排列。
    public static func futureOverdueOffsets(dueAt: Date, now: Date) -> [TimeInterval] {
        overdueOffsets.filter { dueAt.addingTimeInterval($0) > now }
    }

    /// 是否还值得排期：dueAt / override / 任一逾期补提醒中至少一个在未来。
    public static func needsReschedule(_ item: Item, now: Date) -> Bool {
        let hasFutureDue = (item.dueAt ?? .distantPast) > now
        let hasFutureOverride = (item.reminderOverrideAt ?? .distantPast) > now
        let hasFutureOverdueReminder = item.dueAt.map { due in
            overdueOffsets.contains { due.addingTimeInterval($0) > now }
        } ?? false
        return hasFutureDue || hasFutureOverride || hasFutureOverdueReminder
    }

    /// 重排排序键：优先 override，否则「dueAt 减提前量」。
    /// 保持与原实现一致：这里不 clamp 负提前量、也不判断是否过期（截断口径与逐项排期口径本就不同）。
    public static func sortKey(_ item: Item) -> Date {
        item.reminderOverrideAt ?? (item.dueAt ?? .distantFuture).addingTimeInterval(-TimeInterval(item.remindBeforeMinutes * 60))
    }

    /// 批量重排选择：先过滤掉全无未来提醒的项，再按最近触发排序，截断到上限（选最近到期的）。
    public static func selectItemsForRescheduling(
        _ items: [Item],
        now: Date,
        limit: Int = maxScheduledItems
    ) -> [Item] {
        items.filter { needsReschedule($0, now: now) }
            .sorted { sortKey($0) < sortKey($1) }
            .prefix(limit)
            .map { $0 }
    }
}
