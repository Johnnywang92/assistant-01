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
}
