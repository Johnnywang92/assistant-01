import SwiftData
import SwiftUI

/// 主应用底部 Tab 栏导航（支持用户自定义板块增删与顺序排列，最多 5 个板块）
struct MainTabView: View {
    @ObservedObject private var router = NavigationRouter.shared
    @ObservedObject private var tabManager = TabBarManager.shared
    @Query(filter: #Predicate<TodoItem> { $0.statusRaw == "active" }) private var activeTodos: [TodoItem]
    @State private var showVoice = false

    var body: some View {
        ZStack {
            // 全局个性化背景底色层
            AppBackgroundView()

            TabView(selection: $router.selectedTab) {
                ForEach(tabManager.activeTabs) { tab in
                    tabContentView(for: tab)
                        .tabItem {
                            Label(tab.title, systemImage: tab.systemImage)
                        }
                        .tag(tab)
                        .badge(badgeCount(for: tab))
                }
            }

            // 单手自由拖拽吸边语音悬浮球
            DraggableVoiceFloatingBall(showVoice: $showVoice)
        }
        .sheet(isPresented: $showVoice) {
            VoiceDialogueView()
        }
        .onChange(of: router.activeSheet) { _, newSheet in
            if newSheet == .voice {
                showVoice = true
                router.activeSheet = nil
            }
        }
        .onAppear {
            // 确保当前选中的 Tab 存在于活跃列表中
            if !tabManager.activeTabs.contains(router.selectedTab) {
                router.selectedTab = tabManager.activeTabs.first ?? .todos
            }
        }
    }

    // MARK: - 板块内容视图分发

    @ViewBuilder
    private func tabContentView(for tab: NavigationRouter.AppTab) -> some View {
        switch tab {
        case .todos:
            TodoListView()
        case .departure:
            NavigationStack {
                DepartureChecklistView()
            }
        case .expenses:
            ExpenseTrackerView()
        case .vault:
            LifeVaultView()
        case .passwords:
            NavigationStack {
                PasswordVaultView()
            }
        case .documents:
            NavigationStack {
                IDDocumentVaultView()
            }
        case .settings:
            SettingsView(isSheet: false)
        }
    }

    // MARK: - 动态角标徽标

    private func badgeCount(for tab: NavigationRouter.AppTab) -> Int {
        switch tab {
        case .todos:
            return activeTodos.isEmpty ? 0 : activeTodos.count
        default:
            return 0
        }
    }
}
