import AssistantCore
import CryptoKit
import Foundation

/// 模型文件判据：对话模型与视觉部件共用这一条，避免两套「什么算有效文件」。
///
/// 抽出来之前它是 `LLMModelManager` 的私有静态方法。视觉包需要逐件校验 mmproj 与权重，
/// 复制一份的代价是两条判据会各自漂移——而漂移在设备上的表现同样只有「文件无效」四个字。
///
/// 最后一层是与**发布方指纹**比对，不是「和自己比一遍」——
/// 后者只能发现「文件在下载后被改过」，发现不了「下载来的本来就是别的东西」。
enum ModelFileValidation {

    struct Validated: Equatable {
        let size: Int64
        let digest: String
        let verdict: ModelIntegrityVerdict
    }

    /// 校验：体积下限 → GGUF 头 → 版本 → SHA-256 → 发布指纹比对。
    nonisolated static func validate(
        at url: URL,
        minSizeBytes: Int64,
        releases: [ModelReleaseIntegrity]
    ) throws -> Validated {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= minSizeBytes else { throw ModelFileValidationError.invalidSize }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 8) ?? Data()
        guard header.count == 8, String(data: header.prefix(4), encoding: .ascii) == "GGUF" else {
            throw ModelFileValidationError.invalidHeader
        }
        let version = header.suffix(4).enumerated().reduce(UInt32(0)) { value, byte in
            value | (UInt32(byte.element) << (UInt32(byte.offset) * 8))
        }
        guard version == 2 || version == 3 else { throw ModelFileValidationError.invalidVersion }
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        while true {
            let chunk: Data? = try autoreleasepool {
                try handle.read(upToCount: 1024 * 1024)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let verdict = ModelIntegrityEvaluator.evaluate(
            actualSize: size,
            actualDigest: digest,
            releases: releases
        )
        switch verdict {
        case .matched, .noPublishedRelease:
            return Validated(size: size, digest: digest, verdict: verdict)
        case .sizeMismatch(let expected, let actual):
            throw ModelFileValidationError.sizeMismatch(expected: expected, actual: actual)
        case .digestMismatch(let expected, let actual):
            throw ModelFileValidationError.digestMismatch(expected: expected, actual: actual)
        }
    }

    /// 把校验结论翻译成「已核验的发布版本」文案。
    /// 无发布背书时返回 nil——**不能**编一个版本号出来。
    nonisolated static func releaseVersionText(_ verdict: ModelIntegrityVerdict) -> String? {
        if case .matched(let release) = verdict { return release.releaseVersion }
        return nil
    }
}

enum ModelFileValidationError: LocalizedError {
    case invalidSize
    case invalidHeader
    case invalidVersion
    /// 体积与发布版本不符：典型是下载没下完
    case sizeMismatch(expected: [Int64], actual: Int64)
    /// 体积对得上但内容对不上：典型是下载损坏或拿到了别的文件
    case digestMismatch(expected: [String], actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidSize:
            return L10n.tr("文件体积与预期模型不符。")
        case .invalidHeader:
            return L10n.tr("文件不是支持的 GGUF 格式。")
        case .invalidVersion:
            return L10n.tr("GGUF 文件格式版本不支持。")
        case .sizeMismatch(let expected, let actual):
            let expectedText = expected.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }.joined(separator: " / ")
            let actualText = ByteCountFormatter.string(fromByteCount: actual, countStyle: .file)
            return L10n.choose(
                "文件不完整（应为 \(expectedText)，实际 \(actualText)），请重新下载。",
                "File is incomplete (expected \(expectedText), got \(actualText)). Please download again."
            )
        case .digestMismatch:
            return L10n.choose(
                "文件校验值与发布版本不一致，可能下载损坏或获取到了其他文件，请重新下载或改用其他节点。",
                "File checksum does not match the published release. The download may be corrupted or from a different file. Please re-download or switch source."
            )
        }
    }
}
