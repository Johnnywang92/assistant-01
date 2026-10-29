import Foundation

/// 偏好设置的单个值。
/// UserDefaults 里 Bool / Double / Int 底层都是 NSNumber，不显记录类型的话，
/// 还原时会把 `true` 写成 `1.0`、把 `8.0` 写成 `8`——外观模糊度、推送时间这类
/// Double 键会被悄悄取整，预算阈值会被塞成整数，因此备份必须带类型。
public enum SettingsValue: Codable, Hashable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case data(Data)
}

/// 用户偏好设置快照（备份 / 迁移用）。
/// **收录原则：只收「用户明确表达过的偏好」。** 以下一律不进备份：
/// - 安全材料：应用锁 PIN 哈希、密码库内容、LLM 远程上下文同意
///   （隐私同意不能替用户搬到新设备，须在新设备上重新明确）
/// - 设备本地缓存与一次性状态：天气缓存、当前城市缓存、剪贴板已处理计数、
///   权限引导完成标记、各审计器的「今日已处理」日期
/// - 局域网地址：LLM 开发者端点（换网络即失效）
public struct SettingsSnapshotDTO: Codable, Hashable {
    /// 偏好键 -> 值。键名来自 `AssistantSettingsKeys` 白名单，未登记的键不会出现。
    public var entries: [String: SettingsValue]
    /// 自定义壁纸图片字节（背景样式为自定义照片时才有意义）
    public var wallpaperImageData: Data?

    public init(entries: [String: SettingsValue], wallpaperImageData: Data? = nil) {
        self.entries = entries
        self.wallpaperImageData = wallpaperImageData
    }

    /// 还原进 UserDefaults（调用方负责之后让各单例重载）
    public func apply(to defaults: UserDefaults) {
        for (key, value) in entries {
            switch value {
            case .string(let text): defaults.set(text, forKey: key)
            case .bool(let flag): defaults.set(flag, forKey: key)
            case .int(let number): defaults.set(number, forKey: key)
            case .double(let number): defaults.set(number, forKey: key)
            case .data(let data): defaults.set(data, forKey: key)
            }
        }
    }

    /// 快照内的项数（含壁纸，便于备份摘要展示）
    public var itemCount: Int {
        entries.count + (wallpaperImageData != nil ? 1 : 0)
    }
}

/// 参与备份的偏好键白名单。
/// **新增用户偏好时在此登记**——白名单而非全量导出的原因：UserDefaults 里混着
/// 安全材料与设备缓存，必须逐键过审。
/// 「漏登记只是不进备份、不会报错」这条静默路径已由 `scripts/check_settings_keys.py` 堵上：
/// 代码里出现的每个 UserDefaults 键必须在本白名单或闸门的豁免清单里，否则 ci 直接失败。
public enum AssistantSettingsKeys {
    /// 语言偏好键。`LanguageManager.storageKey` 也指向它，保证单一出处。
    public static let languagePreference = "app_language_preference"

    public static let stringKeys: [String] = [
        "assistant_custom_name",               // 助手名称
        "user_preferred_title",                // 对用户的称呼
        "assistant_mode",                      // 运行模式
        "dialogue_retention_policy",           // 对话保留策略
        "app_background_style",                // 背景主题
        languagePreference,                    // 界面语言
        "user_lifestyle_profile",              // 生活节奏画像
        "senior_font_scale_level",             // 长辈模式字号
        "departure_selected_scene_raw",        // 上次选择的出门场景
        "safe_to_spend_rhythm_mode",           // 安心花节奏模式
        "sleepReminder.desiredBedtime",        // 期望入睡时间 HH:mm
        "sleepReminder.pseudoDesiredBedtime",  // 由作息推算出的入睡时间
        ExpenseCurrency.preferredCurrencyKey   // 记账默认币种（出国游偏好）
    ]

    public static let boolKeys: [String] = [
        "voice_reply_enabled",                     // 语音朗读回答
        "todo_notification_show_sensitive_details", // 通知显示敏感详情
        "clipboard_auto_ingest_enabled",           // 剪贴板自动摄取
        "senior_mode_enabled",                     // 长辈模式
        "senior_high_contrast",                    // 高对比度
        "senior_voice_broadcast",                  // 语音播报
        "senior_large_touch_targets",              // 大点击区域
        "context_adaptive_sorting_enabled",        // 情境自适应排序
        "periodic_report_daily_enabled",           // 日报开关
        "periodic_report_weekly_enabled",          // 周报开关
        "periodic_report_monthly_enabled",         // 月报开关
        "periodic_report_quarterly_enabled",       // 季报开关
        "periodic_report_yearly_enabled",          // 年报开关
        "floating_voice_enabled",                  // 悬浮语音球
        "weather_alerts_enabled",                  // 天气预警
        "all_tab_grouping_mode",                   // 待办「全部」按类型分组
        "learnedPlacesEnabled",                    // 常用地点感知
        "voice_memo_auto_transcribe",              // 语音备忘自动转写
        "voice_use_llm_engine",                    // 语音对话用 LLM 引擎
        "sleepReminder.enabled",                   // 睡前提醒总开关
        "life_vault_card_dynamic_sort_enabled_v2"  // 人生档案卡片按使用频率排序
    ]

    public static let intKeys: [String] = [
        "user_off_work_minutes",                  // 下班时间（分钟）
        "periodic_report_weekly_weekday",         // 周报星期
        "day_timeline_wake_minutes",              // 日程轴起床时间（分钟）
        "day_timeline_off_minutes",               // 日程轴下班时间（分钟）
        "omnibox_auto_dismiss_seconds",           // 投喂口执行后自动关闭
        "omnibox_clipboard_auto_dismiss_seconds", // 投喂口剪贴板自动关闭
        "sleepReminder.windDownMinutes",          // 睡前缓冲提前量
        "sleepReminder.sleepGoalMinutes"          // 睡眠目标时长
    ]

    public static let doubleKeys: [String] = [
        "lowDataThresholdMB",                    // 流量预警阈值
        "expense_monthly_budget",                // 月度预算
        "app_background_blur",                   // 背景模糊度
        "app_background_dim",                    // 背景压暗
        "periodic_report_daily_time_interval",   // 日报推送时间
        "periodic_report_weekly_time_interval",  // 周报推送时间
        "periodic_report_monthly_time_interval", // 月报推送时间
        "periodic_report_quarterly_time_interval", // 季报推送时间
        "periodic_report_yearly_time_interval",  // 年报推送时间
        // 场景选择的「上次选择时间」——与已登记的 departure_selected_scene_raw 成对：
        // 只迁移 raw 不迁移时间戳会让还原后的场景被当成不是今天选的（见 SituationalContextEngine 的当日判定）。
        "departure_selected_scene_timestamp",
        "daily_water_goal_ml",                   // 每日纯水目标
        "intent_threshold_min_top",              // 判别阈值校准覆盖 · top1 下限
        "intent_threshold_min_margin"            // 判别阈值校准覆盖 · 与次选最小差
    ] + ExpenseCurrency.allCases.filter { $0 != .cny }.map(\.customRateDefaultsKey)  // gate:dynamic_regex expense_exchange_rate_[A-Z]{3}

    /// Data 型：JSON 编码的偏好（首页 Tab 顺序、类别顺序等），还原时按 Data 原样写回
    public static let dataKeys: [String] = [
        "custom_home_tabs_order_v1",
        // 待办首页的类别排序同样是用户手动排的，与上面的 Tab 顺序同性质
        "todo_home_category_order_v1",
        // 人生档案卡片的自定义顺序
        "life_vault_card_custom_order_v2",
        // 周期记账的定义表。它本该是 SwiftData 里的一张表，现状存在 UserDefaults；
        // 不登记的话备份还原会把用户自己加的周期项整张丢掉，所以先收进白名单止血。
        "recurring_expenses_data_v1"
    ]

    /// 全部白名单键（去重后）
    public static var allKeys: [String] {
        Array(Set(stringKeys + boolKeys + intKeys + doubleKeys + dataKeys)).sorted()
    }
}
