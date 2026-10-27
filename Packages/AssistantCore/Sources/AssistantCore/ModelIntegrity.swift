import Foundation

/// 发布方核验过的模型产物条目。
///
/// 「文件存在」不等于「文件正确」：下载中断、404 错误页、上游重新量化，
/// 都会产出大小看着正常但内容不对的 GGUF。此结构承载**发布方给出的权威指纹**，
/// 让校验结论可追溯到具体发布版本，而不是「本地文件和它自己比一遍」。
public struct ModelReleaseIntegrity: Equatable, Sendable, Codable {
    /// 发布版本标识（仓库 + 修订号短哈希），用于在「哈希对不上」时让用户知道差在哪
    public let releaseVersion: String
    /// 发布方标注的精确字节数
    public let byteSize: Int64
    /// 发布方标注的 SHA-256（十六进制，64 字符）
    public let sha256: String

    public init(releaseVersion: String, byteSize: Int64, sha256: String) {
        self.releaseVersion = releaseVersion
        self.byteSize = byteSize
        self.sha256 = sha256
    }
}

/// 校验结论。刻意区分「体积不对」与「校验值不对」——两者的用户处置完全不同：
/// 前者通常是**没下完**（重下即可），后者通常是**拿到了别的文件**（换来源或换版本）。
public enum ModelIntegrityVerdict: Equatable, Sendable {
    /// 与某个已核验发布版本完全一致
    case matched(ModelReleaseIntegrity)
    /// 体积与所有已核验版本都不一致（典型：截断 / 换量化版本）
    case sizeMismatch(expected: [Int64], actual: Int64)
    /// 体积对得上但校验值不同（典型：字节被改动 / 拿到同尺寸的其他文件）
    case digestMismatch(expected: [String], actual: String)
    /// 该规格没有发布哈希背书，只能做「本地自洽」校验
    case noPublishedRelease
}

extension ModelIntegrityVerdict {
    /// 是否可以放行（视为可信模型文件）
    public var isAcceptable: Bool {
        switch self {
        case .matched, .noPublishedRelease: return true
        case .sizeMismatch, .digestMismatch: return false
        }
    }

    /// 是否获得发布方背书。与「无背书但可用」区分开——两者的 UI 措辞不同，
    /// 不能都写成「已就绪」，否则就是在过度承诺。
    public var isBackedByPublishedRelease: Bool {
        if case .matched = self { return true }
        return false
    }

    /// 失败分类，供 UI 选择处置话术（重下 / 换来源 / 重新导入）
    public enum FailureKind: Equatable, Sendable {
        case sizeMismatch
        case digestMismatch
    }

    /// 失败分类；无失败时为 nil
    public var failureKind: FailureKind? {
        switch self {
        case .sizeMismatch: return .sizeMismatch
        case .digestMismatch: return .digestMismatch
        case .matched, .noPublishedRelease: return nil
        }
    }
}

/// 模型文件发布指纹比对器（纯函数，无 IO）。
///
/// 设计原则：**先查哈希，再查体积**。
/// 哈希是内容级判据，体积只是代理指标——两个不同的文件完全可以一样大，
/// 而「没下完」的文件几乎总是体积偏小。判定顺序反了会把「拿到了别的文件」
/// 误报成「没下完」，让用户白重下一次。
public enum ModelIntegrityEvaluator {
    /// 比对实际文件与已核验发布清单。
    public static func evaluate(
        actualSize: Int64,
        actualDigest: String,
        releases: [ModelReleaseIntegrity]
    ) -> ModelIntegrityVerdict {
        let normalized = normalizeDigest(actualDigest)
        guard !releases.isEmpty else { return .noPublishedRelease }

        if let hit = releases.first(where: { normalizeDigest($0.sha256) == normalized }) {
            return .matched(hit)
        }

        let expectedSizes = releases.map(\.byteSize)
        if expectedSizes.contains(actualSize) {
            return .digestMismatch(
                expected: releases.map { normalizeDigest($0.sha256) },
                actual: normalized
            )
        }
        return .sizeMismatch(expected: expectedSizes, actual: actualSize)
    }

    /// 归一化十六进制摘要：去空白、转小写。
    /// 摘要比对必须容忍大小写与换行差异，否则同一份文件会因来源不同被判成两个。
    public static func normalizeDigest(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 校验发布清单条目自身是否合法。
    ///
    /// 这条自检很关键：清单里的哈希是手抄/复制来的，抄错一位会让**所有**下载
    /// 全部被判为「校验不通过」，而用户看到的提示只会说「文件无效」。
    public static func isWellFormed(_ release: ModelReleaseIntegrity) -> Bool {
        let digest = normalizeDigest(release.sha256)
        guard digest.count == 64 else { return false }
        guard digest.allSatisfy({ $0.isHexDigit }) else { return false }
        guard release.byteSize > 0 else { return false }
        return !release.releaseVersion.isEmpty
    }
}
