import AssistantCore
import SwiftUI

/// 三通道对照卡：问卷 / 微记录 / 生理各说了什么，以及它们之间的关系。
///
/// ## 为什么要抽成共享组件
///
/// 主页与结果页都要展示这张卡。复制两份必然漂移——
/// 主页显示「问卷说：分数比上次高了」、结果页显示「问卷说：暂无趋势」，
/// 用户会以为数据对不上。所以**只有一处实现**。
///
/// ## 这张卡的价值在于「关系」
///
/// 三段孤立事实（分数中等、精力偏低、睡眠不足）用户看不出因果，
/// 但「问卷覆盖过去两周、最近在变差」这种**时间线上的说法**
/// 才指向同一个可行动的方向。
struct PsychCombinedReadingCard: View {
    let reading: MentalHealthCombinedReading

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Text(L10n.tr("三路对照"))
                    .font(.headline)
                    .foregroundStyle(AppColor.text)
                Spacer()
                Text(L10n.tr("问卷 · 日常 · 身体"))
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
            }

            // 各通道读数
            VStack(spacing: AppSpacing.sm) {
                ForEach(reading.channels, id: \.channel) { channel in
                    HStack(alignment: .top, spacing: AppSpacing.sm) {
                        Circle()
                            .fill(channelColor(channel))
                            .frame(width: 7, height: 7)
                            .padding(.top, 6)
                        Text(channelDisplayName(channel.channel))
                            .font(.caption)
                            .foregroundStyle(AppColor.secondaryText)
                            .frame(width: 58, alignment: .leading)
                        Text(channel.hasData ? channel.summary : L10n.tr("暂无数据"))
                            .font(.caption)
                            .foregroundStyle(channel.hasData ? AppColor.text : AppColor.secondaryText.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }

            Divider()

            // 关系结论
            Text(reading.summary)
                .font(.subheadline)
                .foregroundStyle(AppColor.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    /// 通道显示名。
    ///
    /// `L10n.tr` 只能查**固定 key**，变量查表必然失败并回落成中文。
    /// 所以按 case 映射到固定 key。
    private func channelDisplayName(_ channel: PsychChannel) -> String {
        switch channel {
        case .questionnaire: return L10n.tr("问卷说")
        case .daily: return L10n.tr("日常记录说")
        case .physiological: return L10n.tr("身体说")
        }
    }

    private func channelColor(_ channel: PsychChannelReading) -> Color {
        guard channel.hasData else { return AppColor.secondaryText.opacity(0.4) }
        switch channel.level {
        case .low: return AppColor.warning
        case .normal: return AppColor.success
        case .high: return AppColor.info
        case .unknown: return AppColor.secondaryText.opacity(0.4)
        }
    }
}
