import AssistantCore
import Foundation
import SwiftUI

/// 应用语言偏好选项
public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system:
            return L10n.isEnglish ? "Follow System" : "跟随系统"
        case .zhHans:
            return "简体中文"
        case .en:
            return "English"
        }
    }

    public var subtitle: String {
        switch self {
        case .system:
            return L10n.isEnglish
                ? "Automatically match your iPhone's system language"
                : "自动跟随 iPhone 系统语言（支持简体中文与英文）"
        case .zhHans:
            return L10n.isEnglish
                ? "Display interface and voice assistant in Simplified Chinese"
                : "界面、通知与语音助手使用简体中文"
        case .en:
            return L10n.isEnglish
                ? "Display interface and voice assistant in English"
                : "界面、通知与语音助手使用英文 (English)"
        }
    }

    public var icon: String {
        switch self {
        case .system: return "iphone.gen3"
        case .zhHans: return "character.bubble.fill"
        case .en: return "a.square.fill"
        }
    }
}

/// 全局多语言与本地化状态管理器
@MainActor
public final class LanguageManager: ObservableObject {
    public static let shared = LanguageManager()

    public nonisolated static let storageKey = AssistantSettingsKeys.languagePreference

    @Published public var selectedLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: Self.storageKey)
            L10n.syncLanguageCache(selectedLanguage)
            switch selectedLanguage {
            case .system:
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            case .zhHans:
                UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
            case .en:
                UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
            }
            NavigationRouter.shared.registerDynamicShortcuts()
        }
    }

    public var effectiveLanguageCode: String {
        L10n.effectiveLanguageCode(for: selectedLanguage)
    }

    public var isEnglish: Bool {
        effectiveLanguageCode == "en"
    }

    public var locale: Locale {
        Locale(identifier: effectiveLanguageCode == "en" ? "en_US" : "zh_CN")
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppLanguage.system.rawValue
        let initial = AppLanguage(rawValue: raw) ?? .system
        self.selectedLanguage = initial
        L10n.syncLanguageCache(initial)
    }
}

/// 跨线程安全的轻量级本地化查询工具
public enum L10n {
    private static let lock = NSLock()
    private static var cachedLanguageCode: String = {
        let raw = UserDefaults.standard.string(forKey: LanguageManager.storageKey) ?? AppLanguage.system.rawValue
        let pref = AppLanguage(rawValue: raw) ?? .system
        return effectiveLanguageCode(for: pref)
    }()

    private static let enBundle: Bundle? = {
        if let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return nil
    }()

    public static func effectiveLanguageCode(for preference: AppLanguage) -> String {
        switch preference {
        case .en:
            return "en"
        case .zhHans:
            return "zh-Hans"
        case .system:
            // 优先从全局域读取 iOS 系统级 AppleLanguages（不受本 App UserDefaults 覆盖影响）
            if let globalLangs = CFPreferencesCopyValue(
                "AppleLanguages" as CFString,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            ) as? [String],
               let first = globalLangs.first?.lowercased() {
                return first.hasPrefix("en") ? "en" : "zh-Hans"
            }
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "zh-hans"
            if preferred.hasPrefix("en") {
                return "en"
            }
            return "zh-Hans"
        }
    }

    public static func syncLanguageCache(_ preference: AppLanguage) {
        let code = effectiveLanguageCode(for: preference)
        lock.lock()
        cachedLanguageCode = code
        lock.unlock()
    }

    public static var currentLanguageCode: String {
        lock.lock()
        defer { lock.unlock() }
        return cachedLanguageCode
    }

    public static var isEnglish: Bool {
        currentLanguageCode == "en"
    }

    public static var locale: Locale {
        Locale(identifier: isEnglish ? "en_US" : "zh_CN")
    }

    public static var speechLocaleIdentifier: String {
        isEnglish ? "en-US" : "zh-CN"
    }

    public static func choose(_ zh: String, _ en: String) -> String {
        isEnglish ? en : zh
    }

    /// 将中文键名或动态文本转换为当前语言文本
    public static func tr(_ key: String) -> String {
        guard isEnglish, !key.isEmpty else { return key }

        if let bundle = enBundle {
            let localized = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            if localized != key {
                return localized
            }
        }

        let locVal = String.LocalizationValue(stringLiteral: key)
        let catalogVal = String(localized: locVal, table: "Localizable", bundle: .main, locale: Locale(identifier: "en"))
        if catalogVal != key {
            return catalogVal
        }

        if let dynamic = translateDynamic(key) {
            return dynamic
        }

        return key
    }

    /// 针对运行时拼接/插值字符串的动态模式翻译兜底
    private static func translateDynamic(_ text: String) -> String? {        // 1. 常见前缀/后缀动态拼接
        if text.hasPrefix("称呼：") {
            let val = String(text.dropFirst(3))
            return "Title: \(tr(val))"
        }
        if text.hasPrefix("语音备忘 ") {
            let rest = String(text.dropFirst(5))
            return "Voice Memo \(rest)"
        }
        if text.hasPrefix("失败：") {
            return "Failed: \(text.dropFirst(3))"
        }
        if text.hasPrefix("已添加：") {
            return "Added: \(text.dropFirst(4))"
        }
        if text.hasPrefix("取件码：") {
            return "Pickup Code: \(text.dropFirst(4))"
        }
        if text.hasPrefix("取件码: ") {
            return "Pickup Code: \(text.dropFirst(5))"
        }
        if text.hasPrefix("核销码：") {
            return "Redeem Code: \(text.dropFirst(4))"
        }
        if text.hasPrefix("码号：") {
            return "Code: \(text.dropFirst(3))"
        }
        if text.hasPrefix("存放: ") {
            return "Location: \(tr(String(text.dropFirst(4))))"
        }
        if text.hasPrefix("截止：") {
            return "Due: \(text.dropFirst(3))"
        }
        if text.hasPrefix("截止: ") {
            return "Due: \(text.dropFirst(4))"
        }
        if text.hasPrefix("复查：") {
            return "Follow-up: \(text.dropFirst(3))"
        }
        if text.hasPrefix("预防：") {
            return "Prevents: \(tr(String(text.dropFirst(3))))"
        }
        if text.hasPrefix("账号: ") {
            return "Account: \(text.dropFirst(4))"
        }
        if text.hasPrefix("日报时间：") {
            return "Daily Report: \(text.dropFirst(5))"
        }
        // 心理状态提醒：分数是运行时插值，无法作为固定 key 查表，
        // 因此走前缀兜底（从 "最近一次评估是 13 分，…" 里取出分数）。
        let psychTrendPrefix = "最近一次评估是 "
        let psychTrendSuffix = " 分，比之前高些。可能是最近的事，也可能只是没睡好 —— 值得你自己看一眼。"
        if text.hasPrefix(psychTrendPrefix) && text.hasSuffix(psychTrendSuffix) {
            let scoreText = String(text.dropFirst(psychTrendPrefix.count).dropLast(psychTrendSuffix.count))
            return "Your latest score was \(scoreText), a bit higher than before. It could be what has been going on, or just poor sleep — worth a look yourself."
        }
        // 心理趋势卡的变化文案（分数是插值）：
        // 「比上次高 3 分（最新 13 分）」/「比上次低 3 分（最新 13 分）」/「与上次持平（最新 13 分）」
        // 这类文案含两个数字，用正则一次性提取，避免手工数 dropFirst/dropLast 出错。
        if let psychDelta = PsychTrendDeltaPattern.firstMatch(in: text) {
            switch psychDelta.direction {
            case .up:
                return "Up \(psychDelta.deltaValue) points from last time (latest \(psychDelta.latestValue))"
            case .down:
                return "Down \(psychDelta.deltaValue) points from last time (latest \(psychDelta.latestValue))"
            case .flat:
                return "Unchanged from last time (latest \(psychDelta.latestValue))"
            }
        }

        // 2. 周期规则 "每X天"
        if text.hasPrefix("每") && text.hasSuffix("天") {
            let mid = text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if let days = Int(mid) {
                return days == 1 ? "Every day" : "Every \(days) days"
            }
        }

        // 2.5 心理量表相关：题号进度、预计耗时、拨打热线。
        //     都是运行时拼接的数字，查表必然失败，走前缀/后缀兜底。
        if text.hasPrefix("第 ") && text.contains(" / ") && text.hasSuffix(" 题") {
            let digits = text.dropFirst(2).prefix { $0.isNumber || $0 == " " }
            let total = text.split(separator: "/").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let totalDigits = total.prefix { $0.isNumber }
            return "Question \(digits) of \(totalDigits)"
        }
        if text.hasPrefix("约 ") && text.hasSuffix(" 分钟") {
            let minutes = text.dropFirst(2).dropLast(3).trimmingCharacters(in: .whitespaces)
            return "About \(minutes) min"
        }
        if text.hasPrefix("拨打 ") {
            let phone = text.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return "Call \(phone)"
        }

        // 3. 剩余/逾期天数
        if text.hasPrefix("剩 ") && text.hasSuffix(" 天") {
            let mid = text.dropFirst(2).dropLast(2)
            return "\(mid)d left"
        }
        if text.hasPrefix("剩余 ") && text.hasSuffix(" 天") {
            let mid = text.dropFirst(3).dropLast(2)
            return "\(mid) days left"
        }
        if text.hasPrefix("还剩 ") && text.hasSuffix(" 天") {
            let mid = text.dropFirst(3).dropLast(2)
            return "\(mid) days left"
        }
        if text.hasPrefix("已逾期 ") && text.hasSuffix(" 天") {
            let mid = text.dropFirst(4).dropLast(2)
            return "\(mid)d overdue"
        }
        if text.hasPrefix("已逾期 ") && text.hasSuffix(" 天！") {
            let mid = text.dropFirst(4).dropLast(3)
            return "\(mid)d overdue!"
        }

        // 4. 年龄描述（如 "2岁3个月", "2岁整", "8个月", "8个月大", "10天", "10天幼宠"）
        if let match = text.range(of: #"^(\d+)岁(\d+)个月$"#, options: .regularExpression) {
            let comps = text[match].components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            if comps.count == 2 {
                return "\(comps[0])y \(comps[1])m"
            }
        }
        if text.hasSuffix("岁整"), let y = Int(text.dropLast(2)) {
            return "\(y) yr\(y == 1 ? "" : "s")"
        }
        if text.hasSuffix("个月大"), let m = Int(text.dropLast(3)) {
            return "\(m) mo\(m == 1 ? "" : "s")"
        }
        if text.hasSuffix("个月"), let m = Int(text.dropLast(2)) {
            return "\(m) mo\(m == 1 ? "" : "s")"
        }
        if text.hasSuffix("天幼宠"), let d = Int(text.dropLast(3)) {
            return "\(d)d old"
        }
        if text.hasSuffix("天"), let d = Int(text.dropLast(1)) {
            return "\(d) days"
        }

        return nil
    }
}

public extension String {
    /// 返回当前语言环境下的本地化字符串
    var localized: String {
        L10n.tr(self)
    }
}

// MARK: - 心理趋势卡变化文案的正则匹配

/// 心理趋势卡「比上次高/低/持平」文案的匹配器。
///
/// 这类文案形如「比上次高 3 分（最新 13 分）」，**含两个数字**。
/// 手工用 `dropFirst`/`dropLast` 切片极易数错位数（这正是它容易出错的原因），
/// 所以用带捕获组的正则一次性把两个数字与方向都取出来。
enum PsychTrendDeltaPattern {
    /// 变化方向。
    enum Direction {
        case up
        case down
        case flat
    }

    /// 匹配结果：方向 + 两个数字。
    struct Match {
        let direction: Direction
        /// 变化量（持平时为 0）。
        let deltaValue: String
        /// 最新分数。
        let latestValue: String

        /// 取指定位置的数字（1 = 变化量，2 = 最新分）。
        func value(at index: Int) -> String? {
            switch index {
            case 1: return deltaValue
            case 2: return latestValue
            default: return nil
            }
        }
    }

    /// 匹配「比上次高 N 分（最新 M 分）」/「比上次低 N 分（最新 M 分）」/「与上次持平（最新 M 分）」。
    static func match(_ text: String) -> Match? {
        let range = NSRange(text.startIndex..., in: text)
        if let result = upPattern.firstMatch(in: text, range: range),
           let delta = capture(result, in: text, at: 1),
           let latest = capture(result, in: text, at: 2) {
            return Match(direction: .up, deltaValue: delta, latestValue: latest)
        }
        if let result = downPattern.firstMatch(in: text, range: range),
           let delta = capture(result, in: text, at: 1),
           let latest = capture(result, in: text, at: 2) {
            return Match(direction: .down, deltaValue: delta, latestValue: latest)
        }
        if let result = flatPattern.firstMatch(in: text, range: range),
           let latest = capture(result, in: text, at: 1) {
            return Match(direction: .flat, deltaValue: "0", latestValue: latest)
        }
        return nil
    }

    /// 便捷入口：匹配成功时返回指定位置的数字。
    static func firstMatch(in text: String) -> Match? {
        match(text)
    }

    private static let upPattern = try! NSRegularExpression(pattern: "^比上次高 (\\d+) 分（最新 (\\d+) 分）$")
    private static let downPattern = try! NSRegularExpression(pattern: "^比上次低 (\\d+) 分（最新 (\\d+) 分）$")
    private static let flatPattern = try! NSRegularExpression(pattern: "^与上次持平（最新 (\\d+) 分）$")

    private static func capture(_ result: NSTextCheckingResult, in text: String, at index: Int) -> String? {
        guard index < result.numberOfRanges else { return nil }
        let range = result.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return (text as NSString).substring(with: range)
    }
}
