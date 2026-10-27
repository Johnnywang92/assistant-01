import Foundation

// MARK: - 置信度校准与确认策略（纯逻辑）

/// 把判别层的真实概率校准到动作置信度，并把「模型不确定」映射为强制待确认。
///
/// 背景：生成式路径过去把 `confidence` 写死成 0.85，导致 `needsConfirmation`
/// （阈值 0.6）永远为 false——模型不确定时系统也察觉不到。
/// 这里用判别层的真实概率覆盖，并修掉两个缝隙：
/// 1. top1≈0.60 经四舍五入恰为 0.60 时 `confidence < 0.6` 不成立 → 徽章不出现；
/// 2. margin 不足（needsClarification）但绝对概率过线时仍然默认勾选。
public enum IntentConfidenceCalibrator {

    /// 0.05 步进取整，保留一位有效小数，避免日志噪声。
    public static func roundedConfidence(_ probability: Double) -> Double {
        (probability * 20).rounded() / 20
    }

    /// 判别不确定时的置信度上限：必须严格低于 `ActionItem.lowConfidenceThreshold`，
    /// 保证 `needsConfirmation` 一定触发。
    public static var uncertainConfidenceCap: Double {
        ActionItem.lowConfidenceThreshold * 0.95 // 0.57
    }

    /// 用判别层的真实概率校准动作置信度。
    ///
    /// 只在判别成功且指向同一能力时校准，避免用「判别 A 能力」的概率去标注「B 能力」的动作；
    /// 破坏性动作本就强制确认，不参与校准（压低反而会出现「模型不确定要删」的误导解释）。
    public static func apply(to actions: [ActionItem], distribution: IntentDistribution?) -> [ActionItem] {
        guard let distribution, let top = distribution.top else { return actions }
        let uncertain = distribution.needsClarification
        let rounded = roundedConfidence(distribution.topProbability)
        return actions.map { action in
            guard action.capability == top.capability, !action.capability.isDestructive else {
                return action
            }
            var updated = action
            if uncertain {
                updated.confidence = min(rounded, uncertainConfidenceCap)
                // 判别不确定 → 默认不勾选，强制人眼过一遍再执行
                updated.isSelected = false
                updated.confidenceReason = "意图判断把握度不足（\(distribution.reasonText)），请核对后再执行"
            } else {
                updated.confidence = rounded
                updated.confidenceReason = "意图判断：\(distribution.reasonText)"
            }
            return updated
        }
    }

    /// 是否需要提示用户核对。按**最终动作的置信度**推导，而不是直接用判别层的结论：
    /// 判别层说不确定，但规则引擎从扣款短信里抽出 0.88 置信的完整动作时，
    /// 展示「不太确定」反而与用户看到的确定结果矛盾。
    public static func needsClarification(_ actions: [ActionItem]) -> Bool {
        !actions.isEmpty && actions.contains { $0.confidence < ActionItem.lowConfidenceThreshold }
    }

    /// 默认勾选策略：置信度低于阈值的动作**不允许默认勾选**，必须由用户显式打开。
    /// 破坏性动作（requiresConfirmation）例外——它们本来就带着强制确认徽章，
    /// 保持默认勾选让用户在确认卡里一眼看到将要发生什么。
    public static func applySelectionPolicy(_ actions: [ActionItem]) -> [ActionItem] {
        actions.map { action in
            guard action.needsConfirmation, !action.capability.requiresConfirmation, action.isSelected else {
                return action
            }
            var updated = action
            updated.isSelected = false
            return updated
        }
    }
}
