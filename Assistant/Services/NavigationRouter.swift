import Foundation
import SwiftUI
import UIKit

/// 全局快捷导航路由
@MainActor
public final class NavigationRouter: ObservableObject {
    public static let shared = NavigationRouter()

    public enum AppTab: String, CaseIterable, Identifiable, Codable {
        case todos
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
            case .todos: return "待办"
            case .departure: return "出门防丢"
            case .expenses: return "记账"
            case .vault: return "生活档案"
            case .passwords: return "密码箱"
            case .documents: return "证件卡包"
            case .memos: return "语音备忘"
            case .settings: return "设置"
            }
        }

        public var systemImage: String {
            switch self {
            case .todos: return "checklist"
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
            case .todos: return "日常事务、快递取件与待办催办"
            case .departure: return "随身物品清点、防丢检查与口诀"
            case .expenses: return "日常收支账本与统计分析"
            case .vault: return "纪念日、服药、家务习惯等生活全档案"
            case .passwords: return "高强度账号密码离线保险箱"
            case .documents: return "身份证、护照、驾驶证重要卡包"
            case .memos: return "离线随身录音、倍速回放与转写提取待办"
            case .settings: return "主题壁纸、单手悬浮球与偏好设置"
            }
        }
    }

    /// 默认启用的 5 个 Tab 板块（包含出门防遗忘）
    public static let defaultTabs: [AppTab] = [.todos, .departure, .expenses, .vault, .settings]

    public enum ActiveSheet: String, Identifiable {
        case addTodo
        case voice
        case expense
        case idVault
        case settings

        public var id: String { rawValue }
    }

    @Published public var selectedTab: AppTab = .todos
    @Published public var activeSheet: ActiveSheet?
    @Published public var requestedFilter: String?

    private init() {}

    /// 处理 URL Scheme 跳转 (assistant://...)
    public func handleURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "assistant" else { return }

        // 支持 host 或 path 格式，如 assistant://voice 或 assistant:///voice
        let host = (url.host?.lowercased() ?? url.pathComponents.filter { $0 != "/" }.first?.lowercased()) ?? ""

        switch host {
        case "voice", "dialogue":
            activeSheet = .voice
        case "add", "add-todo", "todo":
            selectedTab = .todos
            activeSheet = .addTodo
        case "departure", "checklist", "pack":
            selectedTab = .departure
        case "expense", "billing", "bill":
            selectedTab = .expenses
        case "vault", "id-vault", "ids":
            selectedTab = .vault
        case "passwords", "password":
            selectedTab = .passwords
        case "documents", "document", "cards":
            selectedTab = .documents
        case "memo", "memos", "recorder":
            selectedTab = .memos
        case "parcels", "express", "package":
            selectedTab = .todos
            requestedFilter = "快递"
        case "settings":
            selectedTab = .settings
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
        default:
            break
        }
    }

    /// 注册高保真 SF Symbol 桌面快捷操作项
    public func registerDynamicShortcuts() {
        let items: [UIApplicationShortcutItem] = [
            UIApplicationShortcutItem(
                type: "assistant.action.voice",
                localizedTitle: "语音对话",
                localizedSubtitle: "快速唤起离线语音交互",
                icon: UIApplicationShortcutIcon(systemImageName: "waveform.circle.fill"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: "assistant.action.add_todo",
                localizedTitle: "新建待办",
                localizedSubtitle: "快速记录日程备忘",
                icon: UIApplicationShortcutIcon(systemImageName: "plus.circle.fill"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: "assistant.action.expense",
                localizedTitle: "一句话记账",
                localizedSubtitle: "语音或打字自动记账",
                icon: UIApplicationShortcutIcon(systemImageName: "yensign.circle.fill"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: "assistant.action.parcels",
                localizedTitle: "待取快递",
                localizedSubtitle: "快速查看全部取件码",
                icon: UIApplicationShortcutIcon(systemImageName: "shippingbox.fill"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: "assistant.action.id_vault",
                localizedTitle: "证件保险箱",
                localizedSubtitle: "重要证照安全查阅",
                icon: UIApplicationShortcutIcon(systemImageName: "person.text.rectangle.fill"),
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
        completionHandler([.banner, .sound, .badge])
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
