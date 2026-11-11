import SwiftUI

// MARK: - 小组件视觉令牌
//
// 小组件扩展与主 App 是两个进程、两套模块，**不能共享 App 的 `AppTheme`**：
// `Assistant/Theme/AppTheme.swift` 属于主 App target，扩展 target 编译时看不到它。
//
// 所以小组件侧的令牌独立成文件放在 `WidgetShared/`（主 App 与扩展都编译这个目录）。
// 数值与 App 首页保持一致（§3.1 色板 / §3.2 字号 / §3.3 圆角），
// 但**不引入依赖**——小组件只用系统动态色，保证深浅色自动适配。
//
// 变更纪律：改这里的数值时同步改 `AppTheme.swift` 的对应项，
// 否则桌面与 App 会出现视觉分叉。

enum WidgetTheme {
    // MARK: 色板（§3.1）

    /// 主蓝
    static let primary = Color(red: 0.102, green: 0.451, blue: 0.910)
    /// 完成环轨道
    static let ringTrack = Color(red: 0.910, green: 0.933, blue: 0.984)
    /// 主任务行底
    static let priorityRow = Color(red: 0.918, green: 0.945, blue: 1.0)
    /// 主文字
    static let text = Color(red: 0.125, green: 0.129, blue: 0.141)
    /// 次级文字
    static let secondaryText = Color(red: 0.373, green: 0.388, blue: 0.408)
    /// 三级文字
    static let tertiaryText = Color(red: 0.604, green: 0.627, blue: 0.651)
    /// 成功绿
    static let success = Color(red: 0.204, green: 0.659, blue: 0.325)
    /// 警告黄（色块）
    static let warning = Color(red: 0.984, green: 0.737, blue: 0.016)
    /// 警告文字（深色，在浅黄底上对比 ≥ 4.5:1）
    static let warningText = Color(red: 0.698, green: 0.416, blue: 0.0)
    /// 时间带：空闲段
    static let timelineFree = Color(red: 0.910, green: 0.933, blue: 0.984)
    /// 时间带：已安排段
    static let timelineBusy = Color(red: 0.102, green: 0.451, blue: 0.910)
    /// 时间带：提醒点
    static let timelineReminder = Color(red: 0.984, green: 0.737, blue: 0.016)

    // MARK: 圆角（§3.3）

    static let cardRadius: CGFloat = 16
    static let blockRadius: CGFloat = 8
    static let chipRadius: CGFloat = 12
}

/// 小组件用的完成环。宽度按比例算，不写死像素。
struct WidgetProgressRing: View {
    let fraction: Double
    let lineWidth: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(WidgetTheme.ringTrack, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// 小组件用的今日节奏条。色块宽度按 `weight × GeometryReader` 算。
struct WidgetRhythmBar: View {
    /// 空闲段占比
    let freeRatio: Double
    /// 已安排段占比
    let busyRatio: Double

    var body: some View {
        GeometryReader { geo in
            let free = max(0, min(1, freeRatio))
            let busy = max(0, min(1, busyRatio))
            HStack(spacing: 1) {
                Rectangle()
                    .fill(WidgetTheme.timelineFree)
                    .frame(width: geo.size.width * free)
                Rectangle()
                    .fill(WidgetTheme.timelineBusy)
                    .frame(width: geo.size.width * busy)
                if free + busy < 1 {
                    Rectangle()
                        .fill(WidgetTheme.timelineFree)
                }
            }
        }
    }
}
