import SwiftData
import SwiftUI

/// 主应用底部 Tab 栏导航 (方案 1: 待办、记账、生活档案、设置)
struct MainTabView: View {
    @ObservedObject private var router = NavigationRouter.shared
    @Query(filter: #Predicate<TodoItem> { $0.statusRaw == "active" }) private var activeTodos: [TodoItem]

    var body: some View {
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
    }
}
