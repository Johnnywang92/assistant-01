import AssistantCore
import Foundation
import SwiftData

/// App 侧的心理数据适配层：把 SwiftData 模型转成 Core 的纯结构。
///
/// ## 为什么要单独一层
///
/// Core 只认纯值（`MoodCheckInEntry` / `PsychExportScaleRecord`），
/// App 侧认 SwiftData 模型。两者的转换规则若散落在各个 View 里，
/// 就会出现「主页算一遍、结果页算一遍、导出再算一遍」的三份实现——
/// 这是本项目记忆里反复出现的漂移来源（「同一份规则只有一处」）。
///
/// 所以这里集中一处转换，View 只调用不实现。
@MainActor
enum PsychDataAdapter {

    // MARK: - 微记录

    /// 把 SwiftData 微记录转成 Core 条目。
    static func moodEntries(from records: [MoodCheckInRecord]) -> [MoodCheckInEntry] {
        records
            .map {
                MoodCheckInEntry(
                    day: $0.day,
                    moodScore: $0.moodScore,
                    energyScore: $0.energyScore,
                    stressScore: $0.stressScore
                )
            }
            .sorted { $0.day > $1.day }
    }

    // MARK: - 量表

    /// 把 SwiftData 量表记录转成 Core 计分结果。
    static func scaleScores(from records: [PsychScaleRecord]) -> [PsychScaleScore] {
        records
            .map { record in
                let definition = PsychScaleCatalog.definition(for: record.scaleID)
                return PsychScaleScorer.score(
                    answers: record.toAnswers(),
                    definition: definition,
                    completedAt: record.completedAt
                )
            }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    // MARK: - 生理摘要

    /// 近 7 日平均睡眠时长（小时）。
    ///
    /// 读不到时返回 **nil**（不当 0）——「没有睡眠数据」与「睡了 0 小时」
    /// 语义完全不同，把前者当 0 会凭空造出一个「严重缺觉」的结论。
    ///
    /// 三处（主页 / 结果页 / 导出面板）曾各写一份，三份必然漂移，
    /// 所以收敛到这里一处。
    static func recentAverageSleepHours(context: ModelContext, days: Int = 7) -> Double? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        var descriptor = FetchDescriptor<HealthDaySnapshotRecord>(
            predicate: #Predicate { $0.day >= cutoff }
        )
        descriptor.fetchLimit = days
        let records = (try? context.fetch(descriptor)) ?? []
        let values = records.compactMap { $0.sleepHours }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    // MARK: - 导出载荷

    /// 构造导出载荷。
    ///
    /// 生理数据只进**摘要**（睡眠均值、压力指数），
    /// 逐日原始生理数据不导出——对解读无必要，只是多暴露一份。
    static func exportPayload(
        scaleRecords: [PsychScaleRecord],
        moodRecords: [MoodCheckInRecord],
        recentAverageSleepHours: Double?,
        physiologicalStressScore: Int?
    ) -> PsychExportPayload {
        let exportScales = scaleRecords.map { record in
            let definition = PsychScaleCatalog.definition(for: record.scaleID)
            let answers = record.toAnswers()
            return PsychExportScaleRecord(
                scaleID: record.scaleID,
                completedAt: record.completedAt,
                totalScore: record.score().totalScore,
                band: record.score().band,
                answers: answers,
                safetySignal: PsychSafetyRouter.detectSignal(answers: answers, definition: definition)
            )
        }

        return PsychExportPayload(
            scaleRecords: exportScales.sorted { $0.completedAt > $1.completedAt },
            moodEntries: moodEntries(from: moodRecords),
            recentAverageSleepHours: recentAverageSleepHours,
            physiologicalStressScore: physiologicalStressScore
        )
    }
}
