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

    public init() {}

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
    }

    public func add(_ docs: [SearchIndexDocument]) {
        lock.lock()
        defer { lock.unlock() }
        for doc in docs {
            documents[doc.id] = doc
            indexDocTokens(doc)
        }
    }

    public func remove(ids: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for id in ids {
            documents.removeValue(forKey: id)
        }
        rebuildTokenIndex()
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
        doc: SearchIndexDocument
    ) -> (score: Int, field: String) {
        var bestScore = 0
        var matchedField = "none"

        func evaluate(_ newScore: Int, _ field: String) {
            if newScore > bestScore {
                bestScore = newScore
                matchedField = field
            }
        }

        let titleLower = doc.title.lowercased()

        // 1. 标题完全精确匹配
        if titleLower == term {
            evaluate(1000, "title")
        }
        // 2. 标题前缀匹配
        else if titleLower.hasPrefix(term) {
            evaluate(850, "title")
        }
        // 3. 标题包含匹配
        else if titleLower.contains(term) {
            evaluate(700, "title")
        }

        // 4. 拼音首字母缩写
        if !doc.pinyinInitials.isEmpty {
            if doc.pinyinInitials == term || (!termInitials.isEmpty && doc.pinyinInitials == termInitials) {
                evaluate(680, "pinyin")
            } else if doc.pinyinInitials.hasPrefix(term) || (!termInitials.isEmpty && doc.pinyinInitials.hasPrefix(termInitials)) {
                evaluate(580, "pinyin")
            } else if doc.pinyinInitials.contains(term) || (!termInitials.isEmpty && doc.pinyinInitials.contains(termInitials)) {
                evaluate(480, "pinyin")
            }
        }

        // 5. 拼音全拼匹配
        if !doc.pinyinFull.isEmpty {
            if doc.pinyinFull == term || (!termFull.isEmpty && doc.pinyinFull == termFull) {
                evaluate(650, "pinyin")
            } else if doc.pinyinFull.hasPrefix(term) || (!termFull.isEmpty && doc.pinyinFull.hasPrefix(termFull)) {
                evaluate(550, "pinyin")
            } else if doc.pinyinFull.contains(term) || (!termFull.isEmpty && doc.pinyinFull.contains(termFull)) {
                evaluate(450, "pinyin")
            }
        }

        // 6. 标签与关键词匹配
        for kw in doc.keywords {
            let kwLower = kw.lowercased()
            if kwLower == term {
                evaluate(620, "keyword")
                break
            } else if kwLower.hasPrefix(term) {
                evaluate(520, "keyword")
                break
            } else if kwLower.contains(term) {
                evaluate(420, "keyword")
                break
            }
        }

        // 7. 副标题/详情描述匹配
        if let sub = doc.subtitle?.lowercased(), sub.contains(term) {
            evaluate(320, "subtitle")
        }

        // 8. 全文内容/备注匹配
        if let content = doc.content?.lowercased(), content.contains(term) {
            evaluate(180, "content")
        }

        return (bestScore, matchedField)
    }

    /// 高性能全域搜索：支持完全匹配、前缀匹配、多词组合匹配、拼音全拼与首字母匹配
    public func search(query: String, category: SearchIndexCategory = .all, limit: Int = 30) -> [SearchIndexMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        lock.lock()
        let allDocs = Array(documents.values)
        lock.unlock()

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

        var matches: [SearchIndexMatch] = []
        matches.reserveCapacity(min(allDocs.count, limit * 2))

        for doc in allDocs {
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
                        doc: doc
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
                    doc: doc
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
