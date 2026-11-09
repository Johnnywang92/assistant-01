import SwiftUI

/// Apple Watch 腕上协同指南：展示智能叠放、表盘小组件、Siri 快捷指令与硬件按键联动
struct WatchIntegrationGuideView: View {
    @ObservedObject private var watchBridge = PhoneWatchBridge.shared

    var body: some View {
        List {
            // 顶部核心概览与连接状态
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "applewatch")
                            .font(.system(size: 32))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apple Watch 腕上协同")
                                .font(.headline)
                            Text("支持独立腕上伴生 App 与智能叠放实时联动：抬腕查待办、看大字取件码、一句话记账、10 秒心情打卡与一键补水。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    HStack {
                        Label(
                            watchBridge.isWatchPaired
                                ? (watchBridge.isWatchAppInstalled ? "手表小助已安装" : "已配对手表（可在 Watch App 安装小助）")
                                : "未检测到配对的 Apple Watch",
                            systemImage: watchBridge.isWatchAppInstalled ? "checkmark.circle.fill" : "applewatch.radiowaves.left.and.right"
                        )
                        .font(.caption.bold())
                        .foregroundStyle(watchBridge.isWatchAppInstalled ? Color.green : Color.secondary)

                        Spacer()

                        if let pushed = watchBridge.lastPushedAt {
                            Text("同步于 \(pushed, format: .dateTime.hour().minute())")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // 0. 腕上小助 App 七大高频页（按使用频率排序）
            Section {
                guideRow(
                    icon: "checklist.checked",
                    iconColor: .blue,
                    title: "1. 今天（待办 + 服药习惯 + 今日支出）",
                    subtitle: "首屏默认展示：今日高优待办 Top 6、服药与周期习惯打卡、今日累计支出，以及快递/行程/身心分的一键跳转入口。"
                )

                guideRow(
                    icon: "mic.fill",
                    iconColor: .teal,
                    title: "2. 快速记（语音优先 + 一键预设）",
                    subtitle: "下滑一格即达：点击顶部大按钮直接唤起手腕语音听写，或点按下方 4 格高频预设（早餐 15、咖啡 18、取快递等）零打字秒记。"
                )

                guideRow(
                    icon: "drop.fill",
                    iconColor: .cyan,
                    title: "3. 喝水 +1",
                    subtitle: "全天高频补水：紧凑展示今日有效补水进度，2x2 网格一键 +150ml / +250ml / +350ml / +500ml 并自动同步至 Apple 健康。"
                )

                guideRow(
                    icon: "shippingbox.fill",
                    iconColor: .orange,
                    title: "4. 取件码大字铭牌",
                    subtitle: "大字号展示当前包裹取件码与驿站名称，点击「已取件」自动跳到下一件；有快递时也可从「今天」首屏直接点入。"
                )

                guideRow(
                    icon: "ticket.fill",
                    iconColor: .mint,
                    title: "5. 出行清点与行程护航",
                    subtitle: "展示高铁/航班发车倒计时、检票口与车厢座位号；支持「身·手·钥·耳」与出门必带清单逐项勾选或一键「全部带齐 ✓」。"
                )

                guideRow(
                    icon: "heart.circle.fill",
                    iconColor: .pink,
                    title: "6. 10 秒点按心情打卡",
                    subtitle: "轻触卡片即可循环调节心情、精力、压力三项分值（1~5 分），不抢占数码表冠翻页，10 秒完成每日情绪微记录。"
                )

                guideRow(
                    icon: "bolt.heart.fill",
                    iconColor: .green,
                    title: "7. 身体活力 & 身心愉悦双指数",
                    subtitle: "并排呈现 0~100 身体活力分与身心愉悦指数，融合睡眠、HRV、静息心率与步数给出精炼调养关怀（首屏右上角亦可一键直达）。"
                )
            } header: {
                Text("Apple Watch 伴生 App 页面（按高频排序）")
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
