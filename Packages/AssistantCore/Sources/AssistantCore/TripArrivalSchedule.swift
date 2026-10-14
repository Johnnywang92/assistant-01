import Foundation

/// 到站/落地前「清点随身物品」提醒的判定纯逻辑。
/// 分工：票面（或用户手选）决定交通方式，运动数据只判断「在途 → 刚停下」，时间负责兜底。
/// CoreMotion 采样与 UNNotification 排期留在 app 侧，本文件可单测。
public enum TripArrivalSchedule {

    /// 行程交通方式。flight/train 只能来自票面或用户手选，CoreMotion 无法区分火车与飞机。
    public enum TransportKind: String, CaseIterable, Hashable, Sendable {
        case flight
        case train
        case metro
        case bus
        case automobile
        case bicycle
        case unknown

        /// 运动数据对「是否已停下」是否有参考价值：机上/车上手机多半拿不到可用采样，
        /// 地铁与公交沿途每站都停，「停下」根本推不出「下车」，一律只走时间。
        public var supportsMotionEvidence: Bool {
            self == .automobile || self == .bicycle
        }

        /// 在途时应有的运动模式。
        public var inTransitActivity: MotionSample.Activity? {
            switch self {
            case .automobile: return .automotive
            case .bicycle: return .cycling
            case .flight, .train, .metro, .bus, .unknown: return nil
            }
        }
    }

    /// 单条运动采样。`date` 为该段活动的结束时刻（与 CMMotionActivity.timestamp 口径一致）。
    public struct MotionSample: Hashable, Sendable {
        public enum Activity: String, Hashable, Sendable {
            case unknown, stationary, walking, running, cycling, automotive
        }

        /// 与 CMMotionActivityConfidence 对齐，rawValue 越大越可信。
        public enum Confidence: Int, Hashable, Sendable {
            case unknown, low, medium, high
        }

        public var date: Date
        public var activity: Activity
        public var confidence: Confidence

        public init(date: Date, activity: MotionSample.Activity, confidence: MotionSample.Confidence) {
            self.date = date
            self.activity = activity
            self.confidence = confidence
        }
    }

    /// 提醒提前量：飞机要收行李、过廊桥，提前最多；骑行/开车下车即走，提前最少。
    /// 地铁与公交按「到站前抓起包挤到门口」的实际动作定，且沿途停站多，只走时间不走运动。
    public static func advanceLead(for kind: TransportKind) -> TimeInterval {
        switch kind {
        case .flight: return 20 * 60
        case .train: return 8 * 60
        case .metro: return 5 * 60
        case .bus: return 4 * 60
        case .automobile: return 5 * 60
        case .bicycle: return 3 * 60
        case .unknown: return 5 * 60
        }
    }

    /// 过了预计到达时间仍允许触发的容忍窗口；超出即视为行程已结束，不再打扰。
    public static let backstopGrace: TimeInterval = 40 * 60

    /// 认为「已经停下」需要静止状态连续覆盖的时长。
    public static let settleDuration: TimeInterval = 90

    /// 取回多久的历史采样用于判定在途证据。
    public static let motionLookback: TimeInterval = 20 * 60

    /// 重新排期/编辑到达时间后的去重容忍：早于本窗口触发过的提醒不算「本次已触发」。
    public static let firedTolerance: TimeInterval = 60

    public enum Trigger: String, Hashable, Sendable {
        /// 运动数据确认已停下，可提前于预计到达时间提醒。
        case motionStopped
        /// 已到预计到达时间，无运动证据时兜底提醒。
        case timeBackstop
    }

    public enum NotYetReason: String, Hashable, Sendable {
        case noArrivalTime
        case alreadyFired
        /// 还没进入提前提醒窗口。
        case tooEarly
        /// 已进入窗口但运动数据仍显示在途，等待停下证据或时间兜底。
        case awaitingStopEvidence
    }

    public enum Outcome: Equatable, Sendable {
        case fire(Trigger)
        case notYet(NotYetReason)
        /// 已超过容忍窗口，行程应视为结束（app 侧可顺手清理围栏与排期）。
        case expired

        public var shouldFire: Bool {
            if case .fire = self { return true }
            return false
        }
    }

    /// 判定此刻是否该弹出清点提醒。
    /// - Parameters:
    ///   - expectedArrivalAt: 预计到达/落地时间，nil 表示该待办未开启到站清点。
    ///   - firedAt: 本次行程已触发时间，用于去重。
    ///   - stoppedConfirmed: `isStoppedAfterTransit` 的结论；无运动证据时传 false 即可。
    public static func decide(
        expectedArrivalAt: Date?,
        firedAt: Date?,
        transportKind: TransportKind,
        stoppedConfirmed: Bool,
        now: Date
    ) -> Outcome {
        guard let expectedArrivalAt else { return .notYet(.noArrivalTime) }
        let windowStart = expectedArrivalAt.addingTimeInterval(-advanceLead(for: transportKind))
        let deadline = expectedArrivalAt.addingTimeInterval(backstopGrace)

        if let firedAt, firedAt >= windowStart.addingTimeInterval(-firedTolerance) {
            return .notYet(.alreadyFired)
        }
        if now > deadline { return .expired }
        if now < windowStart { return .notYet(.tooEarly) }
        if stoppedConfirmed { return .fire(.motionStopped) }
        if now >= expectedArrivalAt { return .fire(.timeBackstop) }
        return .notYet(.awaitingStopEvidence)
    }

    /// 由运动采样判定「先前在途、最近已停下」。
    /// 机票/车票不走运动路径（采样不可靠），返回 false 让时间兜底接管；
    /// 权限被拒或采样为空同样返回 false，不会因此漏掉提醒——只是失去提前量。
    public static func isStoppedAfterTransit(
        samples: [MotionSample],
        transportKind: TransportKind,
        now: Date
    ) -> Bool {
        guard transportKind.supportsMotionEvidence,
              let inTransit = transportKind.inTransitActivity else { return false }
        let historyStart = now.addingTimeInterval(-motionLookback)
        let settleStart = now.addingTimeInterval(-settleDuration)
        // 低置信度采样不足以支撑「已停下」的结论
        let usable = samples.filter {
            $0.date >= historyStart && $0.date <= now
                && $0.confidence.rawValue >= MotionSample.Confidence.medium.rawValue
        }
        guard usable.contains(where: { $0.activity == inTransit && $0.date < settleStart }) else {
            return false
        }
        let recent = usable.filter { $0.date >= settleStart }
        guard !recent.isEmpty else { return false }
        return !recent.contains { $0.activity == inTransit }
    }

    /// 票面/手选原文到交通方式的归一化，供 OCR 与手动入口共用。
    public static func transportKind(fromRaw raw: String?) -> TransportKind {
        guard let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else { return .unknown }
        if let matched = TransportKind(rawValue: normalized) { return matched }
        if normalized.contains("flight") || normalized.contains("飞机") || normalized.contains("航班") { return .flight }
        if normalized.contains("metro") || normalized.contains("subway")
            || normalized.contains("地铁") || normalized.contains("城铁") || normalized.contains("轻轨") { return .metro }
        if normalized.contains("bus") || normalized.contains("公交") || normalized.contains("巴士") { return .bus }
        if normalized.contains("train") || normalized.contains("高铁") || normalized.contains("火车")
            || normalized.contains("动车") || normalized.contains("列车") { return .train }
        if normalized.contains("bike") || normalized.contains("骑行") || normalized.contains("自行车") { return .bicycle }
        if normalized.contains("car") || normalized.contains("taxi") || normalized.contains("开车")
            || normalized.contains("打车") || normalized.contains("网约车") || normalized.contains("出租") { return .automobile }
        return .unknown
    }
}
