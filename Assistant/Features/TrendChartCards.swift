import AssistantCore
import Charts
import SwiftUI

// MARK: - 消费趋势卡

/// 消费走势卡片：支持日趋势（7/14/30天）与月趋势（6月）切换。
/// 每日消费总额柱状图支持点击/滑动单日悬浮高亮、日均基准线与零支出正向激励打卡。
struct ExpenseTrendCard: View {
    @Binding var scope: TrendAnalytics.ExpenseTrendScope
    let dailyTrend: TrendAnalytics.DailyExpenseTrend
    let monthlyTrend: TrendAnalytics.ExpenseTrend

    @State private var selectedDate: Date? = nil
    private let calendar = Calendar.current

    init(
        scope: Binding<TrendAnalytics.ExpenseTrendScope>,
        dailyTrend: TrendAnalytics.DailyExpenseTrend,
        monthlyTrend: TrendAnalytics.ExpenseTrend
    ) {
        self._scope = scope
        self.dailyTrend = dailyTrend
        self.monthlyTrend = monthlyTrend
    }

    /// 兼容仅传 monthly trend 的旧调用
    init(trend: TrendAnalytics.ExpenseTrend) {
        self._scope = .constant(.months6)
        self.dailyTrend = TrendAnalytics.dailyExpenseTrend(entries: [])
        self.monthlyTrend = trend
    }

    /// 兼容仅传 daily trend 的调用
    init(
        dailyTrend: TrendAnalytics.DailyExpenseTrend,
        scope: Binding<TrendAnalytics.ExpenseTrendScope> = .constant(.days7),
        monthlyTrend: TrendAnalytics.ExpenseTrend = TrendAnalytics.expenseTrend(entries: [])
    ) {
        self._scope = scope
        self.dailyTrend = dailyTrend
        self.monthlyTrend = monthlyTrend
    }

    private var selectedDailyPoint: TrendAnalytics.DailyExpensePoint? {
        guard let selectedDate else { return nil }
        return dailyTrend.days.min(by: {
            abs($0.dayStart.timeIntervalSince(selectedDate)) < abs($1.dayStart.timeIntervalSince(selectedDate))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            subHeaderInfoRow
            chartContent
            bottomInsightsSection
        }
        .padding(AppSpacing.md)
        .appCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .onChange(of: scope) { _, _ in
            selectedDate = nil
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center) {
            Text("消费趋势")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Spacer()
            Picker("时间范围", selection: $scope) {
                ForEach(TrendAnalytics.ExpenseTrendScope.allCases) { item in
                    Text(item.shortTitle).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .controlSize(.mini)
            .accessibilityLabel("消费趋势时间范围")
        }
    }

    // MARK: - Subheader Info

    private var subHeaderInfoRow: some View {
        Group {
            if scope.isDaily {
                if let selected = selectedDailyPoint {
                    selectedDayHeader(selected)
                } else {
                    dailyOverviewHeader
                }
            } else {
                monthlyOverviewHeader
            }
        }
    }

    private var dailyOverviewHeader: some View {
        HStack(spacing: 8) {
            if let ratio = dailyTrend.changeRatio {
                let pct = Int((abs(ratio) * 100).rounded())
                Label(ratio >= 0 ? "后半期 +\(pct)%" : "后半期 -\(pct)%",
                      systemImage: ratio >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2.bold())
                    .foregroundStyle(ratio >= 0 ? AppColor.danger : AppColor.success)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            } else {
                Text("后半期 —")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }

            Text("日均 \(formatted(dailyTrend.dailyAverageExpense))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            Text("点击柱图看单日")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func selectedDayHeader(_ selected: TrendAnalytics.DailyExpensePoint) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dayDetailDateText(selected.dayStart))
                        .font(.caption.bold())
                        .foregroundStyle(AppColor.text)
                    if selected.expense > 0 {
                        Text(formatted(selected.expense))
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(AppColor.danger)
                    } else {
                        Text("无支出")
                            .font(.caption.bold())
                            .foregroundStyle(AppColor.success)
                    }
                }
                HStack(spacing: 4) {
                    if selected.expense > 0 {
                        Text("\(selected.expenseCount) 笔支出")
                        if let cat = selected.topExpenseCategoryRaw {
                            Text("· 主要为 \(categoryName(cat))")
                        }
                    } else {
                        Text("达成无消费日 🎉")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                selectedDate = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消单日选中")
        }
        .padding(.vertical, 2)
    }

    private var monthlyOverviewHeader: some View {
        HStack(spacing: 8) {
            monthlyChangeBadge
            Text(monthlyTrend.isCurrentMonthPartial
                 ? "历史月均 \(formatted(monthlyTrend.averageExpense))"
                 : "月均 \(formatted(monthlyTrend.averageExpense))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            if monthlyTrend.isCurrentMonthPartial {
                Text("本月截至\(monthlyTrend.currentMonthDay)日")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Chart Content

    @ViewBuilder
    private var chartContent: some View {
        if scope.isDaily {
            dailyChart
        } else {
            monthlyChart
        }
    }

    private var dailyChart: some View {
        Chart {
            if dailyTrend.dailyAverageExpense > 0 {
                RuleMark(y: .value("日均", dailyTrend.dailyAverageExpense))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("日均")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
            }

            if let selected = selectedDailyPoint {
                RuleMark(x: .value("选中日", selected.dayStart))
                    .foregroundStyle((selected.expense > 0 ? AppColor.danger : AppColor.success).opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            }

            ForEach(dailyTrend.days) { point in
                let isSelected = (selectedDailyPoint?.id == point.id)
                BarMark(
                    x: .value("日", point.dayStart),
                    y: .value("支出", point.expense),
                    width: barWidth(for: scope)
                )
                .foregroundStyle(barColor(for: point, isSelected: isSelected))
                .cornerRadius(barCornerRadius(for: scope))

                if point.expense == 0 {
                    PointMark(
                        x: .value("日", point.dayStart),
                        y: .value("支出", 0)
                    )
                    .symbolSize(isSelected ? 36 : 16)
                    .foregroundStyle(isSelected ? AppColor.success : Color.secondary.opacity(0.25))
                }
            }
        }
        .chartYScale(domain: 0...max((dailyTrend.peakDay?.expense ?? 0) * 1.15, 100))
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            dailyAxisMarks
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
    }

    @AxisContentBuilder
    private var dailyAxisMarks: some AxisContent {
        switch scope {
        case .days7:
            AxisMarks(values: dailyTrend.days.map(\.dayStart)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        VStack(spacing: 1) {
                            Text(weekdayString(date))
                                .font(.system(size: 9, weight: .medium))
                            Text(monthDayString(date))
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        case .days14:
            AxisMarks(values: .automatic(desiredCount: 7)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(monthDayString(date))
                            .font(.system(size: 9))
                    }
                }
            }
        case .days30:
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(monthDayString(date))
                            .font(.system(size: 9))
                    }
                }
            }
        case .months6:
            AxisMarks()
        }
    }

    private var monthlyChart: some View {
        Chart {
            if monthlyTrend.averageExpense > 0 {
                RuleMark(y: .value("月均", monthlyTrend.averageExpense))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(monthlyTrend.isCurrentMonthPartial ? "历史月均" : "月均")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
            }

            ForEach(monthlyTrend.months) { point in
                let isCurrent = (point.id == monthlyTrend.months.last?.id)
                BarMark(
                    x: .value("月", "\(point.month)月"),
                    y: .value("支出", point.expense),
                    width: .automatic
                )
                .foregroundStyle(isCurrent ? AppColor.danger : AppColor.danger.opacity(0.42))
                .cornerRadius(AppRadius.badge)
                .annotation(position: .top) {
                    if isCurrent && monthlyTrend.isCurrentMonthPartial {
                        Text("进行中")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(AppColor.danger.opacity(0.85))
                    }
                }
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
    }

    // MARK: - Bottom Insights Section

    @ViewBuilder
    private var bottomInsightsSection: some View {
        if scope.isDaily {
            HStack(spacing: 8) {
                statTile(
                    title: "日均支出",
                    value: formatted(dailyTrend.dailyAverageExpense)
                )
                if let peak = dailyTrend.peakDay {
                    statTile(
                        title: "单日最高",
                        value: formatted(peak.expense),
                        subtitle: monthDayString(peak.dayStart)
                    )
                } else {
                    statTile(title: "单日最高", value: "—")
                }
                statTile(
                    title: "无支出天数",
                    value: "\(dailyTrend.zeroExpenseDaysCount)/\(dailyTrend.days.count) 天",
                    highlight: dailyTrend.zeroExpenseDaysCount > 0
                )
            }
        } else {
            if monthlyTrend.growingCategory != nil || monthlyTrend.shrinkingCategory != nil {
                Divider().opacity(0.4)
                if let g = monthlyTrend.growingCategory {
                    categoryShiftRow(shift: g, isGrowing: true)
                }
                if let s = monthlyTrend.shrinkingCategory {
                    categoryShiftRow(shift: s, isGrowing: false)
                }
            }
        }
    }

    private var monthlyChangeBadge: some View {
        Group {
            if let ratio = monthlyTrend.changeRatio {
                let pct = Int((abs(ratio) * 100).rounded())
                let prefix = monthlyTrend.isCurrentMonthPartial ? "同期" : "环比"
                if ratio >= 0 {
                    Label("\(prefix) +\(pct)%", systemImage: "arrow.up.right")
                        .foregroundStyle(AppColor.danger)
                } else {
                    Label("\(prefix) -\(pct)%", systemImage: "arrow.down.right")
                        .foregroundStyle(AppColor.success)
                }
            } else {
                Text(monthlyTrend.isCurrentMonthPartial ? "同期 —" : "环比 —")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2.bold())
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private func categoryShiftRow(shift: TrendAnalytics.CategoryShift, isGrowing: Bool) -> some View {
        let label = monthlyTrend.isCurrentMonthPartial
            ? (isGrowing ? "同期增长最快" : "同期降温最明显")
            : (isGrowing ? "增长最快" : "降温最明显")
        return HStack(spacing: 6) {
            Image(systemName: isGrowing ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
                .font(.caption2.bold())
                .foregroundStyle(isGrowing ? AppColor.danger : AppColor.success)
            Text("\(label)：\(categoryName(shift.categoryRaw))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(formatted(shift.from)) → \(formatted(shift.to))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    private func barColor(for point: TrendAnalytics.DailyExpensePoint, isSelected: Bool) -> Color {
        if isSelected {
            return AppColor.danger
        }
        if selectedDailyPoint != nil {
            return point.expense > 0 ? AppColor.danger.opacity(0.35) : AppColor.danger.opacity(0.08)
        }
        return point.expense > 0 ? AppColor.danger.opacity(0.75) : AppColor.danger.opacity(0.15)
    }

    private func barWidth(for scope: TrendAnalytics.ExpenseTrendScope) -> MarkDimension {
        switch scope {
        case .days7: return .automatic
        case .days14: return .fixed(12)
        case .days30: return .fixed(5)
        case .months6: return .automatic
        }
    }

    private func barCornerRadius(for scope: TrendAnalytics.ExpenseTrendScope) -> CGFloat {
        switch scope {
        case .days7: return 4
        case .days14: return 3
        case .days30: return 2
        case .months6: return AppRadius.badge
        }
    }

    private func statTile(title: String, value: String, subtitle: String? = nil, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(highlight ? AppColor.success : AppColor.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: AppRadius.chip).fill(Color.secondary.opacity(0.08)))
    }

    private func weekdayString(_ date: Date) -> String {
        if calendar.isDateInToday(date) { return "今天" }
        let weekday = calendar.component(.weekday, from: date)
        switch weekday {
        case 1: return "周日"
        case 2: return "周一"
        case 3: return "周二"
        case 4: return "周三"
        case 5: return "周四"
        case 6: return "周五"
        case 7: return "周六"
        default: return ""
        }
    }

    private func monthDayString(_ date: Date) -> String {
        let m = calendar.component(.month, from: date)
        let d = calendar.component(.day, from: date)
        return "\(m)/\(d)"
    }

    private func dayDetailDateText(_ date: Date) -> String {
        let m = calendar.component(.month, from: date)
        let d = calendar.component(.day, from: date)
        let w = weekdayString(date)
        return "\(m)月\(d)日 \(w)"
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

    private var accessibilitySummary: String {
        if scope.isDaily {
            return "消费日趋势：近 \(dailyTrend.days.count) 天，日均 \(formatted(dailyTrend.dailyAverageExpense)) 元，零支出 \(dailyTrend.zeroExpenseDaysCount) 天"
        } else {
            return "消费月趋势：近 \(monthlyTrend.months.count) 个月，月均 \(formatted(monthlyTrend.averageExpense)) 元"
        }
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
        .background(RoundedRectangle(cornerRadius: AppRadius.chip).fill(Color.secondary.opacity(0.08)))
    }
}
