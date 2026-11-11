import Foundation

// MARK: - 主应用与小组件 / 实时活动 / Apple Watch 共享的轻量模型与对账纯逻辑

/// 快照中的单条待办/快递条目（Codable 轻量结构，避免扩展直接查询 SwiftData）
public struct WidgetTodoEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var typeRaw: String
    public var pickupCode: String?
    public var stationName: String?
    public var dueAt: Date?
    public var isRecurring: Bool

    public init(id: UUID, title: String, typeRaw: String,
                pickupCode: String? = nil, stationName: String? = nil,
                dueAt: Date? = nil, isRecurring: Bool = false) {
        self.id = id
        self.title = title
        self.typeRaw = typeRaw
        self.pickupCode = pickupCode
        self.stationName = stationName
        self.dueAt = dueAt
        self.isRecurring = isRecurring
    }
}

/// 今日练习快照条目：来自最近活跃的一条技能学习路径
public struct WidgetPracticeEntry: Codable, Hashable, Sendable {
    public var pathID: UUID
    /// 技能名（如「学吉他」）
    public var title: String
    /// 当前阶段名
    public var stageName: String
    /// 连续打卡天数
    public var streakDays: Int
    /// 本周已练习分钟数
    public var minutesThisWeek: Int
    /// 每周目标分钟数
    public var weeklyTargetMinutes: Int
    /// 今天是否已打卡
    public var isPracticedToday: Bool

    public init(pathID: UUID, title: String, stageName: String, streakDays: Int,
                minutesThisWeek: Int, weeklyTargetMinutes: Int, isPracticedToday: Bool) {
        self.pathID = pathID
        self.title = title
        self.stageName = stageName
        self.streakDays = streakDays
        self.minutesThisWeek = minutesThisWeek
        self.weeklyTargetMinutes = weeklyTargetMinutes
        self.isPracticedToday = isPracticedToday
    }
}

/// 今日情绪微打卡轻量摘要
public struct MoodCheckInSummary: Codable, Hashable, Sendable {
    public var mood: Int
    public var energy: Int
    public var stress: Int

    public init(mood: Int, energy: Int, stress: Int) {
        self.mood = mood
        self.energy = energy
        self.stress = stress
    }
}

/// 手表端出门清点单项条目
public struct WatchDepartureItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var isChecked: Bool
    public var isEssential: Bool
    public var locationNote: String?

    public init(id: UUID, title: String, isChecked: Bool, isEssential: Bool, locationNote: String? = nil) {
        self.id = id
        self.title = title
        self.isChecked = isChecked
        self.isEssential = isEssential
        self.locationNote = locationNote
    }
}

/// 出门清点快照（手表 / 桌面小组件共用）
public struct WatchDepartureSnapshot: Codable, Hashable, Sendable {
    public var sceneName: String
    public var items: [WatchDepartureItem]
    /// 已确认件数。**统计的是场景下的全部条目**，不是 `items` 里的截断子集
    /// （`items` 最多带 12 条，用它算会把「20 件里确认了 12 件」显示成「全部带齐」）。
    public var checkedCount: Int
    /// 场景下的总件数
    public var totalCount: Int

    public init(
        sceneName: String,
        items: [WatchDepartureItem],
        checkedCount: Int? = nil,
        totalCount: Int? = nil
    ) {
        self.sceneName = sceneName
        self.items = items
        // 未显式给出时按 items 现算，保证调用方不会因为漏传而拿到 0。
        self.checkedCount = checkedCount ?? items.filter(\.isChecked).count
        self.totalCount = totalCount ?? items.count
    }

    /// 是否全部带齐。
    public var isAllChecked: Bool {
        totalCount > 0 && checkedCount >= totalCount
    }

    /// 剩余未确认件数。
    public var remainingCount: Int {
        max(0, totalCount - checkedCount)
    }

    enum CodingKeys: String, CodingKey {
        case sceneName, items, checkedCount, totalCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sceneName = try container.decode(String.self, forKey: .sceneName)
        self.items = try container.decode([WatchDepartureItem].self, forKey: .items)
        // 老快照没有这两个字段 → 按 items 现算，而不是解码失败。
        // （小组件快照存于 App Group 且跨版本，解码失败会让组件静默空白）
        self.checkedCount = try container.decodeIfPresent(Int.self, forKey: .checkedCount)
            ?? items.filter(\.isChecked).count
        self.totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount)
            ?? items.count
    }
}

/// 手表端行程护航快照（高铁/航班倒计时、检票口、车厢座位）
public struct WatchTravelSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var departureDate: Date
    public var ticketSummary: String?
    public var gate: String?
    public var place: String?

    public init(
        id: UUID,
        title: String,
        departureDate: Date,
        ticketSummary: String? = nil,
        gate: String? = nil,
        place: String? = nil
    ) {
        self.id = id
        self.title = title
        self.departureDate = departureDate
        self.ticketSummary = ticketSummary
        self.gate = gate
        self.place = place
    }
}

/// 手表端今日服药打卡条目
public struct WatchMedicationEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var medName: String
    public var dosage: String
    public var mealRelationText: String
    public var timePointsText: String
    public var isTakenToday: Bool
    public var activeTodoID: UUID?
    /// 该药今日应服时点数（如 ["08:00","13:00","20:00"] → 3）
    public var scheduledCount: Int
    /// 该药今日已服次数的**保守下界**（有记录即 ≥1；单时间戳无法区分多次）
    public var takenCount: Int
    /// 下一个待服时点的文案（如 "20:00"），已服完时为 nil
    public var nextDueText: String?
    /// **漏服**的那一顿（已过时点但未完成），如 "08:00"；无漏服时 nil
    public var missedSlotText: String?

    public init(
        id: UUID,
        medName: String,
        dosage: String,
        mealRelationText: String,
        timePointsText: String,
        isTakenToday: Bool,
        activeTodoID: UUID? = nil,
        scheduledCount: Int = 0,
        takenCount: Int = 0,
        nextDueText: String? = nil,
        missedSlotText: String? = nil
    ) {
        self.id = id
        self.medName = medName
        self.dosage = dosage
        self.mealRelationText = mealRelationText
        self.timePointsText = timePointsText
        self.isTakenToday = isTakenToday
        self.activeTodoID = activeTodoID
        self.scheduledCount = scheduledCount
        self.takenCount = takenCount
        self.nextDueText = nextDueText
        self.missedSlotText = missedSlotText
    }

    /// 新字段全部 `decodeIfPresent` —— 老快照（没有这些字段）必须仍能解码，
    /// 否则组件会静默变空白。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.medName = try c.decode(String.self, forKey: .medName)
        self.dosage = try c.decode(String.self, forKey: .dosage)
        self.mealRelationText = try c.decode(String.self, forKey: .mealRelationText)
        self.timePointsText = try c.decode(String.self, forKey: .timePointsText)
        self.isTakenToday = try c.decode(Bool.self, forKey: .isTakenToday)
        self.activeTodoID = try c.decodeIfPresent(UUID.self, forKey: .activeTodoID)
        self.scheduledCount = try c.decodeIfPresent(Int.self, forKey: .scheduledCount) ?? 0
        self.takenCount = try c.decodeIfPresent(Int.self, forKey: .takenCount) ?? 0
        self.nextDueText = try c.decodeIfPresent(String.self, forKey: .nextDueText)
        self.missedSlotText = try c.decodeIfPresent(String.self, forKey: .missedSlotText)
    }
}

/// 手表端周期习惯（运动/家务）打卡条目
public struct WatchHabitEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var recurrenceText: String
    public var isDueToday: Bool
    /// 下次到期的时分文案（如 "21:00"），无则 nil
    public var nextDueText: String?

    public init(
        id: UUID,
        title: String,
        recurrenceText: String,
        isDueToday: Bool,
        nextDueText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.recurrenceText = recurrenceText
        self.isDueToday = isDueToday
        self.nextDueText = nextDueText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.recurrenceText = try c.decode(String.self, forKey: .recurrenceText)
        self.isDueToday = try c.decode(Bool.self, forKey: .isDueToday)
        self.nextDueText = try c.decodeIfPresent(String.self, forKey: .nextDueText)
    }
}

/// 今日服药汇总（由主 App 侧算好写入，扩展**不自己聚合**）。
///
/// 为什么不让扩展自己 sum：快照里的 `medications` 是 `prefix(6)` 截断的，
/// 扩展聚合会把「10 个药里服了 6 个」显示成「全部服完」——
/// 这类谎报会直接导致漏服。
public struct WidgetMedicationSummary: Codable, Hashable, Sendable {
    /// 今日应服时点总数（全部计划，不受截断影响）
    public var scheduledDoseCount: Int
    /// 今日已服次数的保守下界
    public var takenDoseLowerBound: Int
    /// 仍有待服时点的**药品种数**
    public var pendingPlanCount: Int
    /// 启用中的药品计划总数
    public var totalPlanCount: Int
    /// 今日是否已全部服完
    public var isAllSatisfied: Bool
    /// 今日尚未服用的时点总数（**显式值**，由主 App 逐个计划累加得出）。
    ///
    /// ## 为什么不能用 `scheduledDoseCount − takenDoseLowerBound` 推
    ///
    /// 那是**聚合层面的同一类谎报**：一个药已服完（3 剂，下界 1）、另一个没吃
    /// （1 剂），差值算出 `4 − 1 = 3`，实际只有 1 剂待服 → 组件报「待服 3 次」
    /// → 用户重复服药。
    ///
    /// 逐计划累加时，已服完的那个计划贡献 0（不是 2），总数才正确。
    public var pendingDoseCount: Int

    public init(
        scheduledDoseCount: Int,
        takenDoseLowerBound: Int,
        pendingPlanCount: Int,
        totalPlanCount: Int,
        isAllSatisfied: Bool,
        pendingDoseCount: Int? = nil
    ) {
        self.scheduledDoseCount = scheduledDoseCount
        self.takenDoseLowerBound = takenDoseLowerBound
        self.pendingPlanCount = pendingPlanCount
        self.totalPlanCount = totalPlanCount
        self.isAllSatisfied = isAllSatisfied
        if let pendingDoseCount {
            self.pendingDoseCount = max(0, pendingDoseCount)
        } else if isAllSatisfied {
            // 已全部服完 → 待服数必须是 0。
            // 走差值回落会算出 `scheduled − 下界`（如 3−1=2）→ 虚报 → 用户重复服药。
            self.pendingDoseCount = 0
        } else {
            // 老快照没有这个字段时回落到差值公式（保持向后兼容的旧行为）。
            self.pendingDoseCount = max(0, scheduledDoseCount - takenDoseLowerBound)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.scheduledDoseCount = try c.decode(Int.self, forKey: .scheduledDoseCount)
        self.takenDoseLowerBound = try c.decodeIfPresent(Int.self, forKey: .takenDoseLowerBound) ?? 0
        self.pendingPlanCount = try c.decodeIfPresent(Int.self, forKey: .pendingPlanCount) ?? 0
        self.totalPlanCount = try c.decodeIfPresent(Int.self, forKey: .totalPlanCount) ?? 0
        self.isAllSatisfied = try c.decodeIfPresent(Bool.self, forKey: .isAllSatisfied) ?? false
        if let explicit = try c.decodeIfPresent(Int.self, forKey: .pendingDoseCount) {
            self.pendingDoseCount = max(0, explicit)
        } else if self.isAllSatisfied {
            self.pendingDoseCount = 0
        } else {
            self.pendingDoseCount = max(0, self.scheduledDoseCount - self.takenDoseLowerBound)
        }
    }
}

/// 今日打卡汇总（主 App 侧算好）。
public struct WidgetHabitSummary: Codable, Hashable, Sendable {
    /// 今日待打卡的条数
    public var dueCount: Int
    /// 启用中的习惯总数
    public var totalCount: Int

    public init(dueCount: Int, totalCount: Int) {
        self.dueCount = dueCount
        self.totalCount = totalCount
    }

    /// 今日是否已全部完成
    public var isAllDone: Bool { dueCount == 0 }
}

/// 手表端健康双指数（身体活力 & 身心愉悦）轻量速览快照
public struct WatchHealthSnapshot: Codable, Hashable, Sendable {
    public var vitalityScore: Int?
    public var vitalityBadge: String?
    public var pleasureScore: Int?
    public var pleasureBadge: String?
    public var stressBadge: String?
    public var headlineAdvice: String?
    public var sleepHours: Double?
    public var hrvMS: Double?
    public var restingHR: Double?
    public var steps: Int?

    public init(
        vitalityScore: Int? = nil,
        vitalityBadge: String? = nil,
        pleasureScore: Int? = nil,
        pleasureBadge: String? = nil,
        stressBadge: String? = nil,
        headlineAdvice: String? = nil,
        sleepHours: Double? = nil,
        hrvMS: Double? = nil,
        restingHR: Double? = nil,
        steps: Int? = nil
    ) {
        self.vitalityScore = vitalityScore
        self.vitalityBadge = vitalityBadge
        self.pleasureScore = pleasureScore
        self.pleasureBadge = pleasureBadge
        self.stressBadge = stressBadge
        self.headlineAdvice = headlineAdvice
        self.sleepHours = sleepHours
        self.hrvMS = hrvMS
        self.restingHR = restingHR
        self.steps = steps
    }
}

/// 桌面小组件与 Apple Watch 使用的共享快照
public struct WidgetSnapshot: Codable, Hashable, Sendable {
    /// 今日高优待办（紧急性+重要性排序，最多 6 条）
    public var topTodos: [WidgetTodoEntry]
    /// 待取快递（含取件码的活跃快递/退货待办）
    public var parcels: [WidgetTodoEntry]
    /// 今日支出合计（用于小号组件"今日支出"速览）
    public var todayExpense: Double
    /// 今日练习（最近活跃的学习路径；无进行中路径时为 nil）
    public var todayPractice: WidgetPracticeEntry?
    /// 今日有效补水（毫升）
    public var todayWaterML: Double
    /// 每日饮水目标（毫升）
    public var waterGoalML: Double
    /// 今日心情打卡分值（若今日已打卡）
    public var todayMood: MoodCheckInSummary?
    /// 出门防丢清点清单快照
    public var departureSnapshot: WatchDepartureSnapshot?
    /// 近期行程护航快照（高铁/航班）
    public var travelSnapshot: WatchTravelSnapshot?
    /// 今日服药提醒与打卡状态
    public var medications: [WatchMedicationEntry]
    /// 今日到期周期习惯/运动
    public var habits: [WatchHabitEntry]
    /// 身体活力与身心愉悦双指数速览
    public var healthSnapshot: WatchHealthSnapshot?
    /// 首页概览快照（完成环进度 / 空闲时长 / 今日节奏 / 主任务）。
    /// 与 App 首页**同源**：主 App 用同一份 `HomeSnapshotBuilder` 算出后写入，
    /// 小组件只渲染，不再自己算一套，避免「桌面 2/4、App 3/4」对不上。
    public var homeOverview: WidgetHomeOverview?
    /// 纪念日倒计时（按距离升序，最多若干条）
    public var anniversaries: [WidgetAnniversaryEntry]
    /// 今日服药汇总（主 App 侧算好；扩展不自己聚合，避免 prefix 截断导致谎报）
    public var medicationSummary: WidgetMedicationSummary?
    /// 今日打卡汇总（主 App 侧算好）
    public var habitSummary: WidgetHabitSummary?
    /// 主应用已落库确认的指令 ID 列表（用于手表端幂等去重与乐观状态对账）
    public var ackedCommandIDs: [UUID]
    public var generatedAt: Date

    public static let empty = WidgetSnapshot(
        topTodos: [], parcels: [], todayExpense: 0, todayPractice: nil,
        todayWaterML: 0, waterGoalML: 1700, todayMood: nil,
        departureSnapshot: nil, travelSnapshot: nil,
        medications: [], habits: [], healthSnapshot: nil,
        homeOverview: nil, anniversaries: [],
        medicationSummary: nil, habitSummary: nil,
        ackedCommandIDs: [], generatedAt: .distantPast
    )

    public init(topTodos: [WidgetTodoEntry], parcels: [WidgetTodoEntry], todayExpense: Double,
                todayPractice: WidgetPracticeEntry? = nil,
                todayWaterML: Double = 0, waterGoalML: Double = 1700,
                todayMood: MoodCheckInSummary? = nil,
                departureSnapshot: WatchDepartureSnapshot? = nil,
                travelSnapshot: WatchTravelSnapshot? = nil,
                medications: [WatchMedicationEntry] = [],
                habits: [WatchHabitEntry] = [],
                healthSnapshot: WatchHealthSnapshot? = nil,
                homeOverview: WidgetHomeOverview? = nil,
                anniversaries: [WidgetAnniversaryEntry] = [],
                medicationSummary: WidgetMedicationSummary? = nil,
                habitSummary: WidgetHabitSummary? = nil,
                ackedCommandIDs: [UUID] = [],
                generatedAt: Date) {
        self.topTodos = topTodos
        self.parcels = parcels
        self.todayExpense = todayExpense
        self.todayPractice = todayPractice
        self.todayWaterML = todayWaterML
        self.waterGoalML = waterGoalML
        self.todayMood = todayMood
        self.departureSnapshot = departureSnapshot
        self.travelSnapshot = travelSnapshot
        self.medications = medications
        self.habits = habits
        self.healthSnapshot = healthSnapshot
        self.homeOverview = homeOverview
        self.anniversaries = anniversaries
        self.medicationSummary = medicationSummary
        self.habitSummary = habitSummary
        self.ackedCommandIDs = ackedCommandIDs
        self.generatedAt = generatedAt
    }

    enum CodingKeys: String, CodingKey {
        case topTodos, parcels, todayExpense, todayPractice
        case todayWaterML, waterGoalML, todayMood
        case departureSnapshot, travelSnapshot, medications, habits, healthSnapshot
        case homeOverview, anniversaries
        case medicationSummary, habitSummary
        case ackedCommandIDs, generatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.topTodos = try container.decode([WidgetTodoEntry].self, forKey: .topTodos)
        self.parcels = try container.decode([WidgetTodoEntry].self, forKey: .parcels)
        self.todayExpense = try container.decode(Double.self, forKey: .todayExpense)
        self.todayPractice = try container.decodeIfPresent(WidgetPracticeEntry.self, forKey: .todayPractice)
        self.todayWaterML = try container.decodeIfPresent(Double.self, forKey: .todayWaterML) ?? 0
        self.waterGoalML = try container.decodeIfPresent(Double.self, forKey: .waterGoalML) ?? 1700
        self.todayMood = try container.decodeIfPresent(MoodCheckInSummary.self, forKey: .todayMood)
        self.departureSnapshot = try container.decodeIfPresent(WatchDepartureSnapshot.self, forKey: .departureSnapshot)
        self.travelSnapshot = try container.decodeIfPresent(WatchTravelSnapshot.self, forKey: .travelSnapshot)
        self.medications = try container.decodeIfPresent([WatchMedicationEntry].self, forKey: .medications) ?? []
        self.habits = try container.decodeIfPresent([WatchHabitEntry].self, forKey: .habits) ?? []
        self.healthSnapshot = try container.decodeIfPresent(WatchHealthSnapshot.self, forKey: .healthSnapshot)
        // 新增字段一律 decodeIfPresent + 默认值：
        // 老版本写下的快照没有这些 key，若用 decode 会整体抛错，
        // 而 `WidgetSnapshotStore.load()` 用 `try?` 吞错 → 小组件静默变空白且无日志。
        self.homeOverview = try container.decodeIfPresent(WidgetHomeOverview.self, forKey: .homeOverview)
        self.anniversaries = try container.decodeIfPresent([WidgetAnniversaryEntry].self, forKey: .anniversaries) ?? []
        self.medicationSummary = try container.decodeIfPresent(WidgetMedicationSummary.self, forKey: .medicationSummary)
        self.habitSummary = try container.decodeIfPresent(WidgetHabitSummary.self, forKey: .habitSummary)
        self.ackedCommandIDs = try container.decodeIfPresent([UUID].self, forKey: .ackedCommandIDs) ?? []
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    }
}

/// 扩展或手表产生的待同步指令，主应用回前台或在线收到后按序执行并入快照
public enum WidgetCommand: Codable, Hashable, Sendable {
    case completeTodo(UUID)
    /// minutes: 10 / 60 / 1440(明早9点单独编码为 snoozeTomorrow)
    case snoozeTodo(UUID, Int)
    case snoozeTomorrow(UUID)
    case toggleDeparture(UUID, Bool)
    /// 一键勾选全部出门清点物品
    case completeAllDeparture([UUID])
    case quickAddExpense(String)
    case quickAddTodo(String)
    /// 手表端心情微打卡（情绪 1-5、精力 1-5、压力 1-5）
    case logMood(mood: Int, energy: Int, stress: Int)
    /// 手表端快速补水打卡（饮品 rawValue、毫升数）
    case addWater(beverageRaw: String, volumeML: Double)
    /// 手表端服药一键打卡
    case markMedicationTaken(planID: UUID, todoID: UUID?)
    /// 手表端周期习惯一键打卡
    case completeHabit(habitID: UUID)
}

/// 带唯一 ID 的跨设备同步指令信封（用于 WatchConnectivity 幂等对账与未确认指令重放）
public struct WatchCommandEnvelope: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var command: WidgetCommand
    public var createdAt: Date

    public init(id: UUID = UUID(), command: WidgetCommand, createdAt: Date = .now) {
        self.id = id
        self.command = command
        self.createdAt = createdAt
    }
}

// MARK: - 手表跨设备对账与乐观状态重放（纯逻辑，双端共用）

public enum WatchSyncReconciler {
    /// WatchConnectivity payload 键名
    public static let snapshotContextKey = "watch_snapshot_v1"
    public static let commandEnvelopeKey = "watch_command_envelope_v1"
    public static let commandReplyKey = "watch_command_reply_v1"

    /// 将单条指令乐观叠加到快照上（用于手表本地即时反馈，以及收到新快照后对未确认指令重放）
    public static func applyOptimistically(_ command: WidgetCommand, to snapshot: inout WidgetSnapshot, now: Date = .now) {
        switch command {
        case .completeTodo(let id):
            snapshot.topTodos.removeAll { $0.id == id }
            snapshot.parcels.removeAll { $0.id == id }
            if snapshot.travelSnapshot?.id == id {
                snapshot.travelSnapshot = nil
            }
            for idx in snapshot.medications.indices where snapshot.medications[idx].activeTodoID == id {
                snapshot.medications[idx].isTakenToday = true
                snapshot.medications[idx].activeTodoID = nil
                // 同步逐条进度与汇总，避免桌面仍显示「待服 N 次」
                snapshot.medications[idx].takenCount = min(
                    snapshot.medications[idx].scheduledCount,
                    snapshot.medications[idx].takenCount + 1
                )
                if var summary = snapshot.medicationSummary {
                    summary.takenDoseLowerBound = min(
                        summary.scheduledDoseCount,
                        summary.takenDoseLowerBound + 1
                    )
                    summary.pendingDoseCount = max(0, summary.pendingDoseCount - 1)
                    if summary.pendingPlanCount > 0 {
                        summary.pendingPlanCount -= 1
                    }
                    summary.isAllSatisfied = summary.pendingPlanCount == 0
                    snapshot.medicationSummary = summary
                }
            }
        case .snoozeTodo(let id, let minutes):
            let nextDue = now.addingTimeInterval(TimeInterval(max(1, minutes)) * 60)
            if let idx = snapshot.topTodos.firstIndex(where: { $0.id == id }) {
                snapshot.topTodos[idx].dueAt = nextDue
            }
        case .snoozeTomorrow(let id):
            snapshot.topTodos.removeAll { $0.id == id }
        case .toggleDeparture(let id, let isChecked):
            if var dep = snapshot.departureSnapshot,
               let idx = dep.items.firstIndex(where: { $0.id == id }) {
                dep.items[idx].isChecked = isChecked
                snapshot.departureSnapshot = dep
            }
        case .completeAllDeparture(let ids):
            if var dep = snapshot.departureSnapshot {
                let idSet = Set(ids)
                for idx in dep.items.indices where idSet.isEmpty || idSet.contains(dep.items[idx].id) {
                    dep.items[idx].isChecked = true
                }
                snapshot.departureSnapshot = dep
            }
        case .quickAddExpense:
            break
        case .quickAddTodo(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { break }
            let entry = WidgetTodoEntry(id: UUID(), title: trimmed, typeRaw: "task")
            snapshot.topTodos.insert(entry, at: 0)
            if snapshot.topTodos.count > 6 {
                snapshot.topTodos = Array(snapshot.topTodos.prefix(6))
            }
        case .logMood(let mood, let energy, let stress):
            snapshot.todayMood = MoodCheckInSummary(mood: mood, energy: energy, stress: stress)
        case .addWater(_, let volumeML):
            snapshot.todayWaterML += volumeML
        case .markMedicationTaken(let planID, let todoID):
            if let idx = snapshot.medications.firstIndex(where: { $0.id == planID }) {
                snapshot.medications[idx].isTakenToday = true
                snapshot.medications[idx].activeTodoID = nil
                // 同步逐条进度（保守下界 +1，不超过应服时点数）
                snapshot.medications[idx].takenCount = min(
                    snapshot.medications[idx].scheduledCount,
                    snapshot.medications[idx].takenCount + 1
                )
            }
            // 同步汇总：不改的话手表显示「已服」而桌面仍显示「待服 N 次」。
            if var summary = snapshot.medicationSummary {
                summary.takenDoseLowerBound = min(
                    summary.scheduledDoseCount,
                    summary.takenDoseLowerBound + 1
                )
                // 待服数逐条减，不用差值推（差值会虚报已服完的计划）
                summary.pendingDoseCount = max(0, summary.pendingDoseCount - 1)
                if summary.pendingPlanCount > 0 {
                    summary.pendingPlanCount -= 1
                }
                summary.isAllSatisfied = summary.pendingPlanCount == 0
                snapshot.medicationSummary = summary
            }
            if let todoID {
                snapshot.topTodos.removeAll { $0.id == todoID }
            }
        case .completeHabit(let habitID):
            if let idx = snapshot.habits.firstIndex(where: { $0.id == habitID }) {
                snapshot.habits[idx].isDueToday = false
            }
            // 同步汇总的待打卡数
            if var summary = snapshot.habitSummary {
                if summary.dueCount > 0 {
                    summary.dueCount -= 1
                }
                snapshot.habitSummary = summary
            }
        }
    }

    /// 手表收到来自 iPhone 的远端快照时，与本地基准快照及未确认指令队列对账：
    /// 1. 若远端快照比本地基准快照更旧，忽略远端快照；
    /// 2. 剔除已被远端 `ackedCommandIDs` 确认落库的待确认指令；
    /// 3. 将剩余未确认指令按序重新叠加到新快照上，生成最新展示快照。
    public static func reconcile(
        remoteSnapshot: WidgetSnapshot,
        localBaseSnapshot: WidgetSnapshot,
        pendingEnvelopes: [WatchCommandEnvelope],
        now: Date = .now
    ) -> (baseSnapshot: WidgetSnapshot, displaySnapshot: WidgetSnapshot, remainingPending: [WatchCommandEnvelope]) {
        let ackedSet = Set(remoteSnapshot.ackedCommandIDs)
        let remaining = pendingEnvelopes.filter { !ackedSet.contains($0.id) }

        let newestBase: WidgetSnapshot
        if remoteSnapshot.generatedAt >= localBaseSnapshot.generatedAt {
            newestBase = remoteSnapshot
        } else {
            newestBase = localBaseSnapshot
        }

        var display = newestBase
        for env in remaining {
            applyOptimistically(env.command, to: &display, now: now)
        }
        return (newestBase, display, remaining)
    }

    /// 过滤出超过 24 小时仍未被主应用确认的滞留指令数
    public static func stalePendingCount(
        in pendingEnvelopes: [WatchCommandEnvelope],
        now: Date = .now,
        staleThreshold: TimeInterval = 24 * 3600
    ) -> Int {
        pendingEnvelopes.filter { now.timeIntervalSince($0.createdAt) >= staleThreshold }.count
    }
}
