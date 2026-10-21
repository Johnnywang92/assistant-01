import AssistantCore
import SwiftData
import SwiftUI

/// Apple 健康数据页：展示当天的步数、活动能量、饮水与睡眠，
/// 并把健康侧数值与本地的运动 / 喝水 / 服药打卡待办并排呈现。
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
    @Environment(\.scenePhase) private var scenePhase

    /// 本地打卡目标：与健康侧指标一一对应
    private let goals = HealthGoal.defaults

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.md) {
                foodCalorieEntryCard
                if !HealthKitService.isAvailable {
                    unavailableCard
                } else {
                    statusCard
                    if health.snapshot?.readState == .hasData {
                        metricCards
                        todoCorrelationSection
                    }
                }
            }
            .padding(AppSpacing.lg)
        }
        .themedAppBackground()
        .navigationTitle("健康数据")
        .navigationBarTitleDisplayMode(.inline)
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

    private func metricCard(_ progress: HealthGoalProgress) -> some View {
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

    // MARK: - 与本地打卡待办的关联

    /// 把健康侧数值与本地三类打卡待办放在一起看：
    /// 让人知道「今天已经走了 8000 步」时，手动打卡就有了真实依据。
    private var todoCorrelationSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("与本地打卡的关系")
                .font(.subheadline.bold())
                .foregroundStyle(AppColor.text)

            ForEach(HealthRelatedTodoType.allCases, id: \.self) { todoType in
                if let progress = HealthMetrics.progress(for: todoType, snapshot: health.snapshot!, goals: goals) {
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: icon(for: todoType))
                            .foregroundStyle(AppColor.info)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(todoType.displayName)
                                .font(.subheadline)
                            Text(HealthMetrics.summary(for: progress))
                                .font(.caption)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        Spacer()
                    }
                    .padding(.vertical, AppSpacing.xs)
                }
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private func icon(for todoType: HealthRelatedTodoType) -> String {
        switch todoType {
        case .exercise: return "figure.run"
        case .hydration: return "drop.fill"
        case .medication: return "pills.fill"
        }
    }
}
