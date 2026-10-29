import SwiftUI

/// Apple Watch 腕上协同指南：展示智能叠放、表盘小组件、Siri 快捷指令与硬件按键联动
struct WatchIntegrationGuideView: View {
    var body: some View {
        List {
            // 顶部核心概览
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "applewatch")
                            .font(.system(size: 32))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apple Watch 腕上协同")
                                .font(.headline)
                            Text("无需单独安装 Watch App，即可享受完整的抬腕即看与语音查记体验。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // 1. 智能叠放（Smart Stack 实时活动）
            Section {
                guideRow(
                    icon: "shippingbox.fill",
                    iconColor: .orange,
                    title: "快递取件码抬腕即看",
                    subtitle: "靠近驿站或在手机上点击「快递上岛」，取件码与剩余包裹件数自动推送到手表智能叠放顶部，大字排版一目了然。"
                )

                guideRow(
                    icon: "ticket.fill",
                    iconColor: .blue,
                    title: "行程护航与检票口提醒",
                    subtitle: "乘车前发车倒计时、车次、座位号与检票口自动常驻手表卡片，支持常亮屏幕低功耗降亮排版。"
                )

                guideRow(
                    icon: "checklist",
                    iconColor: .mint,
                    title: "出门防丢随身清点",
                    subtitle: "离家或到达目的地前，在手表智能叠放中查看待带随身物品（身份证、钥匙、工牌等）。"
                )

                guideRow(
                    icon: "bell.badge.fill",
                    iconColor: .green,
                    title: "抬腕通知直接操作（可交互通知）",
                    subtitle: "取件通知直点「已取这一件 / 全部取齐」，待办到期直点「已完成 / 推迟」，直接在手腕上销号，无需掏出手机。"
                )
            } header: {
                Text("watchOS 11+ 智能叠放与通知")
            } footer: {
                Text("提示：iOS 仅在 iPhone 锁屏熄屏且 Apple Watch 佩戴解锁时将提醒推送至手表；请在 iPhone「Watch」App →「通知」→「从 iPhone 镜像提醒」中确认本应用已开启。")
            }

            // 2. 表盘复杂功能（Complications）
            Section {
                guideRow(
                    icon: "gauge.with.dots.needle.bottom.50percent",
                    iconColor: .teal,
                    title: "今日支出与安心花表盘",
                    subtitle: "在 Apple Watch 表盘添加「小助速览」组件，长按切换为「今日支出」模式，圆形表盘紧凑展示已花金额，矩形表盘显示大字支出与预算状态。"
                )

                guideRow(
                    icon: "shippingbox.circle.fill",
                    iconColor: .orange,
                    title: "待取快递表盘组件",
                    subtitle: "圆形组件显示待取包裹件数，矩形组件大字展示首件取件码，行内组件单行紧凑轮播。"
                )

                guideRow(
                    icon: "flame.fill",
                    iconColor: .purple,
                    title: "学习练习打卡表盘",
                    subtitle: "表盘实时显示连续练习天数与今日打卡状态，抬腕提醒自己保持专注习惯。"
                )
            } header: {
                Text("表盘复杂功能 (Complications)")
            } footer: {
                Text("在 Apple Watch 长按表盘 → 点击「编辑」→ 滑动到「复杂功能」槽位，选择「小助速览」添加。")
            }

            // 3. 抬腕语音交互（Siri 免开 App 即查即记）
            Section {
                siriPhraseRow(phrase: "“Hey Siri, 用小助记一笔”", desc: "抬腕说出花费，如「午餐 25 元」，手表内联语音记账无需掏出手机。")
                siriPhraseRow(phrase: "“Hey Siri, 小助还剩多少钱”", desc: "播报今日已支出金额与今日安心花可用额度，随时掌握财务节奏。")
                siriPhraseRow(phrase: "“Hey Siri, 查小助待取快递”", desc: "播报待取包裹取件码并一键将取件卡片推送到手腕。")
                siriPhraseRow(phrase: "“Hey Siri, 小助今天还有什么事”", desc: "播报今日优先级最高的高优待办事项。")
                siriPhraseRow(phrase: "“Hey Siri, 用小助记个待办”", desc: "快速语音创建日程琐事与待办。")
            } header: {
                Text("Siri 抬腕语音指令（免开 App 内联执行）")
            }

            // 4. 硬件按键与自动化
            Section {
                guideRow(
                    icon: "button.programmable",
                    iconColor: .indigo,
                    title: "Apple Watch Ultra 操作按钮",
                    subtitle: "设置 → 操作按钮 →「快捷指令」→ 选择「用小助记一笔」或「待取快递上岛」，登山或跑步时按一下侧边橙色按键即可开始语音操作。"
                )

                guideRow(
                    icon: "battery.25",
                    iconColor: .red,
                    title: "手表低电量自动充电提醒",
                    subtitle: "在 iPhone 快捷指令 App 新建自动化：「当 Apple Watch 电量低于 20%」时执行「汇报设备电量」（设备选 Apple Watch），小助会自动生成床头充电待办并提醒您。"
                )
            } header: {
                Text("硬件按键与低电量自动化")
            }
        }
        .themedScrollContentBackground()
        .themedAppBackground()
        .themedRow()
        .navigationTitle("Apple Watch 腕上协同")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func guideRow(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func siriPhraseRow(phrase: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(phrase)
                .font(.subheadline.bold())
                .foregroundStyle(.tint)
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
