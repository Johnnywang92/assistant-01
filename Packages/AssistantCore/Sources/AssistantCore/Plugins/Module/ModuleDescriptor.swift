import Foundation

/// 模块在底部 Tab 栏上的展示声明。
public struct ModuleTabBarDisplay: Sendable, Equatable {
    /// Tab 标题（`NavigationRouter.AppTab.title` 的真相源）
    public let title: String
    /// SF Symbol（`NavigationRouter.AppTab.systemImage` 的真相源）
    public let systemImage: String
    /// 副标题（设置页板块描述，`NavigationRouter.AppTab.subtitle` 的真相源）
    public let subtitle: String

    public init(title: String, systemImage: String, subtitle: String) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
    }
}

/// 模块在生活档案大厅卡片上的展示声明。
///
/// `iconColor` 刻意不在此处：它是 SwiftUI `Color`，属纯视觉主题，Core 不依赖 SwiftUI。
/// App 侧 `LifeVaultCardType.iconColor` 保留为本地 switch。
public struct ModuleVaultCardDisplay: Sendable, Equatable {
    /// 卡片标题（`LifeVaultView.cardInfo.title` 的真相源）
    public let title: String
    /// SF Symbol（`LifeVaultCardType.icon` 的真相源）。
    /// 与 Tab 栏图标可以不同（如 departure：Tab 用 `briefcase.fill`，卡片用 `bag.fill`）。
    public let icon: String
    /// 类别胶囊文字（`LifeVaultCardType.category` 的真相源）
    public let category: String

    public init(title: String, icon: String, category: String) {
        self.title = title
        self.icon = icon
        self.category = category
    }
}

/// 一个 UI 模块的静态元数据声明。与 `CapabilityDescriptor`（A 批）、`ModelDescriptor`（C1）同层：
/// Core 只声明事实，App 侧 Provider 承接 View 构造与运行时状态。
///
/// **tabBar vs vaultCard 的 title 刻意分开**（同 C4 `displayName` vs `intentLegendName`）：
/// Tab 栏叫「出门防丢」，生活档案卡片叫「出门清单」——两处用户语境不同，
/// 5 个双 surface 模块全部存在这种分家。契约测试钉住分家集合。
///
/// **surfaces 是派生的**：`tabBar != nil` 即 `.tabBar`，`vaultCard != nil` 即 `.vault`。
/// 不单独声明 surfaces 字段，避免「声明了 surface 却没给展示信息」的不一致。
public struct ModuleDescriptor: Sendable {
    /// 注册表键
    public let id: ModuleID
    /// Tab 栏展示（nil = 不出现在 Tab 栏上）
    public let tabBar: ModuleTabBarDisplay?
    /// 生活档案卡片展示（nil = 不出现在生活档案里）
    public let vaultCard: ModuleVaultCardDisplay?
    /// 关联的提示词块（B 批 `PromptBlockID`）。多对多：一个模块可贡献多个块
    /// （如 todos → [.parcel, .todo]），一个块也可被多个模块共享（如 .family → pets/children/vehicles）。
    /// 空数组表示该模块不向 LLM 提示词贡献数据段。
    public let promptBlockIDs: [PromptBlockID]

    public init(
        id: ModuleID,
        tabBar: ModuleTabBarDisplay?,
        vaultCard: ModuleVaultCardDisplay?,
        promptBlockIDs: [PromptBlockID] = []
    ) {
        self.id = id
        self.tabBar = tabBar
        self.vaultCard = vaultCard
        self.promptBlockIDs = promptBlockIDs
    }

    /// 该模块出现的 surface 集合（派生，非独立声明）
    public var surfaces: Set<ModuleSurface> {
        var s: Set<ModuleSurface> = []
        if tabBar != nil { s.insert(.tabBar) }
        if vaultCard != nil { s.insert(.vault) }
        return s
    }
}
