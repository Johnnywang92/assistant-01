import Foundation
import SwiftUI
import UIKit

/// 全局快捷导航路由
@MainActor
public final class NavigationRouter: ObservableObject {
    public static let shared = NavigationRouter()

    public enum ActiveSheet: String, Identifiable {
        case addTodo
        case voice
        case expense
        case idVault
        case settings

        public var id: String { rawValue }
    }

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
            activeSheet = .addTodo
        case "expense", "billing", "bill":
            activeSheet = .expense
        case "vault", "id-vault", "ids":
            activeSheet = .idVault
        case "parcels", "express", "package":
            requestedFilter = "快递"
            activeSheet = nil
        case "settings":
            activeSheet = .settings
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
            activeSheet = .addTodo
        case "assistant.action.expense":
            activeSheet = .expense
        case "assistant.action.parcels":
            requestedFilter = "快递"
            activeSheet = nil
        case "assistant.action.id_vault":
            activeSheet = .idVault
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

public final class AppDelegate: NSObject, UIApplicationDelegate {
    public func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem {
            Task { @MainActor in
                NavigationRouter.shared.handleShortcutItem(shortcutItem)
            }
        }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
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
