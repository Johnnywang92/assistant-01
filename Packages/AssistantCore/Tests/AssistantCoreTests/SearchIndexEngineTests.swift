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
}
