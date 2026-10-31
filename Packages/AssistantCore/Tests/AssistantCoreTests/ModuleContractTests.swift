import XCTest
@testable import AssistantCore

/// D 批契约测试：钉住 ModuleRegistry 的顺序、surface 归属、标题分家与交叉引用。
/// rawValue 持久化安全由 App 侧 DEBUG 断言保障（ModuleViewRegistry.contractIssues），
/// 这里只测 Core 声明层的完整性。
final class ModuleContractTests: XCTestCase {

    // MARK: - 顺序与完整性

    /// builtIn 顺序即「设置 → Tab 栏自定义」候选列表的展示顺序。
    /// 改动要显式更新此测试。
    func testBuiltInOrderIsPinned() {
        let expected: [ModuleID] = [
            .todos, .expenses, .vault, .settings,
            .lifeEvents, .departure, .passwords, .documents, .voiceMemos,
            .anniversaries, .painPoints, .skillPaths, .storage, .learnedPlaces,
            .foodCalorie, .healthData, .habits, .pets, .children, .vehicles,
        ]
        XCTAssertEqual(ModuleRegistry.builtIn.map(\.id), expected)
        XCTAssertEqual(ModuleRegistry.builtIn.count, ModuleID.allCases.count)
    }

    func testEveryModuleIDHasDescriptor() {
        for id in ModuleID.allCases {
            XCTAssertNotNil(ModuleRegistry.descriptor(id: id), "\(id.rawValue) 缺少描述符")
        }
    }

    func testValidateReturnsEmpty() {
        XCTAssertEqual(ModuleRegistry.validate(), [])
    }

    // MARK: - rawValue 钉住

    /// ModuleID.rawValue 虽不直接持久化，但 AppTab / LifeVaultCardType 的转发 switch
    /// 依赖它做注册表键。改 rawValue 等于改注册表寻址。
    func testModuleIDRawValuesArePinned() {
        let expected: [String: String] = [
            "todos": "todos", "expenses": "expenses", "vault": "vault", "settings": "settings",
            "lifeEvents": "lifeEvents", "departure": "departure", "passwords": "passwords",
            "documents": "documents", "voiceMemos": "voiceMemos",
            "anniversaries": "anniversaries", "painPoints": "painPoints",
            "skillPaths": "skillPaths", "storage": "storage", "learnedPlaces": "learnedPlaces",
            "foodCalorie": "foodCalorie", "healthData": "healthData", "habits": "habits",
            "pets": "pets", "children": "children", "vehicles": "vehicles",
        ]
        for id in ModuleID.allCases {
            XCTAssertEqual(id.rawValue, expected[id.rawValue], "\(id.rawValue) 的 rawValue 漂移")
        }
        XCTAssertEqual(Set(ModuleID.allCases.map(\.rawValue)), Set(expected.values))
    }

    // MARK: - Surface 归属

    func testSurfaceAssignmentIsPinned() {
        let tabOnly: Set<ModuleID> = [.todos, .expenses, .vault, .settings]
        let dualSurface: Set<ModuleID> = [.lifeEvents, .departure, .passwords, .documents, .voiceMemos]
        let vaultOnly: Set<ModuleID> = [
            .anniversaries, .painPoints, .skillPaths, .storage, .learnedPlaces,
            .foodCalorie, .healthData, .habits, .pets, .children, .vehicles,
        ]

        for descriptor in ModuleRegistry.builtIn {
            let surfaces = descriptor.surfaces
            if tabOnly.contains(descriptor.id) {
                XCTAssertEqual(surfaces, [.tabBar], "\(descriptor.id.rawValue) 应仅在 tabBar")
            } else if dualSurface.contains(descriptor.id) {
                XCTAssertEqual(surfaces, [.tabBar, .vault], "\(descriptor.id.rawValue) 应同时在 tabBar 和 vault")
            } else if vaultOnly.contains(descriptor.id) {
                XCTAssertEqual(surfaces, [.vault], "\(descriptor.id.rawValue) 应仅在 vault")
            } else {
                XCTFail("\(descriptor.id.rawValue) 不在任何预期分组里")
            }
        }
    }

    func testDefaultTabIDsMatchTabBarSurface() {
        for id in ModuleRegistry.defaultTabIDs {
            let descriptor = ModuleRegistry.descriptor(id: id)
            XCTAssertNotNil(descriptor?.tabBar, "\(id.rawValue) 在 defaultTabIDs 里却没有 tabBar 声明")
        }
        XCTAssertEqual(ModuleRegistry.defaultTabIDs.count, 5)
    }

    // MARK: - 标题分家（同 C4 displayName vs intentLegendName）

    /// 5 个双 surface 模块的 Tab 标题与 Vault 卡片标题全部不同。
    /// 多一处少一处都要被这条测试抓到。
    func testTitleSplitIsPinnedForDualSurfaceModules() {
        let splitIDs: Set<ModuleID> = [.lifeEvents, .departure, .passwords, .documents, .voiceMemos]
        var actualSplit = Set<ModuleID>()

        for descriptor in ModuleRegistry.builtIn {
            guard let tab = descriptor.tabBar, let vault = descriptor.vaultCard else { continue }
            if tab.title != vault.title {
                actualSplit.insert(descriptor.id)
            }
        }

        XCTAssertEqual(actualSplit, splitIDs)
    }

    /// 逐字钉住 5 处分家的具体标题，防止「改了但测试只查集合不查值」。
    func testDualSurfaceTitlesArePinnedByteForByte() {
        let golden: [(ModuleID, tab: String, vault: String)] = [
            (.lifeEvents, tab: "人生大事", vault: "人生大事筹备中心"),
            (.departure, tab: "出门防丢", vault: "出门清单"),
            (.passwords, tab: "密码箱", vault: "密码库"),
            (.documents, tab: "证件卡包", vault: "重要证件"),
            (.voiceMemos, tab: "语音备忘", vault: "语音备忘录"),
        ]
        for (id, tab, vault) in golden {
            let descriptor = ModuleRegistry.descriptor(id: id)
            XCTAssertEqual(descriptor?.tabBar?.title, tab, "\(id.rawValue) Tab 标题漂移")
            XCTAssertEqual(descriptor?.vaultCard?.title, vault, "\(id.rawValue) Vault 标题漂移")
        }
    }

    // MARK: - 提示词块交叉引用

    func testPromptBlockIDsResolve() {
        for descriptor in ModuleRegistry.builtIn {
            for blockID in descriptor.promptBlockIDs {
                XCTAssertTrue(
                    PromptBlockID.allCases.contains(blockID),
                    "\(descriptor.id.rawValue) 引用了不存在的 PromptBlockID \(blockID.rawValue)"
                )
            }
        }
    }

    /// lifeProfileOrder 里的每个块至少被一个模块声明（否则该块没有数据来源）。
    func testEveryLifeProfileBlockHasOwner() {
        let declared = Set(ModuleRegistry.builtIn.flatMap(\.promptBlockIDs))
        for blockID in PromptBlockID.lifeProfileOrder {
            XCTAssertTrue(
                declared.contains(blockID),
                "PromptBlockID \(blockID.rawValue) 在 lifeProfileOrder 里但没有模块声明它"
            )
        }
    }

    // MARK: - 负例

    func testValidateRejectsMissingDescriptor() {
        // 构造一个少了一个描述符的注册表：validate 应报「缺少描述符」
        let subset = Array(ModuleRegistry.builtIn.dropFirst())
        let issues = ModuleRegistry.validateSubset(subset)
        XCTAssertTrue(issues.contains { $0.contains("缺少描述符") }, "漏注册必须被抓到：\(issues)")
    }

    func testValidateRejectsDuplicate() {
        let duplicated = ModuleRegistry.builtIn + [ModuleRegistry.builtIn[0]]
        let issues = ModuleRegistry.validateSubset(duplicated)
        XCTAssertTrue(issues.contains { $0.contains("重复注册") }, "重复必须被抓到：\(issues)")
    }

    func testValidateRejectsEmptySurfaces() {
        let empty = ModuleDescriptor(id: .todos, tabBar: nil, vaultCard: nil)
        let issues = ModuleRegistry.validateSubset([empty])
        XCTAssertTrue(issues.contains { $0.contains("没有声明任何 surface") }, "空 surface 必须被抓到：\(issues)")
    }
}
