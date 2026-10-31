import Foundation

/// 模块出现的 UI  surface。一个模块可以同时出现在多个 surface 上
/// （如「人生大事」既是底部 Tab 也是生活档案子卡片）。
public enum ModuleSurface: String, CaseIterable, Sendable, Hashable {
    /// 底部 Tab 栏（最多 5 个活跃，由 TabBarManager 管理）
    case tabBar
    /// 生活档案大厅的子卡片（LifeVaultView 内 NavigationStack）
    case vault
}
