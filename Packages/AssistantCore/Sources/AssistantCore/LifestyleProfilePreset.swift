import Foundation

/// 人群预设能改动的偏好键。
/// rawValue 就是 UserDefaults 里的键名，因此每个 case 都必须已在
/// `AssistantSettingsKeys` 白名单登记（由契约测试钉住），app 侧的差异清单
/// 用 `allCases` 的顺序作展示顺序，并按 case 补本地化行名。
public enum LifestylePresetField: String, CaseIterable, Sendable, Hashable {
    /// 时间轴起床锚点（当天分钟数）
    case dayTimelineWake = "day_timeline_wake_minutes"
    /// 时间轴收工锚点（当天分钟数）
    case dayTimelineOff = "day_timeline_off_minutes"
    /// 早间天气推送时间（"HH:mm"）
    case weatherMorningPushTime = "weather_morning_push_time"
    /// 睡前提醒缓冲提前量（15/30/45 三档）
    case sleepWindDownMinutes = "sleepReminder.windDownMinutes"
    /// 睡眠目标时长（360~480，档距 30）
    case sleepGoalMinutes = "sleepReminder.sleepGoalMinutes"
    /// 安心花消费节奏
    case spendingRhythmMode = "safe_to_spend_rhythm_mode"
}

/// 身份 → 建议写入的偏好键值。
///
/// 纯值表：不读写 UserDefaults，取当前值、摆差异清单与落笔都由 app 侧负责，
/// 所以这里既不碰 `@AppStorage`，也不碰任何 scheduler。
///
/// **只收「与该键现状默认值不同」的项。** 等于默认值的键一律不写，于是：
/// - 「上班族」档是空集——现有默认值本来就是按上班族设计的，选它没有可改的东西；
/// - 预设不会把「用户手工调回了默认值」的那一项当成改动再覆盖一遍。
///
/// 明确不收录的键，连同理由（改这些要另开批次，不是本表漏了）：
/// - `sleepReminder.desiredBedtime` / `.pseudoDesiredBedtime`：期望入睡时间是
///   「用户填的 → 否则用 HealthKit 学到的 pseudo-desired」这条链的第一位，
///   写死它等于永久取消习惯学习，用实测值换一个拍脑袋的档位值不划算。
/// - `user_off_work_minutes`：设置页只在上班族档显示它，给学生/自由职业写这个值
///   只会留下一个 UI 上看不见的键。
/// - `periodic_report_*`（各档开关与推送时间、周报星期）：只有日报在设置页有开关，
///   周报/月报/季报/年报默认关闭且没有 UI 入口，预设打开后用户无法再关掉。
/// - `expense_monthly_budget`：金额是用户事实，不是作息节奏。
/// - `expense_budget_start_day`：生活费到账日与接单结算日都是个人事实；
///   学生档「月初到账」恰好等于默认值 1，所以按上面的规则自然不进表。
public enum LifestyleProfilePreset {

    /// 某一身份档的全部建议值（键名 → 带类型的值）。
    /// 单一穷尽 switch：新增身份 case 会编译报错，不允许运行期静默拿到空表。
    public static func entries(for profile: UserLifestyleProfile) -> [String: SettingsValue] {
        var table: [LifestylePresetField: SettingsValue]
        switch profile {
        case .officeWorker:
            table = [:]

        case .student:
            table = [
                .dayTimelineWake: .int(390),                                  // 06:30 早自习（默认 07:30）
                .dayTimelineOff: .int(1320),                                  // 22:00 晚自习收尾（默认 19:00）
                .weatherMorningPushTime: .string("06:45"),                    // 起床后 15 分钟（默认 07:30）
                .sleepWindDownMinutes: .int(15),                              // 宿舍统一熄灯，长缓冲会错过（默认 30）
                .sleepGoalMinutes: .int(480)                                  // 8 小时（默认 7 小时）
            ]

        case .flexible:
            table = [
                .dayTimelineWake: .int(510),                                  // 08:30（默认 07:30）
                .dayTimelineOff: .int(1200),                                  // 20:00 弹性收工（默认 19:00）
                .weatherMorningPushTime: .string("09:00"),                    // 默认 07:30
                .sleepWindDownMinutes: .int(45),                              // 作息易漂，收工缓冲拉长（默认 30）
                .spendingRhythmMode: .string(SpendingRhythmMode.flat.rawValue) // 默认周末蓄水
            ]
        }
        return Dictionary(uniqueKeysWithValues: table.map { ($0.key.rawValue, $0.value) })
    }

    /// 某一身份档建议改动的字段，按 `allCases` 顺序（供差异清单排序用）。
    public static func fields(for profile: UserLifestyleProfile) -> [LifestylePresetField] {
        let entries = entries(for: profile)
        return LifestylePresetField.allCases.filter { entries[$0.rawValue] != nil }
    }
}
