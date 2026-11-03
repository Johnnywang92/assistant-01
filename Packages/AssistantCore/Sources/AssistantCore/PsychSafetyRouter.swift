import Foundation

// MARK: - 心理危机识别与求助路径（纯逻辑下沉 Core）
//
// 为什么要下沉到 Core：**这是整个功能里唯一「错了会出人命」的一段**，
// 绝不能只存在于 app target 里靠人肉点测。它必须能被单元测试钉死。
//
// ## 三条铁律
//
// 1. **安全题独立于总分路由。** PHQ-9 第 9 题（自伤意念）只要有非零作答，
//    就立刻触发危机响应——**不等总分过线**。
//    总分制会把「只有第 9 题非零、其余题都低」的情况判成「轻度」，
//    而这恰恰是最不能漏判的一种：用户其余症状轻，可能因此不觉得自己需要帮助，
//    也因此不去求助。
//
// 2. **数据不足不能压掉告警。** 即使其余 8 题全未作答，
//    只要第 9 题答了非零，危机响应必须触发。
//    「数据不足所以先不算」在这里不可接受——那正是最需要被看见的时刻。
//
// 3. **App 不是唯一出口。** 任何危机响应都必须给出线下/人工求助路径，
//    且热线号码取官方统一号码，不用民间流传的号码。
//    12356 是国家卫健委 2025-05-01 起全国开通的统一心理援助热线
//    （24 小时 · 免费 · 保密）。

// MARK: - 危机信号

/// 危机信号强度。
public enum PsychSafetySignal: String, Comparable, Sendable, Codable {
    /// 未检测到危机信号。
    case none
    /// 检测到自伤/轻生意念信号。
    case selfHarmIdeation

    private var order: Int {
        switch self {
        case .none: return 0
        case .selfHarmIdeation: return 1
        }
    }

    public static func < (lhs: PsychSafetySignal, rhs: PsychSafetySignal) -> Bool {
        lhs.order < rhs.order
    }

    /// 是否需要展示危机响应。
    public var requiresCrisisResponse: Bool { self != .none }
}

// MARK: - 求助资源

/// 一条求助资源。
public struct PsychHelpResource: Equatable, Sendable, Codable, Identifiable {
    public let id: String
    /// 标题。
    public let title: String
    /// 详情描述。
    public let detail: String
    /// 号码（可拨打）。为空表示非电话类资源。
    public let phoneNumber: String?
    /// 是否为官方统一热线。
    public let isOfficialHotline: Bool

    public init(id: String, title: String, detail: String, phoneNumber: String?, isOfficialHotline: Bool) {
        self.id = id
        self.title = title
        self.detail = detail
        self.phoneNumber = phoneNumber
        self.isOfficialHotline = isOfficialHotline
    }
}

/// 求助资源目录。
public enum PsychHelpResources {

    /// 全国统一心理援助热线。24 小时 · 免费 · 保密。
    ///
    /// 国家卫健委 2025-05-01 起全国开通，取代各地分散号码。
    /// **不要改用其他号码**——民间流传的热线存在接通率与规范性差异。
    public static let nationalHotline = PsychHelpResource(
        id: "hotline.12356",
        title: "12356 全国心理援助热线",
        detail: "24 小时 · 免费 · 保密。国家卫健委统一心理援助热线，可匿名倾诉。",
        phoneNumber: "12356",
        isOfficialHotline: true
    )

    /// 急救电话。用于有即刻生命危险的情形。
    public static let emergency = PsychHelpResource(
        id: "emergency.120",
        title: "120 急救",
        detail: "如果已经出现伤害自己的行为或处于即刻危险中，请立即拨打 120，或让身边的人陪在身边。",
        phoneNumber: "120",
        isOfficialHotline: true
    )

    /// 危机响应时展示的全部资源，按优先级排序。
    public static var crisisResources: [PsychHelpResource] {
        [nationalHotline, emergency]
    }
}

// MARK: - 危机路由

/// 危机路由器。
public enum PsychSafetyRouter {

    /// 从一份计分结果中检测危机信号。
    ///
    /// **只看安全题本身，绝不看总分。**
    ///
    /// - Parameters:
    ///   - score: 量表计分结果。
    ///   - definition: 量表定义，缺省按 score.scaleID 取内置量表。
    /// - Returns: 危机信号。
    public static func detectSignal(
        in score: PsychScaleScore,
        definition: PsychScaleDefinition? = nil
    ) -> PsychSafetySignal {
        let def = definition ?? PsychScaleCatalog.definition(for: score.scaleID)
        guard let safetyItem = def.safetyItem else { return .none }
        guard let itemScore = score.itemScores[safetyItem.index] else { return .none }
        // 非零即触发。哪怕总分只有 1 分、其余题全 0。
        return itemScore > 0 ? .selfHarmIdeation : .none
    }

    /// 从原始作答直接检测危机信号（不经过计分器）。
    ///
    /// 供「提交后立刻判定」的场景使用——这样即使计分因数据不足而失败，
    /// 危机信号依然独立成立（铁律 2）。
    public static func detectSignal(
        answers: [Int: PsychItemAnswer],
        definition: PsychScaleDefinition
    ) -> PsychSafetySignal {
        guard let safetyItem = definition.safetyItem else { return .none }
        guard let answer = answers[safetyItem.index], let value = answer.score else { return .none }
        return value > 0 ? .selfHarmIdeation : .none
    }

    /// 该量表本次作答是否需要展示危机响应。
    public static func requiresCrisisResponse(
        answers: [Int: PsychItemAnswer],
        definition: PsychScaleDefinition
    ) -> Bool {
        detectSignal(answers: answers, definition: definition).requiresCrisisResponse
    }
}
