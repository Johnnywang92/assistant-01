import Foundation

/// 服药 / 打卡「今日状态」的唯一判定实现。
///
/// ## 为什么要有这个类型
///
/// 改动前，「今天是否已服药 / 今天是否该打卡」散落在四处，各写各的：
///
/// | 位置 | 原判定 | 时间窗口 |
/// |---|---|---|
/// | 小组件快照 | `cal.isDateInToday(lastTakenAt)` | 无 |
/// | 药品库行 | `isDateInToday` 且 3 小时内 | 3h |
/// | 饮食时效看板 | `isDate(…inSameDayAs:)` 且 4 小时内 | 4h |
/// | 睡前提醒 | `cal.isDateInToday` | 无 |
///
/// 后果是同一条服药记录在不同界面给出不同结论：吃了药，药品库说「已服用」、
/// 小组件说「待服用」、睡前提醒又说「漏服」。**组件与 App 对不上**是最难查的一类
/// 静默失败——两边都「没报错」，只是显示不一致。
///
/// ## 两条铁律
///
/// 1. **不读墙上时钟**。所有判定都要求显式传入 `now` 与 `calendar`。
///    `Calendar.isDateInToday` 内部读系统当前时间，测试不可复现、也无法在
///    「快照生成时刻 ≠ 展示时刻」的场景下得到正确答案。
/// 2. **窗口时长有名字**。`3 小时`（UI 防抖）与 `4 小时`（服药安全间隔）
///    语义不同，不强行统一成同一个数，但都必须只在 Core 定义一次。
public enum MedicationHabitDoseResolver {

    // MARK: - 窗口常量（唯一来源）

    /// 服药后的**防重复打卡**窗口：打卡后这段时间内不再重复提示「该服药了」。
    ///
    /// 用于界面防抖（药品库行的打卡按钮可用态），**不是**临床安全间隔。
    public static let tapCooldown: TimeInterval = 3 * 3600

    /// 服药后的**安全间隔**：上一次服药后这段时间内，不提示「漏服 / 尽快补服」。
    ///
    /// 用于饮食时效看板的漏服检测，避免刚吃完药就报「轻度超时，建议补服」。
    public static let safetyInterval: TimeInterval = 4 * 3600

    // MARK: - 今日边界

    /// 候选时间是否落在 `now` 所在的日历日。
    ///
    /// 这是全项目「今天」的**唯一**定义。禁止再出现 `isDateInToday`。
    public static func isSameDay(_ candidate: Date, now: Date, calendar: Calendar) -> Bool {
        calendar.isDate(candidate, inSameDayAs: now)
    }

    /// `now` 所在日历日的起始时刻。
    public static func startOfToday(now: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: now)
    }

    /// `now` 所在日历日的**下一日**起始时刻（即今日终点，不含）。
    public static func endOfToday(now: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start
    }

    // MARK: - 服药

    /// 今日是否已服用（当天存在服药记录即算）。
    ///
    /// 用于「今天有没有吃药」这一粗粒度事实：小组件状态、睡前提醒的待服清单。
    public static func isMedicationTakenToday(
        lastTakenAt: Date?,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard let lastTakenAt else { return false }
        return isSameDay(lastTakenAt, now: now, calendar: calendar)
    }

    /// 是否处于服药后的防重复打卡窗口内（默认 `tapCooldown`）。
    ///
    /// 用于界面可用态：刚打卡 3 小时内不重复提示，也不重复累加。
    public static func isMedicationWithinCooldown(
        lastTakenAt: Date?,
        now: Date,
        window: TimeInterval = tapCooldown
    ) -> Bool {
        guard let lastTakenAt else { return false }
        let elapsed = now.timeIntervalSince(lastTakenAt)
        // 负值说明打卡时间在「现在」之后（时钟回拨 / 数据异常），不当成冷却中。
        return elapsed >= 0 && elapsed < window
    }

    /// 今日应服时点数（`dailyTimePoints` 解析失败的时点自动跳过）。
    ///
    /// 单个 `lastTakenAt` 无法表达一天多次服药，因此这里只给**应服总数**，
    /// 展示「已服 N 次」时必须配合 `MedicationDoseProgress.conservativeTakenCount`
    /// 的保守下界，不可凭 `lastTakenAt` 直接声称「都吃完了」。
    public static func scheduledSlotCount(
        dailyTimePoints: [String],
        now: Date,
        calendar: Calendar
    ) -> Int {
        MedicationTodoMaterializer.daySlots(
            medName: "",
            dailyTimePoints: dailyTimePoints,
            on: now,
            calendar: calendar
        ).count
    }

    // MARK: - 打卡

    /// 今日是否该打卡（尚未完成，且到期时间不晚于今日结束）。
    ///
    /// 含**逾期**：到期时间是昨天、今天还没打卡的，仍然算「今日该打卡」。
    /// 到期时间是明天的，不算。
    public static func isHabitDueToday(
        nextDueAt: Date,
        lastCompletedAt: Date?,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        if let lastCompletedAt, isSameDay(lastCompletedAt, now: now, calendar: calendar) {
            return false
        }
        return nextDueAt < endOfToday(now: now, calendar: calendar)
    }

    /// 是否已到打卡时刻（到期时间已过）。
    ///
    /// 与 `isHabitDueToday` 是**两个不同的问题**，不要混用：
    /// - `isHabitDueToday` = 「今天该不该打」→ 用于展示（小组件、待办列表）
    /// - `hasReachedDueTime` = 「到点了没」→ 用于调度（生成待办、排通知）
    ///
    /// 两者分开才能解释「早上 8 点该打卡，组件显示待打卡，但 App 里还没有待办」
    /// —— 组件按日展示，调度按时刻触发，两者本就不该同一时刻生效。
    public static func hasReachedDueTime(nextDueAt: Date, now: Date) -> Bool {
        nextDueAt <= now
    }

    // MARK: - 服药进度

    /// 计算今日服药进度。
    ///
    /// ## 两种口径
    ///
    /// | 输入 | 口径 | 用途 |
    /// |---|---|---|
    /// | 无 `completedSlotTimes` | 保守（只有 `lastTakenAt`） | 兜底：只知道「今天至少服过一次」 |
    /// | 有 `completedSlotTimes` | **证据驱动（精确）** | 正常路径：知道今天具体服了哪几顿 |
    ///
    /// ## 为什么必须有精确口径
    ///
    /// 保守口径只能表达「今天至少服过一次」：`takenLowerBound` 永远 ≤ 1。
    /// 于是一天 3 次的药，用户吃完 08:00 与 13:00 两顿后，组件仍显示
    /// 「待服 2 次」→ 用户照着提示再吃 → **过量服药**。
    /// 反过来，用户只吃了 20:00 那一顿、漏了 08:00，保守口径又可能判定
    /// 「已服完」→ 漏服被静默掩盖。
    ///
    /// 精确口径来自**今日已完成的服药待办**：每完成一顿待办就留下一条证据，
    /// 证据精确到时点（"08:00" / "13:00"），因此「已服几顿」「还差几顿」
    /// 「是否漏服」全部可算准。
    ///
    /// 证据由 App 层从**今日已完成**的服药待办汇总而来（跨天同名标题靠
    /// `completedAt` 落在今天来区分，不能只看标题）。
    ///
    /// `pendingCount` 的规则：
    /// - **已服完**（有证据）→ 0，精确；
    /// - 未服完 → 保守下界（宁可多提醒也不漏服）。
    public static func doseProgress(
        lastTakenAt: Date?,
        dailyTimePoints: [String],
        now: Date,
        calendar: Calendar,
        completedSlotTimes: Set<String>? = nil
    ) -> MedicationDoseProgress {
        let slots = MedicationTodoMaterializer.daySlots(
            medName: "",
            dailyTimePoints: dailyTimePoints,
            on: now,
            calendar: calendar
        )
        let scheduledCount = slots.count
        let takenToday = isMedicationTakenToday(lastTakenAt: lastTakenAt, now: now, calendar: calendar)
        let takenLowerBound = takenToday ? 1 : 0
        let isWithinCooldown = isMedicationWithinCooldown(lastTakenAt: lastTakenAt, now: now)

        let lastSlot = slots.last?.dueAt
        let isFullySatisfied: Bool = {
            guard takenToday, let lastTakenAt, let lastSlot else { return scheduledCount == 0 }
            return lastTakenAt >= lastSlot
        }()

        // 证据驱动：今日已完成的服药待办能精确到时点。
        //
        // 只统计**今日应服时点**与证据的交集——昨天的待办标题与今天同名，
        // 但时点集合只含今天该服的顿次，交集天然排除了历史证据。
        if let completedSlotTimes, !completedSlotTimes.isEmpty {
            let todaySlotTimes = Set(slots.map { slotTimeText($0.dueAt, calendar: calendar) })
            let doneCount = todaySlotTimes.intersection(completedSlotTimes).count
            // 证据比时间戳更具体；但时间戳至少能证明「今天服过一次」，
            // 两者取大：既不因证据不全而谎报未服，也不因证据缺失而漏掉已服。
            let exactTaken = max(doneCount, takenLowerBound)
            return MedicationDoseProgress(
                scheduledCount: scheduledCount,
                takenLowerBound: exactTaken,
                // 与保守分支保持一致：没有应服时点的计划 = 没有待服项（不是待服 1 次）。
                isFullySatisfied: scheduledCount == 0 || doneCount >= scheduledCount,
                isWithinCooldown: isWithinCooldown
            )
        }

        return MedicationDoseProgress(
            scheduledCount: scheduledCount,
            takenLowerBound: takenLowerBound,
            isFullySatisfied: isFullySatisfied,
            isWithinCooldown: isWithinCooldown
        )
    }

    /// 下一个**尚未到时点**的服药时点（用于显示「下一顿 20:00」）。
    ///
    /// 只看未来的时点：已经过去但还没吃的时点不能算「下一顿」——
    /// 那种情况应该报「已超时」，而不是把用户引到一个已经过去的时刻。
    /// 返回 nil 表示今天的时点都过了（要么已服完，要么已漏服）。
    public static func nextScheduledSlot(
        dailyTimePoints: [String],
        now: Date,
        calendar: Calendar
    ) -> MedicationTodoMaterializer.Slot? {
        MedicationTodoMaterializer.daySlots(
            medName: "",
            dailyTimePoints: dailyTimePoints,
            on: now,
            calendar: calendar
        )
        .first { $0.dueAt > now }
    }

    /// 下一个时点的「HH:mm」文案（用于小组件显示）。
    public static func nextScheduledSlotText(
        dailyTimePoints: [String],
        now: Date,
        calendar: Calendar
    ) -> String? {
        guard let slot = nextScheduledSlot(
            dailyTimePoints: dailyTimePoints, now: now, calendar: calendar) else {
            return nil
        }
        return slotTimeText(slot.dueAt, calendar: calendar)
    }

    /// 时刻的「HH:mm」文案。
    public static func slotTimeText(_ date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    // MARK: - 排序（供小组件截断前使用）

    /// 药品排序：**待服排前面**，同组内按药名稳定排序。
    ///
    /// ## 为什么必须先排再截断
    ///
    /// 小组件快照里的药品是 `prefix(6)`。若按数据库原始顺序截断，
    /// 可能截到的全是已服完的，而真正待服的那条排在第 7 位进不来 →
    /// 组件显示「今日用药已服完」→ **用户漏服**。
    ///
    /// - Parameters:
    ///   - items: 待排序的药品条目
    ///   - isPending: 判定某条是否待服的闭包（调用方注入，避免 Core 认识 App 模型）
    ///   - nameOf: 取药名的闭包（用于同组内稳定排序）
    public static func sortMedicationsPendingFirst<Item>(
        _ items: [Item],
        isPending: (Item) -> Bool,
        nameOf: (Item) -> String
    ) -> [Item] {
        items.sorted { lhs, rhs in
            let lhsPending = isPending(lhs)
            let rhsPending = isPending(rhs)
            if lhsPending != rhsPending { return lhsPending }
            // 同组内按名称排序，保证顺序稳定可复现（不依赖数据库返回顺序）
            return nameOf(lhs) < nameOf(rhs)
        }
    }

    /// 习惯排序：**待打卡排前面**，同组内按到期时间升序、再按标题稳定排序。
    ///
    /// 与 `sortMedicationsPendingFirst` 同理：先排再截断，避免待打卡的被挤掉。
    public static func sortHabitsDueFirst<Item>(
        _ items: [Item],
        isDue: (Item) -> Bool,
        dueAt: (Item) -> Date,
        titleOf: (Item) -> String
    ) -> [Item] {
        items.sorted { lhs, rhs in
            let lhsDue = isDue(lhs)
            let rhsDue = isDue(rhs)
            if lhsDue != rhsDue { return lhsDue }
            // 同组内按到期时间升序（最该打的在前）
            let lhsDueAt = dueAt(lhs)
            let rhsDueAt = dueAt(rhs)
            if lhsDueAt != rhsDueAt { return lhsDueAt < rhsDueAt }
            // 再按标题兜底，保证顺序完全确定
            return titleOf(lhs) < titleOf(rhs)
        }
    }

    /// **漏服**的时点文案（已过时点但未完成的那一顿）。
    ///
    /// ## 为什么必须单独识别
    ///
    /// `nextScheduledSlot` 只看**未来**的时点。若 08:00 那顿已过没吃，
    /// 组件显示「下一顿 13:00」—— 用户会以为 08:00 那顿不用管了，
    /// 于是**默默漏服**。漏服比「提示得啰嗦」严重得多。
    ///
    /// - Parameters:
    ///   - medName: 药名。**必须传真实药名** —— 槽位标题里含药名
    ///     （「服药：阿莫西林（08:00）」），空名会生成对不上的标题，
    ///     导致「已完成」判定永远不成立 → 每顿都报漏服。
    ///   - completedTitles: 今日**已完成**的服药待办标题集合（精确全等匹配）。
    /// - Returns: 最靠前的一个漏服时点；没有漏服返回 nil。
    public static func missedSlotText(
        medName: String,
        dailyTimePoints: [String],
        completedTitles: Set<String>,
        now: Date,
        calendar: Calendar
    ) -> String? {
        let slots = MedicationTodoMaterializer.daySlots(
            medName: medName,
            dailyTimePoints: dailyTimePoints,
            on: now,
            calendar: calendar
        )
        for slot in slots where slot.dueAt <= now {
            if !completedTitles.contains(slot.title) {
                return slotTimeText(slot.dueAt, calendar: calendar)
            }
        }
        return nil
    }
}

/// 今日服药进度。
///
/// `MedicationPlan.lastTakenAt` 只有**一个**时间戳，一天多次服药时无法知道
/// 中间那次到底吃没吃。因此默认只给**保守下界**：
/// 「至少服了 1 次」是能确定的，「3 次全吃了」是**不能**确定的。
///
/// 界面据此展示「已服 1 / 3 次」，宁可少报也不谎报完成——谎报会让用户漏服。
///
/// **例外**：当有明确证据表明已服完（`isFullySatisfied`）时，
/// `pendingCount` 精确为 0——此时若还按保守下界报「待服 2 次」，
/// 会让用户重复服药（过量），比漏报更危险。
public struct MedicationDoseProgress: Equatable, Sendable {
    /// 今日应服时点总数
    public let scheduledCount: Int
    /// 今日已服时点数。
    ///
    /// - **保守口径**（无完成证据）：下界，有记录即 ≥ 1，否则 0。
    /// - **证据口径**（有今日完成记录）：精确值。
    public let takenLowerBound: Int
    /// 今日是否已完全满足。
    ///
    /// 保守口径：有明确证据（服药记录不早于最后一个应服时点）才为 true。
    /// 证据口径：今日每一顿都有完成记录才为 true（漏一顿都不算服完）。
    public let isFullySatisfied: Bool
    /// 是否处于服药后的防重复打卡窗口内
    public let isWithinCooldown: Bool

    public init(
        scheduledCount: Int,
        takenLowerBound: Int,
        isFullySatisfied: Bool,
        isWithinCooldown: Bool
    ) {
        self.scheduledCount = scheduledCount
        self.takenLowerBound = takenLowerBound
        self.isFullySatisfied = isFullySatisfied
        self.isWithinCooldown = isWithinCooldown
    }

    /// 尚未服用的时点数。
    ///
    /// - **已服完** → 精确 0。有证据就不能再报「待服」，
    ///   否则用户会照着提示重复服药（过量），比漏报更危险。
    /// - **未服完** → 保守下界 `scheduledCount − takenLowerBound`
    ///   （宁可多提醒也不漏服）。
    public var pendingCount: Int {
        if isFullySatisfied { return 0 }
        return max(0, scheduledCount - takenLowerBound)
    }
}
