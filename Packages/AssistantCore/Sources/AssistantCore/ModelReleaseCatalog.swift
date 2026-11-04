import Foundation

/// 已核验的模型发布清单。
///
/// **为什么指纹数据放在 Core 而不是 App**：哈希是手抄/复制来的常量，
/// 抄错一位会让**所有**下载全部被判为「校验不通过」，而用户看到的只有
/// 「文件无效」四个字，根本查不出原因。把清单下沉到 Core 后，
/// `ModelIntegrityTests` 可以对每一条做格式自检——常量出错要在发布前被拦下。
///
/// 数据来源与核验方式：
/// - ModelScope 官方文件接口返回的 `Sha256` / `Size` / `Revision` 字段；
/// - 与 Hugging Face 同一文件的 LFS pointer `oid sha256:` / `size` 交叉核对一致后才写入。
///
/// 只核对单侧来源是不够的——那等于把「自己下载来的东西」当成标准答案。
///
/// **例外：`visionAll`（Qwen3-VL 视觉包）**。写入时本网络访问 huggingface.co 超时，
/// 未能做 HF 侧交叉核对；改用同一发布方的两个独立接口对齐——文件接口的 `Sha256` 与
/// `resolve` 下载端点返回的 `X-Linked-Etag` 逐字相同，且体积一致。这只证明
/// 「ModelScope 给出的地址与它给出的指纹自洽」，不证明上游没换过产物，
/// 因此这两个条目**只配 ModelScope 一个下载源**（见 `VisionModelRegistry`），
/// HF 指纹补到之后再加第二个源。
public enum ModelReleaseCatalog {

    /// 清单条目
    public struct Entry: Equatable, Sendable {
        /// 与 App 侧模型规格一一对应的稳定标识
        public let id: String
        /// 展示名（供 UI 说明「核验的是哪个产物」）
        public let displayName: String
        /// 发布版本标识（仓库 + 修订号短哈希）
        public let releaseVersion: String
        /// 发布方标注的精确字节数
        public let byteSize: Int64
        /// 发布方标注的 SHA-256
        public let sha256: String

        public init(id: String, displayName: String, releaseVersion: String, byteSize: Int64, sha256: String) {
            self.id = id
            self.displayName = displayName
            self.releaseVersion = releaseVersion
            self.byteSize = byteSize
            self.sha256 = sha256
        }

        /// 转换为比对器可直接消费的指纹
        public var integrity: ModelReleaseIntegrity {
            ModelReleaseIntegrity(releaseVersion: releaseVersion, byteSize: byteSize, sha256: sha256)
        }
    }

    /// Qwen3-1.7B-Instruct · Q4_K_M
    public static let qwen3_1_7b = Entry(
        id: "qwen3_1_7b",
        displayName: "Qwen3-1.7B-Instruct · Q4_K_M",
        releaseVersion: "unsloth/Qwen3-1.7B-GGUF@1e3f4948",
        byteSize: 1_107_409_472,
        sha256: "b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897"
    )

    /// Qwen3-4B-Instruct · Q4_K_M
    public static let qwen3_4b = Entry(
        id: "qwen3_4b",
        displayName: "Qwen3-4B-Instruct · Q4_K_M",
        releaseVersion: "Qwen/Qwen3-4B-GGUF@8cca206c",
        byteSize: 2_497_280_256,
        sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5"
    )

    /// Qwen2.5-1.5B-Instruct · Q4_K_M
    public static let qwen2_5_1_5b = Entry(
        id: "qwen2_5_1_5b",
        displayName: "Qwen2.5-1.5B-Instruct · Q4_K_M",
        releaseVersion: "Qwen/Qwen2.5-1.5B-Instruct-GGUF@e8b19c78",
        byteSize: 1_117_320_736,
        sha256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e"
    )

    /// 全部对话模型条目（与 `ModelRegistry.builtIn` 一一对应，契约测试按此判红）
    public static let all: [Entry] = [qwen3_1_7b, qwen3_4b, qwen2_5_1_5b]

    // MARK: - 视觉模型包

    /// Qwen3-VL-2B-Instruct · Q4_K_M（视觉包的语言模型部件）
    ///
    /// 体积与 `qwen3_1_7b` 只差 480 字节，哈希完全不同——这正是清单最容易被抄错的地方，
    /// 所以两个值在 `ModelIntegrityTests` 里分别钉死，不允许互相「顺手改齐」。
    public static let qwen3_vl_2b_llm = Entry(
        id: "qwen3_vl_2b_llm",
        displayName: "Qwen3-VL-2B-Instruct · Q4_K_M（语言模型部件）",
        releaseVersion: "Qwen/Qwen3-VL-2B-Instruct-GGUF@1d49f1a7",
        byteSize: 1_107_409_952,
        sha256: "089d75c52f4b7ffc56ba998ffc50aae89fcafc755f9e7208aacca281dca6c2ae"
    )

    /// Qwen3-VL-2B-Instruct · Q8_0（视觉包的视觉编码部件，llama.cpp 的 mmproj）
    public static let qwen3_vl_2b_mmproj = Entry(
        id: "qwen3_vl_2b_mmproj",
        displayName: "Qwen3-VL-2B-Instruct · mmproj Q8_0（视觉编码器部件）",
        releaseVersion: "Qwen/Qwen3-VL-2B-Instruct-GGUF@1d49f1a7",
        byteSize: 445_053_216,
        sha256: "f9a68fabba69c3b81e153367b2c7521030b0fa8bb0de400c9599c8e6725f9c82"
    )

    /// 视觉包条目。刻意与 `all` 分开：`ModelRegistry.validate()` 按「`all` 与 builtIn 一一对应」
    /// 判红，而视觉包不是可选对话规格，混进去会让它出现在端侧模型单选列表里。
    public static let visionAll: [Entry] = [qwen3_vl_2b_llm, qwen3_vl_2b_mmproj]

    /// 按 id 取条目（对话模型与视觉部件共用一张表）
    public static func entry(id: String) -> Entry? {
        (all + visionAll).first { $0.id == id }
    }
}
