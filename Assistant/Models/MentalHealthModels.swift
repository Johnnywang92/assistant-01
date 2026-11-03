import AssistantCore
import Foundation
import SwiftData

/// 心理健康量表作答记录（落库模型）。
///
/// ## 为什么必须存题目级响应，不能只存总分
///
/// 三条硬需求都依赖题目级数据：
/// 1. **安全题的独立告警**：PHQ-9 第 9 题（自伤意念）必须能被单独取出。
///    只存总分的话，"第 9 题非零但总分低"这种情况在库里根本不可见。
/// 2. **算法演进后的重算**：阈值、分档规则可能调整；有题目级数据就能重算历史，
///    只存总分则历史全部作废。
/// 3. **具体解读**：结果页要能说出"你在这两项上得分最高"，需要题目级分数。
///
/// ## 落库纪律
///
/// - **条目级数组按题号顺序存储**，下标即题号减一；未作答存 nil，**不用 0 顶替**
///   （0 是"完全不会"这个真实答案，与"没答"语义完全不同）。
/// - **分数不落库**：总分与分档由 Core 的 `PsychScaleScorer` 现算，
///   保证公式跨天一致、阈值调整后历史自动跟随新规则。
/// - **心理数据不上云、不进分享卡、不进 Widget**：与密码库/证件同级敏感度。
@Model
public final class PsychScaleRecord {
    public var id: UUID
    /// 作答时间
    public var completedAt: Date
    /// 量表标识 rawValue（对应 `PsychScaleID`）
    public var scaleIDRaw: String
    /// 题目级得分数组，下标 = 题号 - 1，nil 表示未作答
    public var itemScores: [Int?]
    /// 作答完成度：已作答题数
    public var answeredCount: Int
    /// 是否已读过危机提示（用于避免重复弹窗打扰）
    public var hasAcknowledgedCrisis: Bool
    /// 创建时间
    public var createdAt: Date

    public var scaleID: PsychScaleID {
        get { PsychScaleID(rawValue: scaleIDRaw) ?? .phq9 }
        set { scaleIDRaw = newValue.rawValue }
    }

    public init(
        scaleID: PsychScaleID,
        completedAt: Date = .now,
        itemScores: [Int?],
        hasAcknowledgedCrisis: Bool = false
    ) {
        self.id = UUID()
        self.scaleIDRaw = scaleID.rawValue
        self.completedAt = completedAt
        self.itemScores = itemScores
        self.answeredCount = itemScores.compactMap { $0 }.count
        self.hasAcknowledgedCrisis = hasAcknowledgedCrisis
        self.createdAt = .now
    }

    // MARK: - 互转

    /// 还原为 Core 的题目级作答字典。
    ///
    /// 转换规则下沉在 Core 的 `PsychItemScoreArray`——它是喂给危机路由器的
    /// **安全关键路径**，必须有单测覆盖，不能只活在 app target 里。
    public func toAnswers() -> [Int: PsychItemAnswer] {
        PsychItemScoreArray.answers(from: itemScores)
    }

    /// 用当前量表定义计分。
    ///
    /// **必须带上 `completedAt`**——量表回忆窗是「完成时刻往前 14 天」，
    /// 缺了完成时间就判不了「微记录比问卷新还是旧」，
    /// 三通道合并解读会把「最近好转」误读成「与问卷矛盾」。
    public func score() -> PsychScaleScore {
        let definition = PsychScaleCatalog.definition(for: scaleID)
        return PsychScaleScorer.score(
            answers: toAnswers(),
            definition: definition,
            completedAt: completedAt
        )
    }

    /// 本次作答是否触发危机信号（**独立于总分与完整性**）。
    public func safetySignal() -> PsychSafetySignal {
        PsychSafetyRouter.detectSignal(
            answers: toAnswers(),
            definition: PsychScaleCatalog.definition(for: scaleID)
        )
    }
}

/// 每日情绪微记录（落库模型）。
///
/// 一次 1 题、10 秒内答完，用于让"追踪"这件事真的能坚持下来。
/// 完整量表每周一次即可；每日微记录提供的是**频率与趋势**，
/// 与生理通道（HRV / 睡眠）做交叉验证。
///
/// 落库纪律：与 `HealthDaySnapshotRecord` 一致——
/// **日唯一**，同一天重复记录走 upsert 而不是追加多条。
@Model
public final class MoodCheckInRecord {
    public var id: UUID
    /// 归属日（当天 00:00）
    public var day: Date
    /// 情绪分值 1...5（1 = 很低落，5 = 很轻快）
    public var moodScore: Int
    /// 精力分值 1...5（1 = 很疲惫，5 = 精力充沛）
    public var energyScore: Int
    /// 压力分值 1...5（1 = 没有压力，5 = 压力极大）
    public var stressScore: Int
    /// 备注（可选，一句话）
    public var note: String?
    /// 创建时间
    public var createdAt: Date
    /// 最近一次更新时间
    public var updatedAt: Date

    public init(
        day: Date,
        moodScore: Int,
        energyScore: Int,
        stressScore: Int,
        note: String? = nil
    ) {
        self.id = UUID()
        self.day = Calendar.current.startOfDay(for: day)
        self.moodScore = moodScore
        self.energyScore = energyScore
        self.stressScore = stressScore
        self.note = note
        self.createdAt = .now
        self.updatedAt = .now
    }

    /// 更新分数（保留同一条记录，不追加新行）。
    public func update(mood: Int, energy: Int, stress: Int, note: String?) {
        self.moodScore = mood
        self.energyScore = energy
        self.stressScore = stress
        self.note = note
        self.updatedAt = .now
    }
}

/// 心理状态落库服务。
public enum PsychRecordStore {

    /// 保存一次量表作答。
    ///
    /// - Returns: 是否保存成功。失败**不抛崩溃**——落库失败不该打断测评流程，
    ///   但也绝不能谎报成功。
    @discardableResult
    public static func save(
        scaleID: PsychScaleID,
        answers: [Int: PsychItemAnswer],
        completedAt: Date = .now,
        in context: ModelContext
    ) -> Bool {
        let definition = PsychScaleCatalog.definition(for: scaleID)

        // 题目级数组按题号顺序；未作答存 nil。
        // 转换规则在 Core（`PsychItemScoreArray`），与还原路径同源——
        // 两边用不同实现是「存进去读出来不一样」的经典来源。
        let itemScores = PsychItemScoreArray.itemScores(from: answers, itemCount: definition.itemCount)

        let record = PsychScaleRecord(
            scaleID: scaleID,
            completedAt: completedAt,
            itemScores: itemScores
        )
        context.insert(record)
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }

    /// 保存或更新当天的情绪微记录（日唯一）。
    @discardableResult
    public static func saveMoodCheckIn(
        day: Date,
        mood: Int,
        energy: Int,
        stress: Int,
        note: String?,
        in context: ModelContext
    ) -> Bool {
        let startOfDay = Calendar.current.startOfDay(for: day)
        var descriptor = FetchDescriptor<MoodCheckInRecord>(
            predicate: #Predicate { $0.day == startOfDay }
        )
        descriptor.fetchLimit = 1
        let existing = (try? context.fetch(descriptor))?.first

        if let existing {
            existing.update(mood: mood, energy: energy, stress: stress, note: note)
        } else {
            let record = MoodCheckInRecord(
                day: startOfDay,
                moodScore: mood,
                energyScore: energy,
                stressScore: stress,
                note: note
            )
            context.insert(record)
        }
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }

    /// 取最近一次量表作答。
    public static func latestScaleRecord(
        scaleID: PsychScaleID? = nil,
        in context: ModelContext
    ) -> PsychScaleRecord? {
        var descriptor = FetchDescriptor<PsychScaleRecord>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        if let scaleID {
            let raw = scaleID.rawValue
            descriptor.predicate = #Predicate { $0.scaleIDRaw == raw }
        }
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// 取最近若干次量表作答（按时间倒序）。
    public static func recentScaleRecords(
        limit: Int = 30,
        in context: ModelContext
    ) -> [PsychScaleRecord] {
        var descriptor = FetchDescriptor<PsychScaleRecord>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 近 N 天的情绪微记录（按时间倒序）。
    public static func recentMoodCheckIns(
        days: Int = 30,
        in context: ModelContext
    ) -> [MoodCheckInRecord] {
        guard let startDate = Calendar.current.date(byAdding: .day, value: -days, to: .now) else {
            return []
        }
        var descriptor = FetchDescriptor<MoodCheckInRecord>(
            predicate: #Predicate { $0.day >= startDate },
            sortBy: [SortDescriptor(\.day, order: .reverse)]
        )
        descriptor.fetchLimit = days
        return (try? context.fetch(descriptor)) ?? []
    }
}
