import Foundation

/// UI 模块注册表。20 个描述符覆盖底部 Tab（9）与生活档案子卡片（16）的并集。
///
/// **builtIn 顺序即「设置 → Tab 栏自定义」列表里候选板块的展示顺序**（同 C1 `ModelRegistry.builtIn`
/// 顺序即「设置 → AI 模型」列表顺序）。改动要过 `testBuiltInOrderIsPinned`。
///
/// 新增模块 = 这里一个描述符 + App 侧一个 `ModuleViewProvider` + `ModuleID` 一个 case，
/// 三处齐了才不 assert。
public enum ModuleRegistry {

    // MARK: - 注册表

    public static let builtIn: [ModuleDescriptor] = [
        // —— Tab 独有（含容器）——
        ModuleDescriptor(
            id: .todos,
            tabBar: .init(title: "首页", systemImage: "house.fill", subtitle: "待办、快递取件与每日安排总览"),
            vaultCard: nil,
            promptBlockIDs: [.parcel, .todo]
        ),
        ModuleDescriptor(
            id: .expenses,
            tabBar: .init(title: "记账", systemImage: "yensign.circle.fill", subtitle: "日常收支账本与统计分析"),
            vaultCard: nil,
            promptBlockIDs: [.finance]
        ),
        ModuleDescriptor(
            id: .vault,
            tabBar: .init(title: "生活档案", systemImage: "folder.badge.person.crop", subtitle: "纪念日、运动、药物保健品等生活全档案"),
            vaultCard: nil
        ),
        ModuleDescriptor(
            id: .settings,
            tabBar: .init(title: "设置", systemImage: "gearshape.fill", subtitle: "主题壁纸、单手悬浮球与偏好设置"),
            vaultCard: nil
        ),

        // —— Tab + Vault 双 surface ——
        ModuleDescriptor(
            id: .lifeEvents,
            tabBar: .init(title: "人生大事", systemImage: "sparkles", subtitle: "订婚、婚礼、乔迁、升学宴等长期项目"),
            vaultCard: .init(title: "人生大事筹备中心", icon: "sparkles", category: "人生大事")
        ),
        ModuleDescriptor(
            id: .departure,
            tabBar: .init(title: "出门防丢", systemImage: "briefcase.fill", subtitle: "随身物品清点、防丢检查与口诀"),
            vaultCard: .init(title: "出门清单", icon: "bag.fill", category: "出行")
        ),
        ModuleDescriptor(
            id: .passwords,
            tabBar: .init(title: "密码箱", systemImage: "key.fill", subtitle: "高强度账号密码离线保险箱"),
            vaultCard: .init(title: "密码库", icon: "key.fill", category: "私密资料")
        ),
        ModuleDescriptor(
            id: .documents,
            tabBar: .init(title: "证件卡包", systemImage: "person.text.rectangle.fill", subtitle: "身份证、护照、驾驶证重要卡包"),
            vaultCard: .init(title: "重要证件", icon: "person.text.rectangle.fill", category: "私密资料"),
            promptBlockIDs: [.vault]
        ),
        ModuleDescriptor(
            id: .voiceMemos,
            tabBar: .init(title: "语音备忘", systemImage: "mic.circle.fill", subtitle: "离线随身录音、倍速回放与转写提取待办"),
            vaultCard: .init(title: "语音备忘录", icon: "mic.circle.fill", category: "私密资料"),
            promptBlockIDs: [.memo]
        ),

        // —— Vault 独有 ——
        ModuleDescriptor(
            id: .anniversaries,
            tabBar: nil,
            vaultCard: .init(title: "纪念日", icon: "gift.fill", category: "生活提醒"),
            promptBlockIDs: [.anniversary]
        ),
        ModuleDescriptor(
            id: .painPoints,
            tabBar: nil,
            vaultCard: .init(title: "续费与物品临期", icon: "shield.lefthalf.filled", category: "生活提醒"),
            promptBlockIDs: [.vault]
        ),
        ModuleDescriptor(
            id: .skillPaths,
            tabBar: nil,
            vaultCard: .init(title: "技能学习路径", icon: "book.fill", category: "学习成长")
        ),
        ModuleDescriptor(
            id: .storage,
            tabBar: nil,
            vaultCard: .init(title: "物品收纳", icon: "archivebox.fill", category: "物品与地点"),
            promptBlockIDs: [.storage]
        ),
        ModuleDescriptor(
            id: .learnedPlaces,
            tabBar: nil,
            vaultCard: .init(title: "常用地点", icon: "brain.head.profile", category: "物品与地点"),
            promptBlockIDs: [.place]
        ),
        ModuleDescriptor(
            id: .foodCalorie,
            tabBar: nil,
            vaultCard: .init(title: "饮食热量估算", icon: "fork.knife.circle.fill", category: "健康与习惯")
        ),
        ModuleDescriptor(
            id: .healthData,
            tabBar: nil,
            vaultCard: .init(title: "健康数据", icon: "heart.text.square.fill", category: "健康与习惯")
        ),
        ModuleDescriptor(
            id: .habits,
            tabBar: nil,
            vaultCard: .init(title: "运动与药物保健品", icon: "figure.run", category: "健康与习惯"),
            promptBlockIDs: [.habit]
        ),
        ModuleDescriptor(
            id: .pets,
            tabBar: nil,
            vaultCard: .init(title: "宠物管家", icon: "pawprint.fill", category: "家庭与陪伴"),
            promptBlockIDs: [.family]
        ),
        ModuleDescriptor(
            id: .children,
            tabBar: nil,
            vaultCard: .init(title: "亲子育儿", icon: "figure.and.child.holdinghands", category: "家庭与陪伴"),
            promptBlockIDs: [.family]
        ),
        ModuleDescriptor(
            id: .vehicles,
            tabBar: nil,
            vaultCard: .init(title: "爱车管理", icon: "car.fill", category: "出行"),
            promptBlockIDs: [.family]
        ),
    ]

    /// 默认启用的 5 个 Tab 板块（`NavigationRouter.defaultTabs` 的真相源）。
    /// 改这里等于改新用户首次打开 App 看到的 Tab 栏。
    public static let defaultTabIDs: [ModuleID] = [.todos, .lifeEvents, .expenses, .vault, .settings]

    // MARK: - 查询

    public static func descriptor(id: ModuleID) -> ModuleDescriptor? {
        builtIn.first { $0.id == id }
    }

    /// 按 surface 过滤，返回顺序即 builtIn 顺序。
    public static func modules(on surface: ModuleSurface) -> [ModuleDescriptor] {
        builtIn.filter { $0.surfaces.contains(surface) }
    }

    // MARK: - 契约自检

    /// DEBUG 自检 + 契约测试共用。返回空数组 = 契约完好。
    public static func validate() -> [String] {
        var issues: [String] = []
        var seenIDs = Set<ModuleID>()

        for descriptor in builtIn {
            if !seenIDs.insert(descriptor.id).inserted {
                issues.append("模块重复注册：\(descriptor.id.rawValue)")
            }
            if descriptor.surfaces.isEmpty {
                issues.append("模块 \(descriptor.id.rawValue) 没有声明任何 surface")
            }
            for blockID in descriptor.promptBlockIDs {
                if !PromptBlockID.allCases.contains(blockID) {
                    issues.append("模块 \(descriptor.id.rawValue) 引用了不存在的提示词块 \(blockID.rawValue)")
                }
            }
        }

        for id in ModuleID.allCases where !seenIDs.contains(id) {
            issues.append("ModuleID \(id.rawValue) 缺少描述符")
        }

        for tabID in defaultTabIDs {
            guard let descriptor = descriptor(id: tabID) else {
                issues.append("defaultTabIDs 引用了未注册的模块 \(tabID.rawValue)")
                continue
            }
            if descriptor.tabBar == nil {
                issues.append("defaultTabIDs 里的 \(tabID.rawValue) 没有 tabBar 展示声明")
            }
        }

        return issues
    }

    /// 对任意描述符集合跑结构性检查（负例测试用）。
    /// 与 `validate()` 共享逻辑，但输入是参数而非 `builtIn`。
    public static func validateSubset(_ descriptors: [ModuleDescriptor]) -> [String] {
        var issues: [String] = []
        var seenIDs = Set<ModuleID>()

        for descriptor in descriptors {
            if !seenIDs.insert(descriptor.id).inserted {
                issues.append("模块重复注册：\(descriptor.id.rawValue)")
            }
            if descriptor.surfaces.isEmpty {
                issues.append("模块 \(descriptor.id.rawValue) 没有声明任何 surface")
            }
            for blockID in descriptor.promptBlockIDs {
                if !PromptBlockID.allCases.contains(blockID) {
                    issues.append("模块 \(descriptor.id.rawValue) 引用了不存在的提示词块 \(blockID.rawValue)")
                }
            }
        }

        for id in ModuleID.allCases where !seenIDs.contains(id) {
            issues.append("ModuleID \(id.rawValue) 缺少描述符")
        }

        return issues
    }
}
