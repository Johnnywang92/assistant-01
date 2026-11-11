import AssistantCore
import XCTest

@testable import Assistant

/// 首页横幅的 App 层展示映射测试。
///
/// Core 已经测过**队列规则**（顺序、更多计数、互斥、去重）。
/// 这里测 App 层独有的部分：**文案与语义映射**——
/// ID ↔ 文案表的对应关系、提示色、可关闭性、分组标题。
///
/// 之所以单独测：文案写错、ID 拼错、优先级映射漂移都不会编译报错，
/// 只会在真机上显示成错的横幅，而且极难在 review 时发现。
final class HomeBannerPresenterTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func fact(
        _ id: String,
        _ group: HomeBannerGroup,
        dismissible: Bool = true
    ) -> HomeBannerFact {
        HomeBannerFact(
            id: id,
            group: group,
            isDismissible: dismissible,
            triggeredAt: now
        )
    }

    // MARK: - 文案映射

    /// 每一条存量横幅都有对应文案，不能出现「有事实但没文案」的空条目。
    func testEveryKnownBannerIDHasPresentation() {
        let cases: [(String, HomeBannerGroup)] = [
            (HomeBannerID.reordering, .activeOperation),
            (HomeBannerID.seniorMode, .activeOperation),
            (HomeBannerID.weather, .safetyAndTimeliness),
            (HomeBannerID.anniversary, .safetyAndTimeliness),
            (HomeBannerID.ticket, .safetyAndTimeliness),
            (HomeBannerID.travelCountdown, .safetyAndTimeliness),
            (HomeBannerID.lifeEvent, .informational)
        ]

        for (id, group) in cases {
            let presentation = HomeBannerPresenter.presentation(for: fact(id, group))
            XCTAssertNotNil(presentation, "\(id) 没有对应文案")
            XCTAssertEqual(presentation?.id, id)
        }
    }

    /// 未知 ID 返回 nil —— 不能瞎编文案。
    func testUnknownIDReturnsNil() {
        XCTAssertNil(HomeBannerPresenter.presentation(for: fact("unknownBanner", .informational)))
    }

    /// 标题与操作文案不能为空（空标题会让横幅只剩一个图标）。
    func testPresentationNeverHasEmptyText() {
        let cases = [
            HomeBannerID.reordering, HomeBannerID.seniorMode, HomeBannerID.weather,
            HomeBannerID.anniversary, HomeBannerID.ticket, HomeBannerID.travelCountdown,
            HomeBannerID.lifeEvent
        ]
        for id in cases {
            let presentation = HomeBannerPresenter.presentation(for: fact(id, .informational))
            XCTAssertFalse(presentation?.title.isEmpty ?? true, "\(id) 标题为空")
            XCTAssertFalse(presentation?.detail.isEmpty ?? true, "\(id) 详情为空")
            XCTAssertFalse(presentation?.actionLabel.isEmpty ?? true, "\(id) 操作文案为空")
        }
    }

    // MARK: - 提示色

    /// 安全时效类用警告色，操作态与信息态用中性色。
    func testToneMappingFollowsGroupSemantics() {
        let warning = HomeBannerPresenter.presentation(
            for: fact(HomeBannerID.weather, .safetyAndTimeliness)
        )
        XCTAssertEqual(warning?.tone, .warning)

        let neutral = HomeBannerPresenter.presentation(
            for: fact(HomeBannerID.reordering, .activeOperation)
        )
        XCTAssertEqual(neutral?.tone, .neutral)

        let info = HomeBannerPresenter.presentation(
            for: fact(HomeBannerID.lifeEvent, .informational)
        )
        XCTAssertEqual(info?.tone, .neutral)
    }

    // MARK: - 可关闭性

    /// 进行中的操作态不可「关闭」，必须提供「退出」类动作；
    /// 纯信息态可以关闭。
    func testOperationStateBannersAreNotDismissible() {
        let reordering = HomeBannerPresenter.presentation(
            for: fact(HomeBannerID.reordering, .activeOperation, dismissible: false)
        )
        XCTAssertEqual(reordering?.isDismissible, false)
        XCTAssertEqual(reordering?.actionLabel, "退出排序")

        let senior = HomeBannerPresenter.presentation(
            for: fact(HomeBannerID.seniorMode, .activeOperation, dismissible: false)
        )
        XCTAssertEqual(senior?.isDismissible, false)

        let weather = HomeBannerPresenter.presentation(
            for: fact(HomeBannerID.weather, .safetyAndTimeliness, dismissible: true)
        )
        XCTAssertEqual(weather?.isDismissible, true)
    }

    // MARK: - 动态文案覆盖

    /// 需要动态文案的条目（带天数）可以通过 overrides 覆盖，且覆盖后 ID 不变。
    func testDynamicTitleOverrideIsApplied() {
        let base = fact(HomeBannerID.anniversary, .safetyAndTimeliness)
        let overridden = HomeBannerPresenter.presentation(
            for: base,
            overrides: [
                HomeBannerID.anniversary: (
                    title: "结婚纪念日 · 还有 3 天",
                    detail: "纪念日筹备，可一键把准备事项加入待办"
                )
            ]
        )

        XCTAssertEqual(overridden?.title, "结婚纪念日 · 还有 3 天")
        XCTAssertEqual(overridden?.id, HomeBannerID.anniversary)
    }

    /// overrides 里没有对应 ID 时，回落默认文案。
    func testOverrideForOtherIDDoesNotLeak() {
        let presentation = HomeBannerPresenter.presentation(
            for: fact(HomeBannerID.weather, .safetyAndTimeliness),
            overrides: [
                HomeBannerID.ticket: (title: "不该出现的标题", detail: "不该出现的详情")
            ]
        )

        XCTAssertNotEqual(presentation?.title, "不该出现的标题")
        XCTAssertEqual(presentation?.title, "气象预警 · 有新的天气提醒")
    }

    // MARK: - 行程倒计时横幅

    /// 倒计时是时效类：必须用警告色（错过就失去价值），且允许「不再提醒」。
    func testTravelCountdownBannerUsesWarningTone() {
        let presentation = HomeBannerPresenter.presentation(
            for: fact(HomeBannerID.travelCountdown, .safetyAndTimeliness)
        )

        XCTAssertEqual(presentation?.tone, .warning)
        XCTAssertEqual(presentation?.isDismissible, true)
        XCTAssertEqual(presentation?.actionLabel, "查看行程")
    }

    /// 倒计时横幅要能覆盖成带剩余时间的动态标题。
    func testTravelCountdownBannerAcceptsDynamicOverride() {
        let presentation = HomeBannerPresenter.presentation(
            for: fact(HomeBannerID.travelCountdown, .safetyAndTimeliness),
            overrides: [
                HomeBannerID.travelCountdown: (
                    title: "乘坐 G1234 前往北京 · 还有 3 小时",
                    detail: "临近出发 · G1234 · 5车 12A"
                )
            ]
        )

        XCTAssertEqual(presentation?.title, "乘坐 G1234 前往北京 · 还有 3 小时")
        XCTAssertEqual(presentation?.id, HomeBannerID.travelCountdown)
    }

    // MARK: - 分组标题

    /// 二级页分组标题与 Core 的分组枚举一一对应，不重不漏。
    func testGroupTitlesCoverAllGroups() {
        XCTAssertEqual(
            HomeBannerPresenter.groupTitle(.safetyAndTimeliness),
            "P0 · 安全与时效"
        )
        XCTAssertEqual(
            HomeBannerPresenter.groupTitle(.activeOperation),
            "P1 · 进行中的操作态"
        )
        XCTAssertEqual(
            HomeBannerPresenter.groupTitle(.informational),
            "P2 · 信息态"
        )
        // 三个分组都有非空标题
        for group in HomeBannerGroup.allCases {
            XCTAssertFalse(HomeBannerPresenter.groupTitle(group).isEmpty)
        }
    }

    // MARK: - 互斥常量

    /// 互斥集合里必须同时包含排序模式与长辈模式，且不含其他条目。
    func testMutuallyExclusiveSetContainsExactlyTwoOperationStates() {
        XCTAssertEqual(
            HomeBannerID.mutuallyExclusive,
            [HomeBannerID.reordering, HomeBannerID.seniorMode]
        )
    }

    // MARK: - 与 Core 队列的衔接

    /// 端到端：Core 判定的队头 ID，能在 presenter 查到对应文案。
    /// 这是「Core 排序」与「App 文案」之间唯一的接缝，必须接得上。
    func testCoreQueueHeadAlwaysResolvesToPresentation() {
        let facts = [
            fact(HomeBannerID.reordering, .activeOperation, dismissible: false),
            fact(HomeBannerID.seniorMode, .activeOperation, dismissible: false),
            fact(HomeBannerID.weather, .safetyAndTimeliness),
            fact(HomeBannerID.ticket, .safetyAndTimeliness),
            fact(HomeBannerID.anniversary, .safetyAndTimeliness),
            fact(HomeBannerID.lifeEvent, .informational)
        ]
        let queue = HomeBannerQueueBuilder.make(
            facts: facts,
            mutualExclusiveGroup: HomeBannerID.mutuallyExclusive
        )

        XCTAssertNotNil(queue.head)
        for item in queue.ordered {
            XCTAssertNotNil(
                HomeBannerPresenter.presentation(for: item),
                "队列里的 \(item.id) 查不到文案"
            )
        }
    }
}
