import Foundation

/// 提示词分块装配与 token 预算裁剪（纯函数、无平台依赖，可独立测试）。
///
/// **为什么需要它。** 端侧模型的上下文窗口很小，而「全模块生活档案」有 12 个数据段。
/// 旧实现把整段提示词 tokenize 之后用 `tokens.suffix(available)` 截断——`suffix` 保留的是
/// **尾部**，于是被丢掉的是开头的 system 人格设定，以及紧跟其后、排在最前面的
/// 「待取快递」「日常待办」两组数据：恰好是回答「我现在该干嘛」最需要的东西，
/// 同时 ChatML 的起始结构被截成残缺体，模型收到的是一段没有主人格的碎片。
///
/// 本文件把裁剪从「token 级切尾」改成「**整块丢弃 + 固定丢弃顺序**」：
/// 某段数据要么完整在场，要么完整不在场，绝不出现半截档案。
public enum PromptBlockID: String, CaseIterable, Sendable {
    // —— 必留：丢了答案就不是那个答案 ——
    /// 助手人格与称呼设定
    case persona
    /// 作答规则（含「严禁编造数据」等硬约束）
    case rules
    /// 刚完成的真实操作回执 / 账单精确核实结论。规则要求以此为准，缺了它反而会被诱导编数
    case verified
    /// 用户当前问句
    case query

    // —— 可丢：按 dropRank 从先到后淘汰 ——
    /// 常去地点学习结果
    case place
    /// 近期语音备忘
    case memo
    /// 家庭档案（萌宠 / 育儿 / 爱车）
    case family
    /// 用药与习惯打卡
    case habit
    /// 证件 / 订阅 / 保质期预警
    case vault
    /// 物品收纳位置
    case storage
    /// 纪念日与倒数日
    case anniversary
    /// 财务账本概览
    case finance
    /// 多轮对话历史
    case history
    /// 日常待办与日程
    case todo
    /// 待取快递
    case parcel

    /// 丢弃顺序：值越小越先被丢。**nil 表示必留块，任何情况下都不丢。**
    ///
    /// 排序依据「这段数据缺席时回答的可信度损失」：
    /// 地点/备忘/家庭档案属于点缀性上下文，丢了自己大概率还能答对；
    /// 快递与待办是「现在该做什么」的直接依据，留到最后。
    /// 对话历史排在财务之后、待办之前——多轮指代一旦断裂整段对话就答非所问，
    /// 而财务类问题另有 `verified` 精确回执兜底。
    public var dropRank: Int? {
        switch self {
        case .persona, .rules, .verified, .query: return nil
        case .place: return 0
        case .memo: return 1
        case .family: return 2
        case .habit: return 3
        case .vault: return 4
        case .storage: return 5
        case .anniversary: return 6
        case .finance: return 7
        case .history: return 8
        case .todo: return 9
        case .parcel: return 10
        }
    }

    /// 必留块（dropRank == nil）
    public var isProtected: Bool { dropRank == nil }

    /// 生活档案块在提示词中的固定输出顺序。与 `dropRank` 无关：
    /// 输出顺序影响小模型注意力，丢弃顺序只影响预算裁剪。
    /// App 侧按此清单装配，新增生活档案模块需同时登记 Provider 与这里。
    public static let lifeProfileOrder: [PromptBlockID] = [
        .parcel, .todo, .finance, .anniversary, .storage,
        .habit, .vault, .family, .memo, .place
    ]
}

/// 提示词的一个整块。装配时以块为单位保留或丢弃。
public struct PromptBlock: Sendable, Equatable {
    public let id: PromptBlockID
    public let text: String

    public init(id: PromptBlockID, text: String) {
        self.id = id
        self.text = text
    }

    /// 本块估算 token 数
    public var estimatedTokens: Int { PromptTokenEstimator.estimateTokens(text) }
}

/// 裁剪结果
public struct PromptFit: Sendable, Equatable {
    /// 保留的块，**顺序与入参一致**（丢弃不改序，保证 ChatML 段落次序稳定）
    public let blocks: [PromptBlock]
    /// 被丢弃的块 id，按丢弃先后排列
    public let droppedIDs: [PromptBlockID]
    public let usedTokens: Int
    /// 连必留块都装不下。true 时调用方必须另作处理（缩历史/缩问句/降级规则），
    /// **不能**把 `blocks` 直接当完整提示词发出去。
    public let overflow: Bool

    public init(blocks: [PromptBlock], droppedIDs: [PromptBlockID], usedTokens: Int, overflow: Bool) {
        self.blocks = blocks
        self.droppedIDs = droppedIDs
        self.usedTokens = usedTokens
        self.overflow = overflow
    }
}

/// Token 估算。真分词要拿到模型词表（在 app 侧、且开销大），装配阶段只需要一个
/// **偏保守**的相对量：宁可估多导致早丢一块点缀数据，也不要估少导致发出时被引擎判超窗。
public enum PromptTokenEstimator {
    /// 中文（含全角标点）≈ 1 token/字；ASCII ≈ 4 字符/token；其他文字 ≈ 2 字符/token。
    /// 最后乘 1.15 安全余量——BPE 对中文常出现 1 字 1~2 token 的波动，估算偏乐观是事故源。
    public static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var ascii = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar.value) {
                cjk += 1
            } else if scalar.value < 0x80 {
                ascii += 1
            } else {
                other += 1
            }
        }
        let raw = Double(cjk) + Double(ascii) / 4.0 + Double(other) / 2.0
        let withMargin = Int((raw * 1.15).rounded(.up))
        return max(1, withMargin)
    }

    /// CJK 汉字 + 中日韩标点 + 全角形式 + 兼容表意文字
    private static func isCJK(_ value: UInt32) -> Bool {
        switch value {
        case 0x4E00...0x9FFF,    // CJK 统一表意文字
             0x3400...0x4DBF,    // 扩展 A
             0xF900...0xFAFF,    // 兼容表意文字
             0x3000...0x303F,    // CJK 标点（。、「」等）
             0xFF00...0xFFEF:    // 全角形式（？：￥等）
            return true
        default:
            return false
        }
    }
}

/// 分块装配器。
public enum PromptBudget {
    /// 在预算内保留尽量多的块。
    ///
    /// - Parameters:
    ///   - blocks: 按**期望输出顺序**排列的块（装配结果不改序，只做取舍）
    ///   - budgetTokens: 可用于提示词正文的 token 上限（调用方负责已扣掉生成长度与固定开销）
    /// - Returns: `overflow == true` 表示必留块本身就超预算，此时 blocks 已无可再丢，
    ///   调用方须自行缩历史/问句或降级到规则引擎，**不要**把残段发给模型。
    public static func fit(blocks: [PromptBlock], budgetTokens: Int) -> PromptFit {
        func used(_ some: [PromptBlock]) -> Int {
            some.reduce(0) { $0 + $1.estimatedTokens }
        }

        let total = used(blocks)
        if total <= budgetTokens {
            return PromptFit(blocks: blocks, droppedIDs: [], usedTokens: total, overflow: false)
        }

        var kept = blocks
        var dropped: [PromptBlockID] = []
        // 丢弃顺序只由 dropRank 决定，与入参顺序无关
        let droppable = blocks
            .filter { !$0.id.isProtected }
            .sorted { ($0.id.dropRank ?? .max) < ($1.id.dropRank ?? .max) }

        for candidate in droppable {
            guard used(kept) > budgetTokens else { break }
            dropped.append(candidate.id)
            kept.removeAll { $0.id == candidate.id }
        }

        let finalUsed = used(kept)
        return PromptFit(
            blocks: kept,
            droppedIDs: dropped,
            usedTokens: finalUsed,
            overflow: finalUsed > budgetTokens
        )
    }

    /// 逐块裁剪到预算内并返回拼接文本；超预算的**单块内部**不截断（整块取舍是本模块的契约）。
    public static func joined(
        blocks: [PromptBlock],
        budgetTokens: Int,
        separator: String = "\n"
    ) -> (text: String, fit: PromptFit) {
        let fit = fit(blocks: blocks, budgetTokens: budgetTokens)
        let text = fit.blocks.map(\.text).joined(separator: separator)
        return (text, fit)
    }
}
