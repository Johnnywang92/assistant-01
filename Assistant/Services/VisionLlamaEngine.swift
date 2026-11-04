import AssistantCore
import CoreGraphics
import Foundation

#if !targetEnvironment(simulator) && canImport(LlamaSwift)
import LlamaSwift
#elseif !targetEnvironment(simulator) && canImport(llama)
import llama
#endif

/// 视觉链路专用错误。
///
/// 与 `LlamaInferenceError` 分开是因为「聊天能跑、认图不能跑」是两种故障：
/// 前者文件与词表都没问题，后者多半只出在 mmproj 或图像预处理上。混在一个枚举里，
/// 用户看到的永远是同一句「推理失败」，而重下模型对这两种情况都没用。
public enum VisionInferenceError: LocalizedError {
    /// mmproj 加载失败：视觉编码器没起来，语言模型再好也看不见图
    case mmprojLoadFailed(String)
    /// 这个 GGUF 里没有视觉塔（挂错文件、或下到的是纯文本版本）
    case visionUnsupported(String)
    /// 提示词里没有媒体标记，或标记与 bitmap 数量不匹配
    case markerMismatch
    /// mtmd 图像预处理失败（尺寸不合法、像素数据不完整）
    case imagePreprocessingFailed
    /// 图 + 提示词超出上下文窗口：图像本身就吃掉一大截预算
    case contextOverflowWithImage(required: Int, available: Int)
    /// mtmd_helper_eval_chunks 返回非 0
    case evalFailed(Int32)
    /// 上一次识别还没结束。视觉链路一次只跑一张图，见 `generate` 里的串行说明。
    case busy

    public var errorDescription: String? {
        switch self {
        case .mmprojLoadFailed(let file):
            return L10n.choose(
                "视觉编码器加载失败：\(file)。请重新下载该部件。",
                "Vision encoder failed to load: \(file). Re-download this part."
            )
        case .visionUnsupported(let file):
            return L10n.choose(
                "\(file) 不含视觉能力，无法识别图片。",
                "\(file) has no vision capability and cannot read images."
            )
        case .markerMismatch:
            return L10n.choose(
                "提示词里没有图片占位符，或占位符数量与图片不符。",
                "The prompt is missing the image placeholder, or its count does not match the images."
            )
        case .imagePreprocessingFailed:
            return L10n.choose("图片预处理失败，请换一张照片重试。", "Image preprocessing failed. Try another photo.")
        case .contextOverflowWithImage(let required, let available):
            return L10n.choose(
                "图片加提示词需 \(required) token，模型可用仅 \(available) token。",
                "Image plus prompt needs \(required) tokens but only \(available) are available."
            )
        case .evalFailed(let code):
            return L10n.choose("图像推理执行异常 (code: \(code))", "Image inference failed (code: \(code)).")
        case .busy:
            return L10n.choose(
                "上一次图片识别仍在进行中，请稍候再试。",
                "A previous image is still being processed. Try again shortly."
            )
        }
    }
}

/// 端侧多模态（GGUF 语言模型 + mmproj 视觉编码器）推理引擎。
///
/// 与 `LlamaCppEngine` 是两个独立 actor、各自持有自己的模型权重：视觉包里的语言模型
/// 与聊天用的 Qwen3 是**不同的文件**，共享一份 `llama_model` 既不可能也不安全。
///
/// 解码循环与 `LlamaCppEngine.generate` 是同一条流程（top-k/top-p/temp/dist + UTF-8 字节
/// 缓冲），这里刻意复制而不是抽公共函数：聊天路径本批无法在真机上回归验证，
/// 把它的循环抽走等于用一次不可验证的重构去赌已经在线的行为。改任何一边都要看另一边。
actor VisionLlamaEngine {
    static let shared = VisionLlamaEngine()

    /// mtmd 的媒体标记默认值。**提示词里必须出现它**，`mtmd_tokenize` 才会在这里换成图像 chunk。
    /// 链接到真库时以 context 的标记为准（见 `realMediaMarker`），
    /// 这里的常量只作为调用方拼装提示词时用的占位符。
    static let mediaMarker = "<__media__>"

    /// 送进视觉塔前把长边压到这一尺寸以内。原图常是 4000+ 像素，全尺寸解码出来的 RGB
    /// 有几十 MB，而 Qwen 的视觉塔自己也只处理到千级像素——先缩既是内存决策也是速度决策。
    static let maxImageSide = 1024

    /// Qwen-VL 系列的 patch 数 × 空间合并数（14 × 2）。按这个粒度对齐，
    /// 保证无论 mtmd 内部走不走 smart-resize，拿到的都是合法网格。
    static let pixelAlignment = 28

    static let batchSize = 512

    /// 视觉路径是否可用：取决于二进制是否链接。未链接时上层必须降级，而不是显示假就绪。
    public static var isInferenceAvailable: Bool { LlamaCppEngine.isEngineLinked }

    static func profile(forLLMFileNamed fileName: String) -> ModelInferenceProfile {
        VisionModelRegistry.inferenceProfile(fileName: fileName)
            ?? LlamaCppEngine.defaultInferenceProfile
    }

    #if !targetEnvironment(simulator) && (canImport(LlamaSwift) || canImport(llama))

    private var model: OpaquePointer?
    private var vocab: OpaquePointer?
    private var mtmd: OpaquePointer?
    private var loadedPair: String?
    private var isBackendInitialized = false
    private var activeContextCount = 0
    private var activeRuns = 0
    private var pendingUnload = false

    private init() {
        llama_backend_init()
        isBackendInitialized = true
    }

    var isLoaded: Bool { model != nil && mtmd != nil }

    /// 加载「语言模型 + 视觉编码器」这一对。两件必须一起成功：只成一半会让上层
    /// 以为可以认图，实际每次都在解码阶段失败。
    func ensureLoaded(
        languageModelURL: URL,
        visionProjectorURL: URL,
        imageMaxTokens: Int
    ) throws {
        let llmPath = languageModelURL.path
        let mmprojPath = visionProjectorURL.path
        guard FileManager.default.fileExists(atPath: llmPath),
              FileManager.default.fileExists(atPath: mmprojPath) else {
            throw LlamaInferenceError.modelFileNotFound(
                FileManager.default.fileExists(atPath: llmPath)
                    ? visionProjectorURL.lastPathComponent
                    : languageModelURL.lastPathComponent
            )
        }
        // 图像 token 上限是这张图的预算闸门，它只在 init 时生效，所以必须进缓存键：
        // 只按文件路径命中会让第二次调用沿用第一次的上限，预算算错了还报告「已就绪」。
        let loadKey = "\(llmPath)|\(mmprojPath)|\(max(64, imageMaxTokens))"
        if loadedPair == loadKey, model != nil, mtmd != nil {
            return
        }

        unload()

        if !isBackendInitialized {
            llama_backend_init()
            isBackendInitialized = true
        }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99 // Metal 全层加速，与聊天引擎同口径

        guard let loadedModel = llama_model_load_from_file(llmPath, modelParams) else {
            throw LlamaInferenceError.modelLoadFailed(languageModelURL.lastPathComponent)
        }
        guard let loadedVocab = llama_model_get_vocab(loadedModel) else {
            llama_model_free(loadedModel)
            throw LlamaInferenceError.vocabUnavailable
        }

        var mtmdParams = mtmd_context_params_default()
        mtmdParams.use_gpu = true
        mtmdParams.print_timings = false
        mtmdParams.warmup = false // 首帧不做预热：手机上多花一次编码的时间换首张图的响应
        mtmdParams.n_threads = Self.threadCount()
        // 图像 token 上限是这张图的预算闸门。不显式设的话取 mmproj 元数据里的值，
        // 而注册表钉的是「一张图不能吃光窗口」这条契约——两边必须同一个数。
        mtmdParams.image_max_tokens = Int32(max(64, imageMaxTokens))

        guard let loadedMtmd = mtmd_init_from_file(mmprojPath, loadedModel, mtmdParams) else {
            llama_model_free(loadedModel)
            throw VisionInferenceError.mmprojLoadFailed(visionProjectorURL.lastPathComponent)
        }
        guard mtmd_support_vision(loadedMtmd) else {
            mtmd_free(loadedMtmd)
            llama_model_free(loadedModel)
            throw VisionInferenceError.visionUnsupported(languageModelURL.lastPathComponent)
        }

        self.model = loadedModel
        self.vocab = loadedVocab
        self.mtmd = loadedMtmd
        self.loadedPair = loadKey
    }

    /// 先释放 mtmd（它持有 llama_model 指针），再释放权重。
    func unload() {
        guard activeContextCount == 0 else {
            pendingUnload = true
            return
        }
        pendingUnload = false
        if let mtmd { mtmd_free(mtmd) }
        if let model { llama_model_free(model) }
        self.mtmd = nil
        self.model = nil
        self.vocab = nil
        self.loadedPair = nil
    }

    /// 带图生成：照片 + ChatML 提示词 → 流式文本。
    ///
    /// - Parameter prompt: 完整 ChatML，其中图片所在位置要放 `VisionLlamaEngine.mediaMarker`。
    /// - Parameter image: 已按 EXIF 归一的位图（方向错在这里不会被 mtmd 纠正）。
    func generate(
        prompt: String,
        image: CGImage,
        languageModelURL: URL,
        visionProjectorURL: URL,
        imageMaxTokens: Int,
        maxNewTokens: Int = 256,
        onPartialOutput: @Sendable (String) async -> Void
    ) async throws -> String {
        // 一次只跑一张图。`mtmd_helper_eval_chunks` 明确不是线程安全的，而 actor 可重入：
        // 解码循环每轮都 await 输出回调，第二张照片能在第一张还在输出时挤进来，两次图像编码
        // 共用同一个 mtmd 嵌入缓冲区——结果是一段通顺、但描述的是另一张图的话。
        guard activeRuns == 0 else { throw VisionInferenceError.busy }
        activeRuns += 1
        defer { activeRuns -= 1 }

        try ensureLoaded(
            languageModelURL: languageModelURL,
            visionProjectorURL: visionProjectorURL,
            imageMaxTokens: imageMaxTokens
        )
        guard let model, let vocab, let mtmd else {
            throw LlamaInferenceError.modelLoadFailed(languageModelURL.lastPathComponent)
        }

        let profile = Self.profile(forLLMFileNamed: languageModelURL.lastPathComponent)

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(max(512, min(
            Int(llama_model_n_ctx_train(model)) > 0
                ? Int(llama_model_n_ctx_train(model))
                : profile.fallbackContextTokens,
            profile.maxContextTokens
        )))
        ctxParams.n_batch = UInt32(Self.batchSize)
        let threads = Self.threadCount()
        ctxParams.n_threads = threads
        ctxParams.n_threads_batch = threads

        guard let context = llama_init_from_model(model, ctxParams) else {
            throw LlamaInferenceError.contextInitFailed
        }
        activeContextCount += 1
        defer {
            llama_free(context)
            activeContextCount -= 1
            if activeContextCount == 0, pendingUnload {
                unload()
            }
        }

        // 1. 位图：RGB 交错、nx*ny*3 字节，这是 mtmd_bitmap_init 的唯一约定
        guard let bitmapSpec = Self.rgbBitmap(from: image) else {
            throw VisionInferenceError.imagePreprocessingFailed
        }
        let bitmap: OpaquePointer? = bitmapSpec.bytes.withUnsafeBufferPointer { buf in
            mtmd_bitmap_init(UInt32(bitmapSpec.width), UInt32(bitmapSpec.height), buf.baseAddress)
        }
        defer { if let bitmap { mtmd_bitmap_free(bitmap) } }
        guard let bitmap else { throw VisionInferenceError.imagePreprocessingFailed }

        // 2. tokenize：标记被换成「文本 chunk / 图像 chunk / 文本 chunk」
        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }
        guard let chunks else { throw LlamaInferenceError.contextInitFailed }

        let realMarker = Self.realMediaMarker(mtmd: mtmd)
        let finalPrompt = Self.promptWithMediaMarker(prompt, realMarker: realMarker)
        // 计数必须按**库里那个**标记算。提示词里的占位符已经被换成它了，
        // 再数自己的常量只会数到 0，报出来是「占位符不匹配」——而提示词明明是对的。
        let markerCount = finalPrompt.components(separatedBy: realMarker).count - 1
        guard markerCount == 1 else {
            // 数量不匹配时 mtmd 只会回一个 1，日志里看不出是提示词的问题，先在本地拦住
            throw VisionInferenceError.markerMismatch
        }
        var bitmaps: [OpaquePointer?] = [bitmap]
        let tokenizeStatus = finalPrompt.withCString { textPtr in
            var input = mtmd_input_text(
                text: textPtr,
                text_len: finalPrompt.utf8.count,
                add_special: true,
                parse_special: true
            )
            return mtmd_tokenize(mtmd, chunks, &input, &bitmaps, 1)
        }
        switch tokenizeStatus {
        case 0: break
        case 1: throw VisionInferenceError.markerMismatch
        case 2: throw VisionInferenceError.imagePreprocessingFailed
        default: throw VisionInferenceError.evalFailed(tokenizeStatus)
        }

        // 3. 预算：图像 chunk 已经占掉真实 token 数，窗口检查必须以它为准，
        //    而不是提示词的字符数——一张图就可能把 8192 的窗口吃掉一半。
        //    两个数都要看：KV cache 按 token 计格，M-RoPE 模型的位置数却小于 token 数
        //    （h/w 折叠到同一时间轴），只看 n_pos 会低估占用，直到 llama_decode 才炸。
        let promptTokens = Int(mtmd_helper_get_n_tokens(chunks))
        let promptPositions = Int(mtmd_helper_get_n_pos(chunks))
        let effectiveContextTokens = Int(llama_n_ctx(context))
        let available = effectiveContextTokens - LlamaCppEngine.contextSafetyMargin
        let windowNeed = max(promptTokens, promptPositions) + maxNewTokens
        guard windowNeed <= available else {
            throw VisionInferenceError.contextOverflowWithImage(
                required: windowNeed,
                available: available
            )
        }

        // 4. 交给 helper 逐 chunk 评估（文本 chunk 走 llama_decode，图像 chunk 先 encode 再喂）
        var nPast: llama_pos = 0
        let evalStatus = mtmd_helper_eval_chunks(
            mtmd,
            context,
            chunks,
            0,
            0,
            Int32(Self.batchSize),
            true,
            &nPast
        )
        guard evalStatus == 0 else { throw VisionInferenceError.evalFailed(evalStatus) }

        // 5. 采样链与自回归循环：与聊天路径同一条，无 grammar（认菜输出自由文本，
        //    结构由提示词约束；挂文法会在图文交错的位置上算错候选集）
        let samplerParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(samplerParams) else {
            throw LlamaInferenceError.samplerInitFailed
        }
        defer { llama_sampler_free(sampler) }

        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(Int32(profile.topK)))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(Float(profile.topP), 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(profile.temperature)))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))

        var utf8Bytes: [UInt8] = []
        var pieceBuffer = [CChar](repeating: 0, count: 256)

        for _ in 0..<maxNewTokens {
            try Task.checkCancellation()

            // llama_sampler_sample 内部已 accept，重复 accept 会二次压栈（同聊天路径的注释）
            let newTokenId = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, newTokenId) { break }

            let byteCount = llama_token_to_piece(
                vocab,
                newTokenId,
                &pieceBuffer,
                Int32(pieceBuffer.count),
                0,
                false
            )
            if byteCount > 0 {
                for i in 0..<Int(byteCount) {
                    utf8Bytes.append(UInt8(bitPattern: pieceBuffer[i]))
                }
                let rawDecoded = String(decoding: utf8Bytes, as: UTF8.self)
                if rawDecoded.contains("<|im_end|>") || rawDecoded.contains("<|endoftext|>") { break }
                let cleaned = LlamaCppEngine.cleanChatMLOutput(rawDecoded)
                if !cleaned.isEmpty {
                    await onPartialOutput(cleaned)
                }
            }

            var nextToken = [newTokenId]
            let nextBatch = nextToken.withUnsafeMutableBufferPointer { buf in
                llama_batch_get_one(buf.baseAddress, 1)
            }
            if llama_decode(context, nextBatch) != 0 { break }
        }

        return LlamaCppEngine.cleanChatMLOutput(String(decoding: utf8Bytes, as: UTF8.self))
    }

    // MARK: - 图像准备

    /// 库真实使用的媒体标记。**以当前 context 为准**（`mtmd_get_marker`）：
    /// `media_marker` 能在 `mtmd_context_params` 里被改掉，而提示词里留着旧标记
    /// 只会安静地把图片当成没有——报出来是「占位符不匹配」，提示词明明写着东西。
    private static func realMediaMarker(mtmd: OpaquePointer) -> String {
        if let contextMarker = mtmd_get_marker(mtmd) {
            let marker = String(cString: contextMarker)
            if !marker.isEmpty { return marker }
        }
        let fallback = String(cString: mtmd_default_marker())
        return fallback.isEmpty ? mediaMarker : fallback
    }

    private static func promptWithMediaMarker(_ prompt: String, realMarker: String) -> String {
        guard realMarker != mediaMarker else { return prompt }
        return prompt.replacingOccurrences(of: mediaMarker, with: realMarker)
    }

    /// 归一化成 mtmd 要的紧凑 RGB 字节流：等比缩到长边 ≤ maxImageSide，
    /// 再向下取整到 pixelAlignment 的整数倍。
    ///
    /// CGContext 只能给 32bpp，所以先画成 RGBX 再把每第 4 字节丢掉——
    /// 比逐像素走 CIImage 便宜，也不会引入色彩管理往返。
    private static func rgbBitmap(from image: CGImage) -> (width: Int, height: Int, bytes: [UInt8])? {
        let sourceWidth = image.width
        let sourceHeight = image.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scale = min(1.0, Double(maxImageSide) / Double(max(sourceWidth, sourceHeight)))
        var targetWidth = Int((Double(sourceWidth) * scale).rounded())
        var targetHeight = Int((Double(sourceHeight) * scale).rounded())
        targetWidth = max(pixelAlignment, (targetWidth / pixelAlignment) * pixelAlignment)
        targetHeight = max(pixelAlignment, (targetHeight / pixelAlignment) * pixelAlignment)

        // 自己分配缓冲区，而不是把 Swift 数组的地址交给 CGContext：
        // 上下文活得比 `withUnsafe…` 那次调用久，数组的存储随时可能被释放。
        let pixelCount = targetWidth * targetHeight
        let rgbx = UnsafeMutableRawPointer.allocate(byteCount: pixelCount * 4, alignment: 64)
        defer { rgbx.deallocate() }
        let rgbxBytes = rgbx.bindMemory(to: UInt8.self, capacity: pixelCount * 4)

        guard let ctx = CGContext(
            data: rgbx,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        // 翻转后再画：CGBitmapContext 的坐标系原点在左下，不翻的话缓冲区第 0 行是照片的
        // 底边，视觉塔拿到的是上下颠倒的图——它照样会输出一段通顺的菜名，错得毫无声息。
        ctx.translateBy(x: 0, y: CGFloat(targetHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        var rgb = [UInt8](repeating: 0, count: pixelCount * 3)
        for pixel in 0..<pixelCount {
            rgb[pixel * 3] = rgbxBytes[pixel * 4]
            rgb[pixel * 3 + 1] = rgbxBytes[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = rgbxBytes[pixel * 4 + 2]
        }
        return (targetWidth, targetHeight, rgb)
    }

    private static func threadCount() -> Int32 {
        Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1)))
    }

    #else

    private init() {}

    var isLoaded: Bool { false }

    func ensureLoaded(
        languageModelURL: URL,
        visionProjectorURL: URL,
        imageMaxTokens: Int
    ) throws {
        throw LlamaInferenceError.frameworkNotLinked
    }

    func unload() {}

    /// 未链接二进制时的桩：与聊天引擎同口径抛 `frameworkNotLinked`，由上层降级。
    /// 不要在这里返回空字符串——那会让「拍照算热量」看起来成功了，然后把 0 kcal 写进库。
    func generate(
        prompt: String,
        image: CGImage,
        languageModelURL: URL,
        visionProjectorURL: URL,
        imageMaxTokens: Int,
        maxNewTokens: Int = 256,
        onPartialOutput: @Sendable (String) async -> Void
    ) async throws -> String {
        throw LlamaInferenceError.frameworkNotLinked
    }
    #endif
}
