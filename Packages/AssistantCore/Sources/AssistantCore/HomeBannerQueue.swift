import Foundation

// MARK: - 首页条件横幅 · 纯值事实与队列规则
//
// 文档 §8.4：存量 10 个条件横幅收敛为**一条优先队列**，首页只显示队列头 1 条，
// 其余进「更多 · N」二级页，功能一条不丢。
//
// 为什么把队列规则放进 Core：
// 1. App 层原本用带闭包的 `HomeBannerItem` 表达，闭包无法单测；
//    这里只放**纯值事实**（ID / 分组 / 是否可关闭 / 触发时刻），
//    动作绑定留在 App 层，规则就能被 `swift test` 钉住。
// 2. 队列规则是产品口径，不是渲染细节。视图不排序、不裁剪、不算「更多 · N」。
//
// 队列不变量（§9 验收条目）：
// - 同一时刻首页最多 1 条横幅；「更多 · N」的 N = 命中总数 − 1，为 0 时不显示入口；
// - 关闭 / 已处理后队列重新取头，横幅与徽标同步刷新；
// - 长辈关怀大字模式与排序模式互斥，同时命中只显示一条。

/// 横幅分组。数值越小优先级越高，与设计侧建议的 P0/P1/P2 对应。
/// 顺序**待产品确认**，实现侧只依赖本枚举的相对大小，不依赖绝对数值。
public enum HomeBannerGroup: Int, CaseIterable, Comparable, Sendable {
    /// 安全与时效：有明确时效或安全含义，错过即失去价值（气象预警、出行购票、纪念日筹备）
    case safetyAndTimeliness = 0
    /// 进行中的操作态：用户当前正处在某个模式里，或需要做出决策（排序模式、长辈模式、待确认事项）
    case activeOperation = 1
    /// 信息态：告知性内容，不要求立即处理（生活事件、搜索索引预览）
    case informational = 2

    public static func < (lhs: HomeBannerGroup, rhs: HomeBannerGroup) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 二级页的分组标题。Core 只给分组 ID，文案由 App 层翻译（§2：Core 不认识 App 枚举）。
    public var groupID: String {
        switch self {
        case .safetyAndTimeliness: return "safety"
        case .activeOperation: return "operation"
        case .informational: return "informational"
        }
    }
}

/// 一条横幅的**纯值事实**。不含闭包、不含 UI 颜色。
public struct HomeBannerFact: Hashable, Sendable {
    /// 稳定 ID。用于「关闭后不再回到首页」的持久化去重。
    public let id: String
    public let group: HomeBannerGroup
    /// 是否允许用户手动关闭。进行中的操作态（如排序模式）必须提供「退出」而不是「关闭」。
    public let isDismissible: Bool
    /// 是否已过期。过期必须转警告色并在文案内写明「已过期」。
    public let isExpired: Bool
    /// 触发时刻，用于同组内按时间倒序。
    public let triggeredAt: Date

    public init(
        id: String,
        group: HomeBannerGroup,
        isDismissible: Bool = true,
        isExpired: Bool = false,
        triggeredAt: Date
    ) {
        self.id = id
        self.group = group
        self.isDismissible = isDismissible
        self.isExpired = isExpired
        self.triggeredAt = triggeredAt
    }
}

/// 队列的计算结果。
public struct HomeBannerQueue: Hashable, Sendable {
    /// 排序后的完整队列（队头在前）。
    public let ordered: [HomeBannerFact]
    /// 已被关闭、本会话不再回到首页的 ID。
    public let dismissedIDs: Set<String>

    public init(ordered: [HomeBannerFact], dismissedIDs: Set<String> = []) {
        self.ordered = ordered
        self.dismissedIDs = dismissedIDs
    }

    /// 队列头（首页唯一显示的那条）。无命中时为 nil —— 默认态**不出现空横幅占位**。
    public var head: HomeBannerFact? { ordered.first }

    /// 「更多 · N」的 N = 命中总数 − 1。为 0 时不显示入口，不显示「更多 · 0」。
    public var moreCount: Int { max(0, ordered.count - 1) }

    /// 是否需要显示「更多」入口。
    public var hasMore: Bool { moreCount > 0 }

    /// 按分组切分，供二级页渲染。组内按触发时间倒序。
    public func grouped() -> [(group: HomeBannerGroup, items: [HomeBannerFact])] {
        HomeBannerGroup.allCases.compactMap { group in
            let rows = ordered
                .filter { $0.group == group }
                .sorted { lhs, rhs in
                    if lhs.triggeredAt != rhs.triggeredAt { return lhs.triggeredAt > rhs.triggeredAt }
                    // Array.sorted 不稳定，带原始下标兜底保证顺序可复现
                    return lhs.id < rhs.id
                }
            guard !rows.isEmpty else { return nil }
            return (group, rows)
        }
    }
}

public enum HomeBannerQueueBuilder {

    /// 按队列规则算出排序后的队列。
    ///
    /// - Parameters:
    ///   - facts: 当前命中的全部横幅事实。
    ///   - dismissedIDs: 已关闭的 ID 集合，命中这些 ID 的一律不再展示。
    ///   - mutualExclusiveGroup: 互斥模式组。长辈关怀大字模式与排序模式同时命中时，
    ///     只保留其中一条（按 `facts` 传入顺序取第一条），避免首页出现两条操作态横幅。
    public static func make(
        facts: [HomeBannerFact],
        dismissedIDs: Set<String> = [],
        mutualExclusiveGroup: Set<String> = []
    ) -> HomeBannerQueue {
        var seen = Set<String>()
        var filtered: [HomeBannerFact] = []

        for fact in facts where !dismissedIDs.contains(fact.id) {
            guard seen.insert(fact.id).inserted else { continue }
            filtered.append(fact)
        }

        // 互斥组内只留第一条（先到先得），保证「同一时刻最多 1 条操作态横幅」
        if !mutualExclusiveGroup.isEmpty {
            var keptFromExclusiveGroup = false
            filtered = filtered.filter { fact in
                guard mutualExclusiveGroup.contains(fact.id) else { return true }
                if keptFromExclusiveGroup { return false }
                keptFromExclusiveGroup = true
                return true
            }
        }

        let ordered = filtered.sorted { lhs, rhs in
            if lhs.group != rhs.group { return lhs.group < rhs.group }
            // 同组内：过期优先（安全时效类里过期更紧急），其次触发时间倒序
            if lhs.isExpired != rhs.isExpired { return lhs.isExpired }
            if lhs.triggeredAt != rhs.triggeredAt { return lhs.triggeredAt > rhs.triggeredAt }
            return lhs.id < rhs.id
        }

        return HomeBannerQueue(ordered: ordered, dismissedIDs: dismissedIDs)
    }

    /// 关闭某条后重算队列（§9：关闭后队列重新取头，横幅与徽标同步刷新）。
    public static func dismissing(
        _ id: String,
        in facts: [HomeBannerFact],
        dismissedIDs: Set<String> = [],
        mutualExclusiveGroup: Set<String> = []
    ) -> HomeBannerQueue {
        var next = dismissedIDs
        next.insert(id)
        return make(
            facts: facts,
            dismissedIDs: next,
            mutualExclusiveGroup: mutualExclusiveGroup
        )
    }
}
