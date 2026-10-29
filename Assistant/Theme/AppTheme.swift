import SwiftUI
import UIKit

// MARK: - 语义色令牌
//
// 统一视觉层级的单一事实来源：各页面不要再散落硬编码的 Color.red / Color.orange 等
// 固定色与 opacity 组合，改引用本文件的语义色。所有语义色均基于 iOS 系统动态色
// （UIColor.systemXXX / .label 等），自动随浅色/深色外观切换，保证对比度。

enum AppColor {
    /// 主操作色：跟随 App 全局 accent
    static var primary: Color { Color.accentColor }
    /// 危险/逾期/删除等强警示态
    static var danger: Color { Color(.systemRed) }
    /// 警告/临期/需关注态（如长辈模式横幅、明日到期提醒）
    static var warning: Color { Color(.systemOrange) }
    /// 成功/完成/预算内等正向态
    static var success: Color { Color(.systemGreen) }
    /// 中性信息态（链接、说明性徽标）
    static var info: Color { Color(.systemBlue) }
    /// 智能/模型/AI 特性标识色（保留紫色系品牌识别，但统一出口）
    static var feature: Color { Color(.systemPurple) }

    /// 卡片/胶囊表面底色（随外观自动切换）
    static var surface: Color { Color(.secondarySystemGroupedBackground) }
    /// 胶囊/弱填充底
    static var fillTertiary: Color { Color(.tertiarySystemFill) }
    /// 正文文本
    static var text: Color { Color(.label) }
    /// 次要说明文本
    static var secondaryText: Color { Color(.secondaryLabel) }
    /// 分隔线/卡片描边
    static var separator: Color { Color(.separator) }

    /// 语义色的柔和底（徽标胶囊、浅警示卡片），统一 0.12 透明度
    static func softFill(_ color: Color, opacity: Double = 0.12) -> Color {
        color.opacity(opacity)
    }
}

// MARK: - 间距与圆角令牌

enum AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
}

/// 圆角标尺，按用途从细到粗排列。视图里不要再写字面量，
/// 需要新档位时先改这里，避免同一角色在不同页面差 1–2pt。
enum AppRadius {
    /// 细线、进度条、分割条
    static let hairline: CGFloat = 2
    /// 内嵌小块、标签底
    static let badge: CGFloat = 4
    /// 小徽标/内嵌小圆角
    static let small: CGFloat = 6
    /// 胶囊形小按钮
    static let chip: CGFloat = 8
    /// 图标容器、筛选小按钮
    static let medium: CGFloat = 10
    /// 统计卡等标准卡片
    static let card: CGFloat = 12
    /// 横幅类大卡片
    static let banner: CGFloat = 14
    /// 大图标容器、中等面板
    static let large: CGFloat = 16
    /// 弹层、扫描框等大面板
    static let panel: CGFloat = 20
    /// 分享卡片、主视觉卡
    static let hero: CGFloat = 24
}

// MARK: - 卡片与警告态样式

/// 标准卡片底：语义 surface + 连续圆角
struct AppCardModifier: ViewModifier {
    var cornerRadius: CGFloat = AppRadius.card

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppColor.surface)
        )
    }
}

/// 警告态卡片：命中时叠加语义 danger/warning 描边，替换散落的红色 opacity 描边
struct AppWarningStateModifier: ViewModifier {
    var isActive: Bool
    var severity: Severity = .danger
    var cornerRadius: CGFloat = AppRadius.card

    enum Severity { case danger, warning }

    private var tint: Color {
        switch severity {
        case .danger: return AppColor.danger
        case .warning: return AppColor.warning
        }
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isActive ? tint.opacity(0.35) : Color.clear, lineWidth: 1)
            )
    }
}

/// 柔和胶囊徽标底色（替代 Color.xxx.opacity(0.18) 之类的散落写法）
struct AppSoftCapsuleModifier: ViewModifier {
    var tint: Color

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .background(Capsule().fill(AppColor.softFill(tint)))
            .foregroundStyle(tint)
    }
}

extension View {
    /// 标准语义卡片底
    func appCard(cornerRadius: CGFloat = AppRadius.card) -> some View {
        modifier(AppCardModifier(cornerRadius: cornerRadius))
    }

    /// 警告态卡片：自动带 surface 底 + 命中描边
    func appWarningState(active: Bool, severity: AppWarningStateModifier.Severity = .danger, cornerRadius: CGFloat = AppRadius.card) -> some View {
        modifier(AppWarningStateModifier(isActive: active, severity: severity, cornerRadius: cornerRadius))
    }

    /// 语义色柔和胶囊徽标
    func appSoftCapsule(tint: Color) -> some View {
        modifier(AppSoftCapsuleModifier(tint: tint))
    }
}

// MARK: - 减少动态效果（全局统一出口）
//
// 用法约定：
// 1. 根视图挂载一次 .appMotionObserver()，把系统「减少动态效果」开关同步到 AppMotion.reduceMotion；
// 2. 原先的 withAnimation(...) { } 一律替换为 AppMotion.animate(...) { }；
// 3. 原先的 .animation(_:value:) 一律替换为 .responsiveAnimation(_:value:)（走 environment，更精准）。

enum AppMotion {
    /// 系统「减少动态效果」开关快照，由 AppMotionObserver 在根视图同步（仅主线程读写）
    static var reduceMotion: Bool = false

    /// 页面主弹簧动画的统一参数
    static let standardSpring: Animation = .spring(response: 0.35, dampingFraction: 0.8)

    /// 命中减少动态效果时返回 nil（即不带动画）
    static func resolved(_ animation: Animation?) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// withAnimation 的统一替身：减少动态效果命中时直接落定终态
    static func animate(_ animation: Animation? = AppMotion.standardSpring, _ body: () -> Void) {
        if reduceMotion {
            body()
        } else {
            withAnimation(resolved(animation), body)
        }
    }
}

/// 读取 environment 的动画修饰器：减少动态效果命中时禁用动画
private struct ResponsiveAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var animation: Animation?
    var value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// .animation(_:value:) 的无障碍替身
    func responsiveAnimation(_ animation: Animation?, value: some Equatable) -> some View {
        modifier(ResponsiveAnimationModifier(animation: animation, value: value))
    }
}

/// 隐形观察器：把 accessibilityReduceMotion 环境值同步给 AppMotion（withAnimation 场景无法直接读 environment）
private struct AppMotionObserver: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { AppMotion.reduceMotion = reduceMotion }
            .onChange(of: reduceMotion) { _, newValue in
                AppMotion.reduceMotion = newValue
            }
    }
}

extension View {
    /// 在根视图挂载一次，保证 AppMotion.animate 感知系统开关（含运行期切换）
    func appMotionObserver() -> some View {
        background(AppMotionObserver())
    }
}

// MARK: - 自定义壁纸上的可读性保障
//
// 壁纸亮度不可控（用户自选照片），按亮度切换前景色误判风险高；
// 更稳的做法是统一加深色投影遮罩（scrim），保证任意背景下文字可辨。

private struct WallpaperReadableTextModifier: ViewModifier {
    @ObservedObject private var manager = AppBackgroundManager.shared

    func body(content: Content) -> some View {
        if manager.isCustomBackgroundActive {
            content.shadow(color: .black.opacity(0.55), radius: 2, y: 1)
        } else {
            content
        }
    }
}

extension View {
    /// 悬浮在自定义壁纸/渐变背景上的文本、图标：命中自定义背景时自动加对比度遮罩
    func wallpaperReadableText() -> some View {
        modifier(WallpaperReadableTextModifier())
    }
}
