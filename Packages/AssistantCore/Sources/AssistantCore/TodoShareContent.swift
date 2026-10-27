import Foundation

/// 分享清单的分类（与 App 侧筛选栏一一对应）。
///
/// 分类**规则**住在 Core，App 侧只负责把模型映射成 `TodoShareItem`——
/// 这样「哪些类型算快递清单」「哪些算重要预警」这些规则可以被单测钉死，
/// 而不是散落在一个千行视图文件里靠肉眼维护。
public enum TodoShareCategory: String, CaseIterable, Sendable, Identifiable {
    case all
    case general
    case work
    case recurring
    case parcel
    case life
    case alert
    case parenting
    case pet
    case other

    public var id: String { rawValue }
}

/// 待办类型分组。
///
/// Core 不认识 App 的 `TodoType` 枚举，只认识「这个类型属于哪一组」；
/// 类型 → 分组的映射由 App 侧提供，避免同一份分类规则写两遍然后各自漂移。
public enum TodoShareTypeGroup: String, Sendable, CaseIterable {
    case work
    case parcel
    case returnParcel
    case life
    case alert
    case parenting
    case pet
    case other
}

/// 分享卡片上的单条事项（纯值快照）
public struct TodoShareItem: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let pickupCode: String?
    public let isDone: Bool
    /// 类型分组；nil 表示该类型不属于任何分享分类（只在「全部」里出现）
    public let group: TodoShareTypeGroup?
    public let isRecurring: Bool
    public let dueAt: Date?
    public let reminderOverrideAt: Date?
    public let createdAt: Date

    public init(
        id: UUID,
        title: String,
        pickupCode: String? = nil,
        isDone: Bool = false,
        group: TodoShareTypeGroup? = nil,
        isRecurring: Bool = false,
        dueAt: Date? = nil,
        reminderOverrideAt: Date? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.pickupCode = pickupCode
        self.isDone = isDone
        self.group = group
        self.isRecurring = isRecurring
        self.dueAt = dueAt
        self.reminderOverrideAt = reminderOverrideAt
        self.createdAt = createdAt
    }
}

/// 分享清单的内容规则
public enum TodoShareContent {
    /// 各分类包含的类型分组。
    ///
    /// `.all` / `.general` / `.recurring` 不按类型分组过滤，返回空集合，
    /// 由调用方按各自规则处理（全量 / 今日判定 / 周期标记）。
    public static func groups(for category: TodoShareCategory) -> Set<TodoShareTypeGroup> {
        switch category {
        case .all, .general, .recurring:
            return []
        case .work:
            return [.work]
        case .parcel:
            return [.parcel, .returnParcel]
        case .life:
            return [.life]
        case .alert:
            return [.alert]
        case .parenting:
            return [.parenting]
        case .pet:
            return [.pet]
        case .other:
            return [.other]
        }
    }

    /// 卡片标题（返回中文 key，由 App 侧 `L10n.tr` 做本地化）
    public static func title(for category: TodoShareCategory) -> String {
        switch category {
        case .all: return "我的生活清单"
        case .general: return "日常待办清单"
        case .work: return "工作待办清单"
        case .recurring: return "周期待办清单"
        case .parcel: return "快递与退货清单"
        case .life: return "生活作息备忘"
        case .alert: return "重要提醒与预警"
        case .parenting: return "亲子育儿清单"
        case .pet: return "宠物照护"
        case .other: return "其它清单"
        }
    }

    /// 「今日待办」判定，口径与待办页一致：
    /// 改期时间优先，其次截止时间；都没有则看创建日。
    /// 今天零点之前到期的也算「今天该做的」——那是今天要处理的，不是早就该做的。
    ///
    /// 「今天」一律以传入的 `now` 为准，而不是墙上时钟。
    /// 规则里如果偷偷用 `isDateInToday`，`now` 形参就成了摆设：
    /// 测试无法构造确定性的「今天」，换句话说这类规则根本没法单测。
    public static func isTodayItem(
        dueAt: Date?,
        reminderOverrideAt: Date?,
        createdAt: Date,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        let startOfToday = calendar.startOfDay(for: now)
        if let override = reminderOverrideAt {
            if calendar.isDate(override, inSameDayAs: now) || override < startOfToday { return true }
        }
        if let due = dueAt {
            return calendar.isDate(due, inSameDayAs: now) || due < startOfToday
        }
        return calendar.isDate(createdAt, inSameDayAs: now)
    }

    /// 按分类筛选事项
    public static func items(
        in all: [TodoShareItem],
        category: TodoShareCategory,
        now: Date,
        calendar: Calendar
    ) -> [TodoShareItem] {
        switch category {
        case .all:
            return all
        case .general:
            return all.filter {
                isTodayItem(
                    dueAt: $0.dueAt,
                    reminderOverrideAt: $0.reminderOverrideAt,
                    createdAt: $0.createdAt,
                    now: now,
                    calendar: calendar
                )
            }
        case .recurring:
            return all.filter(\.isRecurring)
        default:
            let groups = groups(for: category)
            return all.filter { item in
                guard let group = item.group else { return false }
                return groups.contains(group)
            }
        }
    }
}

/// 分享文案生成（纯逻辑，规则可独立测试）
public enum TodoShareTextBuilder {
    /// 好友 1 对 1 分享文本
    public static func friendShareText(
        title: String,
        items: [TodoShareItem],
        importURL: String
    ) -> String {
        guard !items.isEmpty else { return "【小助清单】暂无选中的事项" }
        var text = "【小助清单】\(title)\n"
        for (index, item) in items.enumerated() {
            let status = item.isDone ? "✅" : "⏳"
            let code = item.pickupCode.map { " (取件码: \($0))" } ?? ""
            text += "\(index + 1). \(status) \(item.title)\(code)\n"
        }
        text += "\n📲 复制本条内容或轻点链接导入小助 App：\n\(importURL)\n\n—— 记所想，助所行 (Capture thoughts, empower actions.)"
        return text
    }
}
