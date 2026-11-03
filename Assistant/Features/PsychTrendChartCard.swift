import AssistantCore
import Charts
import SwiftUI

// MARK: - 心理量表趋势折线图

/// 心理量表分数趋势折线图。
///
/// ## 为什么是折线而不是柱状
///
/// 柱状图强调「各次之间的高低差异」，折线强调「**方向**」。
/// 心理追踪真正要看的是趋势——分数是在往上走还是往下走，
/// 一次的高低反而不那么重要。所以这里用折线 + 趋势区填充。
///
/// ## 阈值参考线的意义
///
/// 虚线标出**筛查阳性阈值**（PHQ-9 = 7 / GAD-7 = 10）。
/// 让用户一眼看到「线有没有越过那条线」，而不是要自己对照数字算。
///
/// ## 缺失数据不补零
///
/// 没有记录的日期**不在序列里**，不做插值、不补 0——
/// 折线跨过空缺期会让人误读成「那段是平的」。
/// 这与 `HealthDaySnapshotRecord` 的「缺失即缺失」纪律一致。
struct PsychTrendChartCard: View {
    /// 一条量表得分点。
    struct Point: Identifiable, Equatable {
        let id: UUID
        let completedAt: Date
        let totalScore: Int
        let band: PsychBandLevel

        var shortLabel: String {
            let comps = Calendar.current.dateComponents([.month, .day], from: completedAt)
            return "\(comps.month ?? 0)/\(comps.day ?? 0)"
        }
    }

    let scaleID: PsychScaleID
    let points: [Point]
    /// 是否显示趋势箭头与变化幅度。
    var showsDelta: Bool = true

    private var definition: PsychScaleDefinition {
        PsychScaleCatalog.definition(for: scaleID)
    }

    /// 最新一次与上一次的差值。nil 表示不足两次或没有上升。
    private var delta: Int? {
        guard points.count >= 2 else { return nil }
        let sorted = points.sorted { $0.completedAt < $1.completedAt }
        return sorted.last!.totalScore - sorted[sorted.count - 2].totalScore
    }

    private var latestPoint: Point? {
        points.sorted { $0.completedAt < $1.completedAt }.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                // 量表名是插值，不能作为固定 key 查表——用前缀拼接。
                Text("\(scaleID.displayName) \(L10n.tr("趋势"))")
                    .font(.caption.bold())
                    .foregroundStyle(AppColor.secondaryText)
                Spacer()
                Text("\(L10n.tr("近")) \(points.count) \(L10n.tr("次"))")
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText.opacity(0.7))
            }

            if showsDelta, let delta, let latest = latestPoint {
                HStack(spacing: 6) {
                    Image(systemName: delta > 0 ? "arrow.up.right" : (delta < 0 ? "arrow.down.right" : "arrow.right"))
                        .font(.caption2)
                        .foregroundStyle(deltaColor(delta))
                    Text(deltaText(delta, latest: latest))
                        .font(.caption2)
                        .foregroundStyle(AppColor.secondaryText)
                }
            }

            Chart {
                // 阈值参考线标签：分数是插值，拆成「前缀 + 数字」分别翻译。
                RuleMark(y: .value("筛查阈值", definition.screeningCutoff))
                    .foregroundStyle(AppColor.warning.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("\(L10n.tr("筛查阈值")) \(definition.screeningCutoff)")
                            .font(.system(size: 8))
                            .foregroundStyle(AppColor.warning.opacity(0.9))
                    }

                ForEach(points) { point in
                    LineMark(
                        x: .value("日期", point.completedAt),
                        y: .value("分数", point.totalScore)
                    )
                    .foregroundStyle(AppColor.feature)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)

                    AreaMark(
                        x: .value("日期", point.completedAt),
                        y: .value("分数", point.totalScore)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [AppColor.feature.opacity(0.22), AppColor.feature.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value("日期", point.completedAt),
                        y: .value("分数", point.totalScore)
                    )
                    .foregroundStyle(AppColor.feature)
                    .symbolSize(38)
                }
            }
            .chartYScale(domain: 0...max(definition.maxTotalScore, 1))
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let score = value.as(Int.self) {
                            Text("\(score)")
                                .font(.caption2)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(pointLabel(for: date))
                                .font(.system(size: 9))
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }
                }
            }
            .frame(height: 160)
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private func pointLabel(for date: Date) -> String {
        let comps = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(comps.month ?? 0)/\(comps.day ?? 0)"
    }

    /// 变化文案。措辞刻意中性——不制造焦虑，也不粉饰。
    private func deltaText(_ delta: Int, latest: Point) -> String {
        switch delta {
        case let d where d > 0:
            return "比上次高 \(d) 分（最新 \(latest.totalScore) 分）"
        case let d where d < 0:
            return "比上次低 \(-d) 分（最新 \(latest.totalScore) 分）"
        default:
            return "与上次持平（最新 \(latest.totalScore) 分）"
        }
    }

    private func deltaColor(_ delta: Int) -> Color {
        if delta > 0 { return AppColor.warning }
        if delta < 0 { return AppColor.success }
        return AppColor.secondaryText
    }
}
