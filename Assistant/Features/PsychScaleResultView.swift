import AssistantCore
import SwiftData
import SwiftUI

/// 量表结果页：分数解读 + 分档 + **一个**主动作 + 备选 + 求助出口。
///
/// ## 设计纪律
///
/// - **分档是分流，不是诊断**：全页不出现疾病名，只描述症状强度。
/// - **只给一个主动作**：其余收进「还可以试试」。给五个选项等于给零个——
///   选择成本高到一定程度，人会干脆什么都不做。
/// - **数据不足就说数据不足**：不给「你可能有点问题」这种无依据的猜测。
/// - **生理通道无数据时不提生理**：读不到就是读不到，不能拿来当安慰。
struct PsychScaleResultView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let scaleID: PsychScaleID
    let answers: [Int: PsychItemAnswer]

    @State private var addedTodoTitle: String?

    /// 历史量表记录（不含本次），用于判断趋势方向。
    @Query(sort: \PsychScaleRecord.completedAt, order: .reverse)
    private var historyRecords: [PsychScaleRecord]

    /// 每日微记录，用于三通道合并解读。
    @Query(sort: \MoodCheckInRecord.day, order: .reverse)
    private var moodRecords: [MoodCheckInRecord]

    private var definition: PsychScaleDefinition {
        PsychScaleCatalog.definition(for: scaleID)
    }

    /// 本次作答的计分结果。
    ///
    /// **必须带 `completedAt`**——量表回忆窗是「完成时刻往前 14 天」，
    /// 缺了它就判不了「微记录比问卷新还是旧」，
    /// 三通道合并会把「最近好转」误读成「与问卷矛盾」。
    private var score: PsychScaleScore {
        PsychScaleScorer.score(
            answers: answers,
            definition: definition,
            completedAt: .now
        )
    }

    /// 历史量表计分（含本次之前的），按时间倒序。
    private var historyScores: [PsychScaleScore] {
        PsychDataAdapter.scaleScores(from: historyRecords)
    }

    private var insight: MentalHealthInsight {
        // 与主页用**同一份数据、同一个 builder**——
        // 两处各算各的就会出现「主页说在恶化、结果页说平稳」的矛盾。
        MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: [score] + historyScores,
                physiology: HealthKitService.shared.pleasureEvaluation,
                recentAverageSleepHours: recentAverageSleep,
                moodEntries: PsychDataAdapter.moodEntries(from: moodRecords),
                now: .now,
                calendar: .current
            )
        )
    }

    /// 近 7 天平均睡眠。读不到返回 nil（不当 0）。
    ///
    /// 实现收敛在 `PsychDataAdapter`——主页/结果页/导出三处曾各写一份。
    private var recentAverageSleep: Double? {
        PsychDataAdapter.recentAverageSleepHours(context: context)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.lg) {
                scoreCard
                if insight.requiresCrisisResponse {
                    crisisCard
                }
                if insight.dataStatus == .ready {
                    // 三通道对照放在分数卡之后、建议之前——
                    // 先让用户看到「这次分数和最近的状态是什么关系」，
                    // 再给建议，顺序反了建议会显得没有来由。
                    if let combined = insight.combinedReading {
                        combinedReadingCard(combined)
                    }
                    if let action = insight.primaryAction {
                        primaryActionCard(action)
                    }
                    if !insight.secondaryActions.isEmpty {
                        secondaryActionsCard
                    }
                    if insight.recommendsProfessionalCare {
                        professionalCareCard
                    }
                }
                helpFooter
            }
            .padding(AppSpacing.lg)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.tr("评估结果"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.tr("完成")) { dismiss() }
                    .fontWeight(.semibold)
            }
        }
    }

    // MARK: - 三通道对照

    /// 三通道对照卡（共享组件，与主页同一份实现）。
    private func combinedReadingCard(_ reading: MentalHealthCombinedReading) -> some View {
        PsychCombinedReadingCard(reading: reading)
    }

    // MARK: - 分数卡

    private var scoreCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(scaleID.displayName)
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

            if let total = score.totalScore {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(total)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(AppColor.text)
                    Text("/ \(definition.maxTotalScore)")
                        .font(.subheadline)
                        .foregroundStyle(AppColor.secondaryText)
                }

                Text(score.completeness.isProrated
                     ? "筛查分（有一题未答，已折算） · 非诊断"
                     : "筛查分 · 非诊断")
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
            } else {
                // 数据不足：不猜，只说不足。
                Text(score.completeness.hasValidTotal ? "暂无分数" : "这次作答缺了 \(score.completeness.missingItemIndices.count) 道题，算不出可靠结果")
                    .font(.subheadline)
                    .foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(insight.headline)
                .font(.subheadline)
                .foregroundStyle(AppColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, AppSpacing.xs)

            // 双通道对照：只在两边都有数据时展示。
            if let physiology = HealthKitService.shared.pleasureEvaluation,
               score.totalScore != nil {
                HStack(spacing: AppSpacing.md) {
                    channelPill(title: "问卷说", value: bandLabel(insight.band))
                    channelPill(title: "身体说", value: physiology.stressLevel.badge)
                }
                .padding(.top, AppSpacing.xs)
            }
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    private func bandLabel(_ band: PsychBandLevel?) -> String {
        guard let band else { return "无法判定" }
        return band.displayName
    }

    private func channelPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(AppColor.secondaryText)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppColor.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.sm)
        .background(AppColor.fillTertiary, in: RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
    }

    private func bandColor(_ band: PsychBandLevel) -> Color {
        switch band {
        case .none: return AppColor.success
        case .mild: return AppColor.info
        case .moderate: return AppColor.warning
        case .moderatelySevere, .severe: return AppColor.danger
        }
    }

    // MARK: - 主动作

    private func primaryActionCard(_ action: PsychReliefAction) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(L10n.tr("现在，做一件小事"))
                .font(.caption)
                .foregroundStyle(AppColor.secondaryText)

            Text(PsychReliefCopy.title(for: action))
                .font(.headline)
                .foregroundStyle(AppColor.text)

            Text(PsychReliefCopy.detail(for: action))
                .font(.subheadline)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if action.isConvertibleToTodo {
                Button {
                    addTodo(for: action)
                } label: {
                    Label(addedTodoTitle == action.title ? "已加入待办" : "加入待办",
                          systemImage: addedTodoTitle == action.title ? "checkmark.circle.fill" : "plus.circle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(addedTodoTitle == action.title ? AppColor.success : AppColor.primary)
                }
                .buttonStyle(.plain)
                .padding(.top, AppSpacing.xs)
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous)
                .fill(AppColor.softFill(AppColor.primary))
        )
    }

    private func addTodo(for action: PsychReliefAction) {
        let dueAt = Date().addingTimeInterval(30 * 60)
        if PsychReliefTodoBuilder.createTodo(for: action, dueAt: dueAt, in: context) != nil {
            withAnimation(AppMotion.standardSpring) {
                addedTodoTitle = action.title
            }
        }
    }

    // MARK: - 备选动作

    private var secondaryActionsCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    ForEach(insight.secondaryActions, id: \.self) { action in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(PsychReliefCopy.title(for: action))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppColor.text)
                            Text(PsychReliefCopy.detail(for: action))
                                .font(.caption)
                                .foregroundStyle(AppColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            if action.isConvertibleToTodo {
                                Button {
                                    addTodo(for: action)
                                } label: {
                                    Text(addedTodoTitle == action.title ? "已加入待办" : "加入待办")
                                        .font(.caption)
                                        .foregroundStyle(AppColor.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, AppSpacing.sm)
                    }
                }
                .padding(.top, AppSpacing.sm)
            } label: {
                Text(L10n.tr("还可以试试"))
                    .font(.subheadline)
                    .foregroundStyle(AppColor.text)
            }
            .tint(AppColor.secondaryText)
        }
        .padding(AppSpacing.md)
        .appCard()
    }

    // MARK: - 专业支持

    private var professionalCareCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(L10n.tr("这些方法有它的边界"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppColor.text)
            Text(L10n.tr("自助方法能帮上忙，但有它做不到的部分。建议找专业的人聊聊 —— 那会更快，也更稳。"))
                .font(.caption)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous)
                .fill(AppColor.softFill(AppColor.warning))
        )
    }

    // MARK: - 危机

    private var crisisCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Label(L10n.tr("第 9 题的作答需要被认真对待"), systemImage: "lifepreserver.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColor.danger)

            Text(L10n.tr("你最近有过伤害自己的念头。无论总分是多少，这件事都值得找专业的人聊一聊。"))
                .font(.caption)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(insight.crisisResources) { resource in
                if let phone = resource.phoneNumber {
                    Link(destination: URL(string: "tel://\(phone)")!) {
                        HStack {
                            Image(systemName: "phone.fill")
                            Text(L10n.tr("拨打 \(phone)"))
                            Spacer()
                            Text(resource.title)
                                .font(.caption)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.sm)
                        .background(AppColor.danger, in: Capsule())
                    }
                }
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    // MARK: - 页脚求助

    private var helpFooter: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(L10n.tr("如果持续两周没有改善，或情况变重，可以联系全国心理援助热线。"))
                .font(.caption)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: URL(string: "tel://12356")!) {
                HStack(spacing: 6) {
                    Image(systemName: "phone.fill")
                    Text("12356")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(L10n.tr("24 小时 · 免费 · 保密"))
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
                .foregroundStyle(AppColor.primary)
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }
}
