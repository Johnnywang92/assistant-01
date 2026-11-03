import Foundation

// MARK: - 心理健康自评量表定义（纯逻辑下沉 Core）
//
// 为什么要下沉到 Core：量表题面、计分规则、分档阈值与危机路由是整个功能的安全底座。
// app target 没有测试 scheme，写在 app 里的判定逻辑等于没有防线。
//
// ## 授权状态（2026-11-02 核实，不要凭印象改）
//
// - **PHQ-9 / GAD-7：可用。** 2010 年起由 Pfizer 释放进公有领域，
//   可自由复制、翻译、展示、分发，**含商业软件内**，无需许可或付费。
// - **DASS-21：不得用于本项目。** UNSW 明令：DASS 可用于临床与研究，
//   但**禁止用于面向公众的 App/网站**，且**禁止向受测者自动解读分数**
//   （原话：misleading and potentially dangerous）。本项目的形态恰好是
//   「给 App 用户自动出分并给建议」，正落在被禁用法上。
//
// ## 三条不可违反的规则
//
// 1. **题面逐字采用官方中文版原文**，不改写、不合并、不删减、不调换顺序。
//    改一个字，量表的效度就不再成立——这不是文案偏好，是测量工具的契约。
// 2. **阈值必须用中文人群验证值**，不要照搬西方通用值：
//    PHQ-9 一般人群 cut-off **7**（Wang 2014 上海社区 N=1045，AUC 0.92），
//    西方通用的 10 是给临床筛查用的，直接搬来会让中文用户被系统性低估。
// 3. **量表分是严重度描述符，不是诊断。** Core 只产出结构化事实，
//    「这算不算抑郁」这种判定不在本文件的能力范围内，也不该有。
//
// ## 缺失数据（CASRAI 实施指南明确点名）
//
// 「空白静默按 0 计」是量表实施里的经典失败模式：分母不变、分子少算，
// 总分被系统性低估，而用户以为自己是「有点低分」。
// 因此本文件的作答状态用**显式枚举**表达，`unanswered` 永远不等于 0 分。

// MARK: - 量表标识

/// 已纳入的心理健康自评量表。
public enum PsychScaleID: String, CaseIterable, Sendable, Codable, Identifiable {
    /// 抑郁症状自评量表（Patient Health Questionnaire-9）。
    case phq9
    /// 广泛性焦虑自评量表（Generalized Anxiety Disorder-7）。
    case gad7

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .phq9: return "PHQ-9"
        case .gad7: return "GAD-7"
        }
    }

    /// 量表中文名（用于 UI 副标题）。
    public var chineseName: String {
        switch self {
        case .phq9: return "抑郁症状自评量表"
        case .gad7: return "广泛性焦虑自评量表"
        }
    }

    /// 回忆窗。PHQ-9 与 GAD-7 均为「过去两周」，不可改。
    public var recallWindowDays: Int {
        switch self {
        case .phq9, .gad7: return 14
        }
    }

    /// 该量表是否含**需要独立路由**的安全题（自伤意念）。
    ///
    /// PHQ-9 第 9 题命中即触发危机响应，**不等总分过线**——
    /// 总分制会把「只有第 9 题非零、总分仍低」的情况判成正常，
    /// 而这正是最不能漏判的一种。
    public var hasIndependentSafetyItem: Bool {
        switch self {
        case .phq9: return true
        case .gad7: return false
        }
    }
}

// MARK: - 题目与选项

/// 单题定义。
public struct PsychScaleItem: Equatable, Sendable, Codable {
    /// 题号，从 1 开始。
    public let index: Int
    /// 题面原文。**逐字采用官方中文版，不得改写。**
    public let prompt: String
    /// 该题是否为需要独立路由的安全题（仅 PHQ-9 第 9 题为 true）。
    public let isSafetyItem: Bool

    public init(index: Int, prompt: String, isSafetyItem: Bool = false) {
        self.index = index
        self.prompt = prompt
        self.isSafetyItem = isSafetyItem
    }
}

/// 量表定义：题面、计分规则与分档阈值。
public struct PsychScaleDefinition: Equatable, Sendable, Codable {
    public let id: PsychScaleID
    public let items: [PsychScaleItem]
    /// 单题最高分（当前所有纳入量表均为 3）。
    public let maxItemScore: Int
    /// 满分总分。
    public let maxTotalScore: Int
    /// 达到该分即视为**筛查阳性**，应提示用户考虑专业支持。
    /// 取中文人群验证值，见文件头规则 2。
    public let screeningCutoff: Int
    /// 分档描述。分数是严重度描述符，不是诊断。
    public let bands: [PsychScoreBand]

    public init(
        id: PsychScaleID,
        items: [PsychScaleItem],
        maxItemScore: Int,
        maxTotalScore: Int,
        screeningCutoff: Int,
        bands: [PsychScoreBand]
    ) {
        self.id = id
        self.items = items
        self.maxItemScore = maxItemScore
        self.maxTotalScore = maxTotalScore
        self.screeningCutoff = screeningCutoff
        self.bands = bands
    }

    /// 题目数。
    public var itemCount: Int { items.count }

    /// 某题号的题目定义。
    public func item(at index: Int) -> PsychScaleItem? {
        items.first { $0.index == index }
    }

    /// 需要独立路由的安全题（若有）。
    public var safetyItem: PsychScaleItem? {
        items.first { $0.isSafetyItem }
    }

    /// 给定总分所属的分档。
    public func band(forTotal total: Int) -> PsychScoreBand? {
        bands.first { total >= $0.lowerBound && total <= $0.upperBound }
    }
}

/// 分数分档。
public struct PsychScoreBand: Equatable, Sendable, Codable {
    /// 分档标识。
    public let level: PsychBandLevel
    /// 下界（含）。
    public let lowerBound: Int
    /// 上界（含）。
    public let upperBound: Int

    public init(level: PsychBandLevel, lowerBound: Int, upperBound: Int) {
        self.level = level
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

/// 分档等级。
public enum PsychBandLevel: String, CaseIterable, Sendable, Codable {
    /// 无明显症状。
    case none
    /// 轻度。
    case mild
    /// 中度。
    case moderate
    /// 中重度。
    case moderatelySevere
    /// 重度。
    case severe

    /// 中文档位名。措辞刻意避免「抑郁」「焦虑症」等疾病名——
    /// 量表测的是症状频率，不是诊断。
    public var displayName: String {
        switch self {
        case .none: return "无明显症状"
        case .mild: return "轻度"
        case .moderate: return "中度"
        case .moderatelySevere: return "中重度"
        case .severe: return "重度"
        }
    }

    /// 该档位对应的处置强度。分档是分流，不是贴标签。
    public var supportLevel: PsychSupportLevel {
        switch self {
        case .none: return .monitor
        case .mild: return .selfCare
        case .moderate: return .selfCare
        case .moderatelySevere: return .professional
        case .severe: return .professional
        }
    }
}

/// 处置强度。决定给多重的干预——**分档的真正用途**。
public enum PsychSupportLevel: String, Comparable, Sendable, Codable {
    /// 只记录，不打扰。
    case monitor
    /// 轻量自助疏解。
    case selfCare
    /// 建议专业支持。
    case professional

    private var order: Int {
        switch self {
        case .monitor: return 0
        case .selfCare: return 1
        case .professional: return 2
        }
    }

    public static func < (lhs: PsychSupportLevel, rhs: PsychSupportLevel) -> Bool {
        lhs.order < rhs.order
    }
}

// MARK: - 作答状态

/// 单题作答状态。
///
/// 用显式枚举而非 `Int?`，是为了让「没答」在类型层面就与「答了但得 0 分」分开——
/// 后者是一个真实答案（完全不会），前者是缺失数据。二者混为一谈会让总分被低估。
public enum PsychItemAnswer: Equatable, Sendable, Codable {
    /// 未作答。**不计入总分，绝不按 0 计。**
    case unanswered
    /// 已作答，分值 0...maxItemScore。
    case answered(score: Int)

    /// 该题得分；未作答返回 nil（调用方须显式处理缺失，不得默认 0）。
    public var score: Int? {
        switch self {
        case .unanswered: return nil
        case .answered(let value): return value
        }
    }

    public var isAnswered: Bool {
        if case .answered = self { return true }
        return false
    }
}

// MARK: - 量表目录

/// 量表目录：内置量表的唯一定义处。
public enum PsychScaleCatalog {

    /// PHQ-9 抑郁症状自评量表。
    ///
    /// 题面逐字采用官方中文版（题序与英文原版完全对齐）。
    public static let phq9 = PsychScaleDefinition(
        id: .phq9,
        items: [
            PsychScaleItem(index: 1, prompt: "做事时提不起劲或没有兴趣"),
            PsychScaleItem(index: 2, prompt: "感到心情低落、沮丧或绝望"),
            PsychScaleItem(index: 3, prompt: "入睡困难、睡不安稳或睡眠过多"),
            PsychScaleItem(index: 4, prompt: "感觉疲倦或没有活力"),
            PsychScaleItem(index: 5, prompt: "食欲不振或吃太多"),
            PsychScaleItem(index: 6, prompt: "觉得自己很糟或觉得自己很失败，或让自己或家人失望"),
            PsychScaleItem(index: 7, prompt: "对事物专注有困难，例如看报纸或看电视时"),
            PsychScaleItem(index: 8, prompt: "动作或说话速度缓慢到别人已经察觉，或刚好相反——烦躁或坐立不安，动来动去的情况更胜于平常"),
            // 第 9 题：自伤意念。独立路由，命中即触发危机响应。
            PsychScaleItem(index: 9, prompt: "有不如死掉或用某种方式伤害自己的念头", isSafetyItem: true)
        ],
        maxItemScore: 3,
        maxTotalScore: 27,
        // 中文一般人群 cut-off 7（Wang et al. 2014），非西方通用的 10。
        screeningCutoff: 7,
        bands: [
            PsychScoreBand(level: .none, lowerBound: 0, upperBound: 4),
            PsychScoreBand(level: .mild, lowerBound: 5, upperBound: 9),
            PsychScoreBand(level: .moderate, lowerBound: 10, upperBound: 14),
            PsychScoreBand(level: .moderatelySevere, lowerBound: 15, upperBound: 19),
            PsychScoreBand(level: .severe, lowerBound: 20, upperBound: 27)
        ]
    )

    /// GAD-7 广泛性焦虑自评量表。
    public static let gad7 = PsychScaleDefinition(
        id: .gad7,
        items: [
            PsychScaleItem(index: 1, prompt: "感觉紧张、焦虑或急切"),
            PsychScaleItem(index: 2, prompt: "不能够停止或控制担忧"),
            PsychScaleItem(index: 3, prompt: "对各种各样的事情担忧过多"),
            PsychScaleItem(index: 4, prompt: "很难放松下来"),
            PsychScaleItem(index: 5, prompt: "由于不安而无法静坐"),
            PsychScaleItem(index: 6, prompt: "变得容易烦恼或急躁"),
            PsychScaleItem(index: 7, prompt: "感到似乎将有可怕的事情发生而害怕")
        ],
        maxItemScore: 3,
        maxTotalScore: 21,
        screeningCutoff: 10,
        bands: [
            PsychScoreBand(level: .none, lowerBound: 0, upperBound: 4),
            PsychScoreBand(level: .mild, lowerBound: 5, upperBound: 9),
            PsychScoreBand(level: .moderate, lowerBound: 10, upperBound: 14),
            PsychScoreBand(level: .severe, lowerBound: 15, upperBound: 21)
        ]
    )

    /// 按标识取量表定义。
    public static func definition(for id: PsychScaleID) -> PsychScaleDefinition {
        switch id {
        case .phq9: return phq9
        case .gad7: return gad7
        }
    }

    /// 全部量表。
    public static var all: [PsychScaleDefinition] { [phq9, gad7] }
}

// MARK: - 作答选项

/// 单题作答选项（频率锚点）。
public struct PsychResponseOption: Equatable, Sendable, Codable, Identifiable {
    public let score: Int
    public let label: String

    public var id: Int { score }

    public init(score: Int, label: String) {
        self.score = score
        self.label = label
    }
}

/// 量表统一使用的频率选项（0~3），逐字采用官方中文版锚点。
public enum PsychResponseOptions {
    /// 四个频率锚点，PHQ-9 与 GAD-7 一致。
    public static let standard: [PsychResponseOption] = [
        PsychResponseOption(score: 0, label: "完全不会"),
        PsychResponseOption(score: 1, label: "好几天"),
        PsychResponseOption(score: 2, label: "一半以上的天数"),
        PsychResponseOption(score: 3, label: "几乎每天")
    ]
}
