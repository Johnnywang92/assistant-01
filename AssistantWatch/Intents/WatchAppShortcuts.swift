import AppIntents
import Foundation

/// Apple Watch Ultra 操作按钮（Action Button）与表盘快捷指令直达：打开语音速记
struct WatchOpenQuickCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "腕上语音速记"
    static let description = IntentDescription("在 Apple Watch 上直接打开小助语音速记与一键预设（适合绑定 Ultra 操作按钮）。")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchStore.shared.selectedTab = .quickCapture
        return .result()
    }
}

/// Apple Watch Ultra 操作按钮与表盘直达：查看待取快递取件码铭牌
struct WatchOpenParcelsIntent: AppIntent {
    static let title: LocalizedStringResource = "腕上取件码"
    static let description = IntentDescription("在 Apple Watch 上直接打开待取快递大字取件码铭牌。")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchStore.shared.selectedTab = .parcels
        return .result()
    }
}

/// Apple Watch Ultra 操作按钮与表盘直达：出门清点与行程护航
struct WatchOpenDepartureIntent: AppIntent {
    static let title: LocalizedStringResource = "腕上出门清点"
    static let description = IntentDescription("在 Apple Watch 上直接打开出门防丢清点清单与高铁/航班行程护航。")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchStore.shared.selectedTab = .departure
        return .result()
    }
}

/// Apple Watch Ultra 操作按钮与表盘直达：一键补水 +250ml
struct WatchQuickWaterIntent: AppIntent {
    static let title: LocalizedStringResource = "腕上喝水 +250ml"
    static let description = IntentDescription("无需打字，按一下操作按钮或表盘直接记录喝水 250 毫升。")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        WatchStore.shared.sendCommand(
            .addWater(beverageRaw: "白水", volumeML: 250),
            feedbackToast: "已补水 +250ml 💧"
        )
        return .result(dialog: "已记录补水 250ml 💧")
    }
}

/// Apple Watch Ultra 操作按钮与表盘直达：查看身体活力与愉悦双指数
struct WatchOpenHealthIntent: AppIntent {
    static let title: LocalizedStringResource = "腕上身心双指数"
    static let description = IntentDescription("在 Apple Watch 上查看今日身体活力分与身心愉悦指数。")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchStore.shared.selectedTab = .health
        return .result()
    }
}

/// 注册到系统快捷指令与 Apple Watch Ultra 操作按钮列表
struct WatchAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WatchOpenQuickCaptureIntent(),
            phrases: [
                "用\(.applicationName)腕上速记",
                "打开\(.applicationName)速记"
            ],
            shortTitle: "腕上速记",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: WatchOpenParcelsIntent(),
            phrases: [
                "用\(.applicationName)看取件码",
                "打开\(.applicationName)取件码"
            ],
            shortTitle: "取件码铭牌",
            systemImageName: "shippingbox.fill"
        )
        AppShortcut(
            intent: WatchOpenDepartureIntent(),
            phrases: [
                "用\(.applicationName)出门清点",
                "打开\(.applicationName)出行护航"
            ],
            shortTitle: "出门清点",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: WatchQuickWaterIntent(),
            phrases: [
                "用\(.applicationName)喝一杯水",
                "\(.applicationName)补水打卡"
            ],
            shortTitle: "喝水 +250ml",
            systemImageName: "drop.fill"
        )
        AppShortcut(
            intent: WatchOpenHealthIntent(),
            phrases: [
                "查\(.applicationName)身心指数",
                "查看\(.applicationName)活力分"
            ],
            shortTitle: "身心双指数",
            systemImageName: "bolt.heart.fill"
        )
    }
}
