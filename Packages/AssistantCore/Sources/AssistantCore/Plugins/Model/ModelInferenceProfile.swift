import Foundation

/// 一个模型的推理画像：引擎在为它建上下文与采样链时要用的数字。
///
/// **为什么这些数属于模型、而不属于引擎。** 原先它们挤在 `LlamaCppEngine` 的静态常量里
/// （`maxContextTokens` / `fallbackContextTokens` / top-k / top-p / temperature），
/// 对所有 GGUF 一视同仁。但其中真正会变的恰恰是模型侧的事实：KV 缓存按 token 线性增长，
/// 每 token 占多少字节由架构与层数决定，所以「同一台设备上能开多大窗口」是逐模型的答案，
/// 「这个家族建议什么采样」也是逐模型的答案。放在引擎里，新增一个模型就得改引擎；
/// 放在描述符里，新增一个模型只需要填这一格。
///
/// 反过来，**不属于**画像的三项刻意留在引擎：
/// `n_gpu_layers`（是否走 Metal 全层加速）与 `n_batch`、线程数上限是设备与构建配置；
/// `contextSafetyMargin` 是 ChatML 边界对齐的协议开销，与模型无关。
public struct ModelInferenceProfile: Sendable, Equatable {

    /// 设备侧允许申请的上下文窗口上限（与模型训练窗取较小值）。
    ///
    /// KV 缓存按 token 线性增长，而每 token 占多少字节由架构与层数决定：
    /// Qwen2.5-1.5B 约 28KB/token，4096 token ≈ 115MB 是安全上界，再高在低端机有 jetsam 风险。
    /// 正因为这条换算跟架构绑定，它是模型事实而不是设备事实。
    public let maxContextTokens: Int
    /// 读不到模型训练窗（`n_ctx_train` 返回 0）时按这个窗口申请
    public let fallbackContextTokens: Int
    /// Top-K 候选数
    public let topK: Int
    /// Top-P 核采样概率
    public let topP: Double
    /// 采样温度
    public let temperature: Double

    public init(
        maxContextTokens: Int,
        fallbackContextTokens: Int,
        topK: Int,
        topP: Double,
        temperature: Double
    ) {
        self.maxContextTokens = maxContextTokens
        self.fallbackContextTokens = fallbackContextTokens
        self.topK = topK
        self.topP = topP
        self.temperature = temperature
    }
}
