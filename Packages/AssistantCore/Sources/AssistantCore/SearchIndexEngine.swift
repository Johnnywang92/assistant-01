import Foundation

// MARK: - 跨模块搜索统一分类

public enum SearchIndexCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case all = "全部"
    case todo = "待办日程"
    case expense = "账目明细"
    case storage = "收纳物品"
    case document = "证件卡包"
    case memo = "语音备忘"
    case password = "密码保险箱"
    case diet = "饮食营养"
    case habitMed = "习惯用药"
    case anniversary = "纪念倒数"
    case lifeVault = "生活档案"
    case health = "健康活力"
    case setting = "系统设置"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .all: return "sparkle.magnifyingglass"
        case .todo: return "checkmark.circle.fill"
        case .expense: return "yensign.circle.fill"
        case .storage: return "archivebox.fill"
        case .document: return "person.text.rectangle.fill"
        case .memo: return "mic.circle.fill"
        case .password: return "key.fill"
        case .diet: return "fork.knife"
        case .habitMed: return "pills.fill"
        case .anniversary: return "gift.fill"
        case .lifeVault: return "folder.fill"
        case .health: return "heart.fill"
        case .setting: return "gearshape.fill"
        }
    }
}

// MARK: - 统一导航路由目标

public enum SearchRoute: Hashable, Codable, Sendable {
    case todo(id: UUID)
    case tab(tabName: String)
    case vault(destination: String)
    case setting(destination: String)
}

// MARK: - 拼音转换与分词工具

public enum PinyinHelper {
    /// 提取拼音变体（全拼、拼音首字母缩写、音节列表）
    public static func pinyinVariations(for text: String) -> (full: String, initials: String, syllables: [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "", []) }

        let mutable = NSMutableString(string: trimmed)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)

        let latin = String(mutable).lowercased()
        let syllables = latin.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let initials = syllables.compactMap { $0.first }.map { String($0) }.joined()
        let full = syllables.joined()
        return (full, initials, syllables)
    }

    /// 提取中文与英文分词（包含单字、双字 bigram、原词）
    public static func extractSearchTokens(text: String) -> Set<String> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        var tokens = Set<String>()
        tokens.insert(trimmed)

        // 标点分词
        let words = trimmed.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for w in words {
            tokens.insert(w)
            // 中文字符生成 2-gram
            let chars = Array(w)
            if chars.count > 1 {
                for i in 0..<(chars.count - 1) {
                    tokens.insert(String(chars[i...(i + 1)]))
                }
            }
        }

        return tokens
    }
}

// MARK: - 索引文档实体

public struct SearchIndexDocument: Identifiable, Sendable {
    public let id: String
    public let category: SearchIndexCategory
    public let title: String
    public let subtitle: String?
    public let content: String?
    public let keywords: [String]
    public let date: Date?
    public let isSensitive: Bool
    public let route: SearchRoute
    public let badge: String?
    public let scoreBoost: Int

    public let pinyinFull: String
    public let pinyinInitials: String
    public let pinyinSyllables: [String]

    public init(
        id: String,
        category: SearchIndexCategory,
        title: String,
        subtitle: String? = nil,
        content: String? = nil,
        keywords: [String] = [],
        date: Date? = nil,
        isSensitive: Bool = false,
        route: SearchRoute,
        badge: String? = nil,
        scoreBoost: Int = 0
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.keywords = keywords
        self.date = date
        self.isSensitive = isSensitive
        self.route = route
        self.badge = badge
        self.scoreBoost = scoreBoost

        let pinyin = PinyinHelper.pinyinVariations(for: title)
        self.pinyinFull = pinyin.full
        self.pinyinInitials = pinyin.initials
        self.pinyinSyllables = pinyin.syllables
    }
}

// MARK: - 索引命中结果

public struct SearchIndexMatch: Identifiable, Sendable {
    public var id: String { document.id }
    public let document: SearchIndexDocument
    public let score: Int
    public let matchedField: String

    public init(document: SearchIndexDocument, score: Int, matchedField: String) {
        self.document = document
        self.score = score
        self.matchedField = matchedField
    }
}

// MARK: - 高性能内存倒排索引引擎

public final class SearchIndexEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [String: SearchIndexDocument] = [:]
    private var tokenIndex: [String: Set<String>] = [:]

    /// 打分要用的小写字段，**在写入索引时预计算一次**。
    ///
    /// 旧实现每次 search 都在 `scoreSingleTerm` 里对 title/keywords/subtitle/content
    /// 现场 `lowercased()`：1000 篇文档 × 每次按键 × 每个词，等于每敲一个字符
    /// 就把整库文本转一遍小写。这些字段在 add 之后不可变，所以提前算好。
    private struct LoweredFields {
        let title: String
        let keywords: [String]
        let subtitle: String?
        let content: String?

        init(_ doc: SearchIndexDocument) {
            title = doc.title.lowercased()
            keywords = doc.keywords.map { $0.lowercased() }
            subtitle = doc.subtitle?.lowercased()
            content = doc.content?.lowercased()
        }
    }
    private var loweredFields: [String: LoweredFields] = [:]

    // MARK: - bigram 候选索引（CORE-05 的另一半）
    //
    // 打分前先用「查询词的二元组交集」把候选文档压下来，再走原打分逻辑；
    // 返回值保证是「可能命中」的超集，因此结果与全量扫描逐条一致（有等价性测试）。
    // 内存上限保护：条目数超限就整体丢弃、退回全量扫描 —— 宁可慢，不可 OOM。
    /// bigram 键。单标量字符用 UInt64 打包（避免每对字符各分配一个 String，
    /// 1000 篇文档建索引时曾是主要的堆分配来源）；含多标量组合字符时才退回字符串。
    private enum BigramKey: Hashable {
        case packed(UInt64)
        case text(String)
    }

    /// 倒排表用数组而不是 Set：建索引时只需 append + 比较 last（同一文档的 bigram 连续写入，
    /// 用 last 比较即可去重），省掉每对字符一次 Set 哈希插入与分配；查询侧再把参与求交的
    /// 少数倒排表转成 Set。
    private var bigramIndex: [BigramKey: [String]] = [:]
    private var bigramEntryCount = 0
    private var bigramSuppressed = false
    private static let bigramEntryLimit = 1_500_000

    /// 测试钩子：关闭后走全量扫描，用来做「裁剪前后结果一致」的等价性测试。
    private let bigramPruningAllowed: Bool

    public init() { bigramPruningAllowed = true }

    /// 测试/基准用：显式关闭 bigram 候选裁剪，走全量扫描。
    /// 生产默认开启；等价性由 `SearchIndexEngineTests` 里的对照用例保证。
    public init(bigramPruningEnabled: Bool) { bigramPruningAllowed = bigramPruningEnabled }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return documents.count
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        documents.removeAll(keepingCapacity: true)
        tokenIndex.removeAll(keepingCapacity: true)
        loweredFields.removeAll(keepingCapacity: true)
        bigramIndex.removeAll(keepingCapacity: true)
        bigramEntryCount = 0
        bigramSuppressed = false
    }

    public func add(_ docs: [SearchIndexDocument]) {
        lock.lock()
        defer { lock.unlock() }
        for doc in docs {
            documents[doc.id] = doc
            loweredFields[doc.id] = LoweredFields(doc)
            indexDocTokens(doc)
            indexDocBigrams(doc)
        }
    }

    public func remove(ids: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for id in ids {
            documents.removeValue(forKey: id)
            loweredFields.removeValue(forKey: id)
        }
        rebuildTokenIndex()
        rebuildBigramIndex()
    }

    // MARK: - bigram 索引

    /// 对一篇文档的「可搜索字符串」建二元组倒排。
    /// 覆盖打分逻辑会用到的全部字段：标题、关键词、副标题、正文、拼音全拼/首字母。
    private func indexDocBigrams(_ doc: SearchIndexDocument) {
        guard bigramPruningAllowed, !bigramSuppressed else { return }
        var fields: [String] = [doc.title, doc.pinyinFull, doc.pinyinInitials]
        fields.append(contentsOf: doc.keywords)
        if let subtitle = doc.subtitle { fields.append(subtitle) }
        if let content = doc.content { fields.append(content) }

        for field in fields {
            for bigram in bigramKeys(of: field) {
                // 文档按整体顺序写入，同一篇文档的 bigram 是连续处理的 —— 用 last 判重即可
                if bigramIndex[bigram]?.last == doc.id { continue }
                bigramIndex[bigram, default: []].append(doc.id)
                bigramEntryCount += 1
                if bigramEntryCount > Self.bigramEntryLimit {
                    // 超预算：整体放弃索引，后续全部走全量扫描
                    bigramIndex.removeAll(keepingCapacity: false)
                    bigramEntryCount = 0
                    bigramSuppressed = true
                    return
                }
            }
        }
    }

    private func rebuildBigramIndex() {
        bigramIndex.removeAll(keepingCapacity: true)
        bigramEntryCount = 0
        bigramSuppressed = false
        for doc in documents.values { indexDocBigrams(doc) }
    }

    private func bigramKeys(of text: String) -> [BigramKey] {
        let chars = Array(text.lowercased())
        guard chars.count >= 2 else { return [] }
        var result: [BigramKey] = []
        result.reserveCapacity(chars.count - 1)
        for i in 0..<(chars.count - 1) {
            result.append(Self.bigramKey(chars[i], chars[i + 1]))
        }
        return result
    }

    @inline(__always)
    private static func bigramKey(_ first: Character, _ second: Character) -> BigramKey {
        let firstScalars = first.unicodeScalars
        let secondScalars = second.unicodeScalars
        if firstScalars.count == 1, secondScalars.count == 1,
           let a = firstScalars.first, let b = secondScalars.first {
            return .packed((UInt64(a.value) << 32) | UInt64(b.value))
        }
        return .text(String([first, second]))
    }

    /// 用 bigram 索引求「包含该词」的候选文档集合（nil 表示不裁剪）。
    ///
    /// 安全性：只要查询词的任一「变体」（原文 / 拼音首字母 / 全拼）短到无法建 bigram，
    /// 该词就可能命中任意文档，本词不参与裁剪；多个词之间取交集（文档必须同时命中所有词）。
    private func candidateDocIDs(for termVariants: [[String]]) -> Set<String>? {
        guard bigramPruningAllowed, !bigramSuppressed, !bigramIndex.isEmpty else { return nil }
        var intersection: Set<String>?
        var pruned = false
        for variants in termVariants {
            let nonEmpty = variants.filter { !$0.isEmpty }
            guard !nonEmpty.isEmpty, nonEmpty.allSatisfy({ $0.count >= 2 }) else { continue }
            var termCandidates: Set<String>?
            for variant in nonEmpty {
                guard let ids = intersectBigrams(of: variant) else { continue }
                termCandidates = termCandidates.map { $0.union(ids) } ?? ids
            }
            guard let ids = termCandidates else { continue }
            pruned = true
            if let current = intersection {
                intersection = current.intersection(ids)
            } else {
                intersection = ids
            }
            if intersection?.isEmpty == true { return [] }
        }
        return pruned ? intersection : nil
    }

    private func intersectBigrams(of text: String) -> Set<String>? {
        let chars = Array(text.lowercased())
        guard chars.count >= 2 else { return nil }
        var result: Set<String>?
        for i in 0..<(chars.count - 1) {
            let bigram = Self.bigramKey(chars[i], chars[i + 1])
            guard let postings = bigramIndex[bigram], !postings.isEmpty else { return [] }
            if let current = result {
                result = current.intersection(postings)
            } else {
                result = Set(postings)
            }
            if result?.isEmpty == true { return [] }
        }
        return result
    }

    private func indexDocTokens(_ doc: SearchIndexDocument) {
        var tokens = Set<String>()
        tokens.formUnion(PinyinHelper.extractSearchTokens(text: doc.title))

        if !doc.pinyinFull.isEmpty { tokens.insert(doc.pinyinFull) }
        if !doc.pinyinInitials.isEmpty { tokens.insert(doc.pinyinInitials) }
        for s in doc.pinyinSyllables { tokens.insert(s) }

        for kw in doc.keywords {
            tokens.formUnion(PinyinHelper.extractSearchTokens(text: kw))
            let p = PinyinHelper.pinyinVariations(for: kw)
            if !p.full.isEmpty { tokens.insert(p.full) }
            if !p.initials.isEmpty { tokens.insert(p.initials) }
        }

        if let sub = doc.subtitle {
            tokens.formUnion(PinyinHelper.extractSearchTokens(text: sub))
        }
        if let content = doc.content {
            tokens.formUnion(PinyinHelper.extractSearchTokens(text: content))
        }

        for token in tokens {
            let lower = token.lowercased()
            if tokenIndex[lower] == nil {
                tokenIndex[lower] = Set<String>()
            }
            tokenIndex[lower]?.insert(doc.id)
        }
    }

    private func rebuildTokenIndex() {
        tokenIndex.removeAll(keepingCapacity: true)
        for doc in documents.values {
            indexDocTokens(doc)
        }
    }

    /// 单词对文档的匹配得分（使用预计算的查询词拼音，杜绝热循环中的 CFStringTransform）
    private func scoreSingleTerm(
        term: String,
        termInitials: String,
        termFull: String,
        doc: SearchIndexDocument,
        lowered: LoweredFields
    ) -> (score: Int, field: String) {
        var bestScore = 0
        var matchedField = "none"

        func evaluate(_ newScore: Int, _ field: String) {
            if newScore > bestScore {
                bestScore = newScore
                matchedField = field
            }
        }

        let titleLower = lowered.title

        // 1–3. 标题完全/前缀/包含匹配。
        //
        // 标题命中就是本次打分的全局最高档（1000 > 850 > 700 > 后面所有档位），
        // 因此**直接返回**：省掉拼音 2 次 contains、关键词循环、副标题/正文 contains。
        // 搜索是「每敲一个键都跑一遍全库」的热路径，这一步能砍掉大部分文档的打分成本。
        if titleLower == term { return (1000, "title") }
        if titleLower.hasPrefix(term) { return (850, "title") }
        if titleLower.contains(term) { return (700, "title") }

        // 4. 拼音首字母缩写
        if !doc.pinyinInitials.isEmpty {
            if doc.pinyinInitials == term || (!termInitials.isEmpty && doc.pinyinInitials == termInitials) {
                return (680, "pinyin")
            } else if doc.pinyinInitials.hasPrefix(term) || (!termInitials.isEmpty && doc.pinyinInitials.hasPrefix(termInitials)) {
                evaluate(580, "pinyin")
            } else if doc.pinyinInitials.contains(term) || (!termInitials.isEmpty && doc.pinyinInitials.contains(termInitials)) {
                evaluate(480, "pinyin")
            }
        }

        // 5. 拼音全拼匹配
        if !doc.pinyinFull.isEmpty {
            if doc.pinyinFull == term || (!termFull.isEmpty && doc.pinyinFull == termFull) {
                return (650, "pinyin")
            } else if doc.pinyinFull.hasPrefix(term) || (!termFull.isEmpty && doc.pinyinFull.hasPrefix(termFull)) {
                evaluate(550, "pinyin")
            } else if doc.pinyinFull.contains(term) || (!termFull.isEmpty && doc.pinyinFull.contains(termFull)) {
                evaluate(450, "pinyin")
            }
        }

        // 6. 标签与关键词匹配
        for kwLower in lowered.keywords {
            if kwLower == term {
                return (620, "keyword")
            } else if kwLower.hasPrefix(term) {
                evaluate(520, "keyword")
                break
            } else if kwLower.contains(term) {
                evaluate(420, "keyword")
                break
            }
        }

        // 7. 副标题/详情描述匹配
        if let sub = lowered.subtitle, sub.contains(term) {
            evaluate(320, "subtitle")
        }

        // 8. 全文内容/备注匹配
        if let content = lowered.content, content.contains(term) {
            evaluate(180, "content")
        }

        return (bestScore, matchedField)
    }

    /// 高性能全域搜索：支持完全匹配、前缀匹配、多词组合匹配、拼音全拼与首字母匹配
    public func search(query: String, category: SearchIndexCategory = .all, limit: Int = 30) -> [SearchIndexMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        let terms = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        // 预先一次性算好各 term 的拼音，避免在 1000+ 循环里反复调 CFStringTransform
        struct TermContext {
            let term: String
            let initials: String
            let full: String
        }
        let termContexts = terms.map { t -> TermContext in
            let v = PinyinHelper.pinyinVariations(for: t)
            return TermContext(term: t, initials: v.initials, full: v.full)
        }

        lock.lock()
        // 先用 bigram 索引压候选集（nil = 不裁剪），再连同预计算的小写字段一起快照，
        // 避免在打分热循环里再取锁/再转小写。
        let candidates = candidateDocIDs(for: termContexts.map { [$0.term, $0.initials, $0.full] })
        var allDocs: [(doc: SearchIndexDocument, lowered: LoweredFields)] = []
        allDocs.reserveCapacity(candidates?.count ?? documents.count)
        for doc in documents.values {
            if let candidates, !candidates.contains(doc.id) { continue }
            allDocs.append((doc, loweredFields[doc.id] ?? LoweredFields(doc)))
        }
        lock.unlock()

        var matches: [SearchIndexMatch] = []
        matches.reserveCapacity(min(allDocs.count, limit * 2))

        for entry in allDocs {
            let doc = entry.doc
            if category != .all && doc.category != category {
                continue
            }

            var totalScore = 0
            var primaryField = "title"

            if termContexts.count > 1 {
                // 多词组合查询：每个词必须都能在文档中找到某种匹配
                var allTermsMatched = true
                var sumScore = 0
                for ctx in termContexts {
                    let (score, field) = scoreSingleTerm(
                        term: ctx.term,
                        termInitials: ctx.initials,
                        termFull: ctx.full,
                        doc: doc,
                        lowered: entry.lowered
                    )
                    if score == 0 {
                        allTermsMatched = false
                        break
                    }
                    sumScore += score
                    if primaryField == "title" { primaryField = field }
                }
                if allTermsMatched {
                    totalScore = sumScore / termContexts.count + 200 // 全部命中组合奖励
                }
            } else if let ctx = termContexts.first {
                let (score, field) = scoreSingleTerm(
                    term: ctx.term,
                    termInitials: ctx.initials,
                    termFull: ctx.full,
                    doc: doc,
                    lowered: entry.lowered
                )
                totalScore = score
                primaryField = field
            }

            guard totalScore > 0 else { continue }

            // 结合时间新鲜度加权
            var finalScore = totalScore + doc.scoreBoost
            if let date = doc.date {
                let daysAgo = Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 0
                if daysAgo >= 0 && daysAgo <= 30 {
                    finalScore += (30 - daysAgo)
                }
            }

            matches.append(SearchIndexMatch(document: doc, score: finalScore, matchedField: primaryField))
        }

        // 排序：得分优先，其次时间，最后标题
        matches.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            let lDate = lhs.document.date ?? .distantPast
            let rDate = rhs.document.date ?? .distantPast
            if lDate != rDate {
                return lDate > rDate
            }
            return lhs.document.title < rhs.document.title
        }

        return Array(matches.prefix(limit))
    }
}
