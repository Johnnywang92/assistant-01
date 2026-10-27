import AssistantCore
import Charts
import SwiftUI

// MARK: - 消费趋势卡

/// 近 N 个月支出柱状图 + 环比与类别变化（数据来自 TrendAnalytics.expenseTrend）。
struct ExpenseTrendCard: View {
    let trend: TrendAnalytics.ExpenseTrend

    private var monthLabel: (TrendAnalytics.MonthlyExpensePoint) -> String {
        { "\($0.month)月" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("消费趋势")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("近 \(trend.months.count) 个月")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                changeBadge
                Text("月均 \(formatted(trend.averageExpense))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Chart {
                RuleMark(y: .value("月均", trend.averageExpense))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("月均")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                ForEach(trend.months) { point in
                    let isCurrent = (point.id == trend.months.last?.id)
                    BarMark(
                        x: .value("月", monthLabel(point)),
                        y: .value("支出", point.expense),
                        width: .automatic
                    )
                    .foregroundStyle(isCurrent ? AppColor.danger : AppColor.danger.opacity(0.42))
                    .cornerRadius(4)
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(shortAmount(amount))
                                .font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 150)

            if trend.growingCategory != nil || trend.shrinkingCategory != nil {
                Divider().opacity(0.4)
                if let g = trend.growingCategory {
                    categoryShiftRow(shift: g, isGrowing: true)
                }
                if let s = trend.shrinkingCategory {
                    categoryShiftRow(shift: s, isGrowing: false)
                }
            }
        }
        .padding(AppSpacing.md)
        .appCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("消费趋势：近 \(trend.months.count) 个月，月均 \(formatted(trend.averageExpense)) 元")
    }

    private var changeBadge: some View {
        Group {
            if let ratio = trend.changeRatio {
                let pct = Int((abs(ratio) * 100).rounded())
                if ratio >= 0 {
                    Label("环比 +\(pct)%", systemImage: "arrow.up.right")
                        .foregroundStyle(AppColor.danger)
                } else {
                    Label("环比 -\(pct)%", systemImage: "arrow.down.right")
                        .foregroundStyle(AppColor.success)
                }
            } else {
                Text("环比 —")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2.bold())
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private func categoryShiftRow(shift: TrendAnalytics.CategoryShift, isGrowing: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isGrowing ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
                .font(.caption2.bold())
                .foregroundStyle(isGrowing ? AppColor.danger : AppColor.success)
            Text("\(isGrowing ? "增长最快" : "降温最明显")：\(categoryName(shift.categoryRaw))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(formatted(shift.from)) → \(formatted(shift.to))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func categoryName(_ raw: String) -> String {
        ExpenseCategory(rawValue: raw)?.displayName ?? raw
    }

    private func formatted(_ value: Double) -> String {
        "¥" + String(format: value >= 100 ? "%.0f" : "%.1f", value)
    }

    private func shortAmount(_ value: Double) -> String {
        if value >= 10000 { return String(format: "%.1f万", value / 10000) }
        return String(format: "%.0f", value)
    }
}

// MARK: - 饮食趋势卡

/// 近 N 天摄入热量柱状图 + 日均/达标统计（数据来自 TrendAnalytics.dietTrend）。
struct DietTrendCard: View {
    let trend: TrendAnalytics.DietTrend
    @Binding var dayCount: Int

    private let dayOptions = [7, 30]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("饮食趋势")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("天数", selection: $dayCount) {
                    ForEach(dayOptions, id: \.self) { n in
                        Text("近 \(n) 天").tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .controlSize(.mini)
                .accessibilityLabel("趋势时间范围")
            }

            if trend.recordedDays == 0 {
                Text("这段时间还没有饮食记录，拍照估算或记账推测后就能看到趋势。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                Chart {
                    ForEach(trend.days) { point in
                        BarMark(
                            x: .value("日", point.dayStart),
                            y: .value("摄入", point.calories),
                            width: dayCount > 7 ? .fixed(4) : .automatic
                        )
                        .foregroundStyle(point.hasRecords ? Color.orange.opacity(0.75) : Color.orange.opacity(0.12))
                        .cornerRadius(dayCount > 7 ? 2 : 3)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: dayCount > 7 ? 5 : 7)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month().day(), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let cal = value.as(Double.self) {
                                Text("\(Int(cal))")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 150)

                HStack(spacing: 10) {
                    statTile(title: "日均摄入", value: "\(Int(trend.averageCalories)) 千卡")
                    statTile(title: "有记录", value: "\(trend.recordedDays)/\(trend.days.count) 天")
                    if let max = trend.maxDayCalories, let min = trend.minDayCalories {
                        statTile(title: "最高/最低", value: "\(Int(max))/\(Int(min))")
                    }
                }

                if let ratio = trend.changeRatio {
                    let pct = Int((abs(ratio) * 100).rounded())
                    HStack(spacing: 6) {
                        Image(systemName: ratio >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2.bold())
                            .foregroundStyle(ratio >= 0 ? AppColor.danger : AppColor.success)
                        Text("后半段日均摄入较前半段\(ratio >= 0 ? "上升" : "下降") \(pct)%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(AppSpacing.md)
        .appCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("饮食趋势：近 \(trend.days.count) 天，日均 \(Int(trend.averageCalories)) 千卡，有记录 \(trend.recordedDays) 天")
    }

    private func statTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(AppColor.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}
