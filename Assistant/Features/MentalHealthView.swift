import AssistantCore
import Charts
import SwiftData
import SwiftUI

/// 心理健康主页：情绪微记录入口 + 量表测评入口 + 趋势 + 最近解读。
///
/// ## 设计纪律
///
/// - **不打扰**：低分档用户进来只看到「已记录」，不推送任何干预。
/// - **量表分是筛查分不是诊断**：UI 措辞一律走「症状强度」，不出现疾病名。
/// - **只给一个主动作**：结果页的核心建议区只放一个，其余收进「还可以试试」。
struct MentalHealthView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \MoodCheckInRecord.day, order: .reverse)
    private var moodCheckIns: [MoodCheckInRecord]

    @Query(sort: \PsychScaleRecord.completedAt, order: .reverse)
    private var scaleRecords: [PsychScaleRecord]

    @Query
    private var todos: [TodoItem]

    @Query
    private var expenses: [ExpenseRecord]

    @State private var showScalePicker = false
    @State private var showMoodCheckIn = false
    /// 导出面板。
    @State private var showExport = false
    /// 分享日签面板。
    @State private var showShareSheet = false
    /// 最近一次已加入待办的动作标题，用于按钮反馈。
    @State private var addedTodoTitle: String?
    /// 用户选中的量表。变化时打开答题页。
    @State private var selectedScale: PsychScaleID?
    /// 页面入场与进度条生长动画触发标记。
    @State private var hasAppeared = false
    /// 情绪趋势卡周期（7 = 近7天，14 = 近14天，30 = 近30天）。
    @State private var selectedTrendPeriod = 7
    /// 情绪趋势卡中点击选中的单日记录日期。
    @State private var selectedTrendDay: Date?
    /// 每日心情保存完成时的微动效载荷。
    @State private var activeMoodMotion: MoodCheckInMotionData?

    private var healthKit = HealthKitService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.lg) {
                dailyCheckInCard
                companionEchoCardSection
                scaleEntryCard
                if let insight = latestInsight {
                    insightCard(insight)
                    if let combined = insight.combinedReading {
                        combinedReadingCard(combined)
                    }
                }
                // 分数趋势：两条量表各一张折线卡。
                ForEach(availableTrendScales, id: \.self) { scaleID in
                    PsychTrendChartCard(scaleID: scaleID, points: trendPoints(for: scaleID))
                }
                if !moodCheckIns.isEmpty {
                    moodTrendCard
                }
                exportCard
                reminderSettingsCard
            }
            .padding(AppSpacing.lg)
        }
        .themedAppBackground()
        .navigationTitle(L10n.tr("心理状态"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptic.light()
                    showShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(L10n.tr("分享心理状态卡片"))
            }
        }
        .onAppear {
            withAnimation(AppMotion.standardSpring) {
                hasAppeared = true
            }
        }
        .overlay {
            MoodCheckInMotionOverlay(motionData: $activeMoodMotion)
        }
        .sheet(isPresented: $showShareSheet) {
            PsychShareSheet(
                date: .now,
                todayMood: todayCheckIn.map { MoodCheckInEntry(day: $0.day, moodScore: $0.moodScore, energyScore: $0.energyScore, stressScore: $0.stressScore) },
                moodEntries: PsychDataAdapter.moodEntries(from: moodCheckIns),
                scaleScores: PsychDataAdapter.scaleScores(from: scaleRecords),
                insight: latestInsight,
                physiology: healthKit.pleasureEvaluation
            )
        }
        .sheet(isPresented: $showMoodCheckIn) {
            MoodCheckInSheet(initialRecord: todayCheckIn) { moodValue, energyValue, stressValue in
                withAnimation(AppMotion.standardSpring) {
                    activeMoodMotion = MoodCheckInMotionData(
                        mood: moodValue,
                        energy: energyValue,
                        stress: stressValue
                    )
                }
            }
        }
        .sheet(isPresented: $showScalePicker) {
            PsychScalePickerSheet(selectedScale: $selectedScale)
        }
        .sheet(isPresented: $showExport) {
            PsychExportSheet()
        }
        // 用户在选择弹窗里选定量表后，展开答题页。
        .sheet(item: $selectedScale) { scaleID in
            NavigationStack {
                PsychScaleTestView(scaleID: scaleID)
            }
        }
    }

    // MARK: - 趋势折线

    /// 有历史数据的量表（按量表顺序）。
    private var availableTrendScales: [PsychScaleID] {
        PsychScaleID.allCases.filter { scaleID in
            !trendPoints(for: scaleID).isEmpty
        }
    }

    /// 某量表的得分点序列（按时间升序）。
    ///
    /// **只含算得出分数的记录**——数据不足的记录不进序列，
    /// 否则会把「算不出分」误画成「分数低」。
    private func trendPoints(for scaleID: PsychScaleID) -> [PsychTrendChartCard.Point] {
        scaleRecords
            .filter { $0.scaleID == scaleID }
            .compactMap { record in
                let score = record.score()
                guard let total = score.totalScore, let band = score.band else { return nil }
                return PsychTrendChartCard.Point(
                    id: record.id,
                    completedAt: record.completedAt,
                    totalScore: total,
                    band: band
                )
            }
            .sorted { $0.completedAt < $1.completedAt }
    }

    // MARK: - 提醒设置

    private var reminderSettingsCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .fill(AppColor.softFill(AppColor.warning))
                        .frame(width: 38, height: 38)
                    Image(systemName: reminderScheduler.isEnabled ? "bell.badge.fill" : "bell.badge")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColor.warning)
                        .scaleEffect(reminderScheduler.isEnabled ? 1.05 : 1.0)
                        .responsiveAnimation(AppMotion.standardSpring, value: reminderScheduler.isEnabled)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("提醒"))
                        .font(.headline)
                        .foregroundStyle(AppColor.text)
                    Text(L10n.tr("默认关闭。开启后也只在需要时出声 —— 状态良好时不会打扰你。"))
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Divider().opacity(0.45)

            Toggle(L10n.tr("开启心理状态提醒"), isOn: reminderBinding)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppColor.text)
                .tint(AppColor.warning)

            if reminderScheduler.isEnabled {
                VStack(spacing: AppSpacing.sm) {
                    Toggle(L10n.tr("每周提醒我做一次评估"), isOn: assessmentToggleBinding)
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                        .tint(AppColor.primary)
                    Toggle(L10n.tr("状态连续变差时主动关心我"), isOn: trendToggleBinding)
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                        .tint(AppColor.primary)
                }
                .padding(AppSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                        .fill(AppColor.fillTertiary)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private var reminderScheduler: PsychReminderScheduler { .shared }

    /// 总开关。变更后立即重排通知。
    private var reminderBinding: Binding<Bool> {
        Binding(
            get: { reminderScheduler.isEnabled },
            set: { newValue in
                Haptic.selection()
                withAnimation(AppMotion.standardSpring) {
                    reminderScheduler.isEnabled = newValue
                }
                if !newValue {
                    reminderScheduler.resetNotificationState()
                }
                reminderScheduler.rescheduleNotifications(context: context)
            }
        )
    }

    private var assessmentToggleBinding: Binding<Bool> {
        Binding(
            get: { reminderScheduler.isAssessmentReminderEnabled },
            set: { newValue in
                Haptic.selection()
                reminderScheduler.isAssessmentReminderEnabled = newValue
                reminderScheduler.rescheduleNotifications(context: context)
            }
        )
    }

    private var trendToggleBinding: Binding<Bool> {
        Binding(
            get: { reminderScheduler.isTrendReminderEnabled },
            set: { newValue in
                Haptic.selection()
                reminderScheduler.isTrendReminderEnabled = newValue
                reminderScheduler.rescheduleNotifications(context: context)
            }
        )
    }

    // MARK: - 每日微记录

    private var dailyCheckInCard: some View {
        Button {
            Haptic.light()
            showMoodCheckIn = true
        } label: {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                HStack(spacing: AppSpacing.md) {
                    MoodAuraOrbView(
                        moodScore: todayCheckIn?.moodScore,
                        diameter: 48
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: AppSpacing.xs) {
                            Text(L10n.tr("今日心情"))
                                .font(.headline)
                                .foregroundStyle(AppColor.text)

                            if todayCheckIn != nil {
                                Text(L10n.tr("已记录"))
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(AppColor.softFill(AppColor.success), in: Capsule())
                                    .foregroundStyle(AppColor.success)
                            }
                        }

                        Text(todayCheckIn == nil
                             ? "三个问题，10 秒。记下来才能看出趋势"
                             : "已记录 · 心情 \(todayCheckIn!.moodScore) / 精力 \(todayCheckIn!.energyScore) / 压力 \(todayCheckIn!.stressScore)")
                            .font(.caption)
                            .foregroundStyle(AppColor.secondaryText)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 3) {
                        if todayCheckIn != nil {
                            Text(L10n.tr("修改"))
                                .font(.caption2)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }

                if let record = todayCheckIn {
                    // 三维指标胶囊与动态生长进度条
                    HStack(spacing: AppSpacing.sm) {
                        dailyMetricTile(
                            title: L10n.tr("心情"),
                            score: record.moodScore,
                            descriptor: moodDescriptor(record.moodScore),
                            icon: moodIconName(record.moodScore),
                            tint: AppColor.primary
                        )
                        dailyMetricTile(
                            title: L10n.tr("精力"),
                            score: record.energyScore,
                            descriptor: energyDescriptor(record.energyScore),
                            icon: "bolt.fill",
                            tint: AppColor.success
                        )
                        dailyMetricTile(
                            title: L10n.tr("压力"),
                            score: record.stressScore,
                            descriptor: stressDescriptor(record.stressScore),
                            icon: "wind",
                            tint: stressTint(record.stressScore)
                        )
                    }

                    if let note = record.note, !note.isEmpty {
                        HStack(alignment: .top, spacing: AppSpacing.xs) {
                            Image(systemName: "quote.opening")
                                .font(.caption2)
                                .foregroundStyle(AppColor.primary.opacity(0.75))
                                .padding(.top, 2)
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(AppColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                                .fill(AppColor.fillTertiary)
                        )
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.semibold))
                        Text(L10n.tr("记录一下"))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(L10n.tr("10 秒完成"))
                            .font(.caption2)
                            .foregroundStyle(AppColor.primary.opacity(0.8))
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.subheadline)
                    }
                    .foregroundStyle(AppColor.primary)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .fill(AppColor.softFill(AppColor.primary))
                    )
                }
            }
            .padding(AppSpacing.md)
            .appCard()
        }
        .buttonStyle(.plain)
    }

    private func dailyMetricTile(
        title: String,
        score: Int,
        descriptor: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
                Spacer(minLength: 0)
                Text("\(score)/5")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            }

            // 5 段式微缩胶囊进度条（随 hasAppeared 与分数更新平滑过渡）
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { step in
                    Capsule()
                        .fill(step <= (hasAppeared ? score : 0) ? tint : tint.opacity(0.16))
                        .frame(height: 4)
                }
            }
            .responsiveAnimation(AppMotion.standardSpring, value: score)
            .responsiveAnimation(AppMotion.standardSpring, value: hasAppeared)

            Text(descriptor)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppColor.text.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                .fill(AppColor.softFill(tint, opacity: 0.08))
        )
    }

    private func moodIconName(_ score: Int) -> String {
        switch score {
        case 5: return "sun.max.fill"
        case 4: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 2: return "cloud.drizzle.fill"
        default: return "cloud.rain.fill"
        }
    }

    private func moodDescriptor(_ score: Int) -> String {
        switch score {
        case 5: return L10n.tr("很轻快")
        case 4: return L10n.tr("较轻快")
        case 3: return L10n.tr("平稳")
        case 2: return L10n.tr("偏低落")
        default: return L10n.tr("很低落")
        }
    }

    private func energyDescriptor(_ score: Int) -> String {
        switch score {
        case 5: return L10n.tr("精力充沛")
        case 4: return L10n.tr("状态不错")
        case 3: return L10n.tr("正常")
        case 2: return L10n.tr("略疲惫")
        default: return L10n.tr("很疲惫")
        }
    }

    private func stressDescriptor(_ score: Int) -> String {
        switch score {
        case 1: return L10n.tr("很放松")
        case 2: return L10n.tr("压力温和")
        case 3: return L10n.tr("中等压力")
        case 4: return L10n.tr("压力偏高")
        default: return L10n.tr("压力极大")
        }
    }

    private func stressTint(_ score: Int) -> Color {
        switch score {
        case 1, 2: return AppColor.info
        case 3: return AppColor.warning
        default: return AppColor.danger
        }
    }

    private var todayCheckIn: MoodCheckInRecord? {
        let today = Calendar.current.startOfDay(for: .now)
        return moodCheckIns.first { $0.day == today }
    }

    // MARK: - 拟真社交搭子与群体共鸣

    private var companionEchoCardSection: some View {
        CompanionEchoCard(
            moodRecord: todayCheckIn,
            completedTodosCount: completedTodosTodayCount,
            pendingTodosCount: pendingTodosCount,
            todayExpenseAmount: todayExpenseAmount
        )
    }

    private var completedTodosTodayCount: Int {
        let calendar = Calendar.current
        return todos.filter { $0.status == .done && ($0.completedAt.map { calendar.isDateInToday($0) } ?? false) }.count
    }

    private var pendingTodosCount: Int {
        todos.filter { $0.status == .active }.count
    }

    private var todayExpenseAmount: Double {
        let calendar = Calendar.current
        return expenses.filter { !$0.isIncome && calendar.isDateInToday($0.date) }.reduce(0) { $0 + $1.amount }
    }

    // MARK: - 量表入口

    private var scaleEntryCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Button {
                Haptic.light()
                showScalePicker = true
            } label: {
                HStack(spacing: AppSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .fill(AppColor.softFill(AppColor.feature))
                            .frame(width: 40, height: 40)
                        Image(systemName: "checklist")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppColor.feature)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("状态评估"))
                            .font(.headline)
                            .foregroundStyle(AppColor.text)
                        Text(L10n.tr("PHQ-9 / GAD-7 · 过去两周 · 约 2 分钟"))
                            .font(.caption)
                            .foregroundStyle(AppColor.secondaryText)
                    }

                    Spacer(minLength: 0)

                    // 两个分支都要走 L10n——三元表达式里的字面量不会自动被本地化。
                    Text(scaleRecords.isEmpty ? L10n.tr("开始第一次评估") : L10n.tr("再评一次"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColor.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AppColor.softFill(AppColor.primary), in: Capsule())
                }
            }
            .buttonStyle(.plain)

            // 两个量表的快捷卡片入口：可直接点击进入对应量表，并直观显示最近一次评估状态
            HStack(spacing: AppSpacing.sm) {
                scaleQuickTile(
                    scaleID: .phq9,
                    subtitle: L10n.tr("情绪与精力 · 9 题"),
                    icon: "heart.text.square.fill"
                )
                scaleQuickTile(
                    scaleID: .gad7,
                    subtitle: L10n.tr("紧张与放松 · 7 题"),
                    icon: "waveform.path.ecg"
                )
            }

            Text(L10n.tr("评估结果是筛查参考，不构成医学诊断。"))
                .font(.caption2)
                .foregroundStyle(AppColor.secondaryText)
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private func scaleQuickTile(
        scaleID: PsychScaleID,
        subtitle: String,
        icon: String
    ) -> some View {
        let latest = scaleRecords.first { $0.scaleID == scaleID }
        let latestScore = latest?.score()
        return Button {
            Haptic.selection()
            selectedScale = scaleID
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(AppColor.feature)
                    Text(scaleID.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColor.text)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppColor.secondaryText)
                }

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
                    .lineLimit(1)

                if let total = latestScore?.totalScore, let band = latestScore?.band {
                    HStack(spacing: 4) {
                        Text("\(total) 分")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(bandColor(band))
                        Text("· \(band.displayName)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(bandColor(band))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppColor.softFill(bandColor(band)), in: Capsule())
                } else {
                    Text(L10n.tr("尚未评估"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppColor.secondaryText.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppColor.fillTertiary, in: Capsule())
                }
            }
            .padding(AppSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(AppColor.fillTertiary.opacity(0.65))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 最近解读

    /// 用最近一次量表记录 + 生理通道构建解读。
    private var latestInsight: MentalHealthInsight? {
        guard !scaleRecords.isEmpty else { return nil }
        // 转换集中在 `PsychDataAdapter`——主页、结果页、导出三处用同一份规则，
        // 避免「各算各的」导致同一份数据在三个地方读出不同结论。
        let scores = PsychDataAdapter.scaleScores(from: Array(scaleRecords.prefix(4)))
        let moods = PsychDataAdapter.moodEntries(from: moodCheckIns)
        return MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: scores,
                physiology: healthKit.pleasureEvaluation,
                recentAverageSleepHours: recentAverageSleep,
                moodEntries: moods,
                now: .now,
                calendar: .current
            )
        )
    }

    /// 近 7 天平均睡眠时长。读不到时返回 nil（不当 0）。
    ///
    /// 实现收敛在 `PsychDataAdapter`——主页/结果页/导出三处曾各写一份。
    private var recentAverageSleep: Double? {
        PsychDataAdapter.recentAverageSleepHours(context: context)
    }

    private func insightCard(_ insight: MentalHealthInsight) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Text(L10n.tr("最近解读"))
                    .font(.headline)
                    .foregroundStyle(AppColor.text)
                Spacer()
                if let band = insight.band {
                    Text(band.displayName)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(AppColor.softFill(bandColor(band)), in: Capsule())
                        .foregroundStyle(bandColor(band))
                }
            }

            Text(insight.headline)
                .font(.subheadline)
                .foregroundStyle(AppColor.text)
                .fixedSize(horizontal: false, vertical: true)

            // 只给一个主动作。
            if let action = insight.primaryAction {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("现在，做一件小事"))
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                    Text(PsychReliefCopy.title(for: action))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColor.text)
                    Text(PsychReliefCopy.detail(for: action))
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if action.isConvertibleToTodo {
                        Button {
                            addTodo(for: action)
                        } label: {
                            Label(addedTodoTitle == action.title ? "已加入待办" : "加入待办",
                                  systemImage: addedTodoTitle == action.title ? "checkmark.circle.fill" : "plus.circle")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(addedTodoTitle == action.title ? AppColor.success : AppColor.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(AppSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .fill(AppColor.softFill(AppColor.primary))
                )
            }

            // 备选动作收在后面，不与主动作并列。
            if !insight.secondaryActions.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        ForEach(insight.secondaryActions, id: \.self) { action in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PsychReliefCopy.title(for: action))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(AppColor.text)
                                Text(PsychReliefCopy.detail(for: action))
                                    .font(.caption2)
                                    .foregroundStyle(AppColor.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, AppSpacing.sm)
                } label: {
                    Text(L10n.tr("还可以试试"))
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
                .tint(AppColor.secondaryText)
            }

            if insight.recommendsProfessionalCare {
                Divider()
                Text(L10n.tr("这些方法有它的边界。建议找专业的人聊聊 —— 那会更快，也更稳。"))
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private func bandColor(_ band: PsychBandLevel) -> Color {
        switch band {
        case .none: return AppColor.success
        case .mild: return AppColor.info
        case .moderate: return AppColor.warning
        case .moderatelySevere, .severe: return AppColor.danger
        }
    }

    // MARK: - 三通道合并解读

    /// 三通道对照卡。
    ///
    /// 实现放在共享组件 `PsychCombinedReadingCard`——结果页也要展示同一张卡，
    /// 复制两份必然漂移（主页说「在恶化」、结果页说「平稳」会让用户以为数据对不上）。
    private func combinedReadingCard(_ reading: MentalHealthCombinedReading) -> some View {
        PsychCombinedReadingCard(reading: reading)
    }

    // MARK: - 导出入口

    /// 导出卡片。
    ///
    /// 入口放在主页而不是藏在设置里——「想让外部模型看看」是一个真实且常见的诉求，
    /// 但它必须**由用户主动发起**，App 绝不自动上传。
    private var exportCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
                    .foregroundStyle(AppColor.info)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("交给其他模型解读"))
                        .font(.headline)
                        .foregroundStyle(AppColor.text)
                    Text(L10n.tr("把量表与日常记录导出成文字，交给更强的大模型看。内容会附上「不做诊断」的要求。"))
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            Button {
                showExport = true
            } label: {
                Text(L10n.tr("导出记录"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppColor.info)
            }
            .buttonStyle(.plain)
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    /// 把疏解动作落成一条真待办（能提醒、能打卡）。
    ///
    /// 建议不落成可执行动作 = 没做，所以这里直接落库，
    /// 而不是弹一个还要用户再填一遍标题的表单。
    private func addTodo(for action: PsychReliefAction) {
        // 建议时间：30 分钟后，给用户一个「现在就能做」的时间点。
        let dueAt = Date().addingTimeInterval(30 * 60)
        if PsychReliefTodoBuilder.createTodo(for: action, dueAt: dueAt, in: context) != nil {
            withAnimation(AppMotion.standardSpring) {
                addedTodoTitle = action.title
            }
        }
    }

    // MARK: - 情绪趋势与身心共鸣（Emotional Expression）

    private var moodTrendCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            // 标题与周期选择（近 7 天 / 近 14 天 / 近 30 天）
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("最近心情与情绪共鸣"))
                        .font(.headline)
                        .foregroundStyle(AppColor.text)
                    Text(L10n.tr("心情 · 精力 · 压力三线同频感知"))
                        .font(.caption2)
                        .foregroundStyle(AppColor.secondaryText)
                }
                Spacer()
                Picker(L10n.tr("周期"), selection: $selectedTrendPeriod) {
                    Text(L10n.tr("7天")).tag(7)
                    Text(L10n.tr("14天")).tag(14)
                    Text(L10n.tr("30天")).tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            let periodRecords = Array(moodCheckIns.prefix(selectedTrendPeriod).reversed())
            if !periodRecords.isEmpty {
                // 图例说明条与单日触控悬浮详情
                if let selectedRecord = selectedMoodPointRecord(in: periodRecords) {
                    selectedMoodPointHeader(selectedRecord)
                } else {
                    moodLegendAndSummaryHeader(records: periodRecords)
                }

                // 三维情绪共振流光折线图（Charts）
                Chart {
                    ForEach(periodRecords, id: \.id) { record in
                        // 1. 心情线（晨曦蓝 · 饱满生动）
                        LineMark(
                            x: .value(L10n.tr("日期"), record.day),
                            y: .value(L10n.tr("心情"), record.moodScore),
                            series: .value(L10n.tr("维度"), L10n.tr("心情"))
                        )
                        .foregroundStyle(Color(red: 0.20, green: 0.55, blue: 0.95))
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)

                        PointMark(
                            x: .value(L10n.tr("日期"), record.day),
                            y: .value(L10n.tr("心情"), record.moodScore)
                        )
                        .foregroundStyle(Color(red: 0.20, green: 0.55, blue: 0.95))
                        .symbolSize(selectedTrendDay == record.day ? 54 : 22)

                        // 2. 精力线（生机绿 · 平滑柔和）
                        LineMark(
                            x: .value(L10n.tr("日期"), record.day),
                            y: .value(L10n.tr("精力"), record.energyScore),
                            series: .value(L10n.tr("维度"), L10n.tr("精力"))
                        )
                        .foregroundStyle(Color(red: 0.15, green: 0.72, blue: 0.45))
                        .lineStyle(StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)

                        PointMark(
                            x: .value(L10n.tr("日期"), record.day),
                            y: .value(L10n.tr("精力"), record.energyScore)
                        )
                        .foregroundStyle(Color(red: 0.15, green: 0.72, blue: 0.45))
                        .symbolSize(selectedTrendDay == record.day ? 48 : 18)

                        // 3. 压力线（暖橙红 · 虚线张力感）
                        LineMark(
                            x: .value(L10n.tr("日期"), record.day),
                            y: .value(L10n.tr("压力"), record.stressScore),
                            series: .value(L10n.tr("维度"), L10n.tr("压力"))
                        )
                        .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.20))
                        .lineStyle(StrokeStyle(lineWidth: 2.0, lineCap: .round, dash: [4, 3]))
                        .interpolationMethod(.catmullRom)

                        PointMark(
                            x: .value(L10n.tr("日期"), record.day),
                            y: .value(L10n.tr("压力"), record.stressScore)
                        )
                        .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.20))
                        .symbolSize(selectedTrendDay == record.day ? 48 : 18)

                        // 选中日参考竖线
                        if selectedTrendDay == record.day {
                            RuleMark(x: .value(L10n.tr("选中日"), record.day))
                                .foregroundStyle(AppColor.primary.opacity(0.35))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        }
                    }
                }
                .chartYScale(domain: 1...5)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [1, 2, 3, 4, 5]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                            .foregroundStyle(Color.secondary.opacity(0.2))
                        AxisValueLabel {
                            if let score = value.as(Int.self) {
                                Text("\(score)")
                                    .font(.system(size: 8))
                                    .foregroundStyle(AppColor.secondaryText)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: selectedTrendPeriod == 7 ? 7 : (selectedTrendPeriod == 14 ? 6 : 5))) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(shortDayString(date))
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(AppColor.secondaryText)
                            }
                        }
                    }
                }
                .frame(height: 140)
                .padding(.vertical, 4)

                // 交互点击单日气泡选择器（下方滑动触控卡片）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(periodRecords, id: \.id) { record in
                            let isSelected = selectedTrendDay == record.day
                            Button {
                                Haptic.selection()
                                withAnimation(AppMotion.standardSpring) {
                                    if selectedTrendDay == record.day {
                                        selectedTrendDay = nil
                                    } else {
                                        selectedTrendDay = record.day
                                    }
                                }
                            } label: {
                                VStack(spacing: 4) {
                                    Text(shortDayString(record.day))
                                        .font(.system(size: 9, weight: isSelected ? .bold : .regular))
                                        .foregroundStyle(isSelected ? AppColor.primary : AppColor.secondaryText)

                                    MoodAuraOrbView(moodScore: record.moodScore, diameter: 26)

                                    HStack(spacing: 2) {
                                        Text("\(record.moodScore)")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(Color(red: 0.20, green: 0.55, blue: 0.95))
                                        Text("/")
                                            .font(.system(size: 7))
                                            .foregroundStyle(AppColor.secondaryText.opacity(0.5))
                                        Text("\(record.stressScore)")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.20))
                                    }
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                                        .fill(isSelected ? AppColor.softFill(AppColor.primary, opacity: 0.15) : AppColor.fillTertiary.opacity(0.5))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                                        .strokeBorder(isSelected ? AppColor.primary.opacity(0.5) : Color.clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    Text(L10n.tr("横轴按日连续展开 · 1分低/疲/松 ~ 5分高/充/压"))
                        .font(.caption2)
                        .foregroundStyle(AppColor.secondaryText)
                    Spacer()
                    Text(L10n.tr("点击下方胶囊可高亮单日"))
                        .font(.system(size: 10))
                        .foregroundStyle(AppColor.secondaryText.opacity(0.7))
                }
            } else {
                Text(L10n.tr("暂无情绪记录，每日完成 10 秒微记录后将自动绘制三维共振图。"))
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
                    .padding(.vertical, AppSpacing.md)
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private func moodLegendAndSummaryHeader(records: [MoodCheckInRecord]) -> some View {
        HStack(spacing: AppSpacing.md) {
            legendPill(title: L10n.tr("心情"), color: Color(red: 0.20, green: 0.55, blue: 0.95), isDashed: false)
            legendPill(title: L10n.tr("精力"), color: Color(red: 0.15, green: 0.72, blue: 0.45), isDashed: false)
            legendPill(title: L10n.tr("压力"), color: Color(red: 0.95, green: 0.45, blue: 0.20), isDashed: true)
            Spacer()
            if let avgMood = calculateAverageMood(records) {
                Text("均值 \(String(format: "%.1f", avgMood))")
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(AppColor.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppColor.softFill(AppColor.primary), in: Capsule())
            }
        }
    }

    private func legendPill(title: String, color: Color, isDashed: Bool) -> some View {
        HStack(spacing: 4) {
            if isDashed {
                HStack(spacing: 2) {
                    Circle().fill(color).frame(width: 3.5, height: 3.5)
                    Circle().fill(color).frame(width: 3.5, height: 3.5)
                }
            } else {
                RoundedRectangle(cornerRadius: AppRadius.hairline)
                    .fill(color)
                    .frame(width: 12, height: 3)
            }
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AppColor.text)
        }
    }

    private func calculateAverageMood(_ records: [MoodCheckInRecord]) -> Double? {
        guard !records.isEmpty else { return nil }
        return Double(records.map(\.moodScore).reduce(0, +)) / Double(records.count)
    }

    private func selectedMoodPointRecord(in records: [MoodCheckInRecord]) -> MoodCheckInRecord? {
        guard let day = selectedTrendDay else { return nil }
        return records.first { $0.day == day }
    }

    private func selectedMoodPointHeader(_ record: MoodCheckInRecord) -> some View {
        HStack(spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(fullDayString(record.day))
                        .font(.caption.bold())
                        .foregroundStyle(AppColor.text)
                    Text("心情 \(record.moodScore) / 精力 \(record.energyScore) / 压力 \(record.stressScore)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppColor.secondaryText)
                }
                if let note = record.note, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(AppColor.primary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                Haptic.selection()
                withAnimation(AppMotion.standardSpring) {
                    selectedTrendDay = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(AppSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                .fill(AppColor.fillTertiary)
        )
    }

    private func shortDayString(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L10n.tr("今天") }
        let comps = cal.dateComponents([.day], from: date)
        return "\(comps.day ?? 0)日"
    }

    private func fullDayString(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L10n.tr("今天") }
        let comps = cal.dateComponents([.month, .day], from: date)
        return "\(comps.month ?? 0)月\(comps.day ?? 0)日"
    }
}

// MARK: - 每日心情记录弹窗

/// 每日微记录表单。三题，带灵动表情、触感与保存动效。
struct MoodCheckInSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var initialRecord: MoodCheckInRecord?
    var onSaved: ((Int, Int, Int) -> Void)?

    @State private var mood: Int
    @State private var energy: Int
    @State private var stress: Int
    @State private var note: String

    init(
        initialRecord: MoodCheckInRecord? = nil,
        onSaved: ((Int, Int, Int) -> Void)? = nil
    ) {
        self.initialRecord = initialRecord
        self.onSaved = onSaved
        _mood = State(initialValue: initialRecord?.moodScore ?? 3)
        _energy = State(initialValue: initialRecord?.energyScore ?? 3)
        _stress = State(initialValue: initialRecord?.stressScore ?? 2)
        _note = State(initialValue: initialRecord?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    // 顶部呼吸感光环与当前心情动效
                    VStack(spacing: AppSpacing.sm) {
                        MoodAuraOrbView(moodScore: mood, diameter: 72)

                        Text(moodSheetDescriptor(mood))
                            .font(.title3.bold())
                            .foregroundStyle(AppColor.text)
                            .contentTransition(.numericText())

                        Text(L10n.tr("每天花 10 秒，捕捉此刻最真实的身心信号"))
                            .font(.caption)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                    .padding(.top, AppSpacing.sm)

                    interactiveSliderCard(
                        title: L10n.tr("心情"),
                        value: $mood,
                        rangeLabels: [L10n.tr("低落"), L10n.tr("偏低"), L10n.tr("平稳"), L10n.tr("愉悦"), L10n.tr("轻快")],
                        icon: "face.smiling",
                        tint: AppColor.primary
                    )

                    interactiveSliderCard(
                        title: L10n.tr("精力"),
                        value: $energy,
                        rangeLabels: [L10n.tr("耗尽"), L10n.tr("疲劳"), L10n.tr("尚可"), L10n.tr("饱满"), L10n.tr("充沛")],
                        icon: "bolt.fill",
                        tint: AppColor.success
                    )

                    interactiveSliderCard(
                        title: L10n.tr("压力"),
                        value: $stress,
                        rangeLabels: [L10n.tr("无压"), L10n.tr("轻松"), L10n.tr("可控"), L10n.tr("偏大"), L10n.tr("极大")],
                        icon: "wind",
                        tint: stressCardTint(stress)
                    )

                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text(L10n.tr("想补充一句（可选）"))
                            .font(.caption)
                            .foregroundStyle(AppColor.secondaryText)
                        TextField("此刻最强烈的感觉是什么", text: $note, axis: .vertical)
                            .lineLimit(2...4)
                            .font(.subheadline)
                            .textFieldStyle(.plain)
                            .padding(AppSpacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                                    .fill(AppColor.fillTertiary)
                            )
                    }
                }
                .padding(AppSpacing.lg)
            }
            .navigationTitle(L10n.tr("今日心情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("保存")) {
                        Haptic.success()
                        PsychRecordStore.saveMoodCheckIn(
                            day: .now,
                            mood: mood,
                            energy: energy,
                            stress: stress,
                            note: note.isEmpty ? nil : note,
                            in: context
                        )
                        onSaved?(mood, energy, stress)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func interactiveSliderCard(
        title: String,
        value: Binding<Int>,
        rangeLabels: [String],
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColor.text)
                Spacer()
                Text("\(value.wrappedValue) / 5 · \(rangeLabels[max(0, min(value.wrappedValue - 1, rangeLabels.count - 1))])")
                    .font(.subheadline.bold())
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            }

            // 5 格分段触摸/点击条，手感比标准 Slider 更明确
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { step in
                    Button {
                        Haptic.selection()
                        withAnimation(AppMotion.standardSpring) {
                            value.wrappedValue = step
                        }
                    } label: {
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                .fill(step <= value.wrappedValue ? tint : tint.opacity(0.16))
                                .frame(height: 28)
                                .overlay(
                                    Text("\(step)")
                                        .font(.caption.bold())
                                        .foregroundStyle(step <= value.wrappedValue ? Color.white : tint)
                                )

                            Text(rangeLabels[step - 1])
                                .font(.system(size: 9))
                                .foregroundStyle(step == value.wrappedValue ? tint : AppColor.secondaryText)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private func moodSheetDescriptor(_ score: Int) -> String {
        switch score {
        case 5: return L10n.tr("阳光明媚 · 状态极佳")
        case 4: return L10n.tr("温和平稳 · 心情愉悦")
        case 3: return L10n.tr("波澜不惊 · 处于常态")
        case 2: return L10n.tr("偶有阴霾 · 稍显疲态")
        default: return L10n.tr("心事重重 · 抱抱自己")
        }
    }

    private func stressCardTint(_ score: Int) -> Color {
        switch score {
        case 1, 2: return AppColor.info
        case 3: return AppColor.warning
        default: return AppColor.danger
        }
    }
}

// MARK: - 情绪呼吸感微动效光环

/// 动态呼吸感渐变光晕与表情小球，随心情分数动态平滑渐变与缩放
public struct MoodAuraOrbView: View {
    public var moodScore: Int?
    public var diameter: CGFloat = 48

    @State private var isBreathing = false

    public init(moodScore: Int?, diameter: CGFloat = 48) {
        self.moodScore = moodScore
        self.diameter = diameter
    }

    private var score: Int {
        moodScore ?? 3
    }

    private var palette: [Color] {
        switch score {
        case 5:
            return [Color(red: 1.0, green: 0.76, blue: 0.28), Color(red: 0.98, green: 0.52, blue: 0.25)]
        case 4:
            return [Color(red: 0.38, green: 0.82, blue: 0.65), Color(red: 0.25, green: 0.68, blue: 0.85)]
        case 3:
            return [Color(red: 0.35, green: 0.65, blue: 0.95), Color(red: 0.45, green: 0.55, blue: 0.90)]
        case 2:
            return [Color(red: 0.55, green: 0.50, blue: 0.85), Color(red: 0.42, green: 0.38, blue: 0.75)]
        default:
            return [Color(red: 0.45, green: 0.48, blue: 0.60), Color(red: 0.35, green: 0.38, blue: 0.52)]
        }
    }

    private var iconName: String {
        guard moodScore != nil else { return "sparkles" }
        switch score {
        case 5: return "sun.max.fill"
        case 4: return "face.smiling.fill"
        case 3: return "circle.circle.fill"
        case 2: return "cloud.drizzle.fill"
        default: return "heart.fill"
        }
    }

    public var body: some View {
        ZStack {
            // 呼吸光晕外环
            Circle()
                .fill(
                    RadialGradient(
                        colors: [palette[0].opacity(0.35), palette[1].opacity(0.0)],
                        center: .center,
                        startRadius: diameter * 0.2,
                        endRadius: diameter * 0.65
                    )
                )
                .frame(width: diameter * 1.35, height: diameter * 1.35)
                .scaleEffect(isBreathing ? 1.08 : 0.96)
                .opacity(isBreathing ? 0.9 : 0.6)

            // 主渐变球体
            Circle()
                .fill(
                    LinearGradient(
                        colors: palette,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: diameter, height: diameter)
                .shadow(color: palette[0].opacity(0.32), radius: 6, y: 3)

            // 内部图标
            Image(systemName: iconName)
                .font(.system(size: diameter * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: Color.black.opacity(0.2), radius: 2, y: 1)
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            if !AppMotion.reduceMotion {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    isBreathing = true
                }
            }
        }
    }
}

// MARK: - 每日心情打卡动效模型与全屏微动效浮层

/// 心情记录保存后的动效模型
public struct MoodCheckInMotionData: Equatable {
    public var id = UUID()
    public var mood: Int
    public var energy: Int
    public var stress: Int

    public init(mood: Int, energy: Int, stress: Int) {
        self.mood = mood
        self.energy = energy
        self.stress = stress
    }
}

/// 心情打卡全屏交互微动效覆盖层（非阻塞，浮现呼吸光晕与成就胶囊）
public struct MoodCheckInMotionOverlay: View {
    @Binding var motionData: MoodCheckInMotionData?

    public init(motionData: Binding<MoodCheckInMotionData?>) {
        self._motionData = motionData
    }

    public var body: some View {
        ZStack {
            if let active = motionData {
                MoodCelebrationBadgeView(data: active) {
                    dismiss()
                }
                .id(active.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func dismiss() {
        withAnimation(AppMotion.standardSpring) {
            motionData = nil
        }
    }
}

private struct MoodCelebrationBadgeView: View {
    let data: MoodCheckInMotionData
    let onFinished: () -> Void

    @State private var orbScale: CGFloat = 0.5
    @State private var orbOpacity: Double = 0.0
    @State private var badgeOffset: CGFloat = 40
    @State private var badgeOpacity: Double = 0.0
    @State private var sparkleScale: CGFloat = 0.2
    @State private var sparkleOpacity: Double = 0.0

    var body: some View {
        ZStack {
            // 背景星光扩散
            ForEach(0..<6, id: \.self) { i in
                let angle = Double(i) * (.pi / 3.0)
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.yellow)
                    .offset(
                        x: cos(angle) * (52.0 * sparkleScale),
                        y: sin(angle) * (52.0 * sparkleScale)
                    )
                    .opacity(sparkleOpacity)
            }

            // 中心放大呼吸光球
            MoodAuraOrbView(moodScore: data.mood, diameter: 64)
                .scaleEffect(orbScale)
                .opacity(orbOpacity)

            // 悬浮反馈胶囊条
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColor.success)
                Text(L10n.tr("今日心情已记下"))
                    .font(.caption.bold())
                    .foregroundStyle(AppColor.text)
                Text("· 心情 \(data.mood)/5")
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
                    .overlay(
                        Capsule().strokeBorder(AppColor.primary.opacity(0.2), lineWidth: 1)
                    )
            )
            .offset(y: badgeOffset)
            .opacity(badgeOpacity)
        }
        .onAppear {
            play()
        }
    }

    private func play() {
        if AppMotion.reduceMotion {
            badgeOpacity = 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                onFinished()
            }
            return
        }

        withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) {
            orbScale = 1.0
            orbOpacity = 1.0
            sparkleScale = 1.0
            sparkleOpacity = 0.85
        }

        withAnimation(.spring(response: 0.45, dampingFraction: 0.72).delay(0.1)) {
            badgeOffset = 64
            badgeOpacity = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.35)) {
                badgeOpacity = 0.0
                orbOpacity = 0.0
                sparkleOpacity = 0.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                onFinished()
            }
        }
    }
}
