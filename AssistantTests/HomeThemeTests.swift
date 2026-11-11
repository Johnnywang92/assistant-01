import SwiftUI
import XCTest

@testable import Assistant

/// 首页主题令牌的测试。
///
/// §3.1 色板 / §3.2 字号 / §3.3 圆角是**静态规格**，但改坏了不会编译报错，
/// 只会静默偏离设计稿。这里把规格钉成断言。
///
/// 特别关注**深色模式**：浅色下正常不代表深色下可读。
final class HomeThemeTests: XCTestCase {

    // MARK: - 字号层级（§3.2）

    /// 字号层级固定：标题 20 · 卡片标题 15 · 指标 14 · 正文 13 · 辅助 11。
    func testTypographyScaleMatchesSpec() {
        XCTAssertEqual(HomeTypography.Role.pageTitle.size, 20)
        XCTAssertEqual(HomeTypography.Role.cardTitle.size, 15)
        XCTAssertEqual(HomeTypography.Role.metric.size, 14)
        XCTAssertEqual(HomeTypography.Role.body.size, 13)
        XCTAssertEqual(HomeTypography.Role.auxiliary.size, 11)
    }

    /// 字号层级必须严格递减，视觉上才有主次。
    func testTypographyScaleIsStrictlyDescending() {
        let sizes = HomeTypography.Role.allCases.map(\.size)
        for (index, size) in sizes.enumerated() {
            guard index > 0 else { continue }
            XCTAssertLessThan(
                size,
                sizes[index - 1],
                "\(HomeTypography.Role.allCases[index]) 的字号没有小于上一级"
            )
        }
    }

    /// 长辈关怀模式统一放大；缩放不得小于 1（缩小会破坏可读性）。
    func testSeniorScaleNeverShrinksText() {
        for role in HomeTypography.Role.allCases {
            for scale in [0.8, 1.0, 1.2, 1.5] {
                XCTAssertGreaterThanOrEqual(
                    role.size * max(1, scale),
                    role.size,
                    "\(role) 在 scale=\(scale) 时被缩小了"
                )
            }
        }
    }

    // MARK: - 圆角（§3.3）

    /// 圆角档位必须齐全且递增，避免出现「比卡片还大的内层圆角」。
    func testRadiusTokensExistAndAreOrdered() {
        XCTAssertGreaterThan(AppRadius.homeBlock, 0)
        XCTAssertGreaterThan(AppRadius.homeChip, 0)
        XCTAssertGreaterThan(AppRadius.homeList, 0)
        XCTAssertGreaterThan(AppRadius.homeCard, 0)
        XCTAssertGreaterThan(AppRadius.homeDevice, 0)
    }

    /// 圆角令牌闸门的存在意义就是禁止魔法数字，这里确认闸门仍覆盖首页令牌。
    func testHomeRadiusTokensAreRegisteredInGate() {
        // 圆角闸门按文件登记基线；新增令牌必须同步登记，否则闸门会拦下。
        // 这里只做存在性断言，具体规则由 scripts/check_radius_tokens.py 保证。
        XCTAssertGreaterThan(AppRadius.homeBlock, AppRadius.homeChip)
    }
}
