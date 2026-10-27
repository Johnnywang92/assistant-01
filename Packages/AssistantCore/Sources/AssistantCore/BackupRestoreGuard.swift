import Foundation

/// 备份 / 还原的完整性守卫（纯逻辑，无 IO）。
///
/// **要解决的问题**：「备份成功」不等于「备份里有全部内容」。
/// 证件照片、语音音频存在沙盒文件里，导出时读不到就会变成 nil，
/// 而旧实现照常写进备份包并报告成功——用户拿到一份「成功」的备份，
/// 还原后才发现证件没有照片、语音点不开，而且**没有任何地方提示过**。
///
/// 这套逻辑把「哪些附件本应存在」与「实际是否带上」分开核对，
/// 让丢失在**导出/还原之前**就被发现，而不是几个月后翻旧备份才发现。
public enum BackupRestoreGuard {

    // MARK: - 附件核对

    /// 一个应被备份的附件
    public struct AttachmentExpectation: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case idPhotoFront
            case idPhotoBack
            case voiceMemoAudio
        }

        /// 归属条目标题（用于给用户指认是哪一条丢了）
        public let ownerTitle: String
        /// 附件种类
        public let kind: Kind
        /// 沙盒文件名。为 nil 表示「这条记录本来就没有附件」，不算缺失。
        public let fileName: String?
        /// 导出/还原时是否真的取到了字节
        public let hasData: Bool

        public init(ownerTitle: String, kind: Kind, fileName: String?, hasData: Bool) {
            self.ownerTitle = ownerTitle
            self.kind = kind
            self.fileName = fileName
            self.hasData = hasData
        }
    }

    /// 附件核对结论
    public enum AttachmentAudit: Equatable, Sendable {
        /// 全部带上
        case complete
        /// 有附件缺失（`missing` 为非空数组）
        case incomplete(missing: [AttachmentExpectation])
    }

    /// 逐项核对附件是否真的进了备份包。
    ///
    /// 判定规则刻意只对「**本来应该有**附件」的条目提要求：
    /// `fileName == nil` 表示这条记录压根没有附件，不算缺失；
    /// `fileName != nil` 但 `hasData == false` 才是真的丢了东西。
    public static func auditAttachments(_ expectations: [AttachmentExpectation]) -> AttachmentAudit {
        let missing = expectations.filter { $0.fileName != nil && !$0.hasData }
        return missing.isEmpty ? .complete : .incomplete(missing: missing)
    }

    /// 把缺失附件转成给用户看的一句话（按种类去重，避免同一证件刷屏）
    public static func describeMissingAttachments(_ expectations: [AttachmentExpectation]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in expectations {
            let label: String
            switch item.kind {
            case .idPhotoFront: label = "证件「\(item.ownerTitle)」正面照片"
            case .idPhotoBack: label = "证件「\(item.ownerTitle)」背面照片"
            case .voiceMemoAudio: label = "语音「\(item.ownerTitle)」音频"
            }
            if seen.insert(label).inserted {
                result.append(label)
            }
        }
        return result
    }

    // MARK: - 孤儿文件清理闸

    /// 跳过清理的原因
    public enum PruneSkipReason: String, Equatable, Sendable {
        /// 引用集查询失败——**绝不能**清理：空集合会把所有附件文件删光
        case referenceLookupFailed
        /// 本来就没有任何被引用的文件，没什么可清的
        case noReferences
    }

    /// 清理决策
    public enum PruneDecision: Equatable, Sendable {
        /// 可以清理，保留清单之外的文件删除
        case prune(keeping: Set<String>)
        /// 跳过清理
        case skipped(reason: PruneSkipReason)
    }

    /// 判断能不能清理沙盒里的孤儿附件文件。
    ///
    /// 这条闸是为了防一个具体的灾难：旧实现用 `try?` 读引用集，
    /// 读失败时得到空集合，再拿空集合去「保留」，等于**删光所有证件照片和语音**。
    /// 查询失败时的正确反应是「不清」，不是「按空集清」。
    public static func pruneDecision(
        referenceLookupSucceeded: Bool,
        referencedFileNames: Set<String>
    ) -> PruneDecision {
        guard referenceLookupSucceeded else {
            return .skipped(reason: .referenceLookupFailed)
        }
        guard !referencedFileNames.isEmpty else {
            return .skipped(reason: .noReferences)
        }
        return .prune(keeping: referencedFileNames)
    }

    // MARK: - 导入结果台账

    /// 某一类数据的「应有多少 / 实际导入多少」
    public struct ImportExpectation: Equatable, Sendable {
        /// 数据种类标识（如 "todos"）
        public let key: String
        /// 备份包里该类的条数
        public let expectedCount: Int
        /// 实际写入的条数
        public let importedCount: Int
        /// 合并策略下「本机已有、被跳过」的条数
        public let alreadyPresentCount: Int

        public init(key: String, expectedCount: Int, importedCount: Int, alreadyPresentCount: Int = 0) {
            self.key = key
            self.expectedCount = expectedCount
            self.importedCount = importedCount
            self.alreadyPresentCount = alreadyPresentCount
        }

        /// 真正丢掉的条数
        public var shortfall: Int {
            max(0, expectedCount - importedCount - alreadyPresentCount)
        }
    }

    /// 导入结论
    public enum ImportVerdict: Equatable, Sendable {
        /// 数据一条没少
        case complete
        /// 有数据没落库（`missingByKey` 记录每类缺了多少）
        case partial(missingByKey: [String: Int])
    }

    /// 用「应有多少 vs 实际多少」核对导入结果。
    ///
    /// 这是「成功但部分丢失」的最后一道闸：还原流程本身不抛错，
    /// 但台账能算出哪类数据少了几条——少的那部分不能被报告成「还原成功」。
    public static func importVerdict(_ expectations: [ImportExpectation]) -> ImportVerdict {
        var missingByKey: [String: Int] = [:]
        for item in expectations where item.shortfall > 0 {
            missingByKey[item.key] = item.shortfall
        }
        return missingByKey.isEmpty ? .complete : .partial(missingByKey: missingByKey)
    }
}
