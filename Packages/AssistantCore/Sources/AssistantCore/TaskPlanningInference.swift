import Foundation

/// 任务规划执行阶段（纯数据枚举，下沉 AssistantCore）
public enum PlanningPhaseType: String, Codable, CaseIterable, Sendable {
    case prepare = "前置筹备"    // 提前调研、办证、比价、规划
    case execute = "物料执行"    // 采买物资、实地执行、预订
    case sprint  = "行前冲刺"    // 打包清点、临门一脚、细节确认
    case followup = "收尾复盘"   // 结算报销、整理归位、评价

    /// 阶段默认偏移天数（相对于锚点日期）：
    /// prepare −7 天 / execute −3 天 / sprint −1 天 / followup +2 天
    public var defaultOffsetDays: Int {
        switch self {
        case .prepare: return -7
        case .execute: return -3
        case .sprint: return -1
        case .followup: return 2
        }
    }
}

/// 任务规划推导与时间推算纯函数引擎
public enum TaskPlanningInference: Sendable {

    /// 根据任务标题和描述，推导其执行阶段 Phase
    public static func inferPhase(title: String, detail: String? = nil, index: Int = 0, total: Int = 1) -> PlanningPhaseType {
        let text = (title + " " + (detail ?? "")).lowercased()
        if text.contains("提前") || text.contains("前期") || text.contains("调研") || text.contains("预约") ||
            text.contains("挂号") || text.contains("办证") || text.contains("护照") || text.contains("签证") ||
            text.contains("框架") || text.contains("大纲") || text.contains("断舍离") {
            return .prepare
        }
        if text.contains("出门前") || text.contains("前一晚") || text.contains("临行") || text.contains("前一天") ||
            text.contains("打包") || text.contains("随身") || text.contains("核对") || text.contains("清点") ||
            text.contains("检查") || text.contains("准考证") {
            return .sprint
        }
        if text.contains("复盘") || text.contains("收尾") || text.contains("结算") || text.contains("移机") ||
            text.contains("验收") || text.contains("归位") || text.contains("报销") {
            return .followup
        }
        if text.contains("采购") || text.contains("购买") || text.contains("准备") || text.contains("制作") ||
            text.contains("演练") || text.contains("订餐") || text.contains("执行") {
            return .execute
        }
        if total <= 1 { return .execute }
        let progress = Double(index) / Double(max(1, total - 1))
        if progress < 0.25 { return .prepare }
        if progress < 0.70 { return .execute }
        if progress < 0.88 { return .sprint }
        return .followup
    }

    /// 从文本（标题或详情）中抽取相对偏移天数。
    /// 例如：「提前 30 天办理签证」-> -30；「前一周采买物资」-> -7；「前一天打包」-> -1；「当天出发」-> 0；「后 2 天复盘」-> 2。
    public static func extractOffsetDays(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. 明确的「提前/前 N 天」
        if let match = firstMatch(#"(?:提前|前)\s*(\d{1,3})\s*天"#, in: trimmed),
           let days = Int(match) {
            return -days
        }

        // 2. 「前一周」 / 「提前一周」
        if trimmed.contains("前一周") || trimmed.contains("提前一周") || trimmed.contains("提前1周") || trimmed.contains("提前 1 周") {
            return -7
        }
        // 「提前两周」 / 「提前2周」
        if trimmed.contains("提前两周") || trimmed.contains("提前2周") {
            return -14
        }
        // 「提前一个月」 / 「提前1个月」
        if trimmed.contains("提前一个月") || trimmed.contains("提前1个月") {
            return -30
        }

        // 3. 「前一天」 / 「前一晚」
        if trimmed.contains("前一天") || trimmed.contains("前一晚") || trimmed.contains("前夜") || trimmed.contains("临行前") {
            return -1
        }

        // 4. 「当天」
        if trimmed.contains("当天") || trimmed.contains("出发日") {
            return 0
        }

        // 5. 「后 N 天」 / 「结束第 N 天」
        if let match = firstMatch(#"(?:后|第)\s*(\d{1,3})\s*天"#, in: trimmed),
           let days = Int(match) {
            return days
        }

        return nil
    }

    /// 基于锚点日期和偏移天数（或阶段默认偏移）计算 dueAt 截止时间
    public static func calculateDueDate(
        anchorDate: Date,
        offsetDays: Int?,
        phase: PlanningPhaseType,
        calendar: Calendar = .current
    ) -> Date {
        let days = offsetDays ?? phase.defaultOffsetDays
        return calendar.date(byAdding: .day, value: days, to: anchorDate) ?? anchorDate
    }

    /// 根据任务标题和描述推导高精度的 TodoType 字符串标识
    public static func inferTodoTypeIdentifier(title: String, detail: String? = nil) -> String {
        let text = (title + " " + (detail ?? "")).lowercased()
        if text.contains("车票") || text.contains("机票") || text.contains("门票") || text.contains("12306") ||
            text.contains("抢票") || text.contains("放票") || text.contains("景区") || text.contains("特展") ||
            text.contains("博物馆") || text.contains("订房") || text.contains("预订酒店") || text.contains("航班") ||
            text.contains("航司") || text.contains("买票") || text.contains("订票") {
            return "travelBooking"
        }
        if text.contains("药") || text.contains("空腹") || text.contains("抽血") || text.contains("体检") ||
            text.contains("就诊") || text.contains("挂号") || text.contains("病历") || text.contains("医生") ||
            text.contains("创可贴") {
            return "medication"
        }
        if text.contains("充电") || text.contains("电池") || text.contains("充电宝") || text.contains("快充") ||
            text.contains("电量") || text.contains("转接头") || text.contains("数据线") {
            return "charging"
        }
        if text.contains("扫") || text.contains("清洁") || text.contains("擦拭") || text.contains("断舍离") ||
            text.contains("关窗") || text.contains("燃气") || text.contains("拔下") || text.contains("插头") ||
            text.contains("油烟机") || text.contains("除螨") || text.contains("洗晒") {
            return "housework"
        }
        if text.contains("车") || text.contains("胎压") || text.contains("机油") || text.contains("刹车") ||
            text.contains("玻璃水") || text.contains("自驾") || text.contains("高速") || text.contains("补能") ||
            text.contains("保养") {
            return "vehicleCare"
        }
        if text.contains("生日") || text.contains("蛋糕") || text.contains("鲜花") || text.contains("纪念日") ||
            text.contains("庆祝") || text.contains("礼物") {
            return "anniversary"
        }
        if text.contains("缴费") || text.contains("结清") || text.contains("账单") || text.contains("宽带") ||
            text.contains("押金") || text.contains("退押") {
            return "bill"
        }
        if text.contains("周报") || text.contains("月报") || text.contains("汇报") || text.contains("评审") ||
            text.contains("立项") || text.contains("述职") || text.contains("加班") || text.contains("绩效") {
            return "work"
        }
        if text.contains("会议") || text.contains("模拟") || text.contains("演练") || text.contains("演讲") ||
            text.contains("试讲") || text.contains("约好") || text.contains("通知") || text.contains("答辩") ||
            text.contains("聚会") {
            return "event"
        }
        if text.contains("复习") || text.contains("真题") || text.contains("背诵") || text.contains("模拟题") ||
            text.contains("考点") || text.contains("学习") || text.contains("练习") || text.contains("冲刺") {
            return "skillLearning"
        }
        return "general"
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}
