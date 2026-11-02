import Foundation

/// 用户生活方式与作息身份。
/// 下沉自 Assistant/Services/SituationalContextEngine.swift：枚举本体只含纯数据，
/// 依赖 L10n 的展示名 `shortTitle` 留在 app 侧扩展里（与 `TodoRecurrenceRule` 同口径）。
///
/// **rawValue 已持久化**在 UserDefaults 的 `user_lifestyle_profile` 里，
/// 语音向导也按 `"\(profile)"` 的 case 名回收选项，两边都不能改名。
public enum UserLifestyleProfile: String, CaseIterable, Identifiable, Codable {
    case officeWorker = "上班族 (周一至周五通勤)"
    case flexible = "自由职业 / 弹性作息"
    case student = "学生 (周中上课/周末假期)"

    public var id: String { rawValue }
}
