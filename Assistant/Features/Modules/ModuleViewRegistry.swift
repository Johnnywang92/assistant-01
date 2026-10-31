import AssistantCore
import SwiftUI

/// 模块 View 注册表。`MainTabView` 与 `LifeVaultView` 不再各自维护分发 switch，
/// 统一走这里。新增模块 = `ModuleID` 加 case（编译器强制下面两个 switch 补 case）
/// + `ModuleRegistry` 加描述符 + 这里补 View 构造，三处齐了才不 assert。
///
/// Tab 栏视图**含** NavigationStack 包装（departure / passwords / documents / voiceMemos
/// 在 Tab 栏上是独立导航栈）；Vault 子页面**不含**（LifeVaultView 已提供外层 NavigationStack）。
@MainActor
enum ModuleViewRegistry {

    // MARK: - Tab 栏内容视图

    static func tabView(for moduleID: ModuleID) -> AnyView {
        #if DEBUG
        assert(contractIssues.isEmpty, "模块 View 注册表与 Core 描述符不一致：\(contractIssues)")
        #endif
        switch moduleID {
        case .todos:
            return AnyView(TodoListView())
        case .lifeEvents:
            return AnyView(LifeEventManagementView())
        case .departure:
            return AnyView(NavigationStack { DepartureChecklistView() })
        case .expenses:
            return AnyView(ExpenseTrackerView())
        case .vault:
            return AnyView(LifeVaultView())
        case .passwords:
            return AnyView(NavigationStack { PasswordVaultView() })
        case .documents:
            return AnyView(NavigationStack { IDDocumentVaultView() })
        case .voiceMemos:
            return AnyView(NavigationStack { VoiceMemoListView() })
        case .settings:
            return AnyView(SettingsView(isSheet: false))
        // vault-only 模块不出现在 Tab 栏上，走到这里属于路由错误
        case .anniversaries, .painPoints, .skillPaths, .storage, .learnedPlaces,
             .foodCalorie, .healthData, .habits, .pets, .children, .vehicles:
            return AnyView(EmptyView())
        }
    }

    // MARK: - 生活档案子页面视图

    static func vaultView(for moduleID: ModuleID) -> AnyView {
        #if DEBUG
        assert(contractIssues.isEmpty, "模块 View 注册表与 Core 描述符不一致：\(contractIssues)")
        #endif
        switch moduleID {
        case .lifeEvents:
            return AnyView(LifeEventManagementView())
        case .documents:
            return AnyView(IDDocumentVaultView())
        case .passwords:
            return AnyView(PasswordVaultView())
        case .voiceMemos:
            return AnyView(VoiceMemoListView())
        case .departure:
            return AnyView(DepartureChecklistView())
        case .anniversaries:
            return AnyView(AnniversaryManagementView())
        case .painPoints:
            return AnyView(PainPointManagementView())
        case .skillPaths:
            return AnyView(SkillPathListView())
        case .storage:
            return AnyView(ItemStorageVaultView())
        case .learnedPlaces:
            return AnyView(LearnedPlacesView())
        case .foodCalorie:
            return AnyView(FoodPhotoCalorieView())
        case .healthData:
            return AnyView(HealthDataView())
        case .habits:
            return AnyView(HabitAndMedicationView())
        case .pets:
            return AnyView(PetManagementView())
        case .children:
            return AnyView(ChildManagementView())
        case .vehicles:
            return AnyView(VehicleManagementView())
        // tab-only 模块不出现在生活档案里
        case .todos, .expenses, .vault, .settings:
            return AnyView(EmptyView())
        }
    }

    // MARK: - DEBUG 契约自检

    #if DEBUG
    /// 交叉校验：Core 描述符声明了某 surface，这里的 switch 就必须能构造出非空 View。
    /// 漏接会在首次导航时断言，而不是静默展示空白页。
    private static let contractIssues: [String] = {
        var issues: [String] = []
        for descriptor in ModuleRegistry.builtIn {
            if descriptor.tabBar != nil {
                let view = tabView(for: descriptor.id)
                if isBlank(view) {
                    issues.append("模块 \(descriptor.id.rawValue) 声明了 tabBar 但 View 注册表返回空")
                }
            }
            if descriptor.vaultCard != nil {
                let view = vaultView(for: descriptor.id)
                if isBlank(view) {
                    issues.append("模块 \(descriptor.id.rawValue) 声明了 vault 但 View 注册表返回空")
                }
            }
        }
        return issues
    }()

    private static func isBlank(_ view: AnyView) -> Bool {
        // AnyView 包 EmptyView 时 body 是 EmptyView；用镜像近似判断。
        // 这里只需区分「有意返回空」与「忘了接线」，不需要精确类型。
        String(describing: view).contains("EmptyView")
    }
    #endif
}
