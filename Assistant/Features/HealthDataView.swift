import AssistantCore
import SwiftData
import SwiftUI

/// Apple 健康数据页：展示当天的步数、活动能量、饮水与睡眠，
/// 并把健康侧数值与本地的运动 / 喝水 / 睡眠打卡待办并排呈现。
///
/// ## 诚实性约束（贯穿本文件）
/// HealthKit **不向 App 暴露读权限状态**：用户拒绝读取后，查询静默返回空，
/// 与「已授权但今天确实没数据」表现完全一致。因此本页**不显示「已授权 / 未授权」**，
/// 只区分三种可观察状态：
/// - 从未请求过 → 展示授权入口
/// - 请求过但没有数据 → 提示可能是未授权或确实无记录
/// - 有数据 → 展示数值
///
/// 任何情况下都**不会**把「读不到」渲染成「已完成」或「0 步」这类精确假值。
struct HealthDataView: View {
    @StateObject private var health = HealthKitService.shared
    @Query(sort: \FoodIntakeRecord.date, order: .reverse) private var foodRecords: [FoodIntakeRecord]
    @Query(sort: \WaterIntakeRecord.date, order: .reverse) private var waterRecords: [WaterIntakeRecord]
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVitalitySuggestionExpanded = false
    @State private var isPleasureAdviceExpanded = true
    @State private var showShareSheet = false
    @State private var dietTrendDays = 7

    /// 本地打卡目标：与健康侧指标一一对应
    private let goals = HealthGoal.defaults

    private var todayFoodCalories: Double? {
        let cal = Calendar.current
        let today = foodRecords.filter { cal.isDateInToday($0.date) }
        guard !today.isEmpty else { return nil }
        return today.reduce(0.0) { $0 + $1.consumedCalories }
    }

    private var todayEffectiveWaterML: Double? {
        let cal = Calendar.current
        let today = waterRecords.filter { cal.isDateInToday($0.date) }
        guard !today.isEmpty else { return nil }
        return today.reduce(0.0) { $0 + $1.effectiveHydrationML }
    }

    private var vitalityEvaluation: VitalityEvaluation? {
        guard health.snapshot?.readState == .hasData || todayFoodCalories != nil else { return nil }
        return VitalityEvaluator.evaluate(snapshot: health.snapshot, foodIntakeCalories: todayFoodCalories)
    }

    /// 近 N 天饮食摄入趋势（纯函数聚合在 AssistantCore.TrendAnalytics）
    private var dietTrend: TrendAnalytics.DietTrend {
        TrendAnalytics.dietTrend(
            entries: foodRecords.map {
                TrendAnalytics.DietEntry(date: $0.date, calories: $0.consumedCalories)
            },
            dayCount: dietTrendDays
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.md) {
                if let pleasure = health.pleasureEvaluation {
                    pleasureScoreCard(pleasure)
                }
                if let vitality = vitalityEvaluation {
                    vitalityScoreCard(vitality)
                }
                waterTrackerEntryCard
                foodCalorieEntryCard
                DietTrendCard(trend: dietTrend, dayCount: $dietTrendDays)
                if !HealthKitService.isAvailable {
                    unavailableCard
                } else {
                    statusCard
                    if health.snapshot?.readState == .hasData {
                        metricCards
                        energyAndWorkoutSection
                        vitalSignsSection
                        todoCorrelationSection
                    }
                }
            }
            .padding(AppSpacing.lg)
        }
        .themedAppBackground()
        .navigationTitle("健康数据")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享健康日签")
            }
        }
        .sheet(isPresented: $showShareSheet) {
            HealthShareSheet(
                snapshot: health.snapshot,
                vitality: vitalityEvaluation,
                pleasure: health.pleasureEvaluation,
                todayFoodCalories: todayFoodCalories,
                todayWaterML: todayEffectiveWaterML,
                goals: goals
            )
        }
        .task {
            await loadIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            // 回前台刷新：HealthKit 数据由系统「健康」App 随时更新，
            // 回到小助时数据可能已经变了。
            if phase == .active {
                Task { await health.refreshToday() }
            }
        }
    }

    // MARK: - 加载

    private func loadIfNeeded() async {
        // 首次进入且系统认为需要授权时，先弹授权面板；
        // 已经做过选择（无论同意与否）则直接拉数据。
        if await health.needsAuthorizationRequest() {
            await health.requestAuthorization()
        }
        await health.refreshToday()
    }

    // MARK: - 喝水记录与折算入口卡

    private var waterTrackerEntryCard: some View {
        let cal = Calendar.current
        let today = waterRecords.filter { cal.isDateInToday($0.date) }
        let effectiveWater = Int(today.reduce(0.0) { $0 + $1.effectiveHydrationML }.rounded())
        let goal = Int(AppSettings.dailyWaterGoalML)

        return NavigationLink {
            WaterTrackerView()
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "drop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AppColor.primary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("喝水记录与饮品折算")
                        .font(.headline)
                        .foregroundStyle(AppColor.text)
                    Text(today.isEmpty
                         ? "一键记录白开水/咖啡/奶茶 · 智能折算有效补水与咖啡因"
                         : "今日已记 \(today.count) 次 · 补水 \(effectiveWater)/\(goal) ml (\(Int(Double(effectiveWater) / Double(max(goal, 1)) * 100))%)")
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
            .padding(AppSpacing.md)
            .appCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: - 饮食热量估算入口卡

    private var foodCalorieEntryCard: some View {
        let cal = Calendar.current
        let today = foodRecords.filter { cal.isDateInToday($0.date) }
        let totalCalories = Int(today.reduce(0.0) { $0 + $1.consumedCalories }.rounded())

        return NavigationLink {
            FoodPhotoCalorieView()
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "fork.knife.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("食物照片热量估算")
                        .font(.headline)
                        .foregroundStyle(AppColor.text)
                    Text(today.isEmpty
                         ? "拍照或选图推测热量 · 没吃完可手动调整百分比"
                         : "今日已记 \(today.count) 餐 · 共摄入约 \(totalCalories) 千卡")
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
            .padding(AppSpacing.md)
            .appCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: - 状态卡

    @ViewBuilder
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "heart.text.square.fill")
                    .foregroundStyle(AppColor.feature)
                Text("Apple 健康")
                    .font(.headline)
                Spacer()
                if health.isLoading {
                    ProgressView()
                }
            }

            switch currentState {
            case .notDetermined:
                Text("尚未连接「健康」。连接后可读取步数、运动能量、饮水与睡眠，让打卡页显示真实数值。")
                    .font(.footnote)
                    .foregroundStyle(AppColor.secondaryText)
                Button {
                    Task {
                        await health.requestAuthorization()
                        await health.refreshToday()
                    }
                } label: {
                    Label("连接 Apple 健康", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

            case .requestedNoData:
                Text("已向系统请求过读取权限，但没有读到数据。可能是你拒绝了读取权限，或「健康」里今天还没有记录。可前往「健康」App 确认权限与数据。")
                    .font(.footnote)
                    .foregroundStyle(AppColor.secondaryText)
                HStack(spacing: AppSpacing.sm) {
                    Button("重新请求") {
                        Task {
                            await health.requestAuthorization()
                            await health.refreshToday()
                        }
                    }
                    .buttonStyle(.bordered)
                    Button("打开「健康」") { openHealthApp() }
                        .buttonStyle(.bordered)
                }
                .font(.footnote)

            case .hasData:
                Text("正在显示「健康」中的今日数据。数据只在本机读取，不会离开这台设备。")
                    .font(.footnote)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    /// 把「是否请求过」与「是否有数据」合成一个可展示的三态。
    private enum DisplayState {
        case notDetermined
        case requestedNoData
        case hasData
    }

    private var currentState: DisplayState {
        guard health.hasRequestedAuthorization || health.snapshot != nil else { return .notDetermined }
        if health.snapshot?.readState == .hasData { return .hasData }
        return .requestedNoData
    }

    private var unavailableCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Label("此设备不支持健康数据", systemImage: "iphone.slash")
                .font(.headline)
                .foregroundStyle(AppColor.warning)
            Text("iPad 等设备上没有「健康」数据源，本页无法展示任何数值。其它功能不受影响。")
                .font(.footnote)
                .foregroundStyle(AppColor.secondaryText)
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private func openHealthApp() {
        // 「健康」App 的 URL scheme 在部分系统版本上不可用，失败时静默降级
        if let url = URL(string: "x-apple-health://") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - 指标卡

    private var metricCards: some View {
        let progresses = HealthMetrics.progress(for: health.snapshot!, goals: goals)
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: AppSpacing.md),
                                  GridItem(.flexible(), spacing: AppSpacing.md)],
                          spacing: AppSpacing.md) {
            ForEach(progresses, id: \.goal.kind) { progress in
                metricCard(progress)
            }
        }
    }

    @ViewBuilder
    private func metricCard(_ progress: HealthGoalProgress) -> some View {
        let content = metricCardContent(progress)
        if progress.goal.kind == .dietaryWater {
            NavigationLink {
                WaterTrackerView()
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func metricCardContent(_ progress: HealthGoalProgress) -> some View {
        let kind = progress.goal.kind
        let tint: Color = switch progress.status {
        case .achieved: AppColor.success
        case .notAchieved: AppColor.info
        case .noData: AppColor.secondaryText
        }

        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: kind.iconName)
                    .foregroundStyle(tint)
                Text(kind.displayName)
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
                Spacer()
                if progress.status == .achieved {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AppColor.success)
                        .accessibilityLabel("已达标")
                }
            }

            // 无数据时显示占位文案，**不显示 0**——那会造成「今天走了 0 步」的假象
            if let actual = progress.actual {
                Text(HealthMetrics.format(actual, for: kind))
                    .font(.title3.bold())
                    .foregroundStyle(AppColor.text)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            } else {
                Text("暂无数据")
                    .font(.title3.bold())
                    .foregroundStyle(AppColor.secondaryText)
            }

            ProgressView(value: progress.ratio)
                .tint(tint)

            Text(subtitle(for: progress))
                .font(.caption2)
                .foregroundStyle(AppColor.secondaryText)
                .lineLimit(2)
        }
        .padding(AppSpacing.md)
        .appCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.displayName)，\(accessibilityText(for: progress))")
    }

    private func subtitle(for progress: HealthGoalProgress) -> String {
        switch progress.status {
        case .achieved:
            return "目标 \(HealthMetrics.format(progress.goal.target, for: progress.goal.kind))"
        case .notAchieved:
            return "目标 \(HealthMetrics.format(progress.goal.target, for: progress.goal.kind))"
        case .noData:
            return "未读取到数据"
        }
    }

    private func accessibilityText(for progress: HealthGoalProgress) -> String {
        switch progress.status {
        case .achieved:
            return "已达标"
        case .notAchieved:
            return "未达标"
        case .noData:
            return "暂无数据"
        }
    }

    // MARK: - 综合活力卡

    private func vitalityScoreCard(_ vitality: VitalityEvaluation) -> some View {
        let levelColor: Color = switch vitality.level {
        case .peak: AppColor.warning
        case .good: AppColor.success
        case .balanced: AppColor.info
        case .low: .yellow
        case .exhausted: AppColor.danger
        }

        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Label("活力指数", systemImage: "bolt.heart.fill")
                    .font(.headline)
                    .foregroundStyle(AppColor.text)
                Spacer()
                Text(vitality.level.badge)
                    .font(.caption.bold())
                    .foregroundStyle(levelColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppColor.softFill(levelColor), in: Capsule())
            }

            // 核心数值与极简摘要
            HStack(spacing: AppSpacing.md) {
                VStack(spacing: 2) {
                    Text("\(vitality.score)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(levelColor)
                    Text("满分 100")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppColor.secondaryText)
                }
                .frame(width: 68, height: 56)
                .background(AppColor.softFill(levelColor, opacity: 0.08), in: RoundedRectangle(cornerRadius: AppRadius.card))

                Text(vitality.summary)
                    .font(.subheadline)
                    .foregroundStyle(AppColor.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }

            // 关键指标摘要（2列紧凑胶囊卡）
            if !vitality.highlights.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: AppSpacing.sm), GridItem(.flexible(), spacing: AppSpacing.sm)],
                    spacing: AppSpacing.sm
                ) {
                    ForEach(vitality.highlights) { h in
                        vitalityHighlightTile(h)
                    }
                }
            }

            // 调养建议：轻量收折，按需展开
            if !vitality.suggestion.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isVitalitySuggestionExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "lightbulb.fill")
                                .font(.caption2)
                                .foregroundStyle(AppColor.warning)
                            Text(isVitalitySuggestionExpanded ? "收起调养建议" : "查看生活调养建议")
                                .font(.caption2.bold())
                                .foregroundStyle(AppColor.secondaryText)
                            Image(systemName: isVitalitySuggestionExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)

                    if isVitalitySuggestionExpanded {
                        Text(vitality.suggestion)
                            .font(.caption)
                            .foregroundStyle(AppColor.secondaryText)
                            .lineSpacing(3)
                            .padding(AppSpacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private func vitalityHighlightTile(_ h: VitalityHighlight) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: h.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(h.isPositive ? AppColor.success : AppColor.warning)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(h.title)
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
                Text(h.valueText)
                    .font(.caption.bold())
                    .foregroundStyle(AppColor.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.chip))
    }

    // MARK: - 能量与身体耗能

    private var energyAndWorkoutSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("能量消耗与健身")
                .font(.subheadline.bold())
                .foregroundStyle(AppColor.text)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: AppSpacing.md),
                                GridItem(.flexible(), spacing: AppSpacing.md)],
                      spacing: AppSpacing.md) {
                if let resting = health.snapshot?.restingEnergy {
                    statBox(title: "静息能量", value: HealthMetrics.format(resting, for: .restingEnergy), icon: "bolt.heart.fill", tint: .indigo)
                }
                if let total = health.snapshot?.totalEnergyBurned {
                    statBox(title: "身体总耗能", value: "\(Int(total.rounded())) 千卡", icon: "flame.fill", tint: .orange)
                }
            }

            if let workout = health.snapshot?.workoutSummary, workout.count > 0 {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "figure.run.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("健身记录")
                            .font(.caption.bold())
                            .foregroundStyle(AppColor.text)
                        Text(workout.summaryText)
                            .font(.caption2)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                    Spacer()
                }
                .padding(AppSpacing.sm)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    // MARK: - 生命体征

    private var vitalSignsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("生命体征与生理指标")
                .font(.subheadline.bold())
                .foregroundStyle(AppColor.text)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: AppSpacing.md),
                                GridItem(.flexible(), spacing: AppSpacing.md)],
                      spacing: AppSpacing.md) {
                if let hrv = health.snapshot?.heartRateVariability {
                    statBox(title: "心率变异性(HRV)", value: HealthMetrics.format(hrv, for: .heartRateVariability), icon: "waveform.path.ecg", tint: .purple)
                }
                if let restingHr = health.snapshot?.restingHeartRate {
                    statBox(title: "静息心率", value: HealthMetrics.format(restingHr, for: .restingHeartRate), icon: "heart.circle.fill", tint: .pink)
                }
                if let hr = health.snapshot?.heartRate {
                    statBox(title: "心率", value: HealthMetrics.format(hr, for: .heartRate), icon: "heart.fill", tint: .red)
                }
                if let rem = health.snapshot?.sleepREM {
                    statBox(title: "REM 快速眼动", value: HealthMetrics.format(rem, for: .sleepREM), icon: "brain.head.profile", tint: .indigo)
                }
                if let deep = health.snapshot?.sleepDeep {
                    statBox(title: "深度睡眠", value: HealthMetrics.format(deep, for: .sleepDeep), icon: "moon.zzz.fill", tint: .blue)
                }
                if let ox = health.snapshot?.bloodOxygen {
                    statBox(title: "血氧饱和度", value: HealthMetrics.format(ox, for: .bloodOxygen), icon: "lungs.fill", tint: .cyan)
                }
                if let temp = health.snapshot?.bodyTemperature {
                    statBox(title: "体温", value: HealthMetrics.format(temp, for: .bodyTemperature), icon: "thermometer.medium", tint: .orange)
                }
                if let speed = health.snapshot?.walkingSpeed {
                    statBox(title: "步行速度", value: HealthMetrics.format(speed, for: .walkingSpeed), icon: "figure.walk.motion", tint: .green)
                }
                if let resp = health.snapshot?.respiratoryRate {
                    statBox(title: "呼吸频率", value: HealthMetrics.format(resp, for: .respiratoryRate), icon: "wind", tint: .teal)
                }
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    // MARK: - 愉悦指数卡

    private struct PleasureHighlightTileItem: Identifiable {
        let id: String
        let icon: String
        let title: String
        let valueText: String
        let isPositive: Bool
    }

    private func pleasureHighlights(for eval: PleasureIndexEvaluation) -> [PleasureHighlightTileItem] {
        var items: [PleasureHighlightTileItem] = []

        // 1. 压力负荷
        items.append(PleasureHighlightTileItem(
            id: "stress",
            icon: "gauge.with.needle.fill",
            title: "压力负荷",
            valueText: "\(eval.stressScore)% · \(eval.stressLevel.rawValue)",
            isPositive: eval.stressScore <= 50
        ))

        // 2. 自主神经
        items.append(PleasureHighlightTileItem(
            id: "autonomic",
            icon: "figure.mind.and.body",
            title: "自主神经",
            valueText: eval.autonomicBalance.rawValue,
            isPositive: eval.autonomicBalance != .sympatheticDominant
        ))

        // 3. 心率变异性 / 静息心率
        let hrvDetail = eval.details.first(where: { $0.title.contains("HRV") || $0.title.contains("变异") })
        if let hrv = hrvDetail {
            items.append(PleasureHighlightTileItem(
                id: "hrv",
                icon: "heart.fill",
                title: "心率变异性",
                valueText: hrv.valueText,
                isPositive: hrv.isPositive
            ))
        } else if let rhr = eval.details.first(where: { $0.title.contains("静息") }) {
            items.append(PleasureHighlightTileItem(
                id: "rhr",
                icon: "heart.circle.fill",
                title: "静息心率",
                valueText: rhr.valueText,
                isPositive: rhr.isPositive
            ))
        }

        // 4. 睡眠 / 情绪修复。
        //    注意与活力卡去重：活力卡已展示「睡眠恢复 X 小时」，这里优先 REM；
        //    无 REM 只有时长兜底时改叫「睡眠情绪储备」——同一数值不该两张卡同名再放一遍。
        let sleepDetail = eval.details.first(where: { $0.title.contains("REM") })
            ?? eval.details.first(where: { $0.title.contains("睡眠") })
        if let sleep = sleepDetail {
            items.append(PleasureHighlightTileItem(
                id: "sleep",
                icon: sleep.title.contains("REM") ? "moon.stars.fill" : "sparkles",
                title: sleep.title.contains("REM") ? "REM情绪修复" : "睡眠情绪储备",
                valueText: sleep.valueText,
                isPositive: sleep.isPositive
            ))
        }

        // 补齐至 4 项（保持与活力指数卡一致的 2x2 极简布局）。
        // 跳过与活力卡重复的心率/睡眠时长原始条目，优先补 REM/深度睡眠等情绪修复向指标。
        if items.count < 4 {
            let preferred = eval.details.filter { $0.title.contains("REM") || $0.title.contains("深度") }
            for d in preferred {
                guard items.count < 4 else { break }
                if items.contains(where: { $0.id == d.id || $0.title == d.title }) { continue }
                items.append(PleasureHighlightTileItem(
                    id: d.id,
                    icon: d.title.contains("深度") ? "bed.double.fill" : "moon.stars.fill",
                    title: d.title.contains("深度") ? "深度睡眠" : d.title,
                    valueText: d.valueText,
                    isPositive: d.isPositive
                ))
            }
            for d in eval.details {
                guard items.count < 4 else { break }
                if items.contains(where: { $0.id == d.id || $0.title == d.title }) { continue }
                // 心率类与睡眠时长类不补：活力卡/生命体征区已展示，避免同一数值重复出现
                if d.title.contains("心率") && !d.title.contains("变异") { continue }
                if d.title.contains("睡眠时长") { continue }
                items.append(PleasureHighlightTileItem(
                    id: d.id,
                    icon: "sparkles",
                    title: d.title,
                    valueText: d.valueText,
                    isPositive: d.isPositive
                ))
            }
        }

        return items
    }

    private func pleasureScoreCard(_ eval: PleasureIndexEvaluation) -> some View {
        let stateColor: Color = switch eval.state {
        case .euphoric: AppColor.success
        case .serene: AppColor.info
        case .strained: AppColor.warning
        case .fatigued: .orange
        case .overloaded: AppColor.danger
        }

        let highlights = pleasureHighlights(for: eval)

        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Label("愉悦指数", systemImage: "heart.text.square.fill")
                    .font(.headline)
                    .foregroundStyle(AppColor.text)
                Spacer()
                Text(eval.state.badge)
                    .font(.caption.bold())
                    .foregroundStyle(stateColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppColor.softFill(stateColor), in: Capsule())
            }

            // 核心数值与极简摘要
            HStack(spacing: AppSpacing.md) {
                VStack(spacing: 2) {
                    Text("\(eval.pleasureScore)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(stateColor)
                    Text("满分 100")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppColor.secondaryText)
                }
                .frame(width: 68, height: 56)
                .background(AppColor.softFill(stateColor, opacity: 0.08), in: RoundedRectangle(cornerRadius: AppRadius.card))

                Text(eval.summary)
                    .font(.subheadline)
                    .foregroundStyle(AppColor.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }

            // 关键指标摘要（2列紧凑胶囊卡，参考活力指数卡布局）
            if !highlights.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: AppSpacing.sm), GridItem(.flexible(), spacing: AppSpacing.sm)],
                    spacing: AppSpacing.sm
                ) {
                    ForEach(highlights) { h in
                        pleasureHighlightTile(h)
                    }
                }
            }

            // 身心关怀建议：轻量收折，按需展开
            if !eval.advice.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isPleasureAdviceExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(AppColor.primary)
                            Text(isPleasureAdviceExpanded ? "收起减压建议" : "查看身心减压建议")
                                .font(.caption2.bold())
                                .foregroundStyle(AppColor.secondaryText)
                            Image(systemName: isPleasureAdviceExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)

                    if isPleasureAdviceExpanded {
                        Text(eval.advice)
                            .font(.caption)
                            .foregroundStyle(AppColor.secondaryText)
                            .lineSpacing(3)
                            .padding(AppSpacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private func pleasureHighlightTile(_ h: PleasureHighlightTileItem) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: h.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(h.isPositive ? AppColor.success : AppColor.warning)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(h.title)
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
                Text(h.valueText)
                    .font(.caption.bold())
                    .foregroundStyle(AppColor.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.chip))
    }

    private func statBox(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.caption)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
            }
            Text(value)
                .font(.headline.bold())
                .foregroundStyle(AppColor.text)
                .minimumScaleFactor(0.8)
                .lineLimit(1)
        }
        .padding(AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 与本地打卡待办的关联

    /// 把健康侧数值与本地三类打卡待办放在一起看：
    /// 让人知道「今天已经走了 8000 步」时，手动打卡就有了真实依据。
    private var todoCorrelationSection: some View {
        let items: [(HealthRelatedTodoType, HealthGoalProgress)] = HealthRelatedTodoType.allCases.compactMap { type in
            guard let snapshot = health.snapshot,
                  let progress = HealthMetrics.progress(for: type, snapshot: snapshot, goals: goals) else {
                return nil
            }
            return (type, progress)
        }
        let achievedCount = items.filter { $0.1.status == .achieved }.count

        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Label("健康目标与打卡协同", systemImage: "checklist.checked")
                    .font(.subheadline.bold())
                    .foregroundStyle(AppColor.text)
                Spacer()
                Text("已达标 \(achievedCount)/\(items.count)")
                    .font(.caption2.bold())
                    .foregroundStyle(achievedCount == items.count && !items.isEmpty ? AppColor.success : AppColor.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        AppColor.softFill(achievedCount == items.count && !items.isEmpty ? AppColor.success : AppColor.primary),
                        in: Capsule()
                    )
            }

            VStack(spacing: AppSpacing.sm) {
                ForEach(items, id: \.0) { todoType, progress in
                    todoCorrelationTile(todoType: todoType, progress: progress)
                }
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private func todoCorrelationTile(todoType: HealthRelatedTodoType, progress: HealthGoalProgress) -> some View {
        let tint = correlationTint(for: todoType)

        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.chip)
                        .fill(AppColor.softFill(tint))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon(for: todoType))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(todoType.displayName)
                        .font(.subheadline.bold())
                        .foregroundStyle(AppColor.text)

                    Group {
                        if let actual = progress.actual {
                            Text("当前 \(HealthMetrics.format(actual, for: progress.goal.kind)) / 目标 \(HealthMetrics.format(progress.goal.target, for: progress.goal.kind))")
                        } else {
                            Text("目标 \(HealthMetrics.format(progress.goal.target, for: progress.goal.kind)) · 今日暂未记录")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
                }

                Spacer()

                correlationStatusBadge(for: progress, tint: tint)
            }

            // 进度条
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemFill))
                        .frame(height: 6)
                    Capsule()
                        .fill(progress.status == .achieved ? AppColor.success : tint)
                        .frame(width: max(proxy.size.width * CGFloat(progress.ratio), progress.ratio > 0 ? 6 : 0), height: 6)
                }
            }
            .frame(height: 6)
        }
        .padding(AppSpacing.sm)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.card))
    }

    @ViewBuilder
    private func correlationStatusBadge(for progress: HealthGoalProgress, tint: Color) -> some View {
        switch progress.status {
        case .achieved:
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                Text("已达标")
                    .font(.caption2.bold())
            }
            .foregroundStyle(AppColor.success)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(AppColor.softFill(AppColor.success), in: Capsule())
        case .notAchieved:
            if let actual = progress.actual {
                let remaining = max(progress.goal.target - actual, 0)
                Text("还差 \(HealthMetrics.format(remaining, for: progress.goal.kind))")
                    .font(.caption2.bold())
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(AppColor.softFill(tint), in: Capsule())
            } else {
                Text("未开始")
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(.systemFill), in: Capsule())
            }
        case .noData:
            Text("暂无数据")
                .font(.caption2)
                .foregroundStyle(AppColor.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color(.systemFill), in: Capsule())
        }
    }

    private func correlationTint(for todoType: HealthRelatedTodoType) -> Color {
        switch todoType {
        case .exercise: return AppColor.success
        case .hydration: return AppColor.info
        case .sleep: return .indigo
        }
    }

    private func icon(for todoType: HealthRelatedTodoType) -> String {
        switch todoType {
        case .exercise: return "figure.run"
        case .hydration: return "drop.fill"
        case .sleep: return "bed.double.fill"
        }
    }
}
