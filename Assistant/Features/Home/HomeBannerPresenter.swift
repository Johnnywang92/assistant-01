import AssistantCore
import Foundation

// MARK: - 首页 · 横幅文案与动作绑定
//
// 队列**顺序**由 Core 的 `HomeBannerQueueBuilder` 决定（可被 Core 单测覆盖）。
// App 层负责的是「每条横幅显示什么字、点了做什么」——这部分闭包绑定无法进 Core，
// 但**文案与分组映射**可以抽出来单测，避免标题写错、优先级映射漂移。
//
// 这里刻意不持有闭包：`HomeBannerAction` 只描述「做什么」，具体闭包由视图绑定。
// 这样映射表可以被测试逐条断言，而不会因为闭包无法比较而失去可测性。

/// 横幅的展示文案与语义（不含闭包，可直接断言）。
struct HomeBannerPresentation: Hashable {
    /// 与 `HomeBannerFact.id` 对应。
    let id: String
    let title: String
    let detail: String
    let tone: HomeBannerTone
    /// 操作按钮文案。
    let actionLabel: String
    /// 是否可手动关闭（不可关闭的必须提供「退出」类动作）。
    let isDismissible: Bool
}

/// 横幅 ID 常量。存量 6 个条件横幅 + 4 个常驻模块，ID 与 §8.4 的清单一一对应，
/// 避免「改了一处、另一处还对不上」。
enum HomeBannerID {
    static let reordering = "reordering"
    static let seniorMode = "senior"
    static let weather = "weather"
    static let anniversary = "anniversary"
    static let ticket = "ticket"
    static let travelCountdown = "travelCountdown"
    static let lifeEvent = "lifeEvent"

    /// 长辈模式与排序模式互斥：同一时刻只显示一条操作态横幅。
    static let mutuallyExclusive: Set<String> = [reordering, seniorMode]
}

/// 横幅的展示信息组装器。
enum HomeBannerPresenter {

    /// 纯文案映射表。需要在运行时拼装标题的条目（如带天数的纪念日）
    /// 由调用方通过 `overrides` 传入覆盖值，其余走这里的默认文案。
    ///
    /// - Parameters:
    ///   - fact: Core 判定的横幅事实（提供分组与可关闭性）。
    ///   - overrides: 需要动态文案时传入的标题/详情覆盖值。
    static func presentation(
        for fact: HomeBannerFact,
        overrides: [String: (title: String, detail: String)] = [:]
    ) -> HomeBannerPresentation? {
        let override = overrides[fact.id]

        switch fact.id {
        case HomeBannerID.reordering:
            return HomeBannerPresentation(
                id: fact.id,
                title: override?.title ?? "排序模式 · 拖动把手调整顺序",
                detail: override?.detail ?? "正在调整待办顺序，结束后点「完成」还原",
                tone: .neutral,
                actionLabel: "退出排序",
                isDismissible: false
            )
        case HomeBannerID.seniorMode:
            return HomeBannerPresentation(
                id: fact.id,
                title: override?.title ?? "长辈关怀大字模式已开启",
                detail: override?.detail ?? "可随时调整字号",
                tone: .neutral,
                actionLabel: "调整字号",
                isDismissible: false
            )
        case HomeBannerID.weather:
            return HomeBannerPresentation(
                id: fact.id,
                title: override?.title ?? "气象预警 · 有新的天气提醒",
                detail: override?.detail ?? "突发气象预警或气温骤降，点开可查看详情",
                tone: .warning,
                actionLabel: "知道了",
                isDismissible: true
            )
        case HomeBannerID.anniversary:
            return HomeBannerPresentation(
                id: fact.id,
                title: override?.title ?? "纪念日筹备",
                detail: override?.detail ?? "可一键把准备事项加入待办",
                tone: .warning,
                actionLabel: "加入待办",
                isDismissible: true
            )
        case HomeBannerID.ticket:
            return HomeBannerPresentation(
                id: fact.id,
                title: override?.title ?? "出行购票 · 车票开售提醒",
                detail: override?.detail ?? "临近出行，可查看购票确认信息",
                tone: .warning,
                actionLabel: "去确认",
                isDismissible: true
            )
        case HomeBannerID.travelCountdown:
            return HomeBannerPresentation(
                id: fact.id,
                title: override?.title ?? "行程倒计时",
                detail: override?.detail ?? "临近出发，可查看车次与检票口",
                tone: .warning,
                actionLabel: "查看行程",
                isDismissible: true
            )
        case HomeBannerID.lifeEvent:
            return HomeBannerPresentation(
                id: fact.id,
                title: override?.title ?? "人生大事",
                detail: override?.detail ?? "进行中的人生大事，点开查看筹备进度",
                tone: .neutral,
                actionLabel: "去查看",
                isDismissible: false
            )
        default:
            return nil
        }
    }

    /// 分组 → 二级页分组标题。Core 只给分组 ID，文案在 App 层翻译。
    static func groupTitle(_ group: HomeBannerGroup) -> String {
        switch group {
        case .safetyAndTimeliness: return "P0 · 安全与时效"
        case .activeOperation: return "P1 · 进行中的操作态"
        case .informational: return "P2 · 信息态"
        }
    }
}
