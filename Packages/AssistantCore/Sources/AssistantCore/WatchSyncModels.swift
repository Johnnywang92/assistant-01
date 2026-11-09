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

/// 手表端出门清点快照
public struct WatchDepartureSnapshot: Codable, Hashable, Sendable {
    public var sceneName: String
    public var items: [WatchDepartureItem]

    public init(sceneName: String, items: [WatchDepartureItem]) {
        self.sceneName = sceneName
        self.items = items
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

    public init(
        id: UUID,
        medName: String,
        dosage: String,
        mealRelationText: String,
        timePointsText: String,
        isTakenToday: Bool,
        activeTodoID: UUID? = nil
    ) {
        self.id = id
        self.medName = medName
        self.dosage = dosage
        self.mealRelationText = mealRelationText
        self.timePointsText = timePointsText
        self.isTakenToday = isTakenToday
        self.activeTodoID = activeTodoID
    }
}

/// 手表端周期习惯（运动/家务）打卡条目
public struct WatchHabitEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var recurrenceText: String
    public var isDueToday: Bool

    public init(id: UUID, title: String, recurrenceText: String, isDueToday: Bool) {
        self.id = id
        self.title = title
        self.recurrenceText = recurrenceText
        self.isDueToday = isDueToday
    }
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
    /// 主应用已落库确认的指令 ID 列表（用于手表端幂等去重与乐观状态对账）
    public var ackedCommandIDs: [UUID]
    public var generatedAt: Date

    public static let empty = WidgetSnapshot(
        topTodos: [], parcels: [], todayExpense: 0, todayPractice: nil,
        todayWaterML: 0, waterGoalML: 1700, todayMood: nil,
        departureSnapshot: nil, travelSnapshot: nil,
        medications: [], habits: [], healthSnapshot: nil,
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
        self.ackedCommandIDs = ackedCommandIDs
        self.generatedAt = generatedAt
    }

    enum CodingKeys: String, CodingKey {
        case topTodos, parcels, todayExpense, todayPractice
        case todayWaterML, waterGoalML, todayMood
        case departureSnapshot, travelSnapshot, medications, habits, healthSnapshot
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
            }
            if let todoID {
                snapshot.topTodos.removeAll { $0.id == todoID }
            }
        case .completeHabit(let habitID):
            if let idx = snapshot.habits.firstIndex(where: { $0.id == habitID }) {
                snapshot.habits[idx].isDueToday = false
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
