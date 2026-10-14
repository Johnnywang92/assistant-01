import XCTest
@testable import AssistantCore

/// 到站/落地清点提醒判定的回归测试。
/// 核心风险：票面方式判错导致提前量失真、停下判定把「仍在行驶」当成已下车、
/// 已提醒过一次后同一趟行程被反复弹窗、过期行程继续打扰。
final class TripArrivalScheduleTests: XCTestCase {

    /// 固定 now：2026-06-01 12:00:00 UTC
    private let now = Date(timeIntervalSince1970: 1_780_315_200)
    private let minute: TimeInterval = 60

    private func minutes(_ m: Int) -> TimeInterval { TimeInterval(m) * minute }

    private func sample(_ activity: TripArrivalSchedule.MotionSample.Activity,
                        minutesAgo: Int,
                        confidence: TripArrivalSchedule.MotionSample.Confidence = .high) -> TripArrivalSchedule.MotionSample {
        TripArrivalSchedule.MotionSample(
            date: now.addingTimeInterval(-minutes(minutesAgo)),
            activity: activity,
            confidence: confidence
        )
    }

    // MARK: - 提前量

    func testAdvanceLeadOrdersByTransportKind() {
        XCTAssertEqual(TripArrivalSchedule.advanceLead(for: .flight), minutes(20))
        XCTAssertEqual(TripArrivalSchedule.advanceLead(for: .train), minutes(8))
        XCTAssertEqual(TripArrivalSchedule.advanceLead(for: .metro), minutes(5))
        XCTAssertEqual(TripArrivalSchedule.advanceLead(for: .bus), minutes(4))
        XCTAssertEqual(TripArrivalSchedule.advanceLead(for: .automobile), minutes(5))
        XCTAssertEqual(TripArrivalSchedule.advanceLead(for: .bicycle), minutes(3))
        XCTAssertEqual(TripArrivalSchedule.advanceLead(for: .unknown), TripArrivalSchedule.advanceLead(for: .automobile))
    }

    // MARK: - 触发判定

    func testNotYetBeforeWindowStart() {
        let arrival = now.addingTimeInterval(minutes(30))
        XCTAssertEqual(
            TripArrivalSchedule.decide(expectedArrivalAt: arrival, firedAt: nil, transportKind: .flight, stoppedConfirmed: false, now: now),
            .notYet(.tooEarly)
        )
    }

    func testInWindowWithoutEvidenceWaits() {
        // 落地前 10 分钟：提前窗口已开（飞机 20 分钟），但既没停下证据也没到点
        let arrival = now.addingTimeInterval(minutes(10))
        XCTAssertEqual(
            TripArrivalSchedule.decide(expectedArrivalAt: arrival, firedAt: nil, transportKind: .flight, stoppedConfirmed: false, now: now),
            .notYet(.awaitingStopEvidence)
        )
    }

    func testMotionStoppedFiresInsideWindow() {
        let arrival = now.addingTimeInterval(minutes(2))
        XCTAssertEqual(
            TripArrivalSchedule.decide(expectedArrivalAt: arrival, firedAt: nil, transportKind: .automobile, stoppedConfirmed: true, now: now),
            .fire(.motionStopped)
        )
    }

    func testTimeBackstopFiresAtArrivalWithoutMotion() {
        let arrival = now.addingTimeInterval(-minutes(1))
        XCTAssertEqual(
            TripArrivalSchedule.decide(expectedArrivalAt: arrival, firedAt: nil, transportKind: .train, stoppedConfirmed: false, now: now),
            .fire(.timeBackstop)
        )
    }

    func testAlreadyFiredInsideWindowSuppressesRepeat() {
        let arrival = now.addingTimeInterval(minutes(1))
        let fired = now.addingTimeInterval(-minutes(3))
        XCTAssertEqual(
            TripArrivalSchedule.decide(expectedArrivalAt: arrival, firedAt: fired, transportKind: .train, stoppedConfirmed: true, now: now),
            .notYet(.alreadyFired)
        )
    }

    func testFiredForPreviousTripDoesNotBlockNewWindow() {
        // 昨天提醒过的下一趟行程：firedAt 远早于本次提前窗口，仍需正常提醒
        let arrival = now.addingTimeInterval(minutes(3))
        let fired = now.addingTimeInterval(-minutes(60 * 24))
        XCTAssertTrue(TripArrivalSchedule.decide(
            expectedArrivalAt: arrival, firedAt: fired, transportKind: .train, stoppedConfirmed: false, now: now
        ).shouldFire == false)
        XCTAssertEqual(
            TripArrivalSchedule.decide(expectedArrivalAt: arrival, firedAt: fired, transportKind: .train, stoppedConfirmed: true, now: now),
            .fire(.motionStopped)
        )
    }

    func testExpiredAfterGraceWindow() {
        let arrival = now.addingTimeInterval(-TripArrivalSchedule.backstopGrace - minutes(1))
        XCTAssertEqual(
            TripArrivalSchedule.decide(expectedArrivalAt: arrival, firedAt: nil, transportKind: .flight, stoppedConfirmed: true, now: now),
            .expired
        )
    }

    func testMissingArrivalTimeMeansDisabled() {
        XCTAssertEqual(
            TripArrivalSchedule.decide(expectedArrivalAt: nil, firedAt: nil, transportKind: .flight, stoppedConfirmed: true, now: now),
            .notYet(.noArrivalTime)
        )
    }

    // MARK: - 停下判定

    func testTransitEvidenceOnlyUsedForCarAndBike() {
        let arrivalKindSamples = [sample(.automotive, minutesAgo: 8), sample(.stationary, minutesAgo: 1)]
        XCTAssertFalse(TripArrivalSchedule.isStoppedAfterTransit(samples: arrivalKindSamples, transportKind: .flight, now: now))
        XCTAssertFalse(TripArrivalSchedule.isStoppedAfterTransit(samples: arrivalKindSamples, transportKind: .train, now: now))
        // 地铁与公交沿途每站都停，「停下」推不出「下车」，只能靠时间
        XCTAssertFalse(TripArrivalSchedule.isStoppedAfterTransit(samples: arrivalKindSamples, transportKind: .metro, now: now))
        XCTAssertFalse(TripArrivalSchedule.isStoppedAfterTransit(samples: arrivalKindSamples, transportKind: .bus, now: now))
        XCTAssertTrue(TripArrivalSchedule.isStoppedAfterTransit(samples: arrivalKindSamples, transportKind: .automobile, now: now))
    }

    func testStillMovingIsNotStopped() {
        let samples = [sample(.automotive, minutesAgo: 8), sample(.automotive, minutesAgo: 1)]
        XCTAssertFalse(TripArrivalSchedule.isStoppedAfterTransit(samples: samples, transportKind: .automobile, now: now))
    }

    func testTransitInsideSettleWindowIsNotStopped() {
        // 在途证据必须早于静止观察窗，否则「刚停」与「在途」互相矛盾
        let samples = [sample(.automotive, minutesAgo: 1), sample(.stationary, minutesAgo: 0)]
        XCTAssertFalse(TripArrivalSchedule.isStoppedAfterTransit(samples: samples, transportKind: .automobile, now: now))
    }

    func testWalkingAfterGettingOffBikeCountsAsStopped() {
        let samples = [sample(.cycling, minutesAgo: 10), sample(.walking, minutesAgo: 1)]
        XCTAssertTrue(TripArrivalSchedule.isStoppedAfterTransit(samples: samples, transportKind: .bicycle, now: now))
    }

    func testLowConfidenceSamplesAreIgnored() {
        let samples = [
            sample(.automotive, minutesAgo: 8, confidence: .high),
            sample(.stationary, minutesAgo: 1, confidence: .low)
        ]
        XCTAssertFalse(TripArrivalSchedule.isStoppedAfterTransit(samples: samples, transportKind: .automobile, now: now))
    }

    func testSamplesOutsideLookbackAreIgnored() {
        let samples = [sample(.automotive, minutesAgo: 40), sample(.stationary, minutesAgo: 1)]
        XCTAssertFalse(TripArrivalSchedule.isStoppedAfterTransit(samples: samples, transportKind: .automobile, now: now))
    }

    func testNoSamplesYieldNoStopEvidence() {
        XCTAssertFalse(TripArrivalSchedule.isStoppedAfterTransit(samples: [], transportKind: .automobile, now: now))
    }

    // MARK: - 方式归一化

    func testTransportKindNormalization() {
        XCTAssertEqual(TripArrivalSchedule.transportKind(fromRaw: "flight"), .flight)
        XCTAssertEqual(TripArrivalSchedule.transportKind(fromRaw: " 飞机 "), .flight)
        XCTAssertEqual(TripArrivalSchedule.transportKind(fromRaw: "G1234 高铁"), .train)
        XCTAssertEqual(TripArrivalSchedule.transportKind(fromRaw: "地铁 10 号线"), .metro)
        XCTAssertEqual(TripArrivalSchedule.transportKind(fromRaw: "subway"), .metro)
        XCTAssertEqual(TripArrivalSchedule.transportKind(fromRaw: "公交车"), .bus)
        XCTAssertEqual(TripArrivalSchedule.transportKind(fromRaw: "bus 300"), .bus)
        XCTAssertEqual(TripArrivalSchedule.transportKind(fromRaw: "轻轨"), .metro)
        XCTAssertEqual(TripArrivalSchedule.transportKind(fromRaw: "网约车"), .automobile)
        XCTAssertEqual(TripArrivalSchedule.transportKind(fromRaw: "骑行通勤"), .bicycle)
        XCTAssertEqual(TripArrivalSchedule.transportKind(fromRaw: "walk"), .unknown)
        XCTAssertEqual(TripArrivalSchedule.transportKind(fromRaw: nil), .unknown)
        XCTAssertEqual(TripArrivalSchedule.transportKind(fromRaw: "train"), .train)
    }
}
