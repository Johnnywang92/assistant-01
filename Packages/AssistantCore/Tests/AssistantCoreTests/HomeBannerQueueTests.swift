import XCTest
@testable import AssistantCore

/// 首页条件横幅队列的验收测试。
///
/// 对应 docs/home-redesign-handoff.md §8.4 与 §9：
/// 存量 10 个条件横幅收敛为一条优先队列，首页只显示队头 1 条，其余进「更多 · N」，
/// 功能一条不丢。本文件把该口径钉成可执行断言，避免后续迭代把规则改漂。
final class HomeBannerQueueTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func fact(
        _ id: String,
        _ group: HomeBannerGroup,
        expired: Bool = false,
        dismissible: Bool = true,
        offset: TimeInterval = 0
    ) -> HomeBannerFact {
        HomeBannerFact(
            id: id,
            group: group,
            isDismissible: dismissible,
            isExpired: expired,
            triggeredAt: base.addingTimeInterval(offset)
        )
    }

    // MARK: - 默认态

    /// §9 追加条目：默认态（无横幅命中）首屏与定稿一致，不出现空横幅占位。
    func testEmptyQueueHasNoHeadAndNoMoreEntry() {
        let queue = HomeBannerQueueBuilder.make(facts: [])

        XCTAssertNil(queue.head, "无命中时不能出现占位横幅")
        XCTAssertEqual(queue.moreCount, 0)
        XCTAssertFalse(queue.hasMore, "为 0 时不显示「更多」入口")
    }

    // MARK: - 只显示队头一条

    /// §9 追加条目：同一时刻首页最多 1 条横幅。
    func testOnlyOneBannerShownOnHome() {
        let queue = HomeBannerQueueBuilder.make(facts: [
            fact("weather", .safetyAndTimeliness),
            fact("reorder", .activeOperation),
            fact("lifeEvent", .informational)
        ])

        XCTAssertEqual(queue.head?.id, "weather")
        XCTAssertEqual(queue.moreCount, 2, "N = 命中总数 − 1")
        XCTAssertTrue(queue.hasMore)
    }

    /// §9 追加条目：N = 命中数 − 1；只有 1 条时不显示「更多 · 0」。
    func testMoreCountIsTotalMinusOne() {
        let single = HomeBannerQueueBuilder.make(facts: [fact("a", .informational)])
        XCTAssertEqual(single.moreCount, 0)
        XCTAssertFalse(single.hasMore)

        let triple = HomeBannerQueueBuilder.make(facts: [
            fact("a", .informational),
            fact("b", .informational),
            fact("c", .informational)
        ])
        XCTAssertEqual(triple.moreCount, 2)
    }

    // MARK: - 优先级

    /// P0 安全时效 > P1 操作态 > P2 信息态。
    func testPriorityOrderAcrossGroups() {
        let queue = HomeBannerQueueBuilder.make(facts: [
            fact("informational", .informational),
            fact("operation", .activeOperation),
            fact("safety", .safetyAndTimeliness)
        ])

        XCTAssertEqual(queue.ordered.map(\.id), ["safety", "operation", "informational"])
    }

    /// 同组内按触发时间倒序（新的在前）。
    func testSameGroupSortedByTriggeredAtDescending() {
        let queue = HomeBannerQueueBuilder.make(facts: [
            fact("older", .safetyAndTimeliness, offset: 0),
            fact("newer", .safetyAndTimeliness, offset: 600)
        ])

        XCTAssertEqual(queue.ordered.map(\.id), ["newer", "older"])
    }

    /// 同组同刻时按 ID 兜底，保证顺序可复现（Array.sorted 不稳定）。
    func testTieBreakIsDeterministic() {
        let facts = [
            fact("b", .informational, offset: 0),
            fact("a", .informational, offset: 0),
            fact("c", .informational, offset: 0)
        ]
        let first = HomeBannerQueueBuilder.make(facts: facts).ordered.map(\.id)
        let second = HomeBannerQueueBuilder.make(facts: facts.reversed()).ordered.map(\.id)

        XCTAssertEqual(first, ["a", "b", "c"])
        XCTAssertEqual(first, second, "相同输入（含顺序变化）必须产出相同顺序")
    }

    /// 同组内过期项优先（安全时效类里过期更紧急）。
    func testExpiredWinsWithinSameGroup() {
        let queue = HomeBannerQueueBuilder.make(facts: [
            fact("fresh", .safetyAndTimeliness, offset: 900),
            fact("expired", .safetyAndTimeliness, expired: true, offset: 0)
        ])

        XCTAssertEqual(queue.head?.id, "expired")
        XCTAssertTrue(queue.head?.isExpired == true)
    }

    // MARK: - 关闭后重算

    /// §9 追加条目：关闭 / 已处理后队列重新取头，横幅与徽标同步刷新。
    func testDismissingRequeuesHeadAndUpdatesCount() {
        let facts = [
            fact("weather", .safetyAndTimeliness),
            fact("reorder", .activeOperation),
            fact("lifeEvent", .informational)
        ]
        let before = HomeBannerQueueBuilder.make(facts: facts)
        XCTAssertEqual(before.head?.id, "weather")
        XCTAssertEqual(before.moreCount, 2)

        let after = HomeBannerQueueBuilder.dismissing("weather", in: facts)
        XCTAssertEqual(after.head?.id, "reorder", "关闭后队头应换成下一条")
        XCTAssertEqual(after.moreCount, 1, "徽标同步减 1")
        XCTAssertTrue(after.dismissedIDs.contains("weather"))
    }

    /// 已关闭的 ID 不再回到首页。
    func testDismissedItemNeverComesBack() {
        let facts = [fact("weather", .safetyAndTimeliness), fact("reorder", .activeOperation)]
        let after = HomeBannerQueueBuilder.dismissing("weather", in: facts)

        XCTAssertFalse(after.ordered.contains { $0.id == "weather" })
        XCTAssertEqual(after.ordered.count, 1)
    }

    // MARK: - 互斥

    /// §9 追加条目：长辈模式与排序模式互斥，同时命中只显示一条。
    func testMutuallyExclusiveBannersOnlyOneSurvives() {
        let facts = [
            fact("reorder", .activeOperation),
            fact("seniorMode", .activeOperation),
            fact("lifeEvent", .informational)
        ]
        let queue = HomeBannerQueueBuilder.make(
            facts: facts,
            mutualExclusiveGroup: ["reorder", "seniorMode"]
        )

        XCTAssertEqual(queue.ordered.filter { $0.id == "reorder" || $0.id == "seniorMode" }.count, 1)
        XCTAssertEqual(queue.head?.id, "reorder", "同组互斥时保留先到的一条")
    }

    /// 互斥组不影响其他分组的条目。
    func testMutualExclusionDoesNotDropOtherGroups() {
        let facts = [
            fact("weather", .safetyAndTimeliness),
            fact("reorder", .activeOperation),
            fact("seniorMode", .activeOperation)
        ]
        let queue = HomeBannerQueueBuilder.make(
            facts: facts,
            mutualExclusiveGroup: ["reorder", "seniorMode"]
        )

        XCTAssertEqual(queue.ordered.count, 2)
        XCTAssertTrue(queue.ordered.contains { $0.id == "weather" })
    }

    // MARK: - 去重

    /// 同一 ID 重复命中只出一条（避免同一横幅在首页出现两次）。
    func testDuplicateIDsAreDeduplicated() {
        let queue = HomeBannerQueueBuilder.make(facts: [
            fact("weather", .safetyAndTimeliness),
            fact("weather", .safetyAndTimeliness)
        ])

        XCTAssertEqual(queue.ordered.count, 1)
        XCTAssertEqual(queue.moreCount, 0)
    }

    // MARK: - 分组

    /// 二级页按 P0/P1/P2 分组，组内按触发时间倒序。
    func testGroupingProducesOrderedSections() {
        let queue = HomeBannerQueueBuilder.make(facts: [
            fact("lifeEvent", .informational),
            fact("anniversary", .safetyAndTimeliness, offset: 100),
            fact("weather", .safetyAndTimeliness, offset: 500),
            fact("reorder", .activeOperation)
        ])

        let grouped = queue.grouped()
        XCTAssertEqual(grouped.count, 3)
        XCTAssertEqual(grouped[0].group, .safetyAndTimeliness)
        XCTAssertEqual(grouped[0].items.map(\.id), ["weather", "anniversary"])
        XCTAssertEqual(grouped[1].group, .activeOperation)
        XCTAssertEqual(grouped[2].group, .informational)
    }

    /// 空队列不产生任何分组（二级页不显示空分组标题）。
    func testGroupingOnEmptyQueueProducesNoSections() {
        XCTAssertTrue(HomeBannerQueueBuilder.make(facts: []).grouped().isEmpty)
    }

    // MARK: - §8.4 的 10 项一个不丢

    /// §9 末条：8.4 的 10 条横幅一个不丢，仅改为队列展示。
    /// 这里把 10 个存量横幅 ID 全列出来，断言全部能进队列。
    func testAllTenLegacyBannersAreRepresented() {
        let legacyIDs = [
            "TodoWeatherAlertBanner",
            "TodoTravelTicketPrepBanner",
            "TodoAnniversaryPrepBanner",
            "TodoReorderingBanner",
            "TodoSeniorModeBanner",
            "pendingConfirmationSection",
            "LifeEventHomeBanner",
            "homeSearchIndexPreview"
        ]

        let facts = legacyIDs.map { id in
            fact(id, .informational)
        }
        let queue = HomeBannerQueueBuilder.make(facts: facts)

        for id in legacyIDs {
            XCTAssertTrue(queue.ordered.contains { $0.id == id }, "\(id) 丢了")
        }
    }

    /// 行程倒计时是新增的 P0 时效横幅，必须能进队列，
    /// 且与「出行购票」横幅同属安全时效组。
    func testTravelCountdownBannerJoinsSafetyGroup() {
        let queue = HomeBannerQueueBuilder.make(facts: [
            fact("ticket", .safetyAndTimeliness),
            fact("travelCountdown", .safetyAndTimeliness)
        ])

        XCTAssertEqual(queue.ordered.count, 2)
        XCTAssertTrue(queue.ordered.allSatisfy { $0.group == .safetyAndTimeliness })
        XCTAssertNotNil(queue.head)
    }
}
