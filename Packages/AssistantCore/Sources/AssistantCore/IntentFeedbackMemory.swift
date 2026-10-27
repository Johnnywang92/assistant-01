import Foundation

// MARK: - 判别反馈（点赞/点踩）

/// 一次「这次意图判断准不准」的用户反馈。纯数据模型：
/// App 层负责持久化（OmniboxJudgmentFeedback），本层负责回流计算。
///
/// 除 verdict 外还快照 topProbability / margin——这是判别层阈值校准的
/// 真实语料（IntentDecisionPolicy 目前只有经验值），攒够样本后可离线重设阈值。
public struct JudgmentFeedback: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        case up     // 判断准确
        case down   // 判断错误
    }

    public let id: UUID
    /// 归一化后的输入文本（见 `IntentFeedbackMemory.normalize`）
    public let inputText: String
    /// 反馈时刻判别的标签（`OmniboxIntentLabel.rawValue`）
    public let labelRaw: String
    public let verdict: Verdict
    /// 判别时 top1 概率快照
    public let topProbability: Double
    /// 判别时 top1 与 top2 的概率差快照
    public let margin: Double
    /// 判别时次选标签（top2）快照。点踩且未给出正确标签时，
    /// 「top1 ↔ top2」是疑似混淆对——模型在这两类之间摇摆。
    public let runnerUpLabelRaw: String?
    /// 点踩后用户点选的正确意图标签。与 `labelRaw` 构成**实锤混淆对**
    /// （判成了 X、实际是 Y），是识别质量统计里最有价值的语料。
    public let correctedLabelRaw: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        inputText: String,
        labelRaw: String,
        verdict: Verdict,
        topProbability: Double = 0,
        margin: Double = 0,
        runnerUpLabelRaw: String? = nil,
        correctedLabelRaw: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.inputText = inputText
        self.labelRaw = labelRaw
        self.verdict = verdict
        self.topProbability = topProbability
        self.margin = margin
        self.runnerUpLabelRaw = runnerUpLabelRaw
        self.correctedLabelRaw = correctedLabelRaw
        self.createdAt = createdAt
    }

    public var label: OmniboxIntentLabel? { OmniboxIntentLabel(rawValue: labelRaw) }

    public var runnerUpLabel: OmniboxIntentLabel? {
        runnerUpLabelRaw.flatMap(OmniboxIntentLabel.init(rawValue:))
    }

    public var correctedLabel: OmniboxIntentLabel? {
        correctedLabelRaw.flatMap(OmniboxIntentLabel.init(rawValue:))
    }
}

// MARK: - 反馈回流记忆

/// 点赞/点踩如何提升下一次判断：无在线训练，全部是本地、可解释的确定性规则。
///
/// 1. **被点踩的输入**（最近一次反馈为 down）→ 下次同类输入强制进确认卡
///    （被质疑过的输入不再默认信模型）。
/// 2. **被点赞的输入**（最近一次反馈为 up）→ 下次把该标签提升为首选
///    （用户确认过的意图优先预填）。
/// 3. 同一输入多次反馈**以最近一次为准**——用户改变主意是常态，不是噪声。
///
/// 匹配只做归一化后的全等：宁可少生效，不做模糊匹配猜错反馈归属。
public struct IntentFeedbackMemory: Sendable {
    private var records: [JudgmentFeedback]

    public init(records: [JudgmentFeedback] = []) {
        self.records = records.sorted { $0.createdAt < $1.createdAt }
    }

    public var all: [JudgmentFeedback] { records }

    public mutating func append(_ record: JudgmentFeedback) {
        records.append(record)
    }

    /// 输入归一化：小写、**剔除全部标点与空白**。
    /// 反馈匹配的唯一依据——同一句话不同空白/标点写法必须能对上：
    /// 「把账改成30。」「把账改成30」「把账改成30，顺便」与「把账改成30 顺便」都归到同一个键。
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars.filter { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
            if CharacterSet.punctuationCharacters.contains(scalar) { return false }
            if CharacterSet.symbols.contains(scalar) { return false }
            // 不在上述集合里的全角标点兜底
            let ch = Character(scalar)
            return !"，。；：？！、（）【】「」“”‘’％·…—　".contains(ch)
        }
        return String(String.UnicodeScalarView(stripped))
    }

    /// 该输入最近一次反馈。没有记录 → nil。
    public func latestFeedback(for input: String) -> JudgmentFeedback? {
        let key = Self.normalize(input)
        return records.last { $0.inputText == key }
    }

    /// 是否被点踩过（最近一次反馈为 down）。下次强制进确认卡。
    public func isDisputed(_ input: String) -> Bool {
        latestFeedback(for: input)?.verdict == .down
    }

    /// 该输入最近一次点赞的标签。下次优先预填。
    public func endorsedLabel(for input: String) -> OmniboxIntentLabel? {
        guard let latest = latestFeedback(for: input), latest.verdict == .up else { return nil }
        return latest.label
    }

    /// 把被点赞过的标签提升到分布首位，用于「优先预填」。
    /// 只影响提示词收窄与预填顺序；**不改写任何概率值**——
    /// 概率快照要原样留给阈值校准做语料。
    public func promoted(_ distribution: IntentDistribution, for input: String) -> IntentDistribution {
        guard let endorsed = endorsedLabel(for: input),
              let top = distribution.top, top != endorsed,
              let idx = distribution.ranked.firstIndex(where: { $0.label == endorsed }) else {
            return distribution
        }
        var reordered = distribution.ranked
        let picked = reordered.remove(at: idx)
        reordered.insert(picked, at: 0)
        return IntentDistribution(ranked: reordered, policy: distribution.policy)
    }
}
