import Foundation

// MARK: - 待办时间聚合（缺口：首页「今天/即将到期」聚合视图）
//
// 把待办按时间组织成**互斥**三桶：逾期 / 今天 / 本周。
// 互斥是「聚合格数与详情一致」的前提——同一事项只落一桶，
// chip 上的数字直接就是详情列表长度，不存在重复计数。
//
// 分桶语义（日粒度，非时刻粒度）：
// - 逾期：生效时间早于**今天零点**。今天上午 9 点到期、现在 10 点的事项
//   仍属「今天」——它是「今天该做的」，不是「早就该做的」。
// - 今天：生效时间落在今天（含边界 startOfToday），或无日期但今天创建。
// - 本周：生效时间在明天（含）至本周末（不含下周）之间。
//
// 生效时间 = reminderOverrideAt ?? dueAt：改期后以改期时间为准，
// 与提醒重排链路口径一致。完成事项不参与分桶。

/// 分桶输入快照（纯值，Core 可独立测试，不依赖 SwiftData 模型）
public struct TodoTimeSnapshot: Hashable, Sendable {
    public let id: UUID
    public let dueAt: Date?
    public let reminderOverrideAt: Date?
    public let createdAt: Date
    public let isDone: Bool

    public init(
        id: UUID = UUID(),
        dueAt: Date?,
        reminderOverrideAt: Date? = nil,
        createdAt: Date,
        isDone: Bool = false
    ) {
        self.id = id
        self.dueAt = dueAt
        self.reminderOverrideAt = reminderOverrideAt
        self.createdAt = createdAt
        self.isDone = isDone
    }

    /// 生效时间：改期后的提醒时间优先于原定截止时间
    public var effectiveDate: Date? { reminderOverrideAt ?? dueAt }
}

/// 时间桶种类（UI 入口的三个 chip）
public enum TodoTimeBucketKind: String, CaseIterable, Sendable, Identifiable {
    case overdue
    case today
    case thisWeek

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overdue: return "逾期"
        case .today: return "今天"
        case .thisWeek: return "本周"
        }
    }

    public var systemImage: String {
        switch self {
        case .overdue: return "exclamationmark.triangle.fill"
        case .today: return "calendar.badge.clock"
        case .thisWeek: return "calendar"
        }
    }
}

/// 互斥分桶结果。ID 顺序即展示顺序（按生效时间升序，无日期的排最后按创建时间降序）。
public struct TodoTimeBuckets: Sendable, Equatable {
    public let overdue: [UUID]
    public let today: [UUID]
    public let thisWeek: [UUID]

    public init(overdue: [UUID] = [], today: [UUID] = [], thisWeek: [UUID] = []) {
        self.overdue = overdue
        self.today = today
        self.thisWeek = thisWeek
    }

    public static let empty = TodoTimeBuckets()

    public var isEmpty: Bool { overdue.isEmpty && today.isEmpty && thisWeek.isEmpty }

    public func ids(for kind: TodoTimeBucketKind) -> [UUID] {
        switch kind {
        case .overdue: return overdue
        case .today: return today
        case .thisWeek: return thisWeek
        }
    }

    public func count(for kind: TodoTimeBucketKind) -> Int {
        ids(for: kind).count
    }
}

/// 分桶纯函数。日期运算全部走传入的 calendar，保证测试确定性。
public enum TodoTimeAggregator {

    /// 将快照集合分为逾期/今天/本周三个互斥桶。
    /// - Parameters:
    ///   - items: 待分桶快照（含已完成的，内部会剔除）
    ///   - now: 参照时刻（默认当前）
    ///   - calendar: 日历（默认当前；测试传固定时区/周起始）
    public static func bucket(
        _ items: [TodoTimeSnapshot],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> TodoTimeBuckets {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? .distantFuture
        // 本周末 = 当前周区间的终点（下一周起点，不含）。今天是本周最后一天时本周桶为空。
        let endOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.end ?? .distantFuture

        var overdue: [(id: UUID, sortDate: Date)] = []
        var today: [(id: UUID, sortDate: Date)] = []
        var thisWeek: [(id: UUID, sortDate: Date)] = []

        for item in items where !item.isDone {
            if let effective = item.effectiveDate {
                if effective < startOfToday {
                    overdue.append((item.id, effective))
                } else if effective < startOfTomorrow {
                    // 含 startOfToday 边界：今天零点到期算「今天」
                    today.append((item.id, effective))
                } else if effective < endOfWeek {
                    thisWeek.append((item.id, effective))
                }
                // 超出本周的事项不进聚合（仍在类型分类里）
            } else if item.createdAt >= startOfToday && item.createdAt < startOfTomorrow {
                // 无日期但今天创建：按「今天冒出来的活」处理，与首页今日待办口径一致
                today.append((item.id, item.createdAt))
            }
        }

        return TodoTimeBuckets(
            overdue: overdue.sorted { $0.sortDate < $1.sortDate }.map(\.id),
            today: today.sorted { $0.sortDate < $1.sortDate }.map(\.id),
            thisWeek: thisWeek.sorted { $0.sortDate < $1.sortDate }.map(\.id)
        )
    }

    /// 从模型侧快照便捷装配（保持 ID 可回查）。
    public static func snapshots(
        dueAt: Date?,
        reminderOverrideAt: Date?,
        createdAt: Date,
        isDone: Bool
    ) -> TodoTimeSnapshot {
        TodoTimeSnapshot(
            dueAt: dueAt,
            reminderOverrideAt: reminderOverrideAt,
            createdAt: createdAt,
            isDone: isDone
        )
    }
}
