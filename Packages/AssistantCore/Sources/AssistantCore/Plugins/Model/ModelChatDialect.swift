import Foundation

/// ChatML 家族的解码方言。
///
/// 取代原来的 `isQwen3Family: Bool`。那个布尔在代码里只做一件事——决定助手起始标记后面
/// 要不要紧跟一段已闭合的思考块。把「要做的那件事」直接建成数据，就不再需要一个
/// 与模型家族名绑死的布尔位（换一家模型就得改名）。
public enum ModelChatDialect: String, CaseIterable, Sendable {
    /// 纯 ChatML：助手起始标记后不追加任何内容
    case plainChatML
    /// 指令后带思考标签的家族（Qwen3）：预填一段已闭合的空思考块，跳过长思考链直出答案
    case chatMLWithClosedThinkBlock

    /// 拼接在助手起始标记之后的片段
    public var assistantStartSuffix: String {
        switch self {
        case .plainChatML:
            return ""
        case .chatMLWithClosedThinkBlock:
            return "\n<think>\n\n</think>\n\n"
        }
    }
}

/// 模型发布方提供的下载源。稳定标识，与 UI 展示文案解耦。
public enum ModelDownloadSourceID: String, CaseIterable, Sendable {
    case modelScope
    case huggingFace
}
