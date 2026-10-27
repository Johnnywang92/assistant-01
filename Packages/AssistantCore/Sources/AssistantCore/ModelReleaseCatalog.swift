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

    /// 全部条目
    public static let all: [Entry] = [qwen3_1_7b, qwen3_4b, qwen2_5_1_5b]

    /// 按 id 取条目
    public static func entry(id: String) -> Entry? {
        all.first { $0.id == id }
    }
}
