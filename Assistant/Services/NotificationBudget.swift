import Foundation
import os
@preconcurrency import UserNotifications

/// 单 App 待处理通知的统一预算入口（审计 SVC-06 / SVC-08）。
///
/// 背景：iOS 对同一个 App 只保留约 64 条待处理通知，超出部分被系统**静默丢弃**；
/// 此前服药（每次全删全加）、待办（15 项 × 最多 4 条 = 60 条）、睡眠、到站、报告、
/// 天气等模块各自 `add`，没有任何一处核算总额，用户只会表现为「某天没收到提醒」。
///
/// 本入口只做**调度策略**决策，不碰通知文案 / 触发时间 / 业务语义：
/// - 每个 identifier 前缀都映射到真实业务档位，按优先级保留
///   服药 > 睡眠 > 到站 > 心理 > 报告 > 待办主提醒 > 待办逾期补提醒 > 环境类；
/// - 被拒绝 / 被裁剪的数量与来源写入 `lastSummary` 与日志，真机可观测；
/// - 一轮前台巡检里多个模块依次排期，彼此的 `admit` 决策会互相推翻
///   （A 裁掉 B 的存量 → B 差量对账发现缺失 → 立刻加回）。因此：
///     · 被裁剪的 identifier 进入带 TTL 的抑制名单，`admit` 在 TTL 内直接拒绝它；
///     · 巡检末尾调用一次 `reconcile()` 作为**唯一全局裁决点**，读真实 pending 兜底；
/// - 只在「存量已超上限」或「存量优先级严格更低」时裁剪，不做同优先级互相抢占，
///   避免每次回前台都全删全加造成 churn。
enum NotificationBudget {
    /// iOS 的单 App 待处理通知硬上限（系统行为，非本 App 常量）。
    static let systemPendingLimit = 64
    /// 默认软上限：给即时投递与系统预留 8 条余量。
    /// 需要按场景调整时传 `admit(..., limit:)` 覆盖；这里是唯一默认值。
    static let defaultPendingLimit = 56

    // MARK: - 优先级

    /// 通知优先级：数值越大越「保命」，预算不足时从低到高裁剪。
    ///
    /// 2026-11-06 重设计：旧版把「未接入预算的模块」一律记为 `.external = 5`
    /// （最高、**永不**裁剪），结果守规矩走 `admit` 的待办 / 报告被反复裁掉，
    /// 而直接 `center.add` 的模块反而占着名额不动 —— 预算裁决形同虚设。
    /// 现在所有前缀都有真实档位，兜底为最低的 `.ambient`，**没有模块享有豁免**。
    enum Priority: Int, Comparable, Sendable {
        /// 低频环境类 / 未识别模块（天气、纪念日、签名到期、灵动岛伴随、地理围栏等）。
        /// 多数是 1~2 条或 `trigger: nil` 的即时投递，超限时最先让位。
        case ambient = -4
        /// 待办逾期补提醒（主提醒已经响过，补提醒最先可省）。
        case todoOverdue = -3
        /// 待办主提醒。
        case todo = -2
        /// 定期报告通知。
        case report = -1
        /// 心理状态复评 / 趋势提醒。
        case psych = 0
        /// 到站 / 落地清点提醒。
        case tripArrival = 1
        /// 睡前提醒。
        case sleep = 2
        /// 服药提醒（最高：健康关键）。
        case medication = 3

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .ambient: return "ambient"
            case .todoOverdue: return "todoOverdue"
            case .todo: return "todo"
            case .report: return "report"
            case .psych: return "psych"
            case .tripArrival: return "tripArrival"
            case .sleep: return "sleep"
            case .medication: return "medication"
            }
        }
    }

    /// 一条「本轮想排期」的通知。
    struct Item {
        let request: UNNotificationRequest
        let priority: Priority

        init(request: UNNotificationRequest, priority: Priority) {
            self.request = request
            self.priority = priority
        }
    }

    /// 一次预算决策的结果。
    struct Admission {
        /// 允许 `add` 的请求（已按优先级 / 触发时间排序）。
        let accepted: [Item]
        /// 因名额不足被拒绝的请求；调用方可记录，下一轮对账会自然重试。
        let rejected: [Item]
        /// 需要从系统移除的既有通知 identifier（为高优先级腾名额 / 存量已超上限）。
        let evictedIdentifiers: [String]
        /// 决策前系统待处理通知数。
        let pendingBefore: Int
        /// 本次生效的软上限。
        let limit: Int
        /// 决策后的预估待处理通知数。
        let finalPendingCount: Int
        let source: String
    }

    /// 供日志 / 设置页 / 真机排查读取的最近一次决策快照（线程安全）。
    struct Summary: Sendable {
        let source: String
        let pendingBefore: Int
        let limit: Int
        let requested: Int
        let accepted: Int
        let rejected: Int
        let evicted: Int
        let rejectedByPriority: [String: Int]
        let evictedByPriority: [String: Int]
        let finalPendingCount: Int
        let timestamp: Date
    }

    private static let summaryLock = OSAllocatedUnfairLock<Summary?>(initialState: nil)

    /// 最近一次预算决策快照；从未发生裁剪/拒绝时也可能为 nil。
    static var lastSummary: Summary? {
        summaryLock.withLock { $0 }
    }

    /// 最近一次全局裁决快照。独立于 `lastSummary`：一轮巡检里多个模块依次
    /// `admit`，若裁决每轮覆盖 `lastSummary`，真机就看不到各模块被拒绝的明细了。
    struct ReconcileSnapshot: Sendable {
        let pendingBefore: Int
        let scheduled: Int
        let trimmed: Int
        let limit: Int
        let suppressedTotal: Int
        let timestamp: Date
    }

    private static let reconcileLock = OSAllocatedUnfairLock<ReconcileSnapshot?>(initialState: nil)
    static var lastReconcile: ReconcileSnapshot? { reconcileLock.withLock { $0 } }

    // MARK: - 抑制名单

    /// 被裁剪的 identifier 及其「允许重试」时刻。
    ///
    /// 一轮巡检里报告 / 待办 / 服药 / 心理依次排期，若某模块裁掉另一模块的存量，
    /// 对方下一轮差量对账会「发现缺失 → 立刻加回」，同轮裁决被自己人推翻。
    /// 抑制名单让 `admit` 在 TTL 内直接拒绝这些请求；TTL 到期后自然恢复，
    /// 不会因一次名额紧张而永久丢掉用户设置过的提醒。
    static let suppressionTTL: TimeInterval = 30 * 60
    private static let suppressionLock = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])

    /// 读侧顺带清理过期项，避免字典无限增长。
    private static func activeSuppressions(now: Date = .now) -> Set<String> {
        suppressionLock.withLock { store in
            store = store.filter { $0.value > now }
            return Set(store.keys)
        }
    }

    private static func suppress(_ identifiers: [String], now: Date = .now) {
        guard !identifiers.isEmpty else { return }
        let until = now.addingTimeInterval(suppressionTTL)
        suppressionLock.withLock { store in
            for identifier in identifiers { store[identifier] = until }
        }
    }

    /// 仅供调试 / 真机排查：当前仍生效的抑制数量。
    static var activeSuppressionCount: Int { activeSuppressions().count }

    // MARK: - 预算决策

    /// 计算本轮对账的接纳/拒绝/裁剪结果。纯决策，无任何系统调用，可在任意线程调用。
    ///
    /// - Parameters:
    ///   - pending: `getPendingNotificationRequests` / `pendingNotificationRequests()` 的结果。
    ///   - requested: 本轮希望新增或替换的请求（同 identifier 的旧请求会被视为替换，不额外占名额）。
    ///   - source: 来源标签（日志用，例如 `"todoSync"` / `"medication"`）。
    ///   - limit: 覆盖软上限（测试 / 调试用）；nil 时读 UserDefaults 配置或默认值。
    static func admit(
        pending: [UNNotificationRequest],
        requested: [Item],
        source: String,
        limit override: Int? = nil
    ) -> Admission {
        let cap = clampedLimit(override)
        let requestedIDs = Set(requested.map { $0.request.identifier })

        // 被统一裁剪过（或将被本轮 reconcil 裁剪）的 identifier 在 TTL 内直接拒绝，
        // 否则「A 模块裁掉 B 的存量 → B 差量对账发现缺失 → 立刻加回」，
        // 一轮巡检跑完预算裁决形同虚设。
        let suppressed = activeSuppressions()
        let suppressedItems = requested.filter { suppressed.contains($0.request.identifier) }
        let eligible = requested.filter { !suppressed.contains($0.request.identifier) }

        // 同 identifier 的存量项视为被本轮替换，不重复占名额。
        var survivors = pending
            .filter { !requestedIDs.contains($0.identifier) }
            .map { Item(request: $0, priority: priority(for: $0)) }
        var evicted: [Item] = []

        // 阶段 1：存量本身已超上限 → 先做全局裁剪（所有模块都参与，无豁免）。
        // 注意：只在「存量」超上限时裁剪，不因为本轮请求放不下就裁存量——
        // 否则「请求放不下 → 裁掉同优先级存量 → 下轮又缺失 → 再裁」会每次前台互相抢占。
        while survivors.count > cap {
            guard let candidate = globalTrimCandidateIndex(in: survivors) else { break }
            evicted.append(survivors.remove(at: candidate))
        }

        // 阶段 2：按优先级从高到低接纳本轮请求；名额不足时只裁「优先级严格更低」的存量项。
        let ordered = eligible.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return fireDate(of: lhs.request) < fireDate(of: rhs.request)
        }
        var accepted: [Item] = []
        var rejected: [Item] = suppressedItems
        var freeSlots = cap - survivors.count
        for item in ordered {
            if freeSlots > 0 {
                accepted.append(item)
                freeSlots -= 1
                continue
            }
            if let candidate = victimIndex(in: survivors, lowerThan: item.priority) {
                evicted.append(survivors.remove(at: candidate))
                accepted.append(item)
            } else {
                rejected.append(item)
            }
        }

        // 本轮裁掉的存量也进抑制名单：它的宿主模块下一轮会想把它加回来。
        suppress(evicted.map { $0.request.identifier })

        let finalCount = survivors.count + accepted.count
        let admission = Admission(
            accepted: accepted,
            rejected: rejected,
            evictedIdentifiers: evicted.map { $0.request.identifier },
            pendingBefore: pending.count,
            limit: cap,
            finalPendingCount: finalCount,
            source: source
        )
        record(admission)
        return admission
    }

    /// 软上限：默认 56（64 条硬上限留 8 条余量），夹到 [16, 64]。
    static func clampedLimit(_ override: Int?) -> Int {
        min(max(override ?? defaultPendingLimit, 16), systemPendingLimit)
    }

    /// 按 identifier 前缀识别模块优先级；未知前缀落到最低的 `.ambient`。
    static func priority(for request: UNNotificationRequest) -> Priority {
        priority(forIdentifier: request.identifier)
    }

    /// identifier 前缀 → 业务档位。新增通知模块时**必须在此登记**：
    /// 漏登记会落到 `.ambient`（超限时最先让位），是刻意的保守兜底，
    /// 不再像旧版 `.external = 5` 那样反过来拿到最高豁免。
    private static let prefixPriorities: [(String, Priority)] = [
        ("med-", .medication),
        ("sleep-bedtime-", .sleep),
        ("trip-arrival-", .tripArrival),
        ("psych-reminder-", .psych),
        ("periodic-report-", .report),
        ("todo-", .todo),
        ("weather-alert-", .ambient),
        ("anni_prep_", .ambient),
        ("expiry-reminder", .ambient),
        ("battery-", .ambient),
        ("geofence-arrival-", .ambient),
        ("parcel-station-", .ambient),
        ("travel-escort-session", .ambient),
        ("departure-check-session", .ambient),
        ("pickup-checkout-session", .ambient)
    ]

    static func priority(forIdentifier identifier: String) -> Priority {
        // 逾期补提醒（todo-<id>-overdue-<offset>）比主提醒先让位。
        if identifier.hasPrefix("todo-") && identifier.contains("-overdue-") {
            return .todoOverdue
        }
        for (prefix, priority) in prefixPriorities where identifier.hasPrefix(prefix) {
            return priority
        }
        return .ambient
    }

    // MARK: - 全局裁决

    /// 前台巡检末尾的**唯一全局裁决点**。
    ///
    /// 各模块排期时只看到自己那一刻的 pending 快照，彼此的 `admit` 决策
    /// 可能互相推翻；这里等所有排期完成后再读一次真实 pending，超限就按
    /// 优先级从低到高删除，并把被删 identifier 写入抑制名单，
    /// 下一轮各模块的差量对账不会立刻把它们加回来。
    ///
    /// 只处理带 trigger 的待处理通知：`trigger == nil` 是即时投递，不占 64 条名额。
    /// - Returns: 本轮实际裁剪的条数（真机排查 / 日志用）。
    @discardableResult
    static func reconcile(source: String = "foregroundReconcile", limit override: Int? = nil) async -> Int {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let cap = clampedLimit(override)
        let scheduled = pending.filter { $0.trigger != nil }

        // Swift 6 并发检查：`withLock` 的闭包按「并发执行代码」处理，捕获外层可变
        // `var` 即使只读也会报错。所以 victims 用 `let` 一次成型，闭包内要用的计数
        // 也先在闭包外提取成 Sendable 局部 `let` —— 顺带不捕获非 Sendable 的
        // `[UNNotificationRequest]`，也不在临界区里嵌套拿 suppressionLock。
        // 排序：优先级从低到高；同档位先删「离触发最远」的，保住更近的提醒。
        let victims: [String] = scheduled.count > cap
            ? scheduled
                .map { Item(request: $0, priority: priority(for: $0)) }
                .sorted { lhs, rhs in
                    if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                    return fireDate(of: lhs.request) > fireDate(of: rhs.request)
                }
                .prefix(scheduled.count - cap)
                .map { $0.request.identifier }
            : []
        if !victims.isEmpty {
            suppress(victims)
            center.removePendingNotificationRequests(withIdentifiers: victims)
        }
        let pendingCount = pending.count
        let scheduledCount = scheduled.count
        let trimmedCount = victims.count
        let suppressedTotal = activeSuppressions().count
        reconcileLock.withLock {
            $0 = ReconcileSnapshot(
                pendingBefore: pendingCount,
                scheduled: scheduledCount,
                trimmed: trimmedCount,
                limit: cap,
                suppressedTotal: suppressedTotal,
                timestamp: .now
            )
        }
        // 只有真发生裁剪才进 lastSummary 与日志，避免每轮巡检把各模块的
        // 准入决策快照冲掉；正常路径下 lastReconcile 足以确认裁决跑过。
        if !victims.isEmpty {
            record(Admission(
                accepted: [],
                rejected: [],
                evictedIdentifiers: victims,
                pendingBefore: pending.count,
                limit: cap,
                finalPendingCount: pending.count - victims.count,
                source: source
            ))
        }
        return trimmedCount
    }

    // MARK: - 指纹（差量对账用）

    /// 日历触发器的「墙钟槽位」：只比较年月日时分，忽略时区 / 日历表示差异。
    struct CalendarSlot: Equatable {
        let year: Int?
        let month: Int?
        let day: Int?
        let hour: Int?
        let minute: Int?
    }

    /// 通知的「内容指纹」。差量对账用它判断一条已排期通知是否与期望一致。
    ///
    /// 注意：`UNTimeIntervalNotificationTrigger`（待办主提醒）的剩余时长每次读取都会变，
    /// 不参与比较；其触发时刻的变化由副标题里的格式化到期时间 + 直接排期调用点覆盖。
    struct Fingerprint: Equatable {
        let title: String
        let subtitle: String
        let body: String
        let categoryIdentifier: String
        let threadIdentifier: String
        let userInfo: [String: String]
        let calendarSlot: CalendarSlot?
        let repeats: Bool
    }

    static func fingerprint(of request: UNNotificationRequest) -> Fingerprint {
        let content = request.content
        var userInfo: [String: String] = [:]
        for (key, value) in content.userInfo {
            guard let key = key as? String else { continue }
            userInfo[key] = String(describing: value)
        }
        var slot: CalendarSlot?
        var repeats = false
        if let trigger = request.trigger as? UNCalendarNotificationTrigger {
            let components = trigger.dateComponents
            slot = CalendarSlot(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: components.hour,
                minute: components.minute
            )
            repeats = trigger.repeats
        }
        return Fingerprint(
            title: content.title,
            subtitle: content.subtitle,
            body: content.body,
            categoryIdentifier: content.categoryIdentifier,
            threadIdentifier: content.threadIdentifier,
            userInfo: userInfo,
            calendarSlot: slot,
            repeats: repeats
        )
    }

    // MARK: - 私有

    /// 全局裁剪候选：优先级最低者优先；同优先级时裁掉「离触发最远」的一条（保住更近的提醒）。
    /// 所有模块都参与，没有 `.external` 豁免。
    private static func globalTrimCandidateIndex(in survivors: [Item]) -> Int? {
        var bestIndex: Int?
        var bestPriority: Priority?
        var bestFireDate = Date.distantPast
        for (index, item) in survivors.enumerated() {
            if let currentBest = bestPriority {
                if item.priority < currentBest {
                    bestIndex = index
                    bestPriority = item.priority
                    bestFireDate = fireDate(of: item.request)
                } else if item.priority == currentBest {
                    let candidateFireDate = fireDate(of: item.request)
                    if candidateFireDate > bestFireDate {
                        bestIndex = index
                        bestFireDate = candidateFireDate
                    }
                }
            } else {
                bestIndex = index
                bestPriority = item.priority
                bestFireDate = fireDate(of: item.request)
            }
        }
        return bestIndex
    }

    /// 为「优先级更高的新请求」腾名额的候选：必须是优先级严格更低的存量项（同优先级不互相抢占）。
    private static func victimIndex(in survivors: [Item], lowerThan priority: Priority) -> Int? {
        var bestIndex: Int?
        var bestPriority: Priority?
        var bestFireDate = Date.distantPast
        for (index, item) in survivors.enumerated() {
            guard item.priority < priority else { continue }
            if let currentBest = bestPriority {
                if item.priority < currentBest
                    || (item.priority == currentBest && fireDate(of: item.request) > bestFireDate) {
                    bestIndex = index
                    bestPriority = item.priority
                    bestFireDate = fireDate(of: item.request)
                }
            } else {
                bestIndex = index
                bestPriority = item.priority
                bestFireDate = fireDate(of: item.request)
            }
        }
        return bestIndex
    }

    private static func fireDate(of request: UNNotificationRequest) -> Date {
        guard let trigger = request.trigger else { return .distantFuture }
        if let calendarTrigger = trigger as? UNCalendarNotificationTrigger {
            return calendarTrigger.nextTriggerDate() ?? .distantFuture
        }
        if let intervalTrigger = trigger as? UNTimeIntervalNotificationTrigger {
            return intervalTrigger.nextTriggerDate() ?? .distantFuture
        }
        return .distantFuture
    }

    private static func record(_ admission: Admission) {
        var rejectedByPriority: [String: Int] = [:]
        for item in admission.rejected {
            rejectedByPriority[item.priority.label, default: 0] += 1
        }
        var evictedByPriority: [String: Int] = [:]
        for identifier in admission.evictedIdentifiers {
            evictedByPriority[priority(forIdentifier: identifier).label, default: 0] += 1
        }
        let summary = Summary(
            source: admission.source,
            pendingBefore: admission.pendingBefore,
            limit: admission.limit,
            requested: admission.accepted.count + admission.rejected.count,
            accepted: admission.accepted.count,
            rejected: admission.rejected.count,
            evicted: admission.evictedIdentifiers.count,
            rejectedByPriority: rejectedByPriority,
            evictedByPriority: evictedByPriority,
            finalPendingCount: admission.finalPendingCount,
            timestamp: Date.now
        )
        summaryLock.withLock { $0 = summary }

        // 只有真正发生裁剪/拒绝时才打日志：正常路径（差量对账无变化）不产生噪音。
        guard admission.finalPendingCount > 0,
              !admission.rejected.isEmpty || !admission.evictedIdentifiers.isEmpty else { return }
        let rejectedDetail = rejectedByPriority.isEmpty
            ? ""
            : "（\(rejectedByPriority.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ","))）"
        let evictedDetail = evictedByPriority.isEmpty
            ? ""
            : "（\(evictedByPriority.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ","))）"
        print("📊 [NotificationBudget] \(admission.source)：待处理 \(admission.pendingBefore)→\(admission.finalPendingCount)/\(admission.limit)，申请 \(summary.requested)，接受 \(summary.accepted)，拒绝 \(summary.rejected)\(rejectedDetail)，裁剪 \(summary.evicted)\(evictedDetail)")
    }
}
