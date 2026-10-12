import Foundation
import SwiftUI

/// 首页 Tab 栏管理引擎（支持自定义板块增删与拖拽排序，最多 5 个）
@MainActor
public final class TabBarManager: ObservableObject {
    public static let shared = TabBarManager()

    public static let maxTabsCount = 5
    public static let minTabsCount = 2

    private let userDefaultsKey = "custom_home_tabs_order_v1"

    /// 当前展示在首页 Tab 栏上的板块列表（严格保持用户自定义顺序）
    @Published public var activeTabs: [NavigationRouter.AppTab] = NavigationRouter.defaultTabs {
        didSet {
            save()
        }
    }

    private init() {
        reloadFromDefaults()
    }

    /// 从 UserDefaults 重载 Tab 配置（备份导入设置后调用，避免单例持有旧值）
    public func reloadFromDefaults() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let saved = try? JSONDecoder().decode([NavigationRouter.AppTab].self, from: data),
           !saved.isEmpty {
            // 过滤重复项并确保不超过 5 个且不少于 2 个
            var unique: [NavigationRouter.AppTab] = []
            for tab in saved {
                if !unique.contains(tab) {
                    unique.append(tab)
                }
            }
            // 确保「设置」作为核心系统入口始终常驻在 Tab 栏中
            if !unique.contains(.settings) {
                if unique.count >= Self.maxTabsCount {
                    unique[unique.count - 1] = .settings
                } else {
                    unique.append(.settings)
                }
            }
            let valid = unique.prefix(Self.maxTabsCount)
            self.activeTabs = valid.count >= Self.minTabsCount ? Array(valid) : NavigationRouter.defaultTabs
        } else {
            self.activeTabs = NavigationRouter.defaultTabs
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(activeTabs) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    /// 检查指定板块是否已放在 Tab 栏上
    public func isTabActive(_ tab: NavigationRouter.AppTab) -> Bool {
        activeTabs.contains(tab)
    }

    /// 检查指定板块是否可以被移除（「设置」为核心入口固定常驻，且保留最少板块数）
    public func canRemoveTab(_ tab: NavigationRouter.AppTab) -> Bool {
        tab != .settings && activeTabs.count > Self.minTabsCount
    }

    /// 所有未添加到 Tab 栏的候选板块
    public var inactiveTabs: [NavigationRouter.AppTab] {
        NavigationRouter.AppTab.allCases.filter { !activeTabs.contains($0) }
    }

    /// 添加板块至 Tab 栏末尾
    @discardableResult
    public func addTab(_ tab: NavigationRouter.AppTab) -> (success: Bool, message: String?) {
        guard !activeTabs.contains(tab) else {
            return (false, L10n.tr("该板块已在首页 Tab 栏中"))
        }
        guard activeTabs.count < Self.maxTabsCount else {
            Haptic.error()
            return (false, L10n.choose(
                "首页 Tab 栏最多只允许放置 \(Self.maxTabsCount) 个板块，请先移除其他板块",
                "Home Tab Bar allows up to \(Self.maxTabsCount) tabs. Please remove another tab first."
            ))
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            activeTabs.append(tab)
        }
        Haptic.success()
        return (true, nil)
    }

    /// 从 Tab 栏移除板块（「设置」板块不允许移除）
    @discardableResult
    public func removeTab(_ tab: NavigationRouter.AppTab) -> (success: Bool, message: String?) {
        guard tab != .settings else {
            Haptic.warning()
            return (false, L10n.tr("「设置」为核心系统入口，固定常驻不可移除"))
        }
        guard activeTabs.count > Self.minTabsCount else {
            Haptic.error()
            return (false, L10n.choose(
                "首页 Tab 栏至少需要保留 \(Self.minTabsCount) 个板块",
                "Home Tab Bar requires at least \(Self.minTabsCount) tabs."
            ))
        }
        guard let index = activeTabs.firstIndex(of: tab) else {
            return (false, L10n.tr("未找到该板块"))
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            _ = activeTabs.remove(at: index)
        }
        // 如果当前选中的 Tab 被移除了，自动切到第一个 Tab
        if NavigationRouter.shared.selectedTab == tab {
            NavigationRouter.shared.selectedTab = activeTabs.first ?? .todos
        }
        Haptic.light()
        return (true, nil)
    }

    /// 拖拽排序
    public func moveTabs(from source: IndexSet, to destination: Int) {
        withAnimation(.easeInOut(duration: 0.25)) {
            activeTabs.move(fromOffsets: source, toOffset: destination)
        }
        Haptic.selection()
    }

    /// 上移某个板块
    public func moveUp(_ tab: NavigationRouter.AppTab) {
        guard let index = activeTabs.firstIndex(of: tab), index > 0 else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            activeTabs.swapAt(index, index - 1)
        }
        Haptic.selection()
    }

    /// 下移某个板块
    public func moveDown(_ tab: NavigationRouter.AppTab) {
        guard let index = activeTabs.firstIndex(of: tab), index < activeTabs.count - 1 else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            activeTabs.swapAt(index, index + 1)
        }
        Haptic.selection()
    }

    /// 重置为默认排列（首页、人生大事、记账、生活档案、设置）
    public func resetToDefault() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            activeTabs = NavigationRouter.defaultTabs
        }
        if !activeTabs.contains(NavigationRouter.shared.selectedTab) {
            NavigationRouter.shared.selectedTab = .todos
        }
        Haptic.medium()
    }
}
