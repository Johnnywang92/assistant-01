import Foundation
import SwiftData

/// 纪念日与重要日子模型（支持公历/农历、提前多天提醒、正数天/倒数天）
@Model
public final class AnniversaryItem {
    public var id: UUID
    public var title: String               // 名称，如 "和伴侣在一起", "妈妈生日", "结婚纪念日"
    public var category: String            // 分类：恋爱情侣/家人亲友/生日/重要里程碑
    public var targetDate: Date            // 原始起始/发生日期
    public var isLunar: Bool               // 是否农历（生日适用）
    public var remindDaysBefore: [Int]     // 提前几天提醒，如 [7, 3, 1, 0]（提前7天备礼物、当天庆祝）
    public var notes: String?              // 备注，如 "想买的手表、喜欢的餐厅"

    public init(
        title: String,
        category: String = "纪念日",
        targetDate: Date,
        isLunar: Bool = false,
        remindDaysBefore: [Int] = [7, 3, 1, 0],
        notes: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.category = category
        self.targetDate = targetDate
        self.isLunar = isLunar
        self.remindDaysBefore = remindDaysBefore
        self.notes = notes
    }

    /// 累计相识/在一起天数（正数天数）
    public var passedDays: Int {
        let cal = Calendar.current
        let start = cal.startOfDay(for: targetDate)
        let now = cal.startOfDay(for: .now)
        return max(0, cal.dateComponents([.day], from: start, to: now).day ?? 0)
    }

    /// 下一次周年的具体日期
    public var nextAnniversaryDate: Date {
        let cal = Calendar.current
        let now = cal.startOfDay(for: .now)
        let targetComps = cal.dateComponents([.month, .day], from: targetDate)

        var thisYearComps = cal.dateComponents([.year], from: now)
        thisYearComps.month = targetComps.month
        thisYearComps.day = targetComps.day

        guard let thisYearDate = cal.date(from: thisYearComps) else { return targetDate }

        if thisYearDate >= now {
            return thisYearDate
        } else {
            // 今年的已经过去，推算下一年
            thisYearComps.year = (thisYearComps.year ?? 2026) + 1
            return cal.date(from: thisYearComps) ?? targetDate
        }
    }

    /// 距离下一次周年还有多少天（倒数日）
    public var daysUntilNext: Int {
        let cal = Calendar.current
        let now = cal.startOfDay(for: .now)
        let next = cal.startOfDay(for: nextAnniversaryDate)
        return max(0, cal.dateComponents([.day], from: now, to: next).day ?? 0)
    }

    /// 当前是第几年（例如结婚第 3 周年）
    public var nextYearsCount: Int {
        let cal = Calendar.current
        let startYear = cal.component(.year, from: targetDate)
        let nextYear = cal.component(.year, from: nextAnniversaryDate)
        return max(1, nextYear - startYear)
    }
}
