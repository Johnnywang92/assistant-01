import AssistantCore
import Foundation
import SwiftData

/// 今日服药「完成证据」的统一采集口。
///
/// ## 证据是什么
///
/// 证据 = 今日**已完成**的服药待办（由 `MedicationTodoMaterializer` 物化，
/// 标题 `服药：药名（HH:mm）`）。每完成一顿待办就留下一条证据，
/// 证据精确到时点，因此「今天已服几顿」「还差几顿」「是否漏服」全部可算准。
///
/// ## 为什么不能只看时间戳
///
/// `MedicationPlan.lastTakenAt` 只有一个时间戳，只能表达「今天至少服过一次」。
/// 一天 3 次的药，用户吃完 08:00 与 13:00 两顿后，光看时间戳仍然只能得出
/// 「已服 1 次」→ 组件显示「待服 2 次」→ 用户照着提示再吃 → **过量服药**。
///
/// ## 跨天同名标题
///
/// 服药待办跨天沿用同一标题（「服药：维生素D（08:00）」不带日期），
/// 所以证据必须靠 `doseConfirmedAt` 落在今天来区分，**不能只看标题**。
enum MedicationDoseEvidence {

    /// 一条服药完成证据。
    struct Entry: Equatable {
        /// 药名（从物化标题反解析，精确匹配用）。
        let medName: String
        /// 时点（"08:00"），与计划里的 `dailyTimePoints` 同格式。
        let timePoint: String
        /// 服药打卡确认时刻。
        let confirmedAt: Date
    }

    /// 今日已完成的服药证据。
    ///
    /// 谓词里直接收窄到今天：先拉全部历史已完成待办再在内存里过滤，
    /// 会把用户几千条历史待办全量物化到主线程（首页快照是主线程构建的）。
    ///
    /// 证据源是 `doseConfirmedAt`（明确的服药打卡确认），**不是** `completedAt`：
    /// 「完成」不等于「服用」——逾期清理里的「算了不做」也会标记完成，
    /// 拿它当证据会把放弃的那一顿算成已服 → 漏服被静默掩盖。
    static func todayEntries(
        context: ModelContext,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Entry] {
        let doneRaw = TodoStatus.done.rawValue
        let medTypeRaw = TodoType.medication.rawValue
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate {
                $0.statusRaw == doneRaw
                    && $0.typeRaw == medTypeRaw
                    && $0.doseConfirmedAt != nil
                    && $0.doseConfirmedAt! >= startOfToday
                    && $0.doseConfirmedAt! < endOfToday
            }
        )
        let completed = (try? context.fetch(descriptor)) ?? []
        return completed.compactMap { item in
            // 只认物化生成的标题：用户手建的「吃药」待办不算——那是另一回事。
            guard let medName = MedicationTodoMaterializer.medName(fromMaterializedTitle: item.title),
                  let timePoint = MedicationTodoMaterializer.timePoint(fromMaterializedTitle: item.title),
                  let confirmedAt = item.doseConfirmedAt else { return nil }
            return Entry(medName: medName, timePoint: timePoint, confirmedAt: confirmedAt)
        }
    }

    /// 某个药今日已服的时点集合（Core `doseProgress` 的证据输入）。
    static func completedSlotTimes(medName: String, entries: [Entry]) -> Set<String> {
        Set(entries.filter { $0.medName == medName }.map(\.timePoint))
    }

    /// 某个药今日最后一条证据的确认时刻（撤销某一顿时用它回填计划状态）。
    static func latestConfirmedAt(medName: String, entries: [Entry]) -> Date? {
        entries.filter { $0.medName == medName }.map(\.confirmedAt).max()
    }
}
