import AssistantCore
import Foundation
import XCTest

final class SearchIndexEngineTests: XCTestCase {
    var engine: SearchIndexEngine!

    override func setUp() {
        super.setUp()
        engine = SearchIndexEngine()
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    func testPinyinVariationsGeneration() {
        let text = "睡眠提醒"
        let pinyin = PinyinHelper.pinyinVariations(for: text)
        XCTAssertEqual(pinyin.full, "shuimiantixing")
        XCTAssertEqual(pinyin.initials, "smtx")
        XCTAssertEqual(pinyin.syllables, ["shui", "mian", "ti", "xing"])
    }

    func testExactAndPrefixSearch() {
        let doc1 = SearchIndexDocument(
            id: "setting_sleep",
            category: .setting,
            title: "睡眠与作息提醒",
            subtitle: "就寝提醒与睡前酝酿",
            keywords: ["睡眠", "作息", "就寝", "早睡"],
            route: .setting(destination: "sleep")
        )
        let doc2 = SearchIndexDocument(
            id: "todo_milk",
            category: .todo,
            title: "去超市买牛奶",
            subtitle: "常温全脂牛奶两箱",
            route: .todo(id: UUID())
        )
        engine.add([doc1, doc2])

        // Exact match
        let matches1 = engine.search(query: "睡眠与作息提醒")
        XCTAssertEqual(matches1.first?.document.id, "setting_sleep")
        XCTAssertEqual(matches1.first?.score, 1000)

        // Prefix match
        let matches2 = engine.search(query: "去超市")
        XCTAssertEqual(matches2.first?.document.id, "todo_milk")
        XCTAssertEqual(matches2.first?.matchedField, "title")
    }

    func testPinyinInitialsAndFullPinyinSearch() {
        let doc1 = SearchIndexDocument(
            id: "setting_theme",
            category: .setting,
            title: "外观主题与深色模式",
            keywords: ["主题", "换肤", "深色", "暗黑"],
            route: .setting(destination: "appearance")
        )
        let doc2 = SearchIndexDocument(
            id: "expense_dinner",
            category: .expense,
            title: "聚餐消费",
            subtitle: "火锅晚餐支出 260 元",
            keywords: ["餐饮", "美食", "记账"],
            route: .tab(tabName: "expenses")
        )
        engine.add([doc1, doc2])

        // Initials search: "wgz" -> "外观主题" (wgztyssms)
        let matchesInitials = engine.search(query: "wg")
        XCTAssertEqual(matchesInitials.first?.document.id, "setting_theme")

        // Pinyin initials "jc" -> "聚餐"
        let matchesJC = engine.search(query: "jc")
        XCTAssertEqual(matchesJC.first?.document.id, "expense_dinner")

        // Full pinyin "jucan" -> "聚餐"
        let matchesJucan = engine.search(query: "jucan")
        XCTAssertEqual(matchesJucan.first?.document.id, "expense_dinner")
    }

    func testCategoryFilter() {
        let doc1 = SearchIndexDocument(
            id: "setting_budget",
            category: .setting,
            title: "预算设置",
            keywords: ["消费", "预算"],
            route: .setting(destination: "reminders")
        )
        let doc2 = SearchIndexDocument(
            id: "expense_budget",
            category: .expense,
            title: "本月餐饮预算扣除",
            subtitle: "-150 元",
            route: .tab(tabName: "expenses")
        )
        engine.add([doc1, doc2])

        let allMatches = engine.search(query: "预算", category: .all)
        XCTAssertEqual(allMatches.count, 2)

        let settingMatches = engine.search(query: "预算", category: .setting)
        XCTAssertEqual(settingMatches.count, 1)
        XCTAssertEqual(settingMatches.first?.document.id, "setting_budget")

        let expenseMatches = engine.search(query: "预算", category: .expense)
        XCTAssertEqual(expenseMatches.count, 1)
        XCTAssertEqual(expenseMatches.first?.document.id, "expense_budget")
    }

    func testSettingsDocumentsIndexingAndSearch() {
        let settingsDocs = [
            SearchIndexDocument(
                id: "setting_model",
                category: .setting,
                title: "AI 大模型配置",
                subtitle: "API Key、厂商选择与参数",
                keywords: ["deepseek", "openai", "claude", "模型", "key"],
                route: .setting(destination: "aiData")
            ),
            SearchIndexDocument(
                id: "setting_applock",
                category: .setting,
                title: "生物识别与应用锁",
                subtitle: "Face ID 与 Touch ID 防偷窥保护",
                keywords: ["密码", "面容", "指纹", "隐私", "锁定"],
                route: .setting(destination: "aiData")
            )
        ]
        engine.add(settingsDocs)

        // Search by English model keyword
        let matchesDeepseek = engine.search(query: "deepseek")
        XCTAssertEqual(matchesDeepseek.first?.document.id, "setting_model")

        // Search by Face ID
        let matchesFaceID = engine.search(query: "face id")
        XCTAssertEqual(matchesFaceID.first?.document.id, "setting_applock")

        // Search by initials "yys" -> "应用锁"
        let matchesYYS = engine.search(query: "yys")
        XCTAssertEqual(matchesYYS.first?.document.id, "setting_applock")
    }

    func testIndexPerformanceWithLargeDataset() {
        var bulkDocs: [SearchIndexDocument] = []
        for i in 0..<1000 {
            bulkDocs.append(
                SearchIndexDocument(
                    id: "item_\(i)",
                    category: .todo,
                    title: "测试事项 \(i) 快递取件顺丰",
                    subtitle: "取件码 88-\(i)",
                    keywords: ["快递", "取件", "顺丰"],
                    route: .todo(id: UUID())
                )
            )
        }

        let startAdd = Date()
        engine.add(bulkDocs)
        let addDuration = Date().timeIntervalSince(startAdd)
        XCTAssertEqual(engine.count, 1000)
        XCTAssertLessThan(addDuration, 0.5, "Indexing 1000 items should take under 500ms")

        let startSearch = Date()
        let results = engine.search(query: "顺丰 88-500", limit: 10)
        let searchDuration = Date().timeIntervalSince(startSearch)
        XCTAssertFalse(results.isEmpty)
        XCTAssertLessThan(searchDuration, 0.05, "Searching 1000 items should take under 50ms")
    }

    // MARK: - bigram 候选裁剪：裁剪前后结果必须逐条一致

    /// 造一批有区分度的文档：中文标题/关键词/正文、拼音字段、英文与数字，覆盖各种查询形态。
    private func makePruningCorpus() -> [SearchIndexDocument] {
        var docs: [SearchIndexDocument] = []
        for i in 0..<300 {
            let title: String
            let keywords: [String]
            let subtitle: String?
            let content: String?
            switch i % 6 {
            case 0:
                title = "顺丰快递取件 \(i)"; keywords = ["快递", "顺丰", "取件"]
                subtitle = "取件码 88-\(i)"; content = "驿站：丰巢柜"
            case 1:
                title = "麦当劳午餐 \(i)"; keywords = ["午饭", "汉堡"]
                subtitle = "花费 38 元"; content = nil
            case 2:
                title = "体检报告 \(i)"; keywords = ["健康", "体检"]
                subtitle = nil; content = "血压血糖血脂复查"
            case 3:
                title = "买猫粮 \(i)"; keywords = ["宠物", "猫"]
                subtitle = "京东下单 199"; content = "皇家猫粮 2kg"
            case 4:
                title = "学习 Swift 并发 \(i)"; keywords = ["学习", "swift"]
                subtitle = "第 \(i) 课"; content = "actor 与 async await"
            default:
                title = "水电费 \(i)"; keywords = ["缴费", "生活"]
                subtitle = "金额 235.60"; content = nil
            }
            docs.append(SearchIndexDocument(
                id: "doc_\(i)",
                category: i % 2 == 0 ? .todo : .expense,
                title: title,
                subtitle: subtitle,
                content: content,
                keywords: keywords,
                route: .todo(id: UUID())
            ))
        }
        return docs
    }

    func testBigramPruningMatchesFullScan() {
        let docs = makePruningCorpus()
        let pruned = SearchIndexEngine()
        let fullScan = SearchIndexEngine(bigramPruningEnabled: false)
        pruned.add(docs)
        fullScan.add(docs)

        let queries = [
            "顺", "顺丰", "顺丰 取件", "快递 顺丰", "取下",
            "麦", "麦当劳", "午饭 汉堡", "shunfeng", "sf", "kuaidi",
            "88-12", "体检 健康", "猫粮", "swift async", "actor",
            "不存在的词", "水电费 235", "第 12 课", "199"
        ]
        for query in queries {
            for category in [SearchIndexCategory.all, .todo, .expense] {
                let a = pruned.search(query: query, category: category, limit: 50)
                let b = fullScan.search(query: query, category: category, limit: 50)
                XCTAssertEqual(a.map(\.document.id), b.map(\.document.id),
                               "查询「\(query)」category=\(category) 裁剪后结果不一致")
                XCTAssertEqual(a.map(\.score), b.map(\.score),
                               "查询「\(query)」category=\(category) 裁剪后分数不一致")
            }
        }
    }

    func testBigramPruningAfterRemoveAndClear() {
        let docs = makePruningCorpus()
        let pruned = SearchIndexEngine()
        let fullScan = SearchIndexEngine(bigramPruningEnabled: false)
        pruned.add(docs)
        fullScan.add(docs)

        let idsToRemove = docs.prefix(60).map(\.id)
        pruned.remove(ids: idsToRemove)
        fullScan.remove(ids: idsToRemove)
        XCTAssertEqual(pruned.count, fullScan.count)

        for query in ["顺丰", "顺丰 取件", "猫粮", "体检"] {
            let a = pruned.search(query: query, limit: 50)
            let b = fullScan.search(query: query, limit: 50)
            XCTAssertEqual(a.map(\.document.id), b.map(\.document.id), "remove 后「\(query)」结果不一致")
        }

        pruned.clear(); fullScan.clear()
        XCTAssertEqual(pruned.count, 0)
        XCTAssertEqual(pruned.search(query: "顺丰").count, 0)
        XCTAssertEqual(fullScan.search(query: "顺丰").count, 0)
    }
}
