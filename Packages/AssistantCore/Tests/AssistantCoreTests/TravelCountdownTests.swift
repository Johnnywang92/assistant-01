import XCTest
@testable import AssistantCore

/// 行程倒计时的验收测试。
///
/// 这些断言对应两个真实缺陷：
/// - **36 小时硬窗口**：旧实现只在发车前 36 小时内才算「近期行程」，
///   3 天后的行程直接从手表/组件上消失，用户以为功能没生效。
/// - **虚假兜底时间**：旧实现在票面信息抽到、但待办没有时间时，
///   编造 `now + 1 小时` 当发车时刻，于是手表上出现一条
///   根本不存在的「1 小时后发车」。
///
/// 口径全部由 Core 决定，`now` 显式注入 → 测试完全可复现。
final class TravelCountdownTests: XCTestCase {

    /// 固定基准时刻（2023-11-14 22:13:20 UTC），避免依赖墙上时钟。
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func candidate(
        _ id: UUID = UUID(),
        title: String = "乘坐 G1234 前往北京",
        departureAt: Date? = nil,
        ticketSummary: String? = "G1234 · 5车 12A",
        gate: String? = "B12",
        place: String? = "北京南站",
        isTravel: Bool = true
    ) -> TravelDepartureCandidate {
        TravelDepartureCandidate(
            id: id,
            title: title,
            departureAt: departureAt,
            ticketSummary: ticketSummary,
            gate: gate,
            place: place,
            isTravel: isTravel
        )
    }
    // MARK: - 窗口（修复 36 小时硬窗口）

    /// 3 天后的行程**必须**能被选中。
    /// 旧实现是 `now + 36h` 硬窗口 → 72 小时的行程直接消失。
    func testTripThreeDaysLaterIsStillCountedDown() {
        let departure = base.addingTimeInterval(3 * 24 * 3600)
        let result = TravelCountdownBuilder.build(
            candidates: [candidate(departureAt: departure)],
            now: base
        )

        XCTAssertNotNil(result, "3 天后的行程不该被窗口丢掉")
        XCTAssertEqual(result?.departureAt, departure)
    }

    /// 超过 3 天的行程不进倒计时（那是购票提醒横幅的职责）。
    func testTripBeyondWindowIsIgnored() {
        let departure = base.addingTimeInterval(4 * 24 * 3600)
        let result = TravelCountdownBuilder.build(
            candidates: [candidate(departureAt: departure)],
            now: base
        )

        XCTAssertNil(result, "超出 3 天窗口的行程不进倒计时")
    }

    /// 窗口边界本身：正好 3 天算在内。
    func testWindowBoundaryIsInclusive() {
        let departure = base.addingTimeInterval(TravelCountdownPolicy.window)
        let result = TravelCountdownBuilder.build(
            candidates: [candidate(departureAt: departure)],
            now: base
        )

        XCTAssertNotNil(result)
    }

    /// 已过发车时间但在宽限期内 → 仍显示「已到出行时间」，不立刻消失。
    func testRecentlyDepartedTripRemainsVisible() {
        let departure = base.addingTimeInterval(-60 * 60)
        let result = TravelCountdownBuilder.build(
            candidates: [candidate(departureAt: departure)],
            now: base
        )

        XCTAssertNotNil(result, "刚过站 1 小时的行程仍应可见")
        XCTAssertEqual(result?.phase, .departed)
    }

    /// 超过宽限期 → 视为行程已结束，不占倒计时位。
    func testLongDepartedTripIsDropped() {
        let departure = base.addingTimeInterval(-10 * 3600)
        let result = TravelCountdownBuilder.build(
            candidates: [candidate(departureAt: departure)],
            now: base
        )

        XCTAssertNil(result)
    }

    // MARK: - 不编造时间（修复虚假「1 小时后发车」）

    /// 没有可靠发车时刻时**不产出**倒计时。
    /// 旧实现会造 `now + 1 小时` → 用户看到一条不存在的发车倒计时。
    func testUnknownDepartureTimeProducesNoCountdown() {
        let result = TravelCountdownBuilder.build(
            candidates: [candidate(departureAt: nil)],
            now: base
        )

        XCTAssertNil(result, "没有发车时间就不能倒计时，更不能编一个")
    }

    /// 即使票面信息齐全（车次/座位/检票口都在），缺时间依然不倒计时。
    /// 票面信息 ≠ 知道什么时候发车。
    func testTicketSignalAloneDoesNotInventDepartureTime() {
        let result = TravelCountdownBuilder.build(
            candidates: [
                candidate(
                    departureAt: nil,
                    ticketSummary: "G1234 · 5车 12A",
                    gate: "B12"
                )
            ],
            now: base
        )

        XCTAssertNil(result)
    }

    /// 候选里混着「有时间的」和「没时间的」→ 取有时间的那个，
    /// 而不是让没时间的把整条链路带偏。
    func testDatedCandidateWinsOverUndated() {
        let departure = base.addingTimeInterval(2 * 3600)
        let result = TravelCountdownBuilder.build(
            candidates: [
                candidate(departureAt: nil),
                candidate(departureAt: departure)
            ],
            now: base
        )

        XCTAssertEqual(result?.departureAt, departure)
    }

    // MARK: - 选哪一趟

    /// 多个行程 → 取**最近发车**的那趟，不是列表里的第一趟。
    func testNearestDepartureIsSelected() {
        let near = base.addingTimeInterval(3 * 3600)
        let far = base.addingTimeInterval(2 * 24 * 3600)
        let result = TravelCountdownBuilder.build(
            candidates: [
                candidate(title: "远途", departureAt: far),
                candidate(title: "近途", departureAt: near)
            ],
            now: base
        )

        XCTAssertEqual(result?.departureAt, near)
        XCTAssertEqual(result?.candidate.title, "近途")
    }

    /// 未来发车优先于「刚过站」：多趟行程时给用户看下一趟。
    func testUpcomingTripWinsOverJustDepartedOne() {
        let upcoming = base.addingTimeInterval(2 * 3600)
        let justDeparted = base.addingTimeInterval(-30 * 60)
        let result = TravelCountdownBuilder.build(
            candidates: [
                candidate(title: "刚走", departureAt: justDeparted),
                candidate(title: "下一趟", departureAt: upcoming)
            ],
            now: base
        )

        XCTAssertEqual(result?.candidate.title, "下一趟")
    }

    /// 发车时间完全相同时按 id 兜底，保证顺序可复现（`Array.sorted` 不稳定）。
    func testEqualDepartureTimesBreakTieDeterministically() {
        let departure = base.addingTimeInterval(4 * 3600)
        let first = candidate(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, departureAt: departure)
        let second = candidate(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, departureAt: departure)

        let forward = TravelCountdownBuilder.build(candidates: [first, second], now: base)
        let reversed = TravelCountdownBuilder.build(candidates: [second, first], now: base)

        XCTAssertEqual(forward?.candidate.id, reversed?.candidate.id, "相同输入必须产出相同结果")
    }

    /// 非出行候选（isTravel == false）一律不参与。
    func testNonTravelCandidateIsIgnored() {
        let result = TravelCountdownBuilder.build(
            candidates: [
                candidate(title: "买菜", departureAt: base.addingTimeInterval(3600), isTravel: false)
            ],
            now: base
        )

        XCTAssertNil(result)
    }

    /// 没有任何候选 → 无倒计时（不返回占位对象）。
    func testEmptyCandidatesProduceNoCountdown() {
        XCTAssertNil(TravelCountdownBuilder.build(candidates: [], now: base))
    }

    // MARK: - 阶段与文案

    /// 超过 1 天 → 天级阶段，天数向上取整。
    func testDaysPhaseRoundsUp() {
        let departure = base.addingTimeInterval(47 * 3600)
        let phase = TravelCountdownPolicy.phase(departureAt: departure, now: base)

        XCTAssertEqual(phase, .days(2), "47 小时应显示「还有 2 天」")
    }

    /// 不足 1 天 → 时/分阶段。
    func testHoursPhaseBelowOneDay() {
        let departure = base.addingTimeInterval(5 * 3600 + 30 * 60)
        let phase = TravelCountdownPolicy.phase(departureAt: departure, now: base)

        XCTAssertEqual(phase, .hours(hours: 5, minutes: 30))
    }

    /// 已过发车时间 → departed 阶段。
    func testDepartedPhase() {
        let departure = base.addingTimeInterval(-60)
        let phase = TravelCountdownPolicy.phase(departureAt: departure, now: base)

        XCTAssertEqual(phase, .departed)
    }

    /// 三档文案。
    func testCountdownTexts() {
        XCTAssertEqual(
            TravelCountdownPolicy.text(departureAt: base.addingTimeInterval(2 * 24 * 3600), now: base),
            "还有 2 天"
        )
        XCTAssertEqual(
            TravelCountdownPolicy.text(departureAt: base.addingTimeInterval(3 * 3600), now: base),
            "还有 3 小时"
        )
        XCTAssertEqual(
            TravelCountdownPolicy.text(departureAt: base.addingTimeInterval(3 * 3600 + 20 * 60), now: base),
            "还有 3 小时 20 分"
        )
        XCTAssertEqual(
            TravelCountdownPolicy.text(departureAt: base.addingTimeInterval(30 * 60), now: base),
            "还有 30 分钟"
        )
        XCTAssertEqual(
            TravelCountdownPolicy.text(departureAt: base.addingTimeInterval(-60), now: base),
            "已到出行时间"
        )
    }

    /// 不足 1 小时不能出现「还有 0 小时 30 分」这种别扭写法。
    func testSubHourTextDoesNotShowZeroHours() {
        let text = TravelCountdownPolicy.text(departureAt: base.addingTimeInterval(30 * 60), now: base)

        XCTAssertEqual(text, "还有 30 分钟")
        XCTAssertFalse(text.contains("0 小时"))
    }

    /// 临近判定：不足 1 天算「临近」。
    func testImminentThreshold() {
        XCTAssertTrue(TravelCountdownPolicy.isImminent(departureAt: base.addingTimeInterval(23 * 3600), now: base))
        XCTAssertFalse(TravelCountdownPolicy.isImminent(departureAt: base.addingTimeInterval(25 * 3600), now: base))
    }

    // MARK: - 出行信号识别

    /// 标题命中关键词 → 出行候选。
    func testTitleKeywordDetection() {
        XCTAssertTrue(TravelDepartureDetector.looksLikeTravel(title: "乘坐 G1234 前往北京", detail: nil, sourceText: nil))
        XCTAssertTrue(TravelDepartureDetector.looksLikeTravel(title: "明天去机场", detail: nil, sourceText: nil))
        XCTAssertTrue(TravelDepartureDetector.looksLikeTravel(title: "出差", detail: nil, sourceText: nil))
    }

    /// 详情里有票面描述 → 也算出行候选。
    func testDetailKeywordDetection() {
        XCTAssertTrue(TravelDepartureDetector.looksLikeTravel(title: "周末安排", detail: "G1234 12A 检票口B12", sourceText: nil))
    }

    /// 无关待办不能被误判成行程。
    func testUnrelatedTodoIsNotTravel() {
        XCTAssertFalse(TravelDepartureDetector.looksLikeTravel(title: "买菜", detail: "西红柿 鸡蛋", sourceText: nil))
        XCTAssertFalse(TravelDepartureDetector.looksLikeTravel(title: "交房租", detail: nil, sourceText: nil))
    }

    /// 票面抽取：抽到车次/座位与检票口。
    func testTicketInfoExtraction() {
        let info = TravelDepartureDetector.ticketInfo(
            title: "行程",
            detail: "车次 G1234 5车 12A 检票口B12",
            sourceText: nil
        )

        XCTAssertTrue(info.hasSignal)
        XCTAssertEqual(info.gate, "B12")
        XCTAssertNotNil(info.summary)
    }

    /// 抽不到就是抽不到——不猜。
    func testTicketInfoAbsentWhenNoTicketText() {
        let info = TravelDepartureDetector.ticketInfo(title: "买菜", detail: "西红柿", sourceText: nil)

        XCTAssertFalse(info.hasSignal)
        XCTAssertNil(info.summary)
        XCTAssertNil(info.gate)
    }
}
