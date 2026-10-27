import XCTest
@testable import AssistantCore

/// 搜索相关性排序 + 万件级性能基准。
///
/// 这组测试守两件事：
/// 1. **排序口径**——命中质量优先于时间倒序。一万条待办里那条旧记录
///    如果只按时间排，会被新记录挤出结果区，用户怎么搜都找不到。
/// 2. **万条规模下的耗时**——搜索必须是「边打字边出结果」的量级，
///    而不是「等几秒才出结果」。
final class SearchRelevanceTests: XCTestCase {

    private func candidate(
        _ title: String,
        id: UUID = UUID(),
        detail: String? = nil,
        pickupCode: String? = nil,
        courier: String? = nil,
        station: String? = nil,
        location: String? = nil,
        sourceText: String? = nil,
        date: Date? = nil
    ) -> SearchCandidate {
        SearchCandidate(
            id: id, title: title, detail: detail, pickupCode: pickupCode,
            courier: courier, station: station, location: location,
            sourceText: sourceText, date: date
        )
    }

    // MARK: - 命中判定

    func testExactTitleMatchHasHighestQuality() {
        XCTAssertEqual(SearchRelevance.match(candidate("取快递"), query: "取快递"), .titleExact)
    }

    func testExactTitleMatchIgnoresCaseAndWhitespace() {
        XCTAssertEqual(SearchRelevance.match(candidate("Takeout"), query: "  takeout "), .titleExact)
    }

    func testExactPickupCodeMatchOutranksTitleContains() {
        let item = candidate("顺丰包裹 SF123", pickupCode: "SF123")
        XCTAssertEqual(SearchRelevance.match(item, query: "SF123"), .codeExact)
    }

    func testTitlePrefixBeatsTitleContains() {
        XCTAssertEqual(SearchRelevance.match(candidate("取快递到驿站"), query: "取快递"), .titlePrefix)
        XCTAssertEqual(SearchRelevance.match(candidate("下午取快递到驿站"), query: "取快递"), .titleContains)
    }

    func testOtherFieldMatchIsLowestQuality() {
        let item = candidate("顺丰包裹", detail: "取件码在柜子里", station: "菜鸟驿站")
        XCTAssertEqual(SearchRelevance.match(item, query: "菜鸟驿站"), .otherFieldContains)
        XCTAssertEqual(SearchRelevance.match(item, query: "柜子"), .otherFieldContains)
    }

    func testNoMatchIsNone() {
        XCTAssertEqual(SearchRelevance.match(candidate("买牛奶"), query: "取快递"), .none)
    }

    func testEmptyQueryMatchesNothing() {
        XCTAssertEqual(SearchRelevance.match(candidate("买牛奶"), query: "   "), .none)
    }

    // MARK: - 排序

    /// 核心回归：一条很老的精确命中，必须排在一条很新的模糊命中之前
    func testExactMatchOutranksNewerFuzzyMatch() {
        let old = candidate("取快递", date: Date(timeIntervalSince1970: 1_000_000))
        let recent = candidate("今天取快递到楼下菜鸟驿站顺便买牛奶", date: Date())
        let ranked = SearchRelevance.rank([recent, old], query: "取快递", limit: 20)
        XCTAssertEqual(ranked.first?.id, old.id)
    }

    func testSameQualitySortedByDateDescending() {
        let older = candidate("取快递A", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, date: Date(timeIntervalSince1970: 100))
        let newer = candidate("取快递B", id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, date: Date(timeIntervalSince1970: 200))
        let ranked = SearchRelevance.rank([older, newer], query: "取快递", limit: 20)
        XCTAssertEqual(ranked.map(\.id), [newer.id, older.id])
    }

    func testUnmatchedCandidatesAreDropped() {
        let hit = candidate("取快递")
        let miss = candidate("买牛奶")
        let ranked = SearchRelevance.rank([miss, hit], query: "取快递", limit: 20)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.id, hit.id)
    }

    func testLimitIsApplied() {
        let many = (0..<50).map { candidate("取快递\($0)") }
        XCTAssertEqual(SearchRelevance.rank(many, query: "取快递", limit: 20).count, 20)
        XCTAssertEqual(SearchRelevance.rank(many, query: "取快递", limit: 0).count, 0)
    }

    /// 空查询退化为「原样取前 N 条」，不做命中过滤
    func testEmptyQueryKeepsPrefixOrder() {
        let a = candidate("A")
        let b = candidate("B")
        XCTAssertEqual(SearchRelevance.rank([a, b], query: "", limit: 2).map(\.id), [a.id, b.id])
    }

    /// 排序必须稳定可复现：同质量同时刻同标题时按 id 兜底，不能每次刷新都换顺序
    func testRankingIsDeterministic() {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let items = [candidate("取快递", id: idB, date: Date(timeIntervalSince1970: 1)),
                     candidate("取快递", id: idA, date: Date(timeIntervalSince1970: 1))]
        let first = SearchRelevance.rank(items, query: "取快递", limit: 2).map(\.id)
        let second = SearchRelevance.rank(items.reversed(), query: "取快递", limit: 2).map(\.id)
        XCTAssertEqual(first, second)
    }

    // MARK: - 万件级实测

    /// 一万条待办规模下：
    /// - 目标条目（一条很老、标题完全匹配的记录）必须能排进结果区顶部；
    /// - 匹配 + 排序耗时必须留在「边打字边出结果」的量级。
    func testTenThousandCandidatesRemainFindableAndFast() {
        let count = 10_000
        let targetID = UUID(uuidString: "00000000-0000-0000-0000-00000000FFFF")!
        let now = Date()
        var candidates: [SearchCandidate] = []
        candidates.reserveCapacity(count)
        for index in 0..<count {
            let isTarget = index == count - 1
            candidates.append(SearchCandidate(
                id: isTarget ? targetID : UUID(),
                title: isTarget ? "取快递" : "日常事项 \(index)",
                detail: isTarget ? nil : "包含关键词的详情 \(index)",
                pickupCode: isTarget ? nil : "SF\(index)",
                date: isTarget ? now.addingTimeInterval(-86_400 * 90) : now.addingTimeInterval(-Double(index))
            ))
        }

        // 预热：首次调用会触发 ICU 字符串比较的惰性初始化（一次性开销约数百毫秒），
        // 基准要测的是稳态耗时，不是冷启动
        _ = SearchRelevance.rank([candidates[0]], query: "取快递", limit: 1)

        let started = CFAbsoluteTimeGetCurrent()
        let ranked = SearchRelevance.rank(candidates, query: "取快递", limit: 20)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(ranked.count, 1, "只有标题精确匹配的那条才该命中")
        // 万条里那条「三个月前的精确命中」必须排在最前——这是「两步找到」的底线
        XCTAssertEqual(ranked.first?.id, targetID, "精确命中必须排在最前")

        // 十万次量级的字符串匹配仍在百毫秒内，才谈得上「边打字边出结果」
        XCTAssertLessThan(elapsed, 0.5, "1 万条排序耗时 \(elapsed)s，超出可接受范围")
    }

    /// 基准数据说明：一条含关键词的旧记录（不是精确命中）也应能被找到，只是排在精确命中之后
    func testTenThousandCandidatesFuzzyMatchStillFound() {
        let count = 10_000
        let now = Date()
        var candidates: [SearchCandidate] = []
        for index in 0..<count {
            candidates.append(SearchCandidate(
                id: UUID(),
                title: "事项 \(index)",
                detail: index == 7 ? "顺丰取件码已更新" : "普通详情",
                date: now.addingTimeInterval(-Double(index))
            ))
        }
        let ranked = SearchRelevance.rank(candidates, query: "顺丰取件码", limit: 20)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.detail, "顺丰取件码已更新")
    }
}
