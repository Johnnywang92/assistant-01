import AssistantCore
import Foundation

/// 疏解动作的 App 侧文案映射。
///
/// ## 为什么文案在 App 侧而不是 Core
///
/// 项目约定：**Core 持有规则，App 持有文案**。Core 是纯 Foundation 层，
/// 不能反向依赖 App 的 `L10n`（那会造成 Core → App 的反向依赖）。
/// `PsychReliefAction` 只提供 `title`/`detail` 的中文基准值，
/// 真正的显示文案由本映射表按当前语言给出。
///
/// 兜底规则：映射表里没有的键，回落到 Core 的中文基准值——
/// 中文环境下永远显示得出，英文环境下显示中文（可接受，不会崩）。
enum PsychReliefCopy {
    /// 动作标题。
    static func title(for action: PsychReliefAction) -> String {
        switch action {
        case .breathing: return L10n.tr("做一次缓慢的生理性叹息")
        case .walk: return L10n.tr("出门走 10 分钟")
        case .journal: return L10n.tr("写下此刻最强烈的一个感受")
        case .speak: return L10n.tr("说出来 · 录一段语音")
        case .sleepEarlier: return L10n.tr("今晚提早 30 分钟上床")
        case .reachOut: return L10n.tr("给一个信任的人发条消息")
        case .professionalCare: return L10n.tr("联系专业支持")
        }
    }

    /// 动作说明。
    static func detail(for action: PsychReliefAction) -> String {
        switch action {
        case .breathing:
            return L10n.tr("连做 3 次：吸一小口气，再慢慢吐长一点。身体会先于情绪松下来。")
        case .walk:
            return L10n.tr("不用换衣服、不用定目标，出门走 10 分钟就行。先动起来，感受可以晚一点再处理。")
        case .journal:
            return L10n.tr("只写一句：现在最强烈的感觉是什么。写下来本身就有整理作用。")
        case .speak:
            return L10n.tr("打开语音备忘，把想说的说出来。说出口比想清楚更容易开始。")
        case .sleepEarlier:
            return L10n.tr("睡眠不足会同时放大情绪的低落与迟钝。今晚先把入睡时间提前半小时。")
        case .reachOut:
            return L10n.tr("不用解释太多，发一句「最近有点闷，能聊两句吗」就够了。")
        case .professionalCare:
            return L10n.tr("自助方法有它的边界。找专业的人聊聊，是更快也更稳的路。")
        }
    }
}
