import AssistantCore
import Foundation
import SwiftData

/// 身体档案上下文的**唯一装配点**。
///
/// ## 为什么必须有这一层
///
/// 活力值 / 身心愉悦指数在健康页、手表快照、日报、睡前提醒、生活问答等
/// **9 处**各自现算。若每处自行去 SwiftData 取档案，必然出现三种漂移：
/// ① 有的读、有的不读；② 刷新时机不同导致同一时刻分数不同；
/// ③ 视图 body 里做 fetch（违反「视图 init/body 零重活」）。
///
/// 这里做一次带短 TTL 的缓存，把 @Model 映射成 Core 的纯值
/// `BodyProfileContext`；所有调用点拿同一份事实，Core 侧算同一套修正。
///
/// ## 历史趋势不编造
///
/// `context(asOf:)` 只保留该日**当时已经存在**的体征记录，并把 `now`
/// 设为该日终点，因此回溯 60 天前的活力分时，不会把今天量的血压套到
/// 两个月前。档案缺失的历史日会自然得到中性修正，而不是伪造一个分数。
@MainActor
final class BodyProfileContextProvider {
    static let shared = BodyProfileContextProvider()

    private struct Facts {
        let heightCm: Double?
        let birthDate: Date?
        let biologicalSexRaw: String?
        /// 按 measuredAt 升序
        let samples: [BodyMetricSample]
    }

    private var cachedFacts: Facts?
    /// 缓存时刻用墙上时钟，不能用 `build(at:)` 的评估时刻——
    /// 历史回溯会把 `now` 设成过去，用它会让缓存反复失效。
    private var fetchedAt: Date = .distantPast
    /// 短 TTL：既避免在 body 里重复 fetch，也能在后台写入后较快自愈。
    private let cacheTTL: TimeInterval = 90
    /// 手动录入是小表；按时间倒序取上限即可，无需按日期窗口切分查询。
    private let fetchLimit = 500
    /// 由 HealthKitService 在自身初始化时注册的「重算愉悦指数」钩子。
    /// 用钩子而不是直接取 `HealthKitService.shared`：备份恢复等流程也会
    /// 调 `invalidate()`，不该为了清缓存就顺带初始化 HKHealthStore 并
    /// 改写授权状态。钩子内弱引用 self，不产生单例间的循环持有。
    private var reevaluationHook: (() -> Void)?

    private init() {}

    func registerReevaluationHook(_ hook: @escaping () -> Void) {
        reevaluationHook = hook
    }

    /// 档案或体征记录写入后调用，立即失效缓存。
    func invalidate() {
        cachedFacts = nil
        fetchedAt = .distantPast
        // 愉悦指数是 HealthKitService 缓存的发布值，光清自己的缓存不够：
        // 必须让已展示的那张卡立刻用新档案重算，否则用户改完仍看到旧分数。
        reevaluationHook?()
    }

    /// 当日评估用的上下文。
    func context(
        now: Date = .now,
        calendar: Calendar = .current
    ) -> BodyProfileContext? {
        build(at: now, calendar: calendar)
    }

    /// 历史某日收盘时的上下文（供日报 / 健康趋势逐日重算）。
    /// 只用当日及之前的记录；`now` 取该日终点，让新鲜度判定也按当时口径。
    func context(
        asOf day: Date,
        calendar: Calendar = .current
    ) -> BodyProfileContext? {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return build(at: end, calendar: calendar)
    }

    // MARK: - 装配

    private func build(at now: Date, calendar: Calendar) -> BodyProfileContext? {
        let facts = load()
        guard let facts else { return nil }

        // 只保留「当时已经存在」的记录。未来时刻的记录（改过系统时钟）
        // 也不能参与，否则会把整份档案判成陈旧。
        let visible = facts.samples.filter { $0.measuredAt <= now }
        let ageYears = facts.birthDate.flatMap {
            BodyMetricCalculator.age(birthDate: $0, now: now, calendar: calendar)
        }

        return BodyProfileContext(
            heightCm: facts.heightCm,
            ageYears: ageYears,
            biologicalSex: Self.biologicalSex(from: facts.biologicalSexRaw),
            samples: visible,
            now: now
        )
    }

    private func load() -> Facts? {
        let wallNow = Date.now
        if let cachedFacts,
           wallNow.timeIntervalSince(fetchedAt) >= 0,
           wallNow.timeIntervalSince(fetchedAt) < cacheTTL {
            return cachedFacts
        }

        let context = Persistence.shared.mainContext

        var profileDescriptor = FetchDescriptor<BodyMetricProfile>(
            sortBy: [SortDescriptor(\BodyMetricProfile.createdAt, order: .forward)]
        )
        profileDescriptor.fetchLimit = 1
        // 只读，不调用 ensureProfile（那是写操作，不该发生在视图求值时）。
        let profile = (try? context.fetch(profileDescriptor))?.first

        var vitalDescriptor = FetchDescriptor<BodyVitalRecord>(
            sortBy: [SortDescriptor(\BodyVitalRecord.measuredAt, order: .reverse)]
        )
        vitalDescriptor.fetchLimit = fetchLimit
        let records = (try? context.fetch(vitalDescriptor)) ?? []
        let samples = records.reversed().map {
            BodyMetricSample(measuredAt: $0.measuredAt, values: $0.metricValues)
        }

        guard profile != nil || !samples.isEmpty else {
            cachedFacts = nil
            fetchedAt = wallNow
            return nil
        }

        let facts = Facts(
            heightCm: profile?.heightCm,
            birthDate: profile?.birthDate,
            biologicalSexRaw: profile?.biologicalSexRaw,
            samples: samples
        )
        cachedFacts = facts
        fetchedAt = wallNow
        return facts
    }

    /// App 侧生理性别存的是中文 rawValue（「男」/「女」/「其他」/「未填写」）。
    /// 映射只在这一处；未知值一律 `unspecified`，不猜测也不默认成男性。
    private static func biologicalSex(from raw: String?) -> BodyBiologicalSex {
        switch raw {
        case "男": return .male
        case "女": return .female
        default: return .unspecified
        }
    }
}
