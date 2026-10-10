import SwiftData
import SwiftUI

/// 主应用底部 Tab 栏导航 (方案 1: 待办、记账、生活档案、设置)
struct MainTabView: View {
    @ObservedObject private var router = NavigationRouter.shared
    @Query(filter: #Predicate<TodoItem> { $0.statusRaw == "active" }) private var activeTodos: [TodoItem]
    @State private var showVoice = false

    var body: some View {
        ZStack {
            // 全局个性化背景底色层
            AppBackgroundView()

            TabView(selection: $router.selectedTab) {
                TodoListView()
                    .tabItem {
                        Label("待办", systemImage: "checklist")
                    }
                    .tag(NavigationRouter.AppTab.todos)
                    .badge(activeTodos.isEmpty ? 0 : activeTodos.count)

                ExpenseTrackerView()
                    .tabItem {
                        Label("记账", systemImage: "yensign.circle.fill")
                    }
                    .tag(NavigationRouter.AppTab.expenses)

                LifeVaultView()
                    .tabItem {
                        Label("生活档案", systemImage: "folder.badge.person.crop")
                    }
                    .tag(NavigationRouter.AppTab.vault)

                SettingsView(isSheet: false)
                    .tabItem {
                        Label("设置", systemImage: "gearshape.fill")
                    }
                    .tag(NavigationRouter.AppTab.settings)
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
    }
}
