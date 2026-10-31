import Foundation

/// UI 模块的唯一标识。20 个 case 覆盖底部 Tab（9）与生活档案子卡片（16）的并集，
/// 其中 5 个模块同时出现在两个 surface 上（lifeEvents / departure / passwords / documents / voiceMemos）。
///
/// **rawValue 不直接持久化**——持久化的是 `AppTab.rawValue`（`custom_home_tabs_order_v1`）
/// 与 `LifeVaultCardType.rawValue`（生活档案 `customOrder`）。本 enum 是注册表键，
/// 两个持久化 enum 各自通过穷尽 switch 转发到这里（同 C1 `LLMModelPreset` → `ModelRegistry` 形态）。
///
/// 命名规则：优先沿用 `LifeVaultCardType.rawValue`（更具体），仅 Tab 独有的模块用 `AppTab.rawValue`。
/// 唯一不对称处：AppTab 用 `"memos"`，本 enum 用 `"voiceMemos"`（与 vault 对齐）。
public enum ModuleID: String, CaseIterable, Sendable, Hashable {
    // —— Tab 独有（含容器）——
    case todos
    case expenses
    case vault
    case settings

    // —— Tab + Vault 双 surface ——
    case lifeEvents
    case departure
    case passwords
    case documents
    case voiceMemos

    // —— Vault 独有 ——
    case anniversaries
    case painPoints
    case skillPaths
    case storage
    case learnedPlaces
    case foodCalorie
    case healthData
    case habits
    case pets
    case children
    case vehicles
}
