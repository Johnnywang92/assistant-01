import AssistantCore
import SwiftData
import SwiftUI

/// 量表选择弹窗：选 PHQ-9 还是 GAD-7。
struct PsychScalePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 选中的量表。父视图监听它来 push 答题页。
    @Binding var selectedScale: PsychScaleID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    scaleRow(.phq9, detail: "9 题 · 关注情绪低落、失去兴趣、睡眠与精力")
                    scaleRow(.gad7, detail: "7 题 · 关注紧张、担忧与难以放松")
                } header: {
                    Text(L10n.tr("选择量表"))
                } footer: {
                    Text(L10n.tr("两项都做能得到更完整的画像。量表结果仅供自我了解参考，不构成医学诊断。"))
                }
            }
            .navigationTitle(L10n.tr("状态评估"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消")) { dismiss() }
                }
            }
        }
    }

    private func scaleRow(_ id: PsychScaleID, detail: String) -> some View {
        Button {
            selectedScale = id
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(id.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColor.text)
                    Text("\(id.chineseName) · \(detail)")
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 量表答题页：一题一屏，逐题推进。
///
/// 题面**逐字采用量表原文**，不改写、不合并、不删减——
/// 改一个字，量表的效度就不再成立。
struct PsychScaleTestView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let scaleID: PsychScaleID

    @State private var currentIndex = 0
    @State private var answers: [Int: PsychItemAnswer] = [:]
    @State private var showCrisis = false
    /// 提交后切到结果视图，而不是直接关闭——用户填完 9 题却什么反馈都没有，
    /// 会让「追踪」这件事失去意义。
    @State private var showResult = false

    private var definition: PsychScaleDefinition {
        PsychScaleCatalog.definition(for: scaleID)
    }

    private var currentItem: PsychScaleItem? {
        definition.item(at: currentIndex + 1)
    }

    private var progress: Double {
        Double(currentIndex) / Double(max(definition.itemCount, 1))
    }

    var body: some View {
        Group {
            if showResult {
                PsychScaleResultView(scaleID: scaleID, answers: answers)
            } else {
                questionnaireBody
            }
        }
        .sheet(isPresented: $showCrisis) {
            PsychCrisisSheet()
                .interactiveDismissDisabled()
        }
    }

    private var questionnaireBody: some View {
        VStack(spacing: 0) {
            progressHeader

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    if let item = currentItem {
                        Text(item.prompt)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(AppColor.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(L10n.tr("过去两周"))
                            .font(.caption)
                            .foregroundStyle(AppColor.secondaryText)

                        optionsList(for: item)
                    }
                }
                .padding(AppSpacing.lg)
            }

            bottomBar
        }
        .navigationTitle(showResult ? "" : scaleID.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !showResult {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("退出")) { dismiss() }
                        .foregroundStyle(AppColor.secondaryText)
                }
            }
        }
    }

    // MARK: - 顶部进度

    private var progressHeader: some View {
        VStack(spacing: AppSpacing.sm) {
            HStack {
                Text(L10n.tr("第 \(currentIndex + 1) / \(definition.itemCount) 题"))
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
                Spacer()
                Text(L10n.tr("约 \(Int(ceil(Double(definition.itemCount - currentIndex) * 0.12))) 分钟"))
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppColor.fillTertiary)
                    Capsule()
                        .fill(AppColor.primary)
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
    }

    // MARK: - 选项

    private func optionsList(for item: PsychScaleItem) -> some View {
        VStack(spacing: AppSpacing.sm) {
            ForEach(PsychResponseOptions.standard) { option in
                Button {
                    select(option.score, for: item)
                } label: {
                    HStack(spacing: AppSpacing.md) {
                        Image(systemName: answers[item.index]?.score == option.score
                              ? "largecircle.fill.circle"
                              : "circle")
                            .font(.title3)
                            .foregroundStyle(answers[item.index]?.score == option.score
                                             ? AppColor.primary
                                             : AppColor.secondaryText)
                        Text(option.label)
                            .font(.body)
                            .foregroundStyle(AppColor.text)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, AppSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .fill(answers[item.index]?.score == option.score
                                  ? AppColor.softFill(AppColor.primary)
                                  : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func select(_ score: Int, for item: PsychScaleItem) {
        answers[item.index] = .answered(score: score)
        // 选中后自动推进到下一题，减少一次点击。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            advance()
        }
    }

    // MARK: - 底部操作

    private var bottomBar: some View {
        HStack {
            Button {
                answers[currentIndex + 1] = .unanswered
                advance()
            } label: {
                Text(L10n.tr("跳过这题"))
                    .font(.subheadline)
                    .foregroundStyle(AppColor.secondaryText)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                advance()
            } label: {
                Text(currentIndex + 1 >= definition.itemCount ? "完成" : "下一题")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColor.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .background(.thinMaterial)
    }

    // MARK: - 推进与提交

    private func advance() {
        if currentIndex + 1 >= definition.itemCount {
            submit()
        } else {
            currentIndex += 1
        }
    }

    private func submit() {
        // 落库。
        PsychRecordStore.save(
            scaleID: scaleID,
            answers: answers,
            in: context
        )

        // 危机信号**独立于总分与完整性**判定。
        // 即使其余题全未作答，只要安全题有非零作答就必须弹危机响应。
        if PsychSafetyRouter.requiresCrisisResponse(
            answers: answers,
            definition: definition
        ) {
            showCrisis = true
        } else {
            showResult = true
        }
    }
}

/// 危机响应弹窗。
///
/// **App 不是唯一出口**：必须给出官方热线与急救号码，并说清楚 App 不能替代专业帮助。
struct PsychCrisisSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hasCalled = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Image(systemName: "lifepreserver.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(AppColor.danger)
                        Text(L10n.tr("你愿意说出来，这很重要"))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(AppColor.text)
                        Text(L10n.tr("第 9 题的作答说明你最近有过伤害自己的念头。这需要被认真对待 —— 无论你现在感觉如何，也无论总分是多少。"))
                            .font(.subheadline)
                            .foregroundStyle(AppColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: AppSpacing.md) {
                        ForEach(PsychHelpResources.crisisResources) { resource in
                            resourceCard(resource)
                        }
                    }

                    Text(L10n.tr("这个 App 不能替代专业帮助。它能做的是记录、提醒你关注自己，并在你需要时把求助的路径指出来。"))
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, AppSpacing.sm)
                }
                .padding(AppSpacing.lg)
            }
            .navigationTitle(L10n.tr("需要你重视"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("我知道了")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func resourceCard(_ resource: PsychHelpResource) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(resource.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColor.text)
            Text(resource.detail)
                .font(.caption)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let phone = resource.phoneNumber {
                Button {
                    hasCalled = true
                } label: {
                    HStack {
                        Image(systemName: "phone.fill")
                        Text(L10n.tr("拨打 \(phone)"))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.sm)
                    .background(AppColor.danger, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }
}
