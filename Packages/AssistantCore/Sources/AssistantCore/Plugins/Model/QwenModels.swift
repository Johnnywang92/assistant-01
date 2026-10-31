import Foundation

extension ModelDescriptor {

    // 三个模型的 `inference` 目前逐字等于 2026-10-30 之前 `LlamaCppEngine` 里那组对所有 GGUF
    // 一视同仁的常量（4096 / 2048 / top-k 40 / top-p 0.90 / temp 0.60）——C3 只把「谁在用这些数」
    // 换成了「每个模型声明自己的数」，没有改任何一个值。真要调窗口是内存决策，必须真机验证。

    /// Qwen3-1.7B-Instruct · Q4_K_M
    public static let qwen3_1_7b = ModelDescriptor(
        id: "qwen3_1_7b",
        displayName: "Qwen3-1.7B-Instruct (推荐)",
        shortName: "Qwen3-1.7B",
        subtitle: "新一代千问 Qwen3 架构 · 推理与指令遵循大幅提升，兼顾速度与低内存",
        parameterCountText: "17.2 亿 (1.7B)",
        expectedSizeText: "约 1.11 GB",
        estimatedRAMText: "约 1.2 GB",
        fileName: "Qwen3-1.7B-Q4_K_M.gguf",
        minValidSizeBytes: 900_000_000,
        downloadURLs: [
            .modelScope: URL(string: "https://www.modelscope.cn/models/unsloth/Qwen3-1.7B-GGUF/resolve/master/Qwen3-1.7B-Q4_K_M.gguf")!,
            .huggingFace: URL(string: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf")!
        ],
        chatDialect: .chatMLWithClosedThinkBlock,
        ollamaModelTag: "qwen3:1.7b",
        inference: ModelInferenceProfile(
            maxContextTokens: 4096, fallbackContextTokens: 2048,
            topK: 40, topP: 0.90, temperature: 0.60
        )
    )

    /// Qwen3-4B-Instruct · Q4_K_M
    public static let qwen3_4b = ModelDescriptor(
        id: "qwen3_4b",
        displayName: "Qwen3-4B-Instruct (增强版)",
        shortName: "Qwen3-4B",
        subtitle: "40 亿参数高阶端侧模型 · 食物热量推断与复杂拆解更强（建议 8GB+ 内存机型）",
        parameterCountText: "40.2 亿 (4.0B)",
        expectedSizeText: "约 2.50 GB",
        estimatedRAMText: "约 2.6 GB",
        fileName: "Qwen3-4B-Q4_K_M.gguf",
        minValidSizeBytes: 2_000_000_000,
        downloadURLs: [
            .modelScope: URL(string: "https://www.modelscope.cn/models/Qwen/Qwen3-4B-GGUF/resolve/master/Qwen3-4B-Q4_K_M.gguf")!,
            .huggingFace: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf")!
        ],
        chatDialect: .chatMLWithClosedThinkBlock,
        ollamaModelTag: "qwen3:4b",
        inference: ModelInferenceProfile(
            maxContextTokens: 4096, fallbackContextTokens: 2048,
            topK: 40, topP: 0.90, temperature: 0.60
        )
    )

    /// Qwen2.5-1.5B-Instruct · Q4_K_M（旧版兼容）
    public static let qwen2_5_1_5b = ModelDescriptor(
        id: "qwen2_5_1_5b",
        displayName: "Qwen2.5-1.5B-Instruct (轻量兼容)",
        shortName: "Qwen2.5-1.5B",
        subtitle: "经典轻量端侧模型 · 体积最小，兼容旧版已下载模型文件",
        parameterCountText: "15.4 亿 (1.54B)",
        expectedSizeText: "约 1.12 GB",
        estimatedRAMText: "约 980 MB",
        fileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        minValidSizeBytes: 850_000_000,
        downloadURLs: [
            .modelScope: URL(string: "https://www.modelscope.cn/models/qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
            .huggingFace: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!
        ],
        chatDialect: .plainChatML,
        ollamaModelTag: "qwen2.5:1.5b",
        inference: ModelInferenceProfile(
            maxContextTokens: 4096, fallbackContextTokens: 2048,
            topK: 40, topP: 0.90, temperature: 0.60
        )
    )
}
