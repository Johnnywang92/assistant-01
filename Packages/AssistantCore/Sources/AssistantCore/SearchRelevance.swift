import Foundation

/// 搜索候选（纯值类型，与 SwiftData 模型解耦，便于做万条级基准测试）。
///
/// 搜索的排序口径必须住在 Core：一旦它只存在于视图层，
/// 「万件待办两步找到」这条验收就没有能自动跑的证据。
public struct SearchCandidate: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let detail: String?
    public let pickupCode: String?
    public let courier: String?
    public let station: String?
    public let location: String?
    public let sourceText: String?
    /// 排序用的时间（越新越靠前；nil 视为最旧）
    public let date: Date?

    public init(
        id: UUID,
        title: String,
        detail: String? = nil,
        pickupCode: String? = nil,
        courier: String? = nil,
        station: String? = nil,
        location: String? = nil,
        sourceText: String? = nil,
        date: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.pickupCode = pickupCode
        self.courier = courier
        self.station = station
        self.location = location
        self.sourceText = sourceText
        self.date = date
    }
}

/// 命中质量。数值越小越靠前。
///
/// 分级的意义在于**排序策略**：只按时间倒序排，
/// 一万条待办里那条「三个月前的旧快递」会被最新的 20 条挤出结果区，
/// 用户无论输入多少次都找不到它——这是「搜索不到」而不是「搜得慢」。
public enum SearchMatchQuality: Int, Comparable, Sendable {
    /// 标题完全一致
    case titleExact = 0
    /// 取件码完全一致（取件码是唯一标识，精确命中价值最高）
    case codeExact = 1
    /// 标题前缀命中
    case titlePrefix = 2
    /// 标题包含
    case titleContains = 3
    /// 其他字段包含（详情/快递公司/驿站/位置/原文）
    case otherFieldContains = 4
    /// 未命中
    case none = 5

    public static func < (lhs: SearchMatchQuality, rhs: SearchMatchQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 一条命中结果
public struct SearchMatch: Equatable, Sendable {
    public let candidate: SearchCandidate
    public let quality: SearchMatchQuality

    public init(candidate: SearchCandidate, quality: SearchMatchQuality) {
        self.candidate = candidate
        self.quality = quality
    }
}

/// 搜索相关性：命中判定 + 质量分级 + 排序（纯函数）。
public enum SearchRelevance {
    /// 判断候选对查询词的命中质量
    public static func match(_ candidate: SearchCandidate, query: String) -> SearchMatchQuality {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        if candidate.title.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return .titleExact
        }
        if let code = candidate.pickupCode,
           !code.isEmpty,
           code.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return .codeExact
        }
        if candidate.title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            // 标题前缀命中比标题包含更接近用户意图（「取件」优先于「取件码已更新」）
            if candidate.title.lowercased().hasPrefix(trimmed.lowercased()) {
                return .titlePrefix
            }
            return .titleContains
        }

        let others = [candidate.detail, candidate.courier, candidate.station, candidate.location, candidate.sourceText]
        for field in others {
            if let value = field,
               value.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return .otherFieldContains
            }
        }
        return .none
    }

    /// 相关性排序：命中质量优先，同质量按时间倒序，最后按标题字典序保证确定性。
    ///
    /// 只返回真正命中的候选——未命中的不该出现在结果里。
    public static func rank(_ candidates: [SearchCandidate], query: String, limit: Int) -> [SearchCandidate] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(candidates.prefix(limit)) }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(candidates.count)
        for candidate in candidates {
            let quality = match(candidate, query: trimmed)
            if quality != .none {
                matches.append(SearchMatch(candidate: candidate, quality: quality))
            }
        }

        matches.sort { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality < rhs.quality }
            let left = lhs.candidate.date ?? .distantPast
            let right = rhs.candidate.date ?? .distantPast
            if left != right { return left > right }
            // 同名同时刻时按标题字典序兜底：排序必须稳定可复现，
            // 否则每次刷新结果顺序都在跳，用户会以为界面出 bug
            if lhs.candidate.title != rhs.candidate.title { return lhs.candidate.title < rhs.candidate.title }
            return lhs.candidate.id.uuidString < rhs.candidate.id.uuidString
        }

        return matches.prefix(limit).map(\.candidate)
    }
}
