import Foundation
import SwiftUI
import UIKit

/// 全局快捷导航路由
@MainActor
public final class NavigationRouter: ObservableObject {
    public static let shared = NavigationRouter()

    public enum AppTab: String, CaseIterable, Identifiable, Codable, Sendable {
        case todos
        case lifeEvents
        case departure
        case expenses
        case vault
        case passwords
        case documents
        case memos
        case settings

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .todos: return L10n.tr("首页")
            case .lifeEvents: return L10n.tr("人生大事")
            case .departure: return L10n.tr("出门防丢")
            case .expenses: return L10n.tr("记账")
            case .vault: return L10n.tr("生活档案")
            case .passwords: return L10n.tr("密码箱")
            case .documents: return L10n.tr("证件卡包")
            case .memos: return L10n.tr("语音备忘")
            case .settings: return L10n.tr("设置")
            }
        }

        public var systemImage: String {
            switch self {
            case .todos: return "house.fill"
            case .lifeEvents: return "sparkles"
            case .departure: return "briefcase.fill"
            case .expenses: return "yensign.circle.fill"
            case .vault: return "folder.badge.person.crop"
            case .passwords: return "key.fill"
            case .documents: return "person.text.rectangle.fill"
            case .memos: return "mic.circle.fill"
            case .settings: return "gearshape.fill"
            }
        }

        public var subtitle: String {
            switch self {
            case .todos: return L10n.tr("待办、快递取件与每日安排总览")
            case .lifeEvents: return L10n.tr("订婚、婚礼、乔迁、升学宴等长期项目")
            case .departure: return L10n.tr("随身物品清点、防丢检查与口诀")
            case .expenses: return L10n.tr("日常收支账本与统计分析")
            case .vault: return L10n.tr("纪念日、运动、药物保健品等生活全档案")
            case .passwords: return L10n.tr("高强度账号密码离线保险箱")
            case .documents: return L10n.tr("身份证、护照、驾驶证重要卡包")
            case .memos: return L10n.tr("离线随身录音、倍速回放与转写提取待办")
            case .settings: return L10n.tr("主题壁纸、单手悬浮球与偏好设置")
            }
        }
    }

    /// 默认启用的 5 个 Tab 板块（包含出门防遗忘）
    public static let defaultTabs: [AppTab] = [.todos, .lifeEvents, .expenses, .vault, .settings]

    public enum ActiveSheet: String, Identifiable {
        case addTodo
        case voice
        case periodicReport
        case expense
        case idVault
        case settings
        case qrScanner
        case omnibox
        case unifiedSearch

        public var id: String { rawValue }
    }

    @Published public var selectedTab: AppTab = .todos
    @Published public var activeSheet: ActiveSheet?
    @Published public var requestedFilter: String?
    @Published public var focusedTodoID: UUID?
    /// 统一搜索/深链直达待办：TodoListView 消费后打开该待办详情并置 nil
    @Published public var requestedTodoDetailID: UUID? = nil
    @Published public var pendingImportPayload: TodoSharePayload?
    /// 万能投喂口的剪贴板预填充载荷（由投喂口消费后置 nil）
    @Published public var omniboxPrefill: OmniboxPayload?
    /// 是否为剪贴板自动唤起投喂口（用于支持无意添加时的倒计时自动关闭）
    @Published public var omniboxIsClipboardAutoIngest: Bool = false
    /// 深链触发：切到生活档案后直接推入技能学习路径列表（由 LifeVaultView 消费后置 false）
    @Published public var requestedSkillPathList: Bool = false
    /// 深链/统一搜索触发：切到生活档案后直接推入指定子板块
    @Published public var requestedVaultDestination: String? = nil
    /// 全局统一搜索预填入检索词
    @Published public var prefilledSearchQuery: String? = nil

    private init() {}

    public func focusTodo(_ id: UUID) {
        selectedTab = .todos
        focusedTodoID = id
    }

    /// 跨模块统一导航路由：若对应 Tab 处于活跃列表则直达 Tab，否则切至生活档案大厅并推入对应子页面
    public func navigateTo(tab: AppTab, vaultDestination: String? = nil, focusTodoID: UUID? = nil) {
        if let focusTodoID {
            // 搜索结果命中待办：滚动定位之外再直达详情
            selectedTab = .todos
            focusedTodoID = focusTodoID
            requestedTodoDetailID = focusTodoID
            return
        }
        if TabBarManager.shared.isTabActive(tab) {
            selectedTab = tab
        } else {
            selectedTab = .vault
            requestedVaultDestination = vaultDestination ?? tab.rawValue
        }
    }

    /// 处理 URL Scheme 跳转 (assistant://...)
    public func handleURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "assistant" else { return }

        // 支持 host 或 path 格式，如 assistant://voice 或 assistant:///voice
        let host = (url.host?.lowercased() ?? url.pathComponents.filter { $0 != "/" }.first?.lowercased()) ?? ""

        // 检查是否有直接指定的事项 ID 参数 (assistant://todo?id=UUID 或 assistant://todos?id=UUID)
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItem = components.queryItems?.first(where: { $0.name == "id" }),
           let idStr = queryItem.value,
           let uuid = UUID(uuidString: idStr) {
            focusTodo(uuid)
            return
        }

        switch host {
        case "search", "unified-search":
            // 深链 assistant://search?q=关键词：小组件/快捷指令直接唤起跨模块统一搜索
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryValue = components.queryItems?.first(where: { $0.name == "q" })?.value,
               !queryValue.isEmpty {
                prefilledSearchQuery = queryValue
            }
            activeSheet = .unifiedSearch
        case "import", "import-todo", "import-qr":
            if let payload = QRCodeService.decodePayload(from: url.absoluteString) {
                selectedTab = .todos
                pendingImportPayload = payload
            }
        case "scan", "scanner", "qr":
            selectedTab = .todos
            activeSheet = .qrScanner
        case "voice", "dialogue":
            activeSheet = .voice
        case "add", "add-todo", "todo":
            selectedTab = .todos
            activeSheet = .addTodo
        case "todos":
            // 小组件/灵动岛深链 assistant://todos：跳待办首页（单数 todo 是新建弹层）
            selectedTab = .todos
        case "departure", "checklist", "pack":
            selectedTab = .departure
        case "expense", "expenses", "billing", "bill":
            selectedTab = .expenses
        case "vault", "id-vault", "ids":
            selectedTab = .vault
        case "storage", "store", "items":
            navigateTo(tab: .vault, vaultDestination: "storage")
        case "skills", "skill", "learning", "practice":
            selectedTab = .vault
            requestedSkillPathList = true
        case "passwords", "password":
            navigateTo(tab: .passwords, vaultDestination: "passwords")
        case "documents", "document", "cards":
            navigateTo(tab: .documents, vaultDestination: "documents")
        case "memo", "memos", "recorder":
            navigateTo(tab: .memos, vaultDestination: "voiceMemos")
        case "parcels", "express", "package":
            selectedTab = .todos
            requestedFilter = "快递"
        case "settings":
            selectedTab = .settings
        case "omnibox", "drop", "feed":
            activeSheet = .omnibox
        case "share", "share-import":
            // 分享扩展交接：排空 App Group 中转区，OCR/解析并落库
            Task { @MainActor in await ShareInboxService.processAll() }
        default:
            break
        }
    }

    /// 处理桌面 3D Touch / 触感触控快捷菜单
    public func handleShortcutItem(_ item: UIApplicationShortcutItem) {
        switch item.type {
        case "assistant.action.voice":
            activeSheet = .voice
        case "assistant.action.add_todo":
            selectedTab = .todos
            activeSheet = .addTodo
        case "assistant.action.expense":
            selectedTab = .expenses
        case "assistant.action.parcels":
            selectedTab = .todos
            requestedFilter = "快递"
        case "assistant.action.id_vault":
            selectedTab = .vault
        case "assistant.action.departure":
            selectedTab = .departure
        case "assistant.action.omnibox":
            activeSheet = .omnibox
        default:
            break
        }
    }

    /// 注册高保真 SF Symbol 桌面快捷操作项
    public func registerDynamicShortcuts() {
        let items: [UIApplicationShortcutItem] = [
            UIApplicationShortcutItem(
                type: "assistant.action.voice",
                localizedTitle: L10n.tr("语音对话"),
                localizedSubtitle: L10n.tr("快速唤起离线语音交互"),
                icon: UIApplicationShortcutIcon(systemImageName: "waveform.circle.fill"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: "assistant.action.add_todo",
                localizedTitle: L10n.tr("新建待办"),
                localizedSubtitle: L10n.tr("快速记录日程备忘"),
                icon: UIApplicationShortcutIcon(systemImageName: "plus.circle.fill"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: "assistant.action.expense",
                localizedTitle: L10n.tr("一句话记账"),
                localizedSubtitle: L10n.tr("语音或打字自动记账"),
                icon: UIApplicationShortcutIcon(systemImageName: "yensign.circle.fill"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: "assistant.action.parcels",
                localizedTitle: L10n.tr("待取快递"),
                localizedSubtitle: L10n.tr("快速查看全部取件码"),
                icon: UIApplicationShortcutIcon(systemImageName: "shippingbox.fill"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: "assistant.action.id_vault",
                localizedTitle: L10n.tr("证件保险箱"),
                localizedSubtitle: L10n.tr("重要证照安全查阅"),
                icon: UIApplicationShortcutIcon(systemImageName: "person.text.rectangle.fill"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: "assistant.action.omnibox",
                localizedTitle: L10n.tr("万能投喂口"),
                localizedSubtitle: L10n.tr("丢进文字或截图，自动记账、建待办"),
                icon: UIApplicationShortcutIcon(systemImageName: "tray.and.arrow.down.fill"),
                userInfo: nil
            )
        ]
        UIApplication.shared.shortcutItems = items
    }
}

// MARK: - UIKit 桥接 AppDelegate 处理冷启动与热唤起快捷方式

import UserNotifications

public final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    public func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UNUserNotificationCenter.current().delegate = self
        if let shortcutItem = options.shortcutItem {
            Task { @MainActor in
                NavigationRouter.shared.handleShortcutItem(shortcutItem)
            }
        }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    // 支持 App 处于前台运行时依然弹出本地通知横幅与声音
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if let type = userInfo["type"] as? String, type == "todo",
           let idString = userInfo["todoId"] as? String,
           let id = UUID(uuidString: idString) {
            Task { @MainActor in NavigationRouter.shared.focusTodo(id) }
        }
        completionHandler([.banner, .sound, .badge])
    }

    // 处理用户点击通知横幅或锁屏快捷操作按钮（如：标记完成、稍后推迟）
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let type = userInfo["type"] as? String, type == "periodic-report" {
            Task { @MainActor in
                NavigationRouter.shared.selectedTab = .todos
                NavigationRouter.shared.activeSheet = .periodicReport
            }
        } else if let type = userInfo["type"] as? String, type == "pickup" {
            // 手腕/锁屏上点「已取件」：销号、推进到下一件或收起销号通知
            Task { @MainActor in
                let context = Persistence.shared.mainContext
                PickupCheckoutService.handle(response, context: context)
                WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
            }
        } else if let type = userInfo["type"] as? String, type == "liveActivityControl" {
            // 手腕/Mac 上点护航·清点的伴随关闭动作：一键结束实时活动
            Task { @MainActor in
                LiveActivityControlNotifications.handle(response)
            }
        } else if let type = userInfo["type"] as? String, type == "todo" {
            if let idString = userInfo["todoId"] as? String, let id = UUID(uuidString: idString) {
                Task { @MainActor in NavigationRouter.shared.focusTodo(id) }
            }
            // 通知快捷操作（完成/推迟）落库后同步刷新桌面组件共享快照
            Task { @MainActor in
                let context = Persistence.shared.mainContext
                TodoNotificationManager.shared.handleNotificationResponse(response, context: context)
                WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
            }
        }
        completionHandler()
    }
}

public final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    public func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            NavigationRouter.shared.handleShortcutItem(shortcutItem)
            completionHandler(true)
        }
    }
}
