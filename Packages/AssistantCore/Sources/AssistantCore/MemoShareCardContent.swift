import Foundation

/// 分享卡片上的一块内容（纯值快照，供 App 侧渲染）。
public struct MemoShareCardItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 正文段落
        case paragraph
        /// 小标题
        case heading
        /// 列表项
        case bullet
        /// 待办项
        case todo
        /// 引用
        case quote
        /// 图片
        case image
        /// 语音片段
        case audio
    }

    public var kind: Kind
    public var text: String
    /// 图片文件名（`.image` 有效）
    public var imageFileName: String?
    /// 语音片段区间（`.audio` 有效）
    public var timeRange: MemoTimeRange?
    /// 待办是否完成（`.todo` 有效）
    public var isDone: Bool

    public init(
        kind: Kind,
        text: String,
        imageFileName: String? = nil,
        timeRange: MemoTimeRange? = nil,
        isDone: Bool = false
    ) {
        self.kind = kind
        self.text = text
        self.imageFileName = imageFileName
        self.timeRange = timeRange
        self.isDone = isDone
    }
}

/// 离屏渲染倍率的安全规则（纯逻辑，可单测）。
///
/// **产品口径：分享永远只出一张完整长图，不分页。**
/// 长笔记靠动态降低渲染倍率把整张图压进位图上限，宁可清晰度低一点，
/// 也不能切成多张、更不能静默输出被裁过的残图。
/// 倍率必须在渲染前算好：先按 3x 渲一张再降，那一次超尺寸渲染本身就是残图来源。
public enum ShareCardRenderScale {
    /// 位图任一边的像素上限。留出余量以覆盖常见 iOS 设备的纹理限制。
    public static let maxPixelSide: Double = 8192

    /// 给定卡片最长边（pt）与期望倍率，返回不越界的安全倍率。
    /// 至少返回 1：宁可用 1x 出一张完整但略糊的图，也不要给用户「生成失败」。
    public static func safeScale(
        longestSide: Double,
        preferred: Double = 3,
        maxPixelSide: Double = ShareCardRenderScale.maxPixelSide
    ) -> Double {
        guard longestSide > 0, preferred > 0, maxPixelSide > 0 else { return 1 }
        let fitted = floor(maxPixelSide / longestSide)
        // 安全倍率永远不能比期望倍率更大。
        return min(preferred, max(1, fitted))
    }

    /// 渲染完成后核对实际像素，避免系统悄悄给了一张缩过/裁过的图。
    public static func isWithinLimit(points: Double, scale: Double) -> Bool {
        points > 0 && scale > 0 && points * scale <= maxPixelSide * 1.02
    }
}

/// 分享卡片的内容规则。
///
/// 核心约束：**分享出去的图片无法携带声音。**
/// 因此语音块在卡片上只能呈现为「原声片段 + 时间区间」的可视标识，
/// 不能让人以为「这段原声已经发出去了」——那是个静默的预期落差。
public enum MemoShareCardContent {

    /// 卡片上最多展示的图片数量。
    ///
    /// 超出部分不静默丢弃：调用方据此在卡片底部显示「还有 N 张图片」，
    /// 让用户知道内容被折叠了而不是丢了。
    public static let maxImages = 3

    /// 卡片上最多展示的语音片段数量（超出同样要显式提示）。
    public static let maxAudioClips = 2

    /// 把块转换成卡片条目。
    ///
    /// - Parameters:
    ///   - blocks: 笔记块。
    ///   - includeImages: 是否包含图片。
    ///   - includeAudio: 是否包含语音片段。
    public static func items(
        from blocks: [MemoBlock],
        includeImages: Bool = true,
        includeAudio: Bool = true
    ) -> [MemoShareCardItem] {
        var result: [MemoShareCardItem] = []
        var imageCount = 0
        var audioCount = 0

        for block in blocks where !block.isEmpty {
            switch block.kind {
            case .paragraph:
                result.append(MemoShareCardItem(kind: .paragraph, text: block.text))
            case .heading:
                result.append(MemoShareCardItem(kind: .heading, text: block.text))
            case .bullet:
                result.append(MemoShareCardItem(kind: .bullet, text: block.text))
            case .todo:
                result.append(MemoShareCardItem(kind: .todo, text: block.text, isDone: block.isDone))
            case .quote:
                result.append(MemoShareCardItem(kind: .quote, text: block.text))
            case .image:
                guard includeImages, imageCount < maxImages else { continue }
                imageCount += 1
                result.append(
                    MemoShareCardItem(kind: .image, text: block.imageCaption ?? "", imageFileName: block.imageFileName)
                )
            case .audio:
                guard includeAudio, audioCount < maxAudioClips else { continue }
                audioCount += 1
                result.append(
                    MemoShareCardItem(kind: .audio, text: block.text, timeRange: block.timeRange)
                )
            }
        }
        return result
    }

    /// 被折叠掉的内容数量（用于卡片底部的「还有 N 项」提示）。
    public static func hiddenCounts(
        from blocks: [MemoBlock],
        includeImages: Bool = true,
        includeAudio: Bool = true
    ) -> (images: Int, audio: Int) {
        let allImages = blocks.filter { $0.kind == .image && !$0.isEmpty }.count
        let allAudio = blocks.filter { $0.kind == .audio && !$0.isEmpty }.count
        let hiddenImages = includeImages ? max(0, allImages - maxImages) : allImages
        let hiddenAudio = includeAudio ? max(0, allAudio - maxAudioClips) : allAudio
        return (hiddenImages, hiddenAudio)
    }

    /// 语音片段在卡片上的说明文案。
    ///
    /// 必须包含「另附录音」或等价表述，让接收方知道原声要另外获取。
    /// 没有有效区间时退化为「原声片段」，**不编造时间点**。
    public static func audioCaption(for range: MemoTimeRange?) -> String {
        guard let range, range.isValid else { return "原声片段 · 完整录音可听" }
        return "原声片段 \(format(range.start))–\(format(range.end)) · 完整录音可听"
    }

    /// 秒 → mm:ss。
    public static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - 单张长图的高度估算（纯逻辑，可单测）

    /// 卡片正文宽约 306pt、正文字号 12.5pt，中文按 24 字/行保守估算。
    public static let charactersPerLine = 24
    /// 单行高度：12.5pt 字号 + 3pt 行距 + 少量行间余量。
    public static let lineHeight: Double = 19
    /// 卡片固定版面（眉标 / 标题 / 分隔线 / 水印 / 22pt 内边距）的估算高度（pt）。
    /// 估算总高用来在渲染前挑倍率，避免先渲一张超尺寸图再补救。
    public static let cardChromeAllowance: Double = 200

    /// 估算一个内容块在卡片上占的高度（pt）。
    public static func estimatedHeight(for item: MemoShareCardItem) -> Double {
        switch item.kind {
        case .heading:
            return 26
        case .image:
            return 140 // 120pt 图片 + 说明文字
        case .audio:
            return 34
        case .paragraph, .bullet, .todo, .quote:
            let chars = max(1, item.text.count)
            let lines = max(1, Int(ceil(Double(chars) / Double(charactersPerLine))))
            return Double(lines) * lineHeight + 4
        }
    }

    /// 估算整张卡片的高度（pt）。
    ///
    /// 这是「只出一张长图」的关键输入：App 用它挑一个不越界的渲染倍率，
    /// 所有内容都留在这张图里，不做任何切分或折叠。
    public static func estimatedCardHeight(for items: [MemoShareCardItem]) -> Double {
        items.reduce(cardChromeAllowance) { $0 + estimatedHeight(for: $1) }
    }
}
