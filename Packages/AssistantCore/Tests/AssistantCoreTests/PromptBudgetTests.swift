import XCTest
@testable import AssistantCore

/// 提示词分块预算测试。
/// 核心风险：旧实现 `tokens.suffix(available)` 保留尾部，溢出时丢掉的是 system 人格
/// 与排在最前面的快递/待办——正是「我现在该干嘛」最需要的数据。
/// 因此这里重点钉住四件事：**整块取舍不截半、必留块永不丢、丢弃顺序由 dropRank 决定、
/// 取舍不得重排段落**。
final class PromptBudgetTests: XCTestCase {

    // MARK: - token 估算

    func testChineseEstimatesRoughlyOneTokenPerCharacter() {
        // 11 个汉字：基线 11 token，×1.15 余量 → 13
        XCTAssertEqual(PromptTokenEstimator.estimateTokens("帮我取快递还有三件没拿"), 13)
    }

    func testASCIIEstimatesFourCharactersPerToken() {
        // 30 个 ASCII：基线 7.5，×1.15 → 9
        XCTAssertEqual(PromptTokenEstimator.estimateTokens("the quick brown fox jumps over"), 9)
        // 4 个 ASCII：基线 1，×1.15 → 2
        XCTAssertEqual(PromptTokenEstimator.estimateTokens("abcd"), 2)
    }

    func testFullWidthPunctuationCountsAsCJK() {
        // 全角 ？： 与 CJK 标点 。 按 1 token/字，不是按 ASCII 的 1/4
        let fullWidth = PromptTokenEstimator.estimateTokens("？：。")
        let halfWidth = PromptTokenEstimator.estimateTokens("?:.")
        XCTAssertGreaterThan(fullWidth, halfWidth, "全角标点若被当成 ASCII 会低估三倍以上")
    }

    func testChineseEstimateIsNeverBelowCharacterCount() {
        // 中文场景 1 字至少 1 token；余量只会让它更高，不会更低
        for sample in ["取件码", "明天三点的高铁", "请把露营清单删掉", "已记账18元餐饮"] {
            XCTAssertGreaterThanOrEqual(PromptTokenEstimator.estimateTokens(sample), sample.count)
        }
    }

    func testEmptyTextIsZero() {
        XCTAssertEqual(PromptTokenEstimator.estimateTokens(""), 0)
    }

    // MARK: - 预算内全保留

    func testFitWithinBudgetKeepsEverythingInOrder() {
        let blocks = [
            PromptBlock(id: .persona, text: "你是本地私人管家"),
            PromptBlock(id: .parcel, text: "待取快递：顺丰（码 8-3-1024）"),
            PromptBlock(id: .query, text: "我现在该干嘛")
        ]
        let fit = PromptBudget.fit(blocks: blocks, budgetTokens: 400)
        XCTAssertTrue(fit.droppedIDs.isEmpty)
        XCTAssertFalse(fit.overflow)
        XCTAssertEqual(fit.blocks.map(\.id), [.persona, .parcel, .query], "装配不得改变段落次序")
    }

    // MARK: - 溢出时的丢弃优先级（本文件的主战场）

    /// 12 段生活档案 + 必留块，每段档案都写到足以撑爆小窗口
    private func makeOverflowingProfile() -> [PromptBlock] {
        let filler = String(repeating: "记录内容", count: 40)
        return [
            PromptBlock(id: .persona, text: "你是运行在用户 iPhone 本地的全能私人管家「小助」"),
            PromptBlock(id: .rules, text: "作答规则：严禁编造数据\(filler)"),
            PromptBlock(id: .parcel, text: "• 待取快递：\(filler)"),
            PromptBlock(id: .todo, text: "• 日常待办与日程：\(filler)"),
            PromptBlock(id: .finance, text: "• 财务账本：\(filler)"),
            PromptBlock(id: .anniversary, text: "• 纪念日倒数：\(filler)"),
            PromptBlock(id: .storage, text: "• 物品收纳位置：\(filler)"),
            PromptBlock(id: .habit, text: "• 用药与习惯打卡：\(filler)"),
            PromptBlock(id: .vault, text: "• 证件/订阅/保质期：\(filler)"),
            PromptBlock(id: .family, text: "• 家庭档案：\(filler)"),
            PromptBlock(id: .memo, text: "• 近期语音备忘：\(filler)"),
            PromptBlock(id: .place, text: "• 常去地点：\(filler)"),
            PromptBlock(id: .history, text: "用户：我有哪些快递\n助手：有三件"),
            PromptBlock(id: .query, text: "我现在该干嘛")
        ]
    }

    func testOverflowDropsDecorativeBlocksBeforeParcelsAndTodos() {
        let fit = PromptBudget.fit(blocks: makeOverflowingProfile(), budgetTokens: 700)

        XCTAssertTrue(fit.droppedIDs.contains(.place), "常去地点应最先被丢")
        XCTAssertTrue(fit.droppedIDs.contains(.memo))
        XCTAssertTrue(fit.droppedIDs.contains(.family))
        XCTAssertFalse(fit.droppedIDs.contains(.parcel), "待取快递是「现在该做什么」的直接依据，不得先丢")
        XCTAssertFalse(fit.droppedIDs.contains(.todo))
        XCTAssertFalse(fit.overflow)
        XCTAssertLessThanOrEqual(fit.usedTokens, 700)
    }

    func testDropOrderFollowsRankNotInputOrder() {
        // 入参故意乱序：place 排最前、parcel 排最后，仍须先丢 place
        let blocks: [PromptBlock] = [
            PromptBlock(id: .place, text: String(repeating: "地点", count: 200)),
            PromptBlock(id: .persona, text: "管家设定"),
            PromptBlock(id: .parcel, text: String(repeating: "快递", count: 200)),
            PromptBlock(id: .memo, text: String(repeating: "备忘", count: 200))
        ]
        // 三块档案各约 460 token，总约 1385；预算 500 → 丢 place(460) 后仍超，再丢 memo 后降到 465 命中预算
        let fit = PromptBudget.fit(blocks: blocks, budgetTokens: 500)
        XCTAssertEqual(fit.droppedIDs.first, .place, "丢弃顺序只由 dropRank 决定")
        XCTAssertEqual(fit.droppedIDs, [.place, .memo])
        XCTAssertFalse(fit.droppedIDs.contains(.parcel))
        XCTAssertFalse(fit.overflow)
    }

    func testKeptBlocksPreserveInputOrderAfterDropping() {
        let input = makeOverflowingProfile()
        let fit = PromptBudget.fit(blocks: input, budgetTokens: 700)
        let expected = input.map(\.id).filter { !fit.droppedIDs.contains($0) }
        XCTAssertEqual(fit.blocks.map(\.id), expected, "取舍不得重排剩余段落")
    }

    func testBlocksAreAllOrNothingNeverHalfTruncated() {
        let profile = makeOverflowingProfile()
        let fit = PromptBudget.fit(blocks: profile, budgetTokens: 700)
        let originals = Dictionary(uniqueKeysWithValues: profile.map { ($0.id, $0.text) })
        for block in fit.blocks {
            XCTAssertEqual(block.text, originals[block.id], "保留的块必须与原文逐字相同，禁止出现半截档案")
        }
    }

    /// 用「仍能保留的最小预算」验证单调性：结论只依赖 dropRank 顺序，不依赖逐块字数，
    /// 因此以后调整档案文案长度也不会让测试假失败。
    func testKeepThresholdStrictlyIncreasesAlongDropOrder() {
        let profile = makeOverflowingProfile()

        func threshold(for id: PromptBlockID) -> Int {
            for budget in stride(from: 40, through: 6000, by: 10) {
                let fit = PromptBudget.fit(blocks: profile, budgetTokens: budget)
                if fit.blocks.contains(where: { $0.id == id }) { return budget }
            }
            return .max
        }

        // 越晚被丢的块，在越紧的预算下仍能保留
        XCTAssertLessThan(threshold(for: .parcel), threshold(for: .todo))
        XCTAssertLessThan(threshold(for: .todo), threshold(for: .history))
        XCTAssertLessThan(threshold(for: .history), threshold(for: .finance))
        XCTAssertLessThan(threshold(for: .finance), threshold(for: .anniversary))
        XCTAssertLessThan(threshold(for: .anniversary), threshold(for: .place))
    }

    // MARK: - 必留块

    func testProtectedBlocksAreNeverDroppedAndReportOverflow() {
        let blocks: [PromptBlock] = [
            PromptBlock(id: .persona, text: String(repeating: "人格设定", count: 100)),
            PromptBlock(id: .rules, text: String(repeating: "作答规则", count: 100)),
            PromptBlock(id: .verified, text: String(repeating: "精确核实结论", count: 100)),
            PromptBlock(id: .query, text: String(repeating: "用户问句", count: 100)),
            PromptBlock(id: .parcel, text: String(repeating: "快递档案", count: 100))
        ]
        let fit = PromptBudget.fit(blocks: blocks, budgetTokens: 120)
        XCTAssertEqual(Set(fit.droppedIDs), [.parcel], "只有可丢块能被丢")
        XCTAssertEqual(fit.blocks.map(\.id), [.persona, .rules, .verified, .query])
        XCTAssertTrue(fit.overflow, "必留块本身超预算必须上报，调用方不得直接把残段发出去")
    }

    func testVerifiedReceiptCountsAsProtected() {
        // 账单精确核实结论缺席时，规则要求「以此为准」而模型只能编数——必须视为必留
        XCTAssertNil(PromptBlockID.verified.dropRank)
        XCTAssertTrue(PromptBlockID.verified.isProtected)
        XCTAssertFalse(PromptBlockID.parcel.isProtected)
    }

    // MARK: - 契约自检

    func testDropRanksAreUniqueAndContiguous() {
        let protected = PromptBlockID.allCases.filter(\.isProtected)
        let droppable = PromptBlockID.allCases.filter { !$0.isProtected }
        XCTAssertEqual(protected.count, 4, "必留块只有 persona/rules/verified/query")

        let ranks = droppable.compactMap(\.dropRank)
        XCTAssertEqual(Set(ranks).count, ranks.count, "丢弃顺序不得有两块同权重")
        XCTAssertEqual(ranks.sorted(), Array(0..<ranks.count), "rank 必须连续从 0 起")
    }

    func testParcelAndTodoAreTheLastToGo() {
        let ranks = PromptBlockID.allCases.compactMap { id in id.dropRank.map { ($0, id) } }
        let twoLatest = ranks.sorted { $0.0 > $1.0 }.prefix(2).map(\.1)
        XCTAssertEqual(Set(twoLatest), [.parcel, .todo], "快递与待办必须留到最后")
    }

    func testJoinedReturnsTextWithSameOrderAsFit() {
        let blocks = [
            PromptBlock(id: .persona, text: "A"),
            PromptBlock(id: .place, text: "B"),
            PromptBlock(id: .query, text: "C")
        ]
        // 三块各 1 token，预算 2 → 丢 rank 最小的可丢块 place
        let (text, fit) = PromptBudget.joined(blocks: blocks, budgetTokens: 2, separator: "|")
        XCTAssertEqual(fit.droppedIDs, [.place])
        XCTAssertEqual(text, "A|C")
    }
}
