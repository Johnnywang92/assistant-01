import Foundation

// MARK: - 行程倒计时 · 唯一口径
//
// 三个消费端（手表行程护航卡、桌面行程倒计时组件、灵动岛发车倒计时）
// 必须显示同一个「还差多久」。任何一端自己算都会出现措辞/数值漂移，
// 所以口径统一放在 Core，App 只做「SwiftData → 纯值事实」的映射与渲染。
//
// 三条硬规则：
//
// 1. **不编造时间**：没有可靠发车时刻就不倒计时，也不拿 `now + 1 小时` 顶替。
//    旧实现这么干过 → 手表上会出现一条根本不存在的「1 小时后发车」，
//    用户照着假时间出门，比不显示更糟。
// 2. **只认最近的一趟**：按发车时间取最近的一条，不按待办优先级
//    （优先级答的是「重要/紧急」，倒计时答的是「最近」，两件事）。
// 3. **窗口有依据**：临近窗口取 3 天，与出行购票阶段的「临近出行（3 天内）」同源。

/// 行程倒计时的公共口径。
public enum TravelCountdownPolicy {

    /// 临近发车的展示窗口（3 天）。
    /// 与 `TravelTicketStage.imminent` 的「临近出行（3 天内）」保持同一口径：
    /// 超过 3 天的行程由购票提醒横幅负责，不再占倒计时位。
    public static let window: TimeInterval = 3 * 24 * 60 * 60

    /// 已过发车时间后的宽限：期间仍算「刚刚发车」，
    /// 避免卡片在整点瞬间消失、用户还没看到就已收起。
    public static let departedGrace: TimeInterval = 2 * 60 * 60

    /// 分钟级倒计时阈值：距发车不足 1 天时用「时/分」表述，超过用「天」表述。
    public static let minuteLevelThreshold: TimeInterval = 24 * 60 * 60

    /// 距发车不足 1 天 → 走分钟级实时计时；否则走天级静态文案。
    public static func isImminent(departureAt: Date, now: Date) -> Bool {
        departureAt.timeIntervalSince(now) < minuteLevelThreshold
    }

    /// 计算倒计时阶段。
    ///
    /// - 参数：`now` 由调用方注入（禁止读墙上时钟，否则不可复现）。
    /// - 天数**向上取整**：47 小时说「还有 2 天」符合倒计时惯例，
    ///   说「还有 1 天」会让用户以为只剩一天。
    public static func phase(departureAt: Date, now: Date) -> TravelDeparturePhase {
        let remaining = departureAt.timeIntervalSince(now)
        if remaining < 0 {
            return .departed
        }
        if remaining < minuteLevelThreshold {
            let totalMinutes = Int((remaining / 60).rounded(.up))
            return .hours(hours: totalMinutes / 60, minutes: totalMinutes % 60)
        }
        return .days(Int((remaining / 86_400).rounded(.up)))
    }

    /// 倒计时文案（中文）。
    ///
    /// 手表 / 桌面组件 / 灵动岛共用这一份措辞，避免三端各写一套。
    /// 「已到出行时间」而不是「已到发车时间」：接人模式锚点是**到站/接人**时刻，
    /// 本人出行才是发车时刻，用「发车」会与接人场景矛盾。
    public static func text(departureAt: Date, now: Date) -> String {
        switch phase(departureAt: departureAt, now: now) {
        case .days(let days):
            return "还有 \(days) 天"
        case .hours(let hours, let minutes):
            if hours == 0 {
                return "还有 \(minutes) 分钟"
            }
            return minutes == 0 ? "还有 \(hours) 小时" : "还有 \(hours) 小时 \(minutes) 分"
        case .departed:
            return "已到出行时间"
        }
    }
}

/// 倒计时阶段。
public enum TravelDeparturePhase: Hashable, Sendable {
    /// 距发车 ≥ 1 天（按天取整，向上取整）。
    case days(Int)
    /// 距发车 < 1 天（时 + 分）。
    case hours(hours: Int, minutes: Int)
    /// 已过发车时间（仍在宽限期内）。
    case departed
}

/// 一条出行候选（App 层从 SwiftData 待办映射而来的纯值事实）。
///
/// `departureAt` 为 nil 表示**待办没有可靠时间**：此时不产出倒计时，
/// 也不允许调用方用「现在 + 1 小时」之类的假时间顶替。
public struct TravelDepartureCandidate: Hashable, Sendable {
    public let id: UUID
    public let title: String
    /// 出行时刻锚点（本人出行=发车，接人=到站/接人）。
    public let departureAt: Date?
    /// 车次 + 座位摘要，如 "G1234 · 5车 12A"。
    public let ticketSummary: String?
    /// 检票口 / 登机口。
    public let gate: String?
    /// 出行地点。
    public let place: String?
    /// 是否命中出行信号（票面信息、标题关键词或出行类待办）。
    public let isTravel: Bool

    public init(
        id: UUID,
        title: String,
        departureAt: Date? = nil,
        ticketSummary: String? = nil,
        gate: String? = nil,
        place: String? = nil,
        isTravel: Bool = true
    ) {
        self.id = id
        self.title = title
        self.departureAt = departureAt
        self.ticketSummary = ticketSummary
        self.gate = gate
        self.place = place
        self.isTravel = isTravel
    }
}

/// 一次倒计时的完整事实。
public struct TravelDepartureCountdown: Hashable, Sendable {
    public let candidate: TravelDepartureCandidate
    /// 实际锚定的发车时刻（一定有值：未知时间的候选不产出倒计时）。
    public let departureAt: Date
    /// 相对 `now` 的阶段（阶段会随时间变化，渲染方应按需重算）。
    public let phase: TravelDeparturePhase

    public init(candidate: TravelDepartureCandidate, departureAt: Date, phase: TravelDeparturePhase) {
        self.candidate = candidate
        self.departureAt = departureAt
        self.phase = phase
    }
}

/// 出行信号识别。
///
/// 判定放在 Core 有两个原因：
/// - 一份词表，避免 App / 手表 / 组件各写一份 `contains` 导致同一件事三种结论；
/// - 词表可被单测钉住（新增词不会悄悄改变既有判定）。
public enum TravelDepartureDetector {

    /// 标题命中即视为出行相关。
    public static let titleKeywords: [String] = [
        "高铁", "动车", "火车", "列车", "车次", "车厢", "座位", "检票口", "登机口",
        "航班", "飞机", "登机", "起飞", "到达", "出发", "前往", "乘坐", "车站", "机场",
        "出行", "差旅", "出差", "旅游", "乘车"
    ]

    /// 详情 / 原文命中：说明这是行程相关文本（含票面描述）。
    public static let detailKeywords: [String] = [
        "车次", "车厢", "座位", "检票口", "登机口", "前往", "乘坐", "到达", "出发", "始发"
    ]

    /// 廉价预筛：命中才值得跑正则抽票面信息。
    ///
    /// 正则抽取比 `contains` 贵得多（见 `TicketDetailsExtractor`），
    /// 全表扫描时先用它把明显无关的待办挡掉。
    public static func looksLikeTravel(title: String, detail: String?, sourceText: String?) -> Bool {
        if titleKeywords.contains(where: { title.contains($0) }) { return true }
        let text = [detail, sourceText].compactMap { $0 }.joined(separator: " ")
        guard !text.isEmpty else { return false }
        return detailKeywords.contains(where: { text.contains($0) })
    }

    /// 票面信息抽取结果。
    public struct TicketInfo: Hashable, Sendable {
        /// 车次 + 座位摘要，如 "G1234 · 5车 12A"。
        public let summary: String?
        /// 检票口 / 登机口。
        public let gate: String?

        public init(summary: String?, gate: String?) {
            self.summary = summary
            self.gate = gate
        }

        /// 是否抽到任何票面信号。
        public var hasSignal: Bool {
            summary != nil || gate != nil
        }

        public static let none = TicketInfo(summary: nil, gate: nil)
    }

    /// 抽取票面信息（车次/座位/检票口）。
    ///
    /// 抽不到就是抽不到——不猜、不编。
    public static func ticketInfo(title: String, detail: String?, sourceText: String?) -> TicketInfo {
        let ticket = TicketDetailsExtractor.extract(from: [detail, sourceText, title])
        return TicketInfo(summary: ticket.vehicleAndSeatLine, gate: ticket.gate)
    }
}

/// 行程倒计时计算。
public enum TravelCountdownBuilder {

    /// 选出应该展示倒计时的那一趟行程，并算出阶段。
    ///
    /// 选取规则（顺序即优先级）：
    /// 1. 只看命中出行信号的候选；
    /// 2. **有时间的优先**——未知时间的候选不产出倒计时（不编造）；
    /// 3. 未来发车优先于刚刚发车：多趟行程时给用户看「下一趟」，
    ///    而不是把「刚过站那一趟」摆在最前面；
    /// 4. 同一趟内部按发车时间取最近的一条；时间相同再按 id 兜底，
    ///    保证顺序可复现（`Array.sorted` 不稳定）。
    ///
    /// - 参数：`now` 由调用方注入（禁止读墙上时钟）。
    public static func build(
        candidates: [TravelDepartureCandidate],
        now: Date
    ) -> TravelDepartureCountdown? {
        let travel = candidates.filter { $0.isTravel }

        let dated = travel.compactMap { candidate -> (TravelDepartureCandidate, Date)? in
            guard let departure = candidate.departureAt else { return nil }
            return (candidate, departure)
        }

        let inWindow = dated.filter { _, departure in
            let remaining = departure.timeIntervalSince(now)
            return remaining <= TravelCountdownPolicy.window && remaining >= -TravelCountdownPolicy.departedGrace
        }
        guard !inWindow.isEmpty else { return nil }

        let upcoming = inWindow.filter { _, departure in departure.timeIntervalSince(now) >= 0 }
        let pool = upcoming.isEmpty ? inWindow : upcoming

        guard let picked = pool.min(by: { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0.id.uuidString < rhs.0.id.uuidString
        }) else { return nil }

        let (candidate, departure) = picked
        return TravelDepartureCountdown(
            candidate: candidate,
            departureAt: departure,
            phase: TravelCountdownPolicy.phase(departureAt: departure, now: now)
        )
    }
}
