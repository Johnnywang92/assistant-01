import Foundation

// MARK: - 投喂口意图判别层（纯逻辑，下沉 AssistantCore 便于测试覆盖）
//
// 设计取舍：不复用「让模型直接写 JSON 动作」的生成式路径，而是在其前面插一层
// 只做分类的判别器。判别器读最后一个 token 的 logits，在固定标签集上做 softmax，
// 得到**真实概率分布**——这是生成式路径拿不到的（那条路上confidence 是硬编码常量）。
//
// 分类只做路由，参数抽取（金额/日期/目标待办名）仍交给后续 LLM：
// 判别式能把 16 类选对，但抽不出「花了多少钱」。

/// 判别层的固定标签集。每个 case 的 token 必须能**单 token 化**且互不相同，
/// 否则无法直接从 logits 读取分布（见 `init(tokens:)` 的校验）。
public enum OmniboxIntentLabel: String, CaseIterable, Sendable {
    case expenseCreate = "0"
    case expenseUpdate = "1"
    case todoCreate = "2"
    case todoUpdate = "3"
    case todoComplete = "4"
    case todoCancel = "5"
    case reminderSnooze = "6"
    case queryLookup = "7"
    case memoInbox = "8"
    case foodRecord = "9"
    case waterRecord = "A"
    case storageRecord = "B"
    case habitLog = "C"
    case anniversaryCreate = "D"
    case departureAdd = "E"
    case lifeRecord = "F"

    /// 该标签对应的动作能力。收集箱是判别层的兜底类别，不是解析失败。
    public var capability: ActionCapability {
        switch self {
        case .expenseCreate: return .expenseCreate
        case .expenseUpdate: return .expenseUpdate
        case .todoCreate: return .todoCreate
        case .todoUpdate: return .todoUpdate
        case .todoComplete: return .todoComplete
        case .todoCancel: return .todoCancel
        case .reminderSnooze: return .reminderSnooze
        case .queryLookup: return .queryLookup
        case .memoInbox: return .memoInbox
        case .foodRecord: return .foodRecord
        case .waterRecord: return .waterRecord
        case .storageRecord: return .storageRecord
        case .habitLog: return .habitLog
        case .anniversaryCreate: return .anniversaryCreate
        case .departureAdd: return .departureAdd
        case .lifeRecord: return .lifeRecord
        }
    }

    /// 中文释义，仅用于构造提示词与调试展示。
    public var displayName: String {
        switch self {
        case .expenseCreate: return "记账"
        case .expenseUpdate: return "修改账目"
        case .todoCreate: return "新建待办"
        case .todoUpdate: return "修改待办"
        case .todoComplete: return "完成待办"
        case .todoCancel: return "取消待办"
        case .reminderSnooze: return "推迟提醒"
        case .queryLookup: return "查询事项"
        case .memoInbox: return "收入收集箱"
        case .foodRecord: return "记录饮食"
        case .waterRecord: return "记录饮水"
        case .storageRecord: return "物品收纳"
        case .habitLog: return "习惯与服药打卡"
        case .anniversaryCreate: return "纪念日与到期"
        case .departureAdd: return "出门清单"
        case .lifeRecord: return "生活档案"
        }
    }

    /// 标签集在提示词里的一行说明。
    public static let promptLegend: String = {
        allCases.map { "\($0.rawValue)=\($0.displayName)" }.joined(separator: " ")
    }()
}

/// 标签 → token id 的映射。仅当所有标签都能单token 化且无碰撞时才有效。
public struct IntentTokenMap: Equatable, Sendable {
    public let tokens: [OmniboxIntentLabel: Int]

    public init(tokens: [OmniboxIntentLabel: Int]) {
        self.tokens = tokens
    }

    /// 由引擎侧分词结果构造。任一标签不是单 token、或出现 token 碰撞时返回 nil，
    /// 调用方据此降级（宁可不判别，也不要给出错误的分布）。
    public init?(tokenizing labels: [OmniboxIntentLabel], with tokenizer: (OmniboxIntentLabel) -> [Int]?) {
        var map: [OmniboxIntentLabel: Int] = [:]
        var seen: [Int: OmniboxIntentLabel] = [:]
        for label in labels {
            guard let ids = tokenizer(label), ids.count == 1 else { return nil }
            let id = ids[0]
            guard seen[id] == nil else { return nil }
            seen[id] = label
            map[label] = id
        }
        guard map.count == labels.count else { return nil }
        self.tokens = map
    }

    public var labels: [OmniboxIntentLabel] { Array(tokens.keys) }
}

// MARK: - 分类结果

/// 分布中的单个条目。用具名类型而非元组，才能合成 `Equatable`（元组不符合协议）。
public struct IntentScore: Equatable, Sendable {
    public let label: OmniboxIntentLabel
    public let probability: Double

    public init(label: OmniboxIntentLabel, probability: Double) {
        self.label = label
        self.probability = probability
    }
}

/// 判别层的输出：完整概率分布 + 决策结论。
public struct IntentDistribution: Equatable, Sendable {
    /// 标签 → 概率，已按概率降序。始终覆盖全部标签（未出现在 logits 中的记为 0）。
    public let ranked: [IntentScore]

    /// 决策阈值，来源见`IntentDecisionPolicy`。
    public let policy: IntentDecisionPolicy

    public var top: OmniboxIntentLabel? { ranked.first?.label }

    public var topProbability: Double { ranked.first?.probability ?? 0 }

    /// 第一名与第二名的概率差。差值小= 模型在两类之间摇摆，
    /// 比单看top1 概率更能反映「其实没分清」。
    public var margin: Double {
        guard ranked.count >= 2 else { return ranked.first?.probability ?? 0 }
        return ranked[0].probability - ranked[1].probability
    }

    public var topCapability: ActionCapability? { top?.capability }

    public func probability(of label: OmniboxIntentLabel) -> Double {
        ranked.first { $0.label == label }?.probability ?? 0
    }

    /// 是否应直接进入动作抽取。低置信时宁可落收集箱，也不要猜错后写库。
    public var shouldExtract: Bool {
        policy.accepts(topProbability: topProbability, margin: margin)
    }

    /// 置信度低于该值时，意图判别本身不可信，提示用户补充而不是硬猜。
    public var needsClarification: Bool {
        !policy.accepts(topProbability: topProbability, margin: margin)
    }

    public var reasonText: String {
        guard let top else { return "无有效标签" }
        let second = ranked.count >= 2 ? ranked[1] : nil
        let base = "\(top.displayName) \(Int((topProbability * 100).rounded()))%"
        guard let second else { return base }
        return "\(base)（次选 \(second.label.displayName) \(Int((second.probability * 100).rounded()))%）"
    }
}

/// 判别层的接受阈值。
///
/// 两个条件都要满足：绝对概率够高，且与次选的差距够大。
/// 只看绝对值会误判「稳定地错」——模型可能以 90% 概率选错类别，
/// 此时 margin 小仍会拦下并要求澄清。
public struct IntentDecisionPolicy: Equatable, Sendable {
    /// top1 概率下限
    public let minTopProbability: Double
    /// top1 与 top2 的最小概率差
    public let minMargin: Double

    public init(minTopProbability: Double = 0.55, minMargin: Double = 0.20) {
        self.minTopProbability = minTopProbability
        self.minMargin = minMargin
    }

    public static let `default` = IntentDecisionPolicy()

    public func accepts(topProbability: Double, margin: Double) -> Bool {
        topProbability >= minTopProbability && margin >= minMargin
    }
}

// MARK: - 分布计算

/// logits → 概率分布的纯函数实现（引擎侧读出的原始 logits 交给这里处理）。
public enum IntentClassifierMath {
    /// 在候选标签的 logits 上做 softmax。
    ///
    /// 只对候选集归一化，而不是先对全词表 softmax 再取候选：
    /// 后者会让候选概率被词表里大量无关 token 稀释，导致所有标签都趋近 0。
    /// 减最大值防止 exp 溢出。
    public static func distribution(logits: [OmniboxIntentLabel: Double]) -> [OmniboxIntentLabel: Double] {
        guard !logits.isEmpty else { return [:] }
        guard let maxLogit = logits.values.max() else { return [:] }

        var exponentials: [OmniboxIntentLabel: Double] = [:]
        for (label, logit) in logits {
            exponentials[label] = exp(logit - maxLogit)
        }
        let sum = exponentials.values.reduce(0, +)
        guard sum > 0, sum.isFinite else {
            // 数值退化（NaN/Inf）时退化为均匀分布，交由阈值拦下，不静默给出错误结论。
            let uniform = 1.0 / Double(logits.count)
            return Dictionary(uniqueKeysWithValues: logits.keys.map { ($0, uniform) })
        }
        return exponentials.mapValues { $0 / sum }
    }

    /// 组装完整分布：补齐未出现在 logits 中的标签，按概率降序排序。
    public static func makeDistribution(
        logits: [OmniboxIntentLabel: Double],
        allLabels: [OmniboxIntentLabel] = OmniboxIntentLabel.allCases,
        policy: IntentDecisionPolicy = .default
    ) -> IntentDistribution {
        let normalized = distribution(logits: logits)
        let ranked = allLabels
            .map { IntentScore(label: $0, probability: normalized[$0] ?? 0) }
            .sorted { lhs, rhs in
                if lhs.probability == rhs.probability {
                    // 概率相同时按 rawValue 稳定排序，保证结果可复现（便于测试与日志比对）。
                    return lhs.label.rawValue < rhs.label.rawValue
                }
                return lhs.probability > rhs.probability
            }
        return IntentDistribution(ranked: ranked, policy: policy)
    }
}
