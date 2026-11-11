import Foundation

/// 服药待办物化规则：把「每日服药计划」展开成首页可勾选的服药待办条目。
///
/// 系统通知侧由 `UNCalendarNotificationTrigger(repeats: true)` 每天重复，
/// 待办侧必须同样按天物化，否则会出现「有推送提醒、首页待办却常年空」的断层。
/// 本类型只做纯规则（标题、时刻解析、幂等判定），不碰 SwiftData。
public enum MedicationTodoMaterializer {

    /// 服药待办标题（绑定时点、不带日期）。
    /// 跨天沿用同一标题做幂等去重：同名未完成条目会保留为逾期供补打卡，
    /// 不会每天堆一张新的；完成后次日再生成新条目。
    public static func todoTitle(medName: String, timePoint: String) -> String {
        "服药：\(medName)（\(timePoint)）"
    }

    /// 判断标题是否为由服药计划物化生成的「服药：XXX（HH:mm）」格式。
    /// 用于区分「由 HabitAndMedicationScheduler 每日循环推送托管的计划任务」与「用户手动新建的独立吃药待办」。
    public static func isMaterializedTitle(_ title: String) -> Bool {
        guard title.hasPrefix("服药："), title.hasSuffix("）"),
              let openRange = title.range(of: "（", options: .backwards) else {
            return false
        }
        let medPrefix = title[title.index(title.startIndex, offsetBy: 3)..<openRange.lowerBound]
        guard !medPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let timeStr = String(title[openRange.upperBound..<title.index(before: title.endIndex)])
        let parts = timeStr.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 && (0...23).contains(parts[0]) && (0...59).contains(parts[1])
    }

    /// 从物化标题反解析药名：「服药：维生素D（08:00）」→ "维生素D"。
    ///
    /// ## 为什么需要反解析
    ///
    /// 服药待办是系统**自动生成并关联**到用药计划上的。用户直接在待办上
    /// 勾完成时，关联计划的状态必须跟着变，否则「待办完成了，计划的今日状态
    /// 却还显示待服」，用户以为按钮没生效。
    ///
    /// 反解析必须与 `todoTitle` 严格对称：解析不出来一律返回 nil，
    /// **宁可漏联动也不能错联动**（药名可能互为子串：「维生素D」⊂「维生素D3」，
    /// 错解析会让一种药认领另一种药的待办 → 漏服）。
    public static func medName(fromMaterializedTitle title: String) -> String? {
        guard isMaterializedTitle(title),
              let openRange = title.range(of: "（", options: .backwards) else { return nil }
        let start = title.index(title.startIndex, offsetBy: 3) // 「服药：」三个字符
        let name = String(title[start..<openRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// 从物化标题反解析时点：「服药：维生素D（08:00）」→ "08:00"。
    ///
    /// 与 `medName(fromMaterializedTitle:)` 同源同规则：解析不出来返回 nil。
    public static func timePoint(fromMaterializedTitle title: String) -> String? {
        guard isMaterializedTitle(title),
              let openRange = title.range(of: "（", options: .backwards) else { return nil }
        let timeStr = String(title[openRange.upperBound..<title.index(before: title.endIndex)])
        let parts = timeStr.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return String(format: "%02d:%02d", parts[0], parts[1])
    }

    /// 解析 "HH:mm" 为指定日期当天的具体时刻；非法时点返回 nil。
    public static func dueDate(timePoint: String, on day: Date, calendar: Calendar = .current) -> Date? {
        let parts = timePoint.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = parts[0]
        comps.minute = parts[1]
        comps.second = 0
        return calendar.date(from: comps)
    }

    /// 单个待物化的服药槽位
    public struct Slot: Equatable, Sendable {
        public let title: String
        public let dueAt: Date

        public init(title: String, dueAt: Date) {
            self.title = title
            self.dueAt = dueAt
        }
    }

    /// 展开某日应物化的服药槽位（时点解析失败的自动跳过，按时刻升序）。
    /// 过了点的槽位也会返回——当天漏服要以逾期形态留在待办里供补打卡，
    /// 否则「晚间才建档 / 晚间才打开 App」时当天一条都看不到。
    public static func daySlots(
        medName: String,
        dailyTimePoints: [String],
        on day: Date,
        calendar: Calendar = .current
    ) -> [Slot] {
        dailyTimePoints.compactMap { tp in
            guard let due = dueDate(timePoint: tp, on: day, calendar: calendar) else { return nil }
            return Slot(title: todoTitle(medName: medName, timePoint: tp), dueAt: due)
        }
        .sorted { $0.dueAt < $1.dueAt }
    }

    /// 是否应为该槽位新建待办：
    /// - 已有未完成条目 → 不建（避免堆积，旧条目自然转为逾期供补打卡）
    /// - 今日已完成同名条目 → 不建（防止同一时点当天重复生成）
    /// - 其余（含昨日及更早的已完成）→ 建当天新条目
    public static func shouldMaterialize(hasActive: Bool, hasCompletedToday: Bool) -> Bool {
        !hasActive && !hasCompletedToday
    }

    /// 某药某日应物化的**槽位标题**列表（与 `daySlots` 的标题一一对应）。
    ///
    /// 用于**精确匹配**服药待办与用药计划。
    ///
    /// ## 为什么不能用 `title.contains(medName)`
    ///
    /// 药名之间可能互为子串：「维生素D」是「维生素D3」的前缀。
    /// 用 `contains` 匹配时，「维生素D3」的待办标题「服药：维生素D3（08:00）」
    /// 会被「维生素D」的计划认领 → 点「维生素D」的按钮会完成
    /// 「维生素D3」的待办 → **另一种药被漏服**。
    ///
    /// 精确匹配（标题全等）没有这个问题。
    public static func slotTitles(
        medName: String,
        dailyTimePoints: [String],
        on day: Date,
        calendar: Calendar = .current
    ) -> [String] {
        daySlots(
            medName: medName,
            dailyTimePoints: dailyTimePoints,
            on: day,
            calendar: calendar
        )
        .map(\.title)
    }
}
